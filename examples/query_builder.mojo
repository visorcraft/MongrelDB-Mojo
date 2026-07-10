# Example: query builder conditions with the MongrelDB Mojo client.
#
# Run: mojo run -I src examples/query_builder.mojo
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, inserts five rows with varying scores, then uses the native
# query builder to fetch rows by a float range condition and by an exact
# primary-key match. Cleans up by dropping the table.

from python import Python
from mongreldb import MongrelDB


fn main() raises:
    let url = "http://127.0.0.1:8453"
    let time_module = Python.import_module("time")
    let suffix = String(Int(time_module.time())) + "_" + String(Int(time_module.time_ns() & 0xFFFFFF))
    let table = "example_query_" + suffix

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

        db.put(table, _cells(1, 1, 2, "Alice", 3, 40.0))
        db.put(table, _cells(1, 2, 2, "Bob", 3, 65.0))
        db.put(table, _cells(1, 3, 2, "Carol", 3, 82.0))
        db.put(table, _cells(1, 4, 2, "Dave", 3, 91.0))
        db.put(table, _cells(1, 5, 2, "Eve", 3, 12.5))
        print("Inserted 5 rows")

        # Range condition: scores in [60.0, 90.0]. "score" is float64, so use
        # range_f64 (plain "range" expects an i64 bound).
        let params = Python.dict()
        params.__setitem__("column", 3)
        params.__setitem__("min", 60.0)
        params.__setitem__("max", 90.0)
        params.__setitem__("min_inclusive", True)
        params.__setitem__("max_inclusive", True)
        let rng = db.query(table).where("range_f64", params).execute().to_list()
        print("Range query (score in [60,90]) returned " + String(len(rng)) + " rows")

        let pk_params = Python.dict()
        pk_params.__setitem__("value", 4)
        let pk = db.query(table).where("pk", pk_params).execute().to_list()
        print("PK query (id == 4) returned " + String(len(pk)) + " rows")
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
