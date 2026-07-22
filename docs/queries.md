# Queries

The fluent `QueryBuilder` pushes conditions down to MongrelDB's native indexes
for sub-millisecond lookups - bitmap, learned-range, FM-index full text, HNSW
vector similarity, and more. Each condition type maps to one specialized index;
conditions are AND-ed together.

```mojo
var params = Python.dict()
params["column"] = 3
params["min"] = 100.0
params["max"] = 500.0
var q = db.query("orders").where("range_f64", params).projection(Python.list()).limit(100)
var rows = q.execute()
```

---

## The basics

| Method | Purpose |
|--------|---------|
| `where(cond_type, params)` | Return a new builder with a native condition added. Multiple conditions are AND-ed. |
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
var p = Python.dict()
p["value"] = 42
var q = db.query("orders").where("pk", p)
_ = q.execute()
```

### `range` - integer range (learned-range index)

```mojo
var p = Python.dict()
p["column"] = 3
p["min"] = 100
p["max"] = 500
var q = db.query("orders").where("range", p)
_ = q.execute()
```

### `range_f64` - float range with inclusive/exclusive control

```mojo
var p = Python.dict()
p["column"] = 3
p["min"] = 100.0
p["max"] = 500.0
p["min_inclusive"] = True
p["max_inclusive"] = False
var q = db.query("orders").where("range_f64", p)
_ = q.execute()
```

### `bitmap_eq` - equality on a bitmap-indexed column

```mojo
var p = Python.dict()
p["column"] = 2
p["value"] = "Alice"
var q = db.query("orders").where("bitmap_eq", p)
_ = q.execute()
```

### `fm_contains` - full-text substring search (FM-index)

Use `pattern` (the server key) or the friendly `value` alias:

```mojo
var p = Python.dict()
p["column"] = 2
p["value"] = "database"
var q = db.query("documents").where("fm_contains", p).limit(10)
_ = q.execute()
```

### `ann` - dense vector similarity (HNSW)

```mojo
var p = Python.dict()
p["column"] = 2
var query_vec = Python.list()
query_vec.append(0.1)
query_vec.append(0.2)
query_vec.append(0.3)
query_vec.append(0.4)
p["query"] = query_vec
p["k"] = 10
var q = db.query("embeddings").where("ann", p)
_ = q.execute()
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
var q = db.query("orders").where("range", params).limit(100)
var rows = q.execute()
if q.truncated():
    print("result capped at " + String(len(rows)))
```

## Putting it together

```mojo
fn top_spenders(db: MongrelDB, customer: String) raises -> PythonObject:
    var p1 = Python.dict()
    p1["column"] = 2
    p1["value"] = customer
    var p2 = Python.dict()
    p2["column"] = 3
    p2["min"] = 100
    var q = db.query("orders").where("bitmap_eq", p1).where("range", p2).limit(50)
    var rows = q.execute()
    if q.truncated():
        print("warning: top_spenders result capped at 50")
    return rows
```

For arbitrary predicates, joins, and aggregations, use SQL - see [sql.md](sql.md).
