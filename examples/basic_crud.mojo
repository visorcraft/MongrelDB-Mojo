# Example: basic CRUD operations with the MongrelDB Mojo client.
#
# Run: mojo run -I src examples/basic_crud.mojo
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, inserts three rows, counts them, queries all rows, upserts
# (updates) one row by primary key, deletes one row, then drops the table.

from python import Python
from mongreldb import MongrelDB


fn main() raises:
    let url = "http://127.0.0.1:8453"
    # Unique suffix per run so concurrent/repeated runs don't collide.
    let time_module = Python.import_module("time")
    let suffix = String(time_module.time()).replace(".", "") + "_" + String(Int(time_module.time_ns() & 0xFFFFFF))
    let table = "example_crud_" + suffix

    let db = MongrelDB(url)
    if not db.health():
        print("daemon not reachable at " + url)
        return

    print("Connected to MongrelDB")

    try:
        let columns = Python.list()
        columns.append(_col(1, "id", "int64", primary_key=True))
        columns.append(_enum_col(2, "role", ["admin", "member", "guest"], "member"))
        columns.append(_col(3, "name", "varchar"))
        columns.append(_col(4, "score", "float64", default_value=0))
        let tid = db.create_table(table, columns)
        print("Created table " + table + " (id " + String(tid) + ")")

        db.put(table, _cells(1, 1, 2, "admin", 3, "Alice", 4, 95.5))
        db.put(table, _cells(1, 2, 3, "Bob", 4, 82.0))   # role defaults to "member"
        db.put(table, _cells(1, 3, 2, "guest", 3, "Carol", 4, 78.3))
        print("Inserted 3 rows")

        print("Total rows: " + String(db.count(table)))

        let all = db.query(table).execute().to_list()
        print("Query returned " + String(len(all)) + " rows")

        let upd = Python.dict()
        upd.__setitem__(2, "admin")
        upd.__setitem__(3, "Alice")
        upd.__setitem__(4, 100.0)
        db.upsert(table, _cells(1, 1, 2, "admin", 3, "Alice", 4, 100.0), upd)
        print("Upserted Alice's score to 100.0")
        print("Total rows after upsert: " + String(db.count(table)))

        db.delete_by_pk(table, 3)
        print("Deleted Carol; remaining rows: " + String(db.count(table)))
    finally:
        try:
            db.drop_table(table)
        except:
            pass
        print("Dropped table " + table)


def _col(col_id: Int, name: String, ty: String, *, primary_key: Bool = False, default_value: PythonObject = PythonObject()) -> PythonObject:
    c = Python.dict()
    c.__setitem__("id", Python.object(col_id))
    c.__setitem__("name", Python.str(name))
    c.__setitem__("ty", Python.str(ty))
    c.__setitem__("primary_key", Python.object(primary_key))
    c.__setitem__("nullable", Python.object(False))
    if default_value:
        c.__setitem__("default_value", default_value)
    return c


def _enum_col(col_id: Int, name: String, variants: List[String], default_value: String) -> PythonObject:
    c = Python.dict()
    c.__setitem__("id", Python.object(col_id))
    c.__setitem__("name", Python.str(name))
    c.__setitem__("ty", "enum")
    pv = Python.list()
    for v in variants:
        pv.append(Python.str(v))
    c.__setitem__("enum_variants", pv)
    c.__setitem__("default_value", Python.str(default_value))
    c.__setitem__("primary_key", Python.object(False))
    c.__setitem__("nullable", Python.object(False))
    return c


def _cells(*kvs: PythonObject) -> PythonObject:
    d = Python.dict()
    i = 0
    while i < len(kvs):
        d.__setitem__(kvs[i], kvs[i + 1])
        i += 2
    return d
