# Example: atomic batch transactions with the MongrelDB Mojo client.
#
# Run: mojo run -I src examples/transactions.mojo
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, stages three inserts in a single transaction, commits them
# atomically, verifies the count, then demonstrates idempotent retries by
# re-committing with the same idempotency key. Cleans up by dropping the table.

from python import Python, PythonObject
from mongreldb import MongrelDB


fn main() raises:
    var url = "http://127.0.0.1:8453"
    var time_module = Python.import_module("time")
    var suffix = String(Int(time_module.time())) + "_" + String(Int(time_module.time_ns() & 0xFFFFFF))
    var table = "example_txn_" + suffix
    var idempotency_key = "example-txn-" + suffix

    var db = MongrelDB(url)
    if not db.health():
        print("daemon not reachable at " + url)
        return
    print("Connected to MongrelDB")

    try:
        var columns = Python.list()
        columns.append(_col(1, "id", "int64", primary_key=True))
        columns.append(_col(2, "name", "varchar"))
        columns.append(_col(3, "score", "float64"))
        _ = db.create_table(table, columns)
        print("Created table " + table)

        var txn = db.begin()
        _ = txn.put(table, _cells3(1, 1, 2, "Alice", 3, 95.5))
        _ = txn.put(table, _cells3(1, 2, 2, "Bob", 3, 82.0))
        _ = txn.put(table, _cells3(1, 3, 2, "Carol", 3, 78.3))
        print("Staged " + String(txn.count()) + " operations")

        var results = txn.commit()
        print("Committed atomically: " + String(len(results)) + " operations applied")
        print("Verified row count after commit: " + String(db.count(table)))

        # Idempotent retry: same key on a second identical commit; the daemon
        # replays the original result and applies no extra rows.
        var retry1 = db.begin()
        _ = retry1.put(table, _cells3(1, 4, 2, "Dave", 3, 60.0))
        _ = retry1.commit(idempotency_key)
        print("After first idempotent commit: " + String(db.count(table)) + " rows")

        var retry2 = db.begin()
        _ = retry2.put(table, _cells3(1, 4, 2, "Dave", 3, 60.0))
        _ = retry2.commit(idempotency_key)
        print("After duplicate idempotent commit (same key): " + String(db.count(table)) + " rows (no double-apply)")
    finally:
        try:
            db.drop_table(table)
        except:
            pass
        print("Dropped table " + table)


def _col(col_id: Int, name: String, ty: String, *, primary_key: Bool = False) -> PythonObject:
    c = Python.dict()
    c["id"] = col_id
    c["name"] = name
    c["ty"] = ty
    c["primary_key"] = primary_key
    c["nullable"] = False
    return c


def _cells3(
    k1: PythonObject, v1: PythonObject,
    k2: PythonObject, v2: PythonObject,
    k3: PythonObject, v3: PythonObject,
) -> PythonObject:
    d = Python.dict()
    d[k1] = v1
    d[k2] = v2
    d[k3] = v3
    return d
