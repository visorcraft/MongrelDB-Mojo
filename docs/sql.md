# SQL

MongrelDB ships a DataFusion-backed SQL engine at `POST /sql`. From Mojo, run
SQL with `db.sql(...)`:

```mojo
let rows = db.sql("SELECT 1")
```

---

## How `sql` behaves

`db.sql(sql)` sends `{"sql": "...", "format": "json"}` to `/sql`. It returns a
Python list of row dicts when the daemon replies with a JSON result set, and an
empty list otherwise.

- **DDL and DML** reply with a non-JSON status body. `sql` returns an empty list
  - success is the signal.
- **`SELECT`** in most daemon builds streams Arrow IPC bytes rather than JSON,
  so `sql` returns an empty list. Use `db.sql_arrow(sql)` to request raw Arrow
  IPC (`format: "arrow"`) when the server supports it, or use the native
  `QueryBuilder` for typed row retrieval.

Errors are mapped to the typed errors: HTTP 400/5xx raises `QueryError`; 409
raises `ConflictError`.

```mojo
try:
    db.sql("INSERT INTO orders (id, amount) VALUES (99, 999.0)")
except ConflictError:
    print("duplicate row")
```

## CREATE TABLE

```mojo
db.sql(
    "CREATE TABLE products (id INT64 PRIMARY KEY, name VARCHAR, price FLOAT64)")
```

## INSERT / UPDATE / DELETE

```mojo
db.sql("INSERT INTO products (id, name, price) VALUES (1, 'Widget', 9.99)")
db.sql("UPDATE products SET price = 14.99 WHERE id = 1")
db.sql("DELETE FROM products WHERE id = 2")
```

For bulk inserts, the native batch transaction (`db.begin()`) is usually faster.

## CREATE TABLE AS SELECT

```mojo
db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")
```

## Recursive CTEs

```mojo
db.sql("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")
```

## Window functions

```mojo
db.sql(
    "SELECT id, customer, amount, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn FROM orders")
```

## When to use SQL vs. the query builder

| Reach for | When |
|-----------|------|
| **`QueryBuilder`** | Point lookups, range scans, bitmap filters, full-text, vector similarity that map to a native index. Sub-millisecond, rows decode into dicts directly. |
| **SQL** | DDL, multi-statement setup, joins, recursive CTEs, window functions, arbitrary aggregates. |

Mix freely: create tables with SQL, write rows with `put`, read them back with
`QueryBuilder`, and run analytics with SQL.

## Next steps

- [queries.md](queries.md) - every native index condition
- [transactions.md](transactions.md) - bulk inserts via batch transactions
- [errors.md](errors.md) - handling SQL execution errors
