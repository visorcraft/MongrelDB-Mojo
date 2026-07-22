# Error handling

Every non-2xx response from the daemon is mapped to a typed error category.
This is the complete reference: the error categories, the HTTP-status mapping,
the daemon's error envelope, and recovery patterns.

---

## The error model

Mojo can only raise the built-in `Error` type (exception subclassing does not
exist), so the client models its error categories as `Error` constructors that
match the other MongrelDB language clients. Each error message is prefixed
with the category name and embeds the HTTP status, the server's structured
code, and the offending op index:

```
ConflictError: constraint violation (status=409, code=UNIQUE_VIOLATION, op_index=0)
```

| Category | Meaning | Typical cause |
|----------|---------|---------------|
| `MongrelDBError` | Base category for all client errors | (matches any client failure) |
| `AuthError` | HTTP 401 or 403 | Missing/bad credentials against an auth-enabled daemon |
| `NotFoundError` | HTTP 404 | Missing table, schema, or resource |
| `ConflictError` | HTTP 409 | Unique, foreign-key, check, or trigger violation at commit |
| `QueryError` | HTTP 400 or 5xx, plus network | Malformed request, server failure, transport error |

## The daemon's error envelope

```json
{
  "status": "aborted",
  "error": {
    "code": "UNIQUE_VIOLATION",
    "message": "duplicate key in column 1",
    "op_index": 0
  }
}
```

Common `code` values: `UNIQUE_VIOLATION`, `FK_VIOLATION`,
`CHECK_VIOLATION`, `NOT_FOUND`.

## HTTP status -> error category mapping

| HTTP status | Category | Notes |
|-------------|----------|-------|
| 401, 403 | `AuthError` | Bad/missing credentials |
| 404 | `NotFoundError` | Resource not found |
| 409 | `ConflictError` | Constraint violation at commit |
| 400 | `QueryError` | Malformed request / bad query |
| 5xx | `QueryError` | Daemon-side failure |
| 2xx | (no error) | Success |

Network and encoding problems are also mapped to `QueryError`.

## Discriminating errors

Catch `Error` and match the category prefix in the message:

```mojo
try:
    _ = db.schema_for("missing_table")
except e:
    var msg = String(e)
    if msg.contains("NotFoundError"):
        print("table does not exist")
    elif msg.contains("AuthError"):
        print("bad credentials")
    else:
        print("server error or malformed request: " + msg)
```

### By details - status, code, and op index

The HTTP status, the server's structured `code` (when reported), and the
offending `op_index` within a batch are embedded in the message:

```mojo
try:
    _ = txn.commit()
except e:
    print(String(e))
    # ConflictError: constraint violation (status=409, code=UNIQUE_VIOLATION, op_index=0)
```

## Recovery patterns

### Auth failure - do not retry blindly

```mojo
try:
    _ = db.schema()
except e:
    if String(e).contains("AuthError"):
        print("credentials rejected; refresh token")
```

### Not found - fall back, do not crash

```mojo
try:
    _ = db.schema_for(table_name)
except e:
    if String(e).contains("NotFoundError"):
        pass  # table missing - treat as empty
```

### Transient failure - retry with an idempotency key

`QueryError` covers transport and 5xx failures. With an idempotency key,
retrying a transaction is safe (see [transactions.md](transactions.md)).

## Quick reference

```mojo
# Category prefixes in the error message:
#   AuthError      401/403
#   NotFoundError  404
#   ConflictError  409
#   QueryError     400/5xx/network
#   MongrelDBError base category
```

## Next steps

- [transactions.md](transactions.md) - constraint handling and retries in context
- [auth.md](auth.md) - credential management
