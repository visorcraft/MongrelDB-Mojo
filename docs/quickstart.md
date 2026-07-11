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
  https://github.com/visorcraft/MongrelDB/releases/download/v0.48.0/mongreldb-server-linux-x64
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
from python import Python
from mongreldb import MongrelDB

fn main() raises:
    let db = MongrelDB("http://127.0.0.1:8453")

    if not db.health():
        print("daemon not reachable")
        return

    let columns = Python.list()
    columns.append(col(1, "id", "int64", primary_key=True))
    columns.append(col(2, "customer", "varchar"))
    columns.append(col(3, "amount", "float64"))
    let tid = db.create_table("orders", columns)
    print("created table id: " + String(tid))

    db.put("orders", cells(1, 1, 2, "Alice", 3, 99.5))
    db.put("orders", cells(1, 2, 2, "Bob",   3, 150.0))

    let params = Python.dict()
    params.__setitem__("column", 3)
    params.__setitem__("min", 100)
    let rows = db.query("orders").where("range", params).limit(100).execute().to_list()
    print("rows: " + String(len(rows)))

    print("total rows: " + String(db.count("orders")))
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

## 6. Common pitfalls

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
- [errors.md](errors.md) - the full error hierarchy
