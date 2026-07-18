<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Mojo Client</h1>

<p align="center">
  <b>Pure Mojo client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No external packages required - built on Python's standard-library <code>urllib</code> via Mojo's seamless Python interop. The API mirrors the MongrelDB Python, Ruby, and Go clients.
</p>

<p align="center">
  <a href="https://docs.modular.com/mojo/"><img src="https://img.shields.io/badge/Mojo-24.x-FF6F00.svg" alt="Mojo" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-Mojo/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Mojo/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Mojo client | `mongreldb` | `magic add mongreldb-mojo` (from source) |

## Requirements

- **Mojo 24.x** (the Modular toolchain)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, all with optional idempotency keys for safe retries.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` -> `column_id`, `min`/`max` -> `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint. JSON mode (`sql`) decodes row arrays; `sql_arrow` requests raw Arrow IPC bytes (`format: "arrow"`).
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors. Column dictionaries preserve scalar `default_value` and dynamic `default_expr` (`"now"` or `"uuid"`).
- **User/role/credentials management** via SQL: Argon2id-hashed catalog users, roles, and `GRANT`/`REVOKE` table-level permissions, all executed through `sql`.
- **Maintenance**: compaction (all tables or per-table).
- **Auth**: Bearer token (`--auth-token` mode) and HTTP Basic (`--auth-users` mode), with the bearer token taking precedence. Credentials are CRLF-validated to prevent header injection.
- **Typed error hierarchy**: `MongrelDBError` (base), `AuthError` (401/403), `NotFoundError` (404), `ConflictError` (409, with code + op index), and `QueryError` (everything else, including network failures).
- **Response size limit** (256 MB) to guard client memory against a malicious or buggy server.

## How it works

Mojo is a Python superset with seamless interop. This client calls Python's
standard-library `urllib.request`, `json`, and `base64` via `Python.import_module`
- no third-party packages and no C FFI. All request/response logic (auth, error
mapping, cell flattening, alias translation) is written in Mojo.

## Install

```sh
magic add mongreldb-mojo
```

Or run the sources directly from this checkout:

```sh
mojo run -I src examples/basic_crud.mojo
```

## Examples

Task-focused, commented guides live in [`docs/`](docs):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - Bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - the error hierarchy and recovery patterns.

## Quick Example

```mojo
from python import Python
from mongreldb import MongrelDB

fn main() raises:
    let db = MongrelDB("http://127.0.0.1:8453")

    # Create a table. Column ids are stable on-wire identifiers.
    let columns = Python.list()
    columns.append(col(1, "id", "int64", primary_key=True))
    columns.append(col(2, "customer", "varchar"))
    columns.append(col(3, "amount", "float64"))
    let check = Python.dict()
    check.__setitem__("id", 1)
    check.__setitem__("name", "id_present")
    let expr = Python.dict()
    expr.__setitem__("IsNotNull", 1)
    check.__setitem__("expr", expr)
    let constraints = Python.dict()
    let checks = Python.list()
    checks.append(check)
    constraints.__setitem__("checks", checks)
    db.create_table("orders", columns, constraints)

    db.put("orders", cells(1, 1, 2, "Alice", 3, 99.50))
    db.put("orders", cells(1, 2, 2, "Bob",   3, 150.00))

    let params = Python.dict()
    params.__setitem__("column", 3)
    params.__setitem__("min", 100.0)
    params.__setitem__("max", 200.0)
    params.__setitem__("min_inclusive", True)
    params.__setitem__("max_inclusive", True)
    let rows = db.query("orders").where("range_f64", params).limit(100).execute()
    print(db.count("orders"))   # 2

    db.sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## Authentication

```mojo
# Bearer token (--auth-token mode)
let db1 = MongrelDB("http://127.0.0.1:8453", "my-secret-token")

# HTTP Basic (--auth-users mode)
let db2 = MongrelDB("http://127.0.0.1:8453", "", "admin", "s3cret")

# Defaults: daemon address 127.0.0.1:8453, no auth.
let db3 = MongrelDB()
```

## Batch transactions

```mojo
let txn = db.begin()
txn.put("orders", cells(1, 10, 2, "Dave", 3, 50.0))
txn.put("orders", cells(1, 11, 2, "Eve",  3, 75.0))
txn.delete_by_pk("orders", 2)

try:
    let results = txn.commit()   # atomic - all or nothing
except ConflictError:
    print("constraint violated")
```

## SQL

```mojo
db.sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")
```

## History retention

Control how far back time-travel queries can read. The window is measured in
epochs (monotonically increasing commit numbers).

```mojo
# Keep at least 1000 epochs of history readable.
let result = db.set_history_retention_epochs(1000)
print(result.__getitem__("history_retention_epochs"))  # 1000
print(result.__getitem__("earliest_retained_epoch"))   # oldest epoch still available

print(db.history_retention_epochs())       # 1000
print(db.earliest_retained_epoch())        # oldest readable epoch

# Read a table as it existed at a specific epoch.
let rows = db.sql("SELECT label FROM orders AS OF EPOCH 42 WHERE id = 1")
```

Raising retention prevents history from being garbage collected, but it cannot
restore epochs that have already been pruned. These endpoints require admin
privileges when the daemon runs with auth enabled.

## Error handling

Every non-2xx response is mapped to a typed error. Catch the specific class for
the category, or `MongrelDBError` for any client failure.

```mojo
try:
    db.put("orders", cells(1, 1))
except ConflictError:
    print("constraint violated")
except NotFoundError:
    print("not found")
except QueryError:
    print("query/server error")
```

## API reference

### `MongrelDB`

| Method | Description |
|--------|-------------|
| `MongrelDB(url, token, username, password)` | Construct a client (`url` defaults to `http://127.0.0.1:8453`) |
| `health() -> Bool` | Check daemon health |
| `table_names() -> List[String]` | List table names |
| `create_table(name, columns) -> Int` | Create a table; returns the table id |
| `drop_table(name) -> None` | Drop a table |
| `count(table) -> Int` | Row count |
| `put(table, cells, idempotency_key) -> dict` | Insert a row |
| `upsert(table, cells, update_cells, idempotency_key) -> dict` | Upsert a row |
| `delete(table, row_id) -> None` | Delete by row id |
| `delete_by_pk(table, pk) -> None` | Delete by primary key |
| `query(table) -> QueryBuilder` | Start a native query |
| `sql(sql) -> list` | Execute SQL (JSON mode) |
| `sql_arrow(sql) -> Bytes` | Execute SQL requesting raw Arrow IPC |
| `schema() -> dict` | Full schema catalog |
| `schema_for(table) -> dict` | Single-table descriptor |
| `set_history_retention_epochs(epochs) -> dict` | Set the history retention window |
| `history_retention_epochs() -> Int` | Get the current retention window |
| `earliest_retained_epoch() -> Int` | Get the oldest readable epoch |
| `compact() -> dict` | Compact all tables |
| `compact_table(table) -> dict` | Compact one table |
| `begin() -> Transaction` | Start a batch |

### `QueryBuilder`

| Method | Description |
|--------|-------------|
| `where(cond_type, params) -> Self` | Add a native condition (AND-ed) |
| `projection(column_ids) -> Self` | Set column projection |
| `limit(n) -> Self` | Set row limit |
| `offset(n) -> Self` | Skip matching rows before the limit |
| `build() -> dict` | Build the request payload |
| `execute() -> list` | Run the query |
| `truncated() -> Bool` | Whether the last `execute` result hit the limit |

### `Transaction`

| Method | Description |
|--------|-------------|
| `put(table, cells, returning) -> Self` | Stage an insert |
| `upsert(table, cells, update_cells, returning) -> Self` | Stage an upsert |
| `delete(table, row_id) -> Self` | Stage a delete by row id |
| `delete_by_pk(table, pk) -> Self` | Stage a delete by primary key |
| `count() -> Int` | Number of staged operations |
| `commit(idempotency_key) -> list` | Commit atomically |
| `rollback() -> None` | Discard all operations |

### Errors

| Class | HTTP status | Notes |
|-------|-------------|-------|
| `MongrelDBError` | - | Base class for all client errors |
| `AuthError` | 401, 403 | Bad or missing credentials |
| `NotFoundError` | 404 | Missing table, schema, or resource |
| `ConflictError` | 409 | Constraint violation; carries `code` and `op_index` |
| `QueryError` | 400, 5xx, network | Everything else |

## Building and testing

The test suite is split into two layers:

- **Offline unit tests** - query-builder alias translation, URL escaping, error
  mapping. No daemon needed.
- **Live integration tests** - boots a real `mongreldb-server` daemon and
  exercises the full client surface (the 14-operation conformance matrix). Live
  tests skip cleanly when no binary is available.

```sh
mojo test -I src tests/live_test.mojo   # runs the whole suite
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.59.1/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

The live harness resolves the binary in this order: the `MONGRELDB_SERVER` env
var, `./bin/mongreldb-server`, `mongreldb-server` on `PATH`. Or point it at an
already-running daemon with `MONGRELDB_URL`.

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Run `mojo test -I src tests/live_test.mojo` before submitting.
4. Keep the client dependency-free (Python standard library only).

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
