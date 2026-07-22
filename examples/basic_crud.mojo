# Example: basic CRUD operations with the MongrelDB Mojo client.
#
# Run: mojo run -I src examples/basic_crud.mojo
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, inserts three rows, counts them, queries all rows, upserts
# (updates) one row by primary key, deletes one row, then drops the table.

from python import Python, PythonObject
from collections import List, Optional
from mongreldb import MongrelDB


fn main() raises:
    var url = "http://127.0.0.1:8453"
    # Unique suffix per run so concurrent/repeated runs don't collide.
    var time_module = Python.import_module("time")
    var suffix = String(Int(time_module.time())) + "_" + String(Int(time_module.time_ns() & 0xFFFFFF))
    var table = "example_crud_" + suffix

    var db = MongrelDB(url)
    if not db.health():
        print("daemon not reachable at " + url)
        return

    print("Connected to MongrelDB")

    try:
        var columns = Python.list()
        columns.append(_col(1, "id", "int64", primary_key=True))
        columns.append(_enum_col(2, "role", List[String]("admin", "member", "guest"), "member"))
        columns.append(_col(3, "name", "varchar"))
        columns.append(_col(4, "score", "float64", default_value=PythonObject(0)))
        var tid = db.create_table(table, columns)
        print("Created table " + table + " (id " + String(tid) + ")")

        _ = db.put(table, _cells4(1, 1, 2, "admin", 3, "Alice", 4, 95.5))
        _ = db.put(table, _cells3(1, 2, 3, "Bob", 4, 82.0))   # role defaults to "member"
        _ = db.put(table, _cells4(1, 3, 2, "guest", 3, "Carol", 4, 78.3))
        print("Inserted 3 rows")

        print("Total rows: " + String(db.count(table)))

        var q = db.query(table)
        var all = q.execute()
        print("Query returned " + String(len(all)) + " rows")

        var upd = Python.dict()
        upd[2] = "admin"
        upd[3] = "Alice"
        upd[4] = 100.0
        _ = db.upsert(table, _cells4(1, 1, 2, "admin", 3, "Alice", 4, 100.0), upd)
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


def _col(
    col_id: Int,
    name: String,
    ty: String,
    *,
    primary_key: Bool = False,
    default_value: Optional[PythonObject] = None,
) -> PythonObject:
    c = Python.dict()
    c["id"] = col_id
    c["name"] = name
    c["ty"] = ty
    c["primary_key"] = primary_key
    c["nullable"] = False
    if default_value:
        c["default_value"] = default_value.value()
    return c


def _enum_col(col_id: Int, name: String, variants: List[String], default_value: String) -> PythonObject:
    c = Python.dict()
    c["id"] = col_id
    c["name"] = name
    c["ty"] = "enum"
    pv = Python.list()
    for v in variants:
        pv.append(v)
    c["enum_variants"] = pv
    c["default_value"] = default_value
    c["primary_key"] = False
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


def _cells4(
    k1: PythonObject, v1: PythonObject,
    k2: PythonObject, v2: PythonObject,
    k3: PythonObject, v3: PythonObject,
    k4: PythonObject, v4: PythonObject,
) -> PythonObject:
    d = Python.dict()
    d[k1] = v1
    d[k2] = v2
    d[k3] = v3
    d[k4] = v4
    return d
