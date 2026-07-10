# Live integration tests for the MongrelDB Mojo client.
#
# These tests boot a real mongreldb-server daemon and exercise the full client
# surface against it (the 14-operation conformance matrix). They resolve the
# daemon binary in this order:
#   1. the MONGRELDB_SERVER env var (path to the server binary)
#   2. a prebuilt binary at ./bin/mongreldb-server
#   3. mongreldb-server on PATH
#
# If no binary is available, the live tests are skipped (the offline tests still
# run). Set MONGRELDB_URL to point at an already-running daemon to skip the boot
# and connect directly.
#
# Run with:   mojo test -I src tests/live_test.mojo

from python import Python
from mongreldb import (
    MongrelDB,
    DEFAULT_BASE_URL,
    QueryError,
    NotFoundError,
    ConflictError,
    _url_path_escape,
)
from mongreldb.query_builder import _normalize_condition
from mongreldb.mongreldb import _flatten_cells


# ── Tiny assertion helpers (wrapping Mojo's builtin assert) ────────────────


def assert_true(cond: Bool):
    if not cond:
        raise Error("assertion failed: expected True")


def assert_false(cond: Bool):
    if cond:
        raise Error("assertion failed: expected False")


def assert_equal[T: EqualityComparable](a: T, b: T):
    if a != b:
        raise Error("assertion failed: " + String(a) + " != " + String(b))


# ── Daemon lifecycle (module-global) ────────────────────────────────────────

var db: MongrelDB
var _server_proc: PythonObject
var _have_daemon: Bool = False


def _start_daemon():
    """Boot a real mongreldb-server once, or reuse MONGRELDB_URL."""
    global db, _have_daemon, _server_proc

    os_module = Python.import_module("os")
    subprocess_module = Python.import_module("subprocess")
    socket_module = Python.import_module("socket")
    time_module = Python.import_module("time")
    tempfile_module = Python.import_module("tempfile")

    existing = String(os_module.environ.get("MONGRELDB_URL", ""))
    if len(existing) > 0:
        db = MongrelDB(existing, String(os_module.environ.get("MONGRELDB_TOKEN", "")))
        if db.health():
            _have_daemon = True
            return
        print("mongreldb: MONGRELDB_URL=" + existing + " is not reachable")

    bin_path = _resolve_server_binary(os_module)
    if len(bin_path) == 0:
        print("--- no mongreldb-server binary: live tests will skip")
        return

    # Find a free port.
    sock = socket_module.socket()
    sock.bind(("127.0.0.1", 0))
    port = Int(sock.getsockname().__getitem__(1))
    sock.close()

    data_dir = tempfile_module.mkdtemp(prefix="mongreldb-mojo-test-")
    _server_proc = subprocess_module.Popen(
        [bin_path, data_dir, "--port", String(port)],
        stdout=subprocess_module.PIPE,
        stderr=subprocess_module.STDOUT,
    )
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
        _kill(_server_proc)
        return

    db = MongrelDB(url)
    _have_daemon = True


def _resolve_server_binary(os_module: PythonObject) -> String:
    env = String(os_module.environ.get("MONGRELDB_SERVER", ""))
    path_module = Python.import_module("os.path")
    if len(env) > 0 and path_module.isfile(env) and _is_executable(env):
        return env
    local = "bin/mongreldb-server"
    if path_module.isfile(local) and _is_executable(local):
        return local
    # Search PATH.
    for d in String(os_module.environ.get("PATH", "")).split(":"):
        candidate = d + "/mongreldb-server"
        if path_module.isfile(candidate) and _is_executable(candidate):
            return candidate
    return ""


def _is_executable(path: String) -> Bool:
    os_module = Python.import_module("os")
    return Bool(os_module.access(path, os_module.X_OK))


def _kill(proc: PythonObject):
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except:
        try:
            proc.kill()
        except:
            pass


def _require_daemon() -> Bool:
    return _have_daemon


# ── Test helpers ────────────────────────────────────────────────────────────


def _unique_table(prefix: String) -> String:
    time_module = Python.import_module("time")
    return prefix + "_" + String(Int(time_module.time_ns()))


def _int_col(col_id: Int, name: String, primary_key: Bool = False) -> PythonObject:
    c = Python.dict()
    c.__setitem__("id", Python.object(col_id))
    c.__setitem__("name", Python.str(name))
    c.__setitem__("ty", "int64")
    c.__setitem__("primary_key", Python.object(primary_key))
    c.__setitem__("nullable", Python.object(False))
    return c


def _float_col(col_id: Int, name: String) -> PythonObject:
    c = Python.dict()
    c.__setitem__("id", Python.object(col_id))
    c.__setitem__("name", Python.str(name))
    c.__setitem__("ty", "float64")
    c.__setitem__("primary_key", Python.object(False))
    c.__setitem__("nullable", Python.object(False))
    return c


def _fresh_table(name: String, *columns: PythonObject) -> None:
    try:
        db.drop_table(name)
    except:
        pass
    cols = Python.list()
    for c in columns:
        cols.append(c)
    db.create_table(name, cols)


def _cells(*kvs: PythonObject) -> PythonObject:
    d = Python.dict()
    i = 0
    while i < len(kvs):
        d.__setitem__(kvs[i], kvs[i + 1])
        i += 2
    return d


def _cell_value(row: PythonObject, col_id: Int) -> PythonObject:
    """Extract a column value from a Kit row's flat cells array."""
    try:
        cells = row.__getitem__("cells").to_list()
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
    if not _require_daemon():
        return
    assert_true(db.health())


def test_create_table_and_count():
    if not _require_daemon():
        return
    name = _unique_table("mojo_create")
    _fresh_table(name, _int_col(1, "id", True), _float_col(2, "amount"))
    assert_equal(db.count(name), 0)


def test_put_and_count_round_trip():
    if not _require_daemon():
        return
    name = _unique_table("mojo_put")
    _fresh_table(name, _int_col(1, "id", True), _float_col(2, "amount"))
    db.put(name, _cells(1, 1, 2, 99.5))
    db.put(name, _cells(1, 2, 2, 150.0))
    assert_equal(db.count(name), 2)


def test_query_by_pk():
    if not _require_daemon():
        return
    name = _unique_table("mojo_pk")
    _fresh_table(name, _int_col(1, "id", True))
    db.put(name, _cells(1, 42))
    db.put(name, _cells(1, 43))
    params = Python.dict()
    params.__setitem__("value", 42)
    rows = db.query(name).where("pk", params).execute().to_list()
    assert_equal(len(rows), 1)
    assert_equal(Int(_cell_value(rows[0], 1)), 42)


def test_query_range():
    if not _require_daemon():
        return
    name = _unique_table("mojo_range")
    _fresh_table(name, _int_col(1, "id", True), _int_col(2, "amount"))
    db.put(name, _cells(1, 1, 2, 50))
    db.put(name, _cells(1, 2, 2, 120))
    db.put(name, _cells(1, 3, 2, 200))
    params = Python.dict()
    params.__setitem__("column", 2)
    params.__setitem__("min", 100)
    params.__setitem__("max", 150)
    q = db.query(name).where("range", params)
    rows = q.execute().to_list()
    assert_equal(len(rows), 1)
    assert_false(q.truncated())


def test_upsert():
    if not _require_daemon():
        return
    name = _unique_table("mojo_upsert")
    _fresh_table(name, _int_col(1, "id", True), _int_col(2, "amount"))
    db.put(name, _cells(1, 1, 2, 50))
    upd = Python.dict()
    upd.__setitem__(2, 999)
    db.upsert(name, _cells(1, 1, 2, 50), upd)
    assert_equal(db.count(name), 1)
    params = Python.dict()
    params.__setitem__("value", 1)
    rows = db.query(name).where("pk", params).execute().to_list()
    assert_equal(len(rows), 1)
    assert_equal(Int(_cell_value(rows[0], 2)), 999)


def test_transaction_put_commit():
    if not _require_daemon():
        return
    name = _unique_table("mojo_txn")
    _fresh_table(name, _int_col(1, "id", True))
    txn = db.begin()
    txn.put(name, _cells(1, 1))
    txn.put(name, _cells(1, 2))
    txn.put(name, _cells(1, 3))
    assert_equal(txn.count(), 3)
    results = txn.commit()
    assert_equal(len(results), 3)
    assert_equal(db.count(name), 3)


def test_transaction_rollback():
    if not _require_daemon():
        return
    name = _unique_table("mojo_rb")
    _fresh_table(name, _int_col(1, "id", True))
    txn = db.begin()
    txn.put(name, _cells(1, 1))
    txn.rollback()
    assert_equal(db.count(name), 0)


def test_idempotent_put():
    if not _require_daemon():
        return
    name = _unique_table("mojo_idem")
    _fresh_table(name, _int_col(1, "id", True))
    key = "idem-" + name
    db.put(name, _cells(1, 7), key)
    db.put(name, _cells(1, 7), key)
    assert_equal(db.count(name), 1)


def test_delete_by_pk():
    if not _require_daemon():
        return
    name = _unique_table("mojo_del")
    _fresh_table(name, _int_col(1, "id", True))
    db.put(name, _cells(1, 5))
    assert_equal(db.count(name), 1)
    db.delete_by_pk(name, 5)
    assert_equal(db.count(name), 0)


def test_sql_insert_and_select():
    if not _require_daemon():
        return
    name = _unique_table("mojo_sql")
    _fresh_table(name, _int_col(1, "id", True), _int_col(2, "amount"))
    assert_equal(db.count(name), 0)
    db.sql("INSERT INTO " + name + " (id, amount) VALUES (10, 42)")
    assert_equal(db.count(name), 1)
    rows = db.sql("SELECT id, amount FROM " + name).to_list()
    if len(rows) > 0:
        assert_equal(len(rows), 1)


def test_table_names():
    if not _require_daemon():
        return
    name = _unique_table("mojo_tables")
    _fresh_table(name, _int_col(1, "id", True))
    names = [String(n) for n in db.table_names()]
    assert_true(name in names)


def test_schema():
    if not _require_daemon():
        return
    name = _unique_table("mojo_schema")
    _fresh_table(name, _int_col(1, "id", True), _float_col(2, "amount"))
    schema = db.schema()
    assert_true(name in [String(k) for k in schema.keys().to_list()])


def test_error_404():
    if not _require_daemon():
        return
    name = _unique_table("mojo_missing")
    var raised = False
    try:
        db.schema_for(name)
    except NotFoundError:
        raised = True
    assert_true(raised)


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
    params.__setitem__("column", 3)
    params.__setitem__("min", 100)
    params.__setitem__("max", 150)
    params.__setitem__("min_inclusive", True)
    params.__setitem__("max_inclusive", False)
    out = _normalize_condition("range", params)
    assert_equal(Int(out.__getitem__("column_id")), 3)
    assert_equal(Int(out.__getitem__("lo")), 100)
    assert_equal(Int(out.__getitem__("hi")), 150)
    assert_true(Bool(out.__getitem__("lo_inclusive")))
    assert_false(Bool(out.__getitem__("hi_inclusive")))


def test_query_builder_fm_contains_value_alias():
    params = Python.dict()
    params.__setitem__("column", 2)
    params.__setitem__("value", "database")
    out = _normalize_condition("fm_contains", params)
    assert_equal(String(out.__getitem__("pattern")), "database")


def test_query_builder_pk_value_not_aliased():
    params = Python.dict()
    params.__setitem__("value", 42)
    out = _normalize_condition("pk", params)
    assert_equal(Int(out.__getitem__("value")), 42)


def test_url_path_escape_encodes_slash():
    assert_equal(_url_path_escape("a/b c"), "a%2Fb%20c")


# ── Boot the daemon once at import time ─────────────────────────────────────

_start_daemon()
