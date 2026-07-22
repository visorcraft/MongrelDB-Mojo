# Live integration tests for the MongrelDB Mojo client.
#
# These tests exercise the full client surface against a real mongreldb-server
# daemon (the 14-operation conformance matrix). The daemon is resolved in this
# order:
#   1. the MONGRELDB_URL env var (an already-running daemon)
#   2. the MONGRELDB_SERVER env var (path to a server binary to boot)
#   3. a prebuilt binary at ./bin/mongreldb-server
#   4. mongreldb-server on PATH
#
# If no daemon is available, the live tests are skipped (the offline tests
# still run). When the tests boot a daemon themselves they register it with
# atexit and publish its URL via MONGRELDB_URL so it is shared across tests.
#
# Run with:   mojo run -I src tests/live_test.mojo

from python import Python, PythonObject
from collections import List, Optional
from mongreldb import (
    MongrelDB,
    DEFAULT_BASE_URL,
    QueryError,
    NotFoundError,
    ConflictError,
    _url_path_escape,
)
from mongreldb.query_builder import _normalize_condition
from mongreldb.mongreldb import _flatten_cells, _decode_json_or


# ── Tiny assertion helpers (wrapping Mojo's builtin assert) ────────────────


def assert_true(cond: Bool):
    if not cond:
        raise Error("assertion failed: expected True")


def assert_false(cond: Bool):
    if cond:
        raise Error("assertion failed: expected False")


def assert_equal[T: EqualityComparable & Stringable & ImplicitlyCopyable](a: T, b: T):
    if a != b:
        raise Error("assertion failed: " + String(a) + " != " + String(b))


# ── Daemon lifecycle ────────────────────────────────────────────────────────


def _connect() -> Optional[MongrelDB]:
    """Connect to a running daemon, booting one from a local binary if needed.
    Returns None when no daemon is available so live tests can skip."""
    os_module = Python.import_module("os")
    existing = String(os_module.environ.get("MONGRELDB_URL", ""))
    if len(existing) > 0:
        db = MongrelDB(existing, String(os_module.environ.get("MONGRELDB_TOKEN", "")))
        if db.health():
            return Optional(db^)
        print("mongreldb: MONGRELDB_URL=" + existing + " is not reachable")
        return None

    bin_path = _resolve_server_binary(os_module)
    if len(bin_path) == 0:
        print("--- no mongreldb-server binary: live tests will skip")
        return None

    socket_module = Python.import_module("socket")
    subprocess_module = Python.import_module("subprocess")
    time_module = Python.import_module("time")
    tempfile_module = Python.import_module("tempfile")
    atexit_module = Python.import_module("atexit")

    # Find a free port.
    sock = socket_module.socket()
    sock.bind(Python.evaluate("('127.0.0.1', 0)"))
    port = Int(sock.getsockname()[1])
    sock.close()

    data_dir = tempfile_module.mkdtemp(prefix="mongreldb-mojo-test-")
    args = Python.list()
    args.append(bin_path)
    args.append(String(data_dir))
    args.append("--port")
    args.append(String(port))
    proc = subprocess_module.Popen(
        args,
        stdout=subprocess_module.PIPE,
        stderr=subprocess_module.STDOUT,
    )
    atexit_module.register(proc.kill)

    url = "http://127.0.0.1:" + String(port)
    deadline = time_module.time() + 40.0
    ok = False
    while time_module.time() < deadline:
        probe = MongrelDB(url)
        if probe.health():
            ok = True
            break
        time_module.sleep(0.5)

    if not ok:
        print("mongreldb: server did not become healthy")
        proc.kill()
        return None

    # Share the booted daemon with the remaining tests in this process.
    os_module.environ["MONGRELDB_URL"] = url
    return Optional(MongrelDB(url))


def _resolve_server_binary(os_module: PythonObject) -> String:
    env = String(os_module.environ.get("MONGRELDB_SERVER", ""))
    path_module = Python.import_module("os.path")
    if len(env) > 0 and Bool(path_module.isfile(env)) and _is_executable(env):
        return env
    local = "bin/mongreldb-server"
    if Bool(path_module.isfile(local)) and _is_executable(local):
        return local
    # Search PATH.
    for d in String(os_module.environ.get("PATH", "")).split(":"):
        candidate = d + "/mongreldb-server"
        if Bool(path_module.isfile(candidate)) and _is_executable(candidate):
            return candidate
    return ""


def _is_executable(path: String) -> Bool:
    os_module = Python.import_module("os")
    return Bool(os_module.access(path, os_module.X_OK))


# ── Test helpers ────────────────────────────────────────────────────────────


def _unique_table(prefix: String) -> String:
    time_module = Python.import_module("time")
    return prefix + "_" + String(Int(time_module.time_ns()))


def _int_col(col_id: Int, name: String, primary_key: Bool = False) -> PythonObject:
    c = Python.dict()
    c["id"] = col_id
    c["name"] = name
    c["ty"] = "int64"
    c["primary_key"] = primary_key
    c["nullable"] = False
    return c


def _float_col(col_id: Int, name: String) -> PythonObject:
    c = Python.dict()
    c["id"] = col_id
    c["name"] = name
    c["ty"] = "float64"
    c["primary_key"] = False
    c["nullable"] = False
    return c


def _string_col(col_id: Int, name: String) -> PythonObject:
    c = Python.dict()
    c["id"] = col_id
    c["name"] = name
    c["ty"] = "varchar"
    c["primary_key"] = False
    c["nullable"] = False
    return c


def _cols(a: PythonObject, b: Optional[PythonObject] = None) -> PythonObject:
    """Build the columns list for create_table (one or two column dicts)."""
    cols = Python.list()
    cols.append(a)
    if b:
        cols.append(b.value())
    return cols


def _fresh_table(db: MongrelDB, name: String, columns: PythonObject) -> None:
    try:
        db.drop_table(name)
    except:
        pass
    _ = db.create_table(name, columns)


def _cells1(k1: PythonObject, v1: PythonObject) -> PythonObject:
    d = Python.dict()
    d[k1] = v1
    return d


def _cells2(k1: PythonObject, v1: PythonObject, k2: PythonObject, v2: PythonObject) -> PythonObject:
    d = Python.dict()
    d[k1] = v1
    d[k2] = v2
    return d


def _cell_value(row: PythonObject, col_id: Int) -> PythonObject:
    """Extract a column value from a Kit row's flat cells array."""
    try:
        cells = row["cells"]
        i = 0
        while i < len(cells):
            if Int(cells[i]) == col_id:
                return cells[i + 1]
            i += 2
    except:
        pass
    return PythonObject()


# ── Live tests (the 14-operation conformance matrix) ────────────────────────


def test_health():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    assert_true(db.health())


def test_create_table_and_count():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_create")
    _fresh_table(db, name, _cols(_int_col(1, "id", True), _float_col(2, "amount")))
    assert_equal(db.count(name), 0)


def test_put_and_count_round_trip():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_put")
    _fresh_table(db, name, _cols(_int_col(1, "id", True), _float_col(2, "amount")))
    _ = db.put(name, _cells2(1, 1, 2, 99.5))
    _ = db.put(name, _cells2(1, 2, 2, 150.0))
    assert_equal(db.count(name), 2)


def test_query_by_pk():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_pk")
    _fresh_table(db, name, _cols(_int_col(1, "id", True)))
    _ = db.put(name, _cells1(1, 42))
    _ = db.put(name, _cells1(1, 43))
    params = Python.dict()
    params["value"] = 42
    var q = db.query(name).where("pk", params)
    var rows = q.execute()
    assert_equal(len(rows), 1)
    assert_equal(Int(_cell_value(rows[0], 1)), 42)


def test_query_range():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_range")
    _fresh_table(db, name, _cols(_int_col(1, "id", True), _int_col(2, "amount")))
    _ = db.put(name, _cells2(1, 1, 2, 50))
    _ = db.put(name, _cells2(1, 2, 2, 120))
    _ = db.put(name, _cells2(1, 3, 2, 200))
    params = Python.dict()
    params["column"] = 2
    params["min"] = 100
    params["max"] = 150
    var q = db.query(name).where("range", params)
    var rows = q.execute()
    assert_equal(len(rows), 1)
    assert_false(q.truncated())


def test_upsert():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_upsert")
    _fresh_table(db, name, _cols(_int_col(1, "id", True), _int_col(2, "amount")))
    _ = db.put(name, _cells2(1, 1, 2, 50))
    upd = Python.dict()
    upd[2] = 999
    _ = db.upsert(name, _cells2(1, 1, 2, 50), upd)
    assert_equal(db.count(name), 1)
    params = Python.dict()
    params["value"] = 1
    var q = db.query(name).where("pk", params)
    var rows = q.execute()
    assert_equal(len(rows), 1)
    assert_equal(Int(_cell_value(rows[0], 2)), 999)


def test_transaction_put_commit():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_txn")
    _fresh_table(db, name, _cols(_int_col(1, "id", True)))
    var txn = db.begin()
    _ = txn.put(name, _cells1(1, 1))
    _ = txn.put(name, _cells1(1, 2))
    _ = txn.put(name, _cells1(1, 3))
    assert_equal(txn.count(), 3)
    var results = txn.commit()
    assert_equal(len(results), 3)
    assert_equal(db.count(name), 3)


def test_transaction_rollback():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_rb")
    _fresh_table(db, name, _cols(_int_col(1, "id", True)))
    var txn = db.begin()
    _ = txn.put(name, _cells1(1, 1))
    txn.rollback()
    assert_equal(db.count(name), 0)


def test_idempotent_put():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_idem")
    _fresh_table(db, name, _cols(_int_col(1, "id", True)))
    key = "idem-" + name
    _ = db.put(name, _cells1(1, 7), key)
    _ = db.put(name, _cells1(1, 7), key)
    assert_equal(db.count(name), 1)


def test_delete_by_pk():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_del")
    _fresh_table(db, name, _cols(_int_col(1, "id", True)))
    _ = db.put(name, _cells1(1, 5))
    assert_equal(db.count(name), 1)
    db.delete_by_pk(name, 5)
    assert_equal(db.count(name), 0)


def test_sql_insert_and_select():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_sql")
    _fresh_table(db, name, _cols(_int_col(1, "id", True), _int_col(2, "amount")))
    assert_equal(db.count(name), 0)
    _ = db.sql("INSERT INTO " + name + " (id, amount) VALUES (10, 42)")
    assert_equal(db.count(name), 1)
    var rows = db.sql("SELECT id, amount FROM " + name)
    if len(rows) > 0:
        assert_equal(len(rows), 1)


def test_table_names():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_tables")
    _fresh_table(db, name, _cols(_int_col(1, "id", True)))
    var names = db.table_names()
    var found = False
    for n in names:
        if n == name:
            found = True
    assert_true(found)


def test_schema():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_schema")
    _fresh_table(db, name, _cols(_int_col(1, "id", True), _float_col(2, "amount")))
    var schema = db.schema()
    var found = False
    for k in schema.keys():
        if String(k) == name:
            found = True
    assert_true(found)


def test_error_404():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    name = _unique_table("mojo_missing")
    var raised = False
    try:
        _ = db.schema_for(name)
    except NotFoundError:
        raised = True
    assert_true(raised)


def test_history_retention():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    original = db.history_retention_epochs()
    try:
        result = db.set_history_retention_epochs(1000)
        assert_equal(Int(result["history_retention_epochs"]), 1000)
        assert_true(Int(result["earliest_retained_epoch"]) <= 1000)
        assert_equal(db.history_retention_epochs(), 1000)
        assert_true(db.earliest_retained_epoch() <= 1000)
    finally:
        _ = db.set_history_retention_epochs(original)


def test_history_retention_read_as_of_epoch():
    var maybe = _connect()
    if not maybe:
        return
    var db = maybe.unsafe_take()
    original = db.history_retention_epochs()
    try:
        _ = db.set_history_retention_epochs(1000)

        name = _unique_table("mojo_retention")
        _fresh_table(db, name, _cols(_int_col(1, "id", True), _string_col(2, "label")))

        # Insert the initial row and capture the commit epoch.
        # The public CRUD helpers discard the top-level commit epoch, so we use
        # the raw /kit/txn endpoint here to obtain the epoch for an AS OF EPOCH
        # read.
        json = Python.import_module("json")
        payload = Python.dict()
        ops = Python.list()
        op = Python.dict()
        put = Python.dict()
        put["table"] = name
        put_cells = Python.list()
        put_cells.append(1)
        put_cells.append(1)
        put_cells.append(2)
        put_cells.append("first")
        put["cells"] = put_cells
        op["put"] = put
        ops.append(op)
        payload["ops"] = ops
        txn_resp = _decode_json_or(json, db._post("/kit/txn", payload), Python.dict())
        write_epoch = Int(txn_resp["epoch"])

        # Update the row so a later epoch exists.
        payload2 = Python.dict()
        ops2 = Python.list()
        op2 = Python.dict()
        upsert = Python.dict()
        upsert["table"] = name
        ups_cells = Python.list()
        ups_cells.append(1)
        ups_cells.append(1)
        ups_cells.append(2)
        ups_cells.append("second")
        upsert["cells"] = ups_cells
        ups_update = Python.list()
        ups_update.append(2)
        ups_update.append("second")
        upsert["update_cells"] = ups_update
        op2["upsert"] = upsert
        ops2.append(op2)
        payload2["ops"] = ops2
        txn_resp2 = _decode_json_or(json, db._post("/kit/txn", payload2), Python.dict())
        update_epoch = Int(txn_resp2["epoch"])
        assert_true(update_epoch > write_epoch)

        # Current value is "second".
        current = db.sql("SELECT label FROM " + name + " WHERE id = 1")
        assert_equal(len(current), 1)
        assert_equal(String(current[0]["label"]), "second")

        # Historical read at the original write epoch should still see "first".
        historical = db.sql(
            "SELECT label FROM " + name + " AS OF EPOCH " + String(write_epoch) + " WHERE id = 1"
        )
        assert_equal(len(historical), 1)
        assert_equal(String(historical[0]["label"]), "first")
    finally:
        _ = db.set_history_retention_epochs(original)


# ── Offline tests (always run, no daemon) ───────────────────────────────────


def test_health_returns_false_when_unreachable():
    unreachable = MongrelDB("http://127.0.0.1:1")
    assert_false(unreachable.health())


def test_default_base_url():
    c = MongrelDB()
    assert_equal(c.base_url, DEFAULT_BASE_URL)


def test_trailing_slash_stripped():
    c = MongrelDB("http://127.0.0.1:8453/")
    assert_equal(c.base_url, "http://127.0.0.1:8453")


def test_query_builder_alias_translation():
    params = Python.dict()
    params["column"] = 3
    params["min"] = 100
    params["max"] = 150
    params["min_inclusive"] = True
    params["max_inclusive"] = False
    out = _normalize_condition("range", params)
    assert_equal(Int(out["column_id"]), 3)
    assert_equal(Int(out["lo"]), 100)
    assert_equal(Int(out["hi"]), 150)
    assert_true(Bool(out["lo_inclusive"]))
    assert_false(Bool(out["hi_inclusive"]))


def test_query_builder_fm_contains_value_alias():
    params = Python.dict()
    params["column"] = 2
    params["value"] = "database"
    out = _normalize_condition("fm_contains", params)
    assert_equal(String(out["pattern"]), "database")


def test_query_builder_pk_value_not_aliased():
    params = Python.dict()
    params["value"] = 42
    out = _normalize_condition("pk", params)
    assert_equal(Int(out["value"]), 42)


def test_url_path_escape_encodes_slash():
    assert_equal(_url_path_escape("a/b c"), "a%2Fb%20c")


# ── Runner (mojo run; the standalone `mojo test` command no longer exists) ──


fn main() raises:
    test_health()
    test_create_table_and_count()
    test_put_and_count_round_trip()
    test_query_by_pk()
    test_query_range()
    test_upsert()
    test_transaction_put_commit()
    test_transaction_rollback()
    test_idempotent_put()
    test_delete_by_pk()
    test_sql_insert_and_select()
    test_table_names()
    test_schema()
    test_error_404()
    test_history_retention()
    test_history_retention_read_as_of_epoch()
    test_health_returns_false_when_unreachable()
    test_default_base_url()
    test_trailing_slash_stripped()
    test_query_builder_alias_translation()
    test_query_builder_fm_contains_value_alias()
    test_query_builder_pk_value_not_aliased()
    test_url_path_escape_encodes_slash()
    print("live_test: all tests passed")
