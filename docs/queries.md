# Queries

The fluent `QueryBuilder` pushes conditions down to MongrelDB's native indexes
for sub-millisecond lookups - bitmap, learned-range, FM-index full text, HNSW
vector similarity, and more. Each condition type maps to one specialized index;
conditions are AND-ed together.

```mojo
let params = Python.dict()
params.__setitem__("column", 3)
params.__setitem__("min", 100.0)
params.__setitem__("max", 500.0)
let rows = db.query("orders")
    .where("range_f64", params)
    .projection(Python.list())
    .limit(100)
    .execute()
```

---

## The basics

| Method | Purpose |
|--------|---------|
| `where(cond_type, params)` | Add a native condition. Multiple calls are AND-ed. |
| `projection(column_ids)` | Return only these column ids (`None` means all columns). |
| `limit(n)` | Cap the number of rows. |
| `build()` | Produce the request payload (useful for debugging). |
| `execute()` | Send and decode. Records the `truncated` flag. |
| `truncated()` | Whether the last `execute` hit the limit. |

## Condition types

`params` is a Python dict (built via `Python.dict()`). Column references use the
numeric **column id**, never the column name.

### `pk` - exact primary-key match

```mojo
let p = Python.dict(); p.__setitem__("value", 42)
db.query("orders").where("pk", p).execute()
```

### `range` - integer range (learned-range index)

```mojo
let p = Python.dict()
p.__setitem__("column", 3); p.__setitem__("min", 100); p.__setitem__("max", 500)
db.query("orders").where("range", p).execute()
```

### `range_f64` - float range with inclusive/exclusive control

```mojo
let p = Python.dict()
p.__setitem__("column", 3); p.__setitem__("min", 100.0); p.__setitem__("max", 500.0)
p.__setitem__("min_inclusive", True); p.__setitem__("max_inclusive", False)
db.query("orders").where("range_f64", p).execute()
```

### `bitmap_eq` - equality on a bitmap-indexed column

```mojo
let p = Python.dict()
p.__setitem__("column", 2); p.__setitem__("value", "Alice")
db.query("orders").where("bitmap_eq", p).execute()
```

### `fm_contains` - full-text substring search (FM-index)

Use `pattern` (the server key) or the friendly `value` alias:

```mojo
let p = Python.dict()
p.__setitem__("column", 2); p.__setitem__("value", "database")
db.query("documents").where("fm_contains", p).limit(10).execute()
```

### `ann` - dense vector similarity (HNSW)

```mojo
let p = Python.dict()
p.__setitem__("column", 2)
p.__setitem__("query", Python.list([0.1, 0.2, 0.3, 0.4]))
p.__setitem__("k", 10)
db.query("embeddings").where("ann", p).execute()
```

## Friendly alias translation

| You write | Sent as | Applies to |
|-----------|---------|------------|
| `column` | `column_id` | all condition types |
| `min` | `lo` | `range`, `range_f64` |
| `max` | `hi` | `range`, `range_f64` |
| `min_inclusive` | `lo_inclusive` | `range_f64` |
| `max_inclusive` | `hi_inclusive` | `range_f64` |
| `value` | `pattern` | `fm_contains`, `fm_contains_all` only |

## Limit and the truncated flag

```mojo
let q = db.query("orders").where("range", params).limit(100)
let rows = q.execute()
if q.truncated():
    print("result capped at " + String(len(rows)))
```

## Putting it together

```mojo
fn top_spenders(db: MongrelDB, customer: String) -> PythonObject:
    let p1 = Python.dict(); p1.__setitem__("column", 2); p1.__setitem__("value", customer)
    let p2 = Python.dict(); p2.__setitem__("column", 3); p2.__setitem__("min", 100)
    let q = db.query("orders").where("bitmap_eq", p1).where("range", p2).limit(50)
    let rows = q.execute()
    if q.truncated():
        print("warning: top_spenders result capped at 50")
    return rows
```

For arbitrary predicates, joins, and aggregations, use SQL - see [sql.md](sql.md).
