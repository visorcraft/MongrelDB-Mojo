# Example: query builder conditions with the MongrelDB Mojo client.
#
# Run: mojo run -I src examples/query_builder.mojo
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, inserts five rows with varying scores, then uses the native
# query builder to fetch rows by a float range condition and by an exact
# primary-key match. Cleans up by dropping the table.

from python import Python, PythonObject
from mongreldb import MongrelDB


fn main() raises:
    var url = "http://127.0.0.1:8453"
    var time_module = Python.import_module("time")
    var suffix = String(Int(time_module.time())) + "_" + String(Int(time_module.time_ns() & 0xFFFFFF))
    var table = "example_query_" + suffix

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

        _ = db.put(table, _cells3(1, 1, 2, "Alice", 3, 40.0))
        _ = db.put(table, _cells3(1, 2, 2, "Bob", 3, 65.0))
        _ = db.put(table, _cells3(1, 3, 2, "Carol", 3, 82.0))
        _ = db.put(table, _cells3(1, 4, 2, "Dave", 3, 91.0))
        _ = db.put(table, _cells3(1, 5, 2, "Eve", 3, 12.5))
        print("Inserted 5 rows")

        # Range condition: scores in [60.0, 90.0]. "score" is float64, so use
        # range_f64 (plain "range" expects an i64 bound).
        var params = Python.dict()
        params["column"] = 3
        params["min"] = 60.0
        params["max"] = 90.0
        params["min_inclusive"] = True
        params["max_inclusive"] = True
        var range_query = db.query(table).where("range_f64", params)
        var rng = range_query.execute()
        print("Range query (score in [60,90]) returned " + String(len(rng)) + " rows")

        var pk_params = Python.dict()
        pk_params["value"] = 4
        var pk_query = db.query(table).where("pk", pk_params)
        var pk = pk_query.execute()
        print("PK query (id == 4) returned " + String(len(pk)) + " rows")
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
