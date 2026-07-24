# Quickstart

Zero to a running MongrelDB Mojo program. This guide assumes a fresh machine
and walks through installing the prerequisites, starting the daemon, and writing
a complete program.

---

## 1. Prerequisites

You need the Mojo toolchain and a `mongreldb-server` daemon.

### Install Mojo

Follow the [official Mojo install guide](https://docs.modular.com/mojo/manual/get-started/).
Verify it:

```sh
mojo --version
```

### Install mongreldb-server

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.64.6/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453`.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

Sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

## 3. Create a project and pull in the client

```sh
magic add mongreldb-mojo
```

Or run from this checkout directly with `-I src` on the import path.

## 4. Write your first program

Create `demo.mojo`:

```mojo
from python import Python, PythonObject
from mongreldb import MongrelDB

fn main() raises:
    var db = MongrelDB("http://127.0.0.1:8453")

    if not db.health():
        print("daemon not reachable")
        return

    var columns = Python.list()
    columns.append(col(1, "id", "int64", primary_key=True))
    columns.append(col(2, "customer", "varchar"))
    columns.append(col(3, "amount", "float64"))
    var tid = db.create_table("orders", columns)
    print("created table id: " + String(tid))

    _ = db.put("orders", cells3(1, 1, 2, "Alice", 3, 99.5))
    _ = db.put("orders", cells3(1, 2, 2, "Bob",   3, 150.0))

    var params = Python.dict()
    params["column"] = 3
    params["min"] = 100.0
    params["max"] = 200.0
    params["min_inclusive"] = True
    params["max_inclusive"] = True
    var q = db.query("orders").where("range_f64", params).limit(100)
    var rows = q.execute()
    print("rows: " + String(len(rows)))

    print("total rows: " + String(db.count("orders")))


def col(col_id: Int, name: String, ty: String, *, primary_key: Bool = False) -> PythonObject:
    c = Python.dict()
    c["id"] = col_id
    c["name"] = name
    c["ty"] = ty
    c["primary_key"] = primary_key
    c["nullable"] = False
    return c


def cells3(
    k1: PythonObject, v1: PythonObject,
    k2: PythonObject, v2: PythonObject,
    k3: PythonObject, v3: PythonObject,
) -> PythonObject:
    d = Python.dict()
    d[k1] = v1
    d[k2] = v2
    d[k3] = v3
    return d
```

Run it:

```sh
mojo run -I src demo.mojo
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `MongrelDB(url)` | Builds an HTTP client targeting one daemon. |
| `db.health()` | GET `/health`; returns `True` when the daemon answers. |
| `db.create_table(name, cols)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers. |
| `db.put(table, cells)` | Single-op transaction: POST `/kit/txn` with one `put` op. |
| `db.query(table).where(...)` | Builds a `/kit/query` body that pushes a condition down to a native index. |
| `.execute()` | Sends the query and decodes the rows. |
| `db.count(table)` | GET `/tables/{name}/count`. |
| `db.set_history_retention_epochs(n)` | PUT `/history/retention`; controls time-travel query depth. |

## 6. Static column defaults

A column dict may carry a `default_value` (a static literal applied when a row
omits the cell) or a `default_expr` (a dynamic engine-computed default such as
`now` or `uuid`). `default_expr` wins over `default_value` when both are set.
The six recognized shapes - each preserving its JSON type on the wire - are:

```mojo
from python import Python, PythonObject
from collections import List

# 1. String default.
var c1 = Python.dict()
c1["id"] = 10
c1["name"] = "status"
c1["ty"] = "varchar"
c1["default_value"] = "draft"

# 2. Integer default.
var c2 = Python.dict()
c2["id"] = 11
c2["name"] = "retries"
c2["ty"] = "int64"
c2["default_value"] = 3

# 3. Boolean default.
var c3 = Python.dict()
c3["id"] = 12
c3["name"] = "enabled"
c3["ty"] = "bool"
c3["default_value"] = True

# 4. Explicit null default (distinct from omitting the key).
var c4 = Python.dict()
c4["id"] = 13
c4["name"] = "note"
c4["ty"] = "varchar"
c4["default_value"] = PythonObject()

# 5. Literal string "now" - stored as a plain string default, not a dynamic
#    expression, because it is passed via default_value rather than default_expr.
var c5 = Python.dict()
c5["id"] = 14
c5["name"] = "tag"
c5["ty"] = "varchar"
c5["default_value"] = "now"

# 6. Dynamic default_expr - the engine evaluates "now" on each insert.
var c6 = Python.dict()
c6["id"] = 15
c6["name"] = "created_at"
c6["ty"] = "timestamp_nanos"
c6["default_expr"] = "now"

var columns = Python.list()
for c in List[PythonObject](c1, c2, c3, c4, c5, c6):
    columns.append(c)
_ = db.create_table("defaults_demo", columns)
```

Omit both keys for a column with no default (the server requires a cell on every
insert in that case).

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `create_table`. The query builder's `column` alias maps to the
server's `column_id` - pass the integer id.

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as a `ConflictError`.

**Calling `commit` twice on the same `Transaction`.** The second call raises an
error. Create a fresh `db.begin()` for each logical unit.

**Expecting `sql` to always return rows.** The `/sql` endpoint streams Arrow IPC
for `SELECT` in most builds, so `sql` returns an empty list. Use the native
query builder for typed row retrieval; use `sql` for DDL/DML.

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions
- [auth.md](auth.md) - bearer tokens, basic auth
- [errors.md](errors.md) - the full error reference
