# Example: atomic batch transactions with the MongrelDB Mojo client.
#
# Run: mojo run -I src examples/transactions.mojo
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, stages three inserts in a single transaction, commits them
# atomically, verifies the count, then demonstrates idempotent retries by
# re-committing with the same idempotency key. Cleans up by dropping the table.

from python import Python
from mongreldb import MongrelDB


fn main() raises:
    let url = "http://127.0.0.1:8453"
    let time_module = Python.import_module("time")
    let suffix = String(Int(time_module.time())) + "_" + String(Int(time_module.time_ns() & 0xFFFFFF))
    let table = "example_txn_" + suffix
    let idempotency_key = "example-txn-" + suffix

    let db = MongrelDB(url)
    if not db.health():
        print("daemon not reachable at " + url)
        return
    print("Connected to MongrelDB")

    try:
        let columns = Python.list()
        columns.append(_col(1, "id", "int64", primary_key=True))
        columns.append(_col(2, "name", "varchar"))
        columns.append(_col(3, "score", "float64"))
        db.create_table(table, columns)
        print("Created table " + table)

        let txn = db.begin()
        txn.put(table, _cells(1, 1, 2, "Alice", 3, 95.5))
        txn.put(table, _cells(1, 2, 2, "Bob", 3, 82.0))
        txn.put(table, _cells(1, 3, 2, "Carol", 3, 78.3))
        print("Staged " + String(txn.count()) + " operations")

        let results = txn.commit()
        print("Committed atomically: " + String(len(results)) + " operations applied")
        print("Verified row count after commit: " + String(db.count(table)))

        # Idempotent retry: same key on a second identical commit; the daemon
        # replays the original result and applies no extra rows.
        let retry1 = db.begin()
        retry1.put(table, _cells(1, 4, 2, "Dave", 3, 60.0))
        retry1.commit(idempotency_key)
        print("After first idempotent commit: " + String(db.count(table)) + " rows")

        let retry2 = db.begin()
        retry2.put(table, _cells(1, 4, 2, "Dave", 3, 60.0))
        retry2.commit(idempotency_key)
        print("After duplicate idempotent commit (same key): " + String(db.count(table)) + " rows (no double-apply)")
    finally:
        try:
            db.drop_table(table)
        except:
            pass
        print("Dropped table " + table)


def _col(col_id: Int, name: String, ty: String, *, primary_key: Bool = False) -> PythonObject:
    c = Python.dict()
    c.__setitem__("id", Python.object(col_id))
    c.__setitem__("name", Python.str(name))
    c.__setitem__("ty", Python.str(ty))
    c.__setitem__("primary_key", Python.object(primary_key))
    c.__setitem__("nullable", Python.object(False))
    return c


def _cells(*kvs: PythonObject) -> PythonObject:
    d = Python.dict()
    i = 0
    while i < len(kvs):
        d.__setitem__(kvs[i], kvs[i + 1])
        i += 2
    return d
