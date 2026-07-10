# Error handling

Every non-2xx response from the daemon is mapped to a typed Mojo error. This is
the complete reference: the error hierarchy, the HTTP-status mapping, the
daemon's error envelope, and recovery patterns.

---

## The error model

All client errors descend from `MongrelDBError`. The client raises a specific
subclass for each failure category:

| Class | Meaning | Typical cause |
|-------|---------|---------------|
| `MongrelDBError` | Base class for all client errors | (catch this to handle any failure) |
| `AuthError` | HTTP 401 or 403 | Missing/bad credentials against an auth-enabled daemon |
| `NotFoundError` | HTTP 404 | Missing table, schema, or resource |
| `ConflictError` | HTTP 409 | Unique, foreign-key, check, or trigger violation at commit |
| `QueryError` | HTTP 400 or 5xx, plus network | Malformed request, server failure, transport error |

Each typed error carries `status()`, `code()` (the server's structured code, e.g.
`UNIQUE_VIOLATION`), and `op_index()` (the offending op index within a batch,
when reported; `-1` when not).

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

## HTTP status -> exception mapping

| HTTP status | Exception | Notes |
|-------------|-----------|-------|
| 401, 403 | `AuthError` | Bad/missing credentials |
| 404 | `NotFoundError` | Resource not found |
| 409 | `ConflictError` | Constraint violation at commit |
| 400 | `QueryError` | Malformed request / bad query |
| 5xx | `QueryError` | Daemon-side failure |
| 2xx | (no error) | Success |

Network and encoding problems are also mapped to `QueryError`.

## Discriminating errors

```mojo
try:
    db.schema_for("missing_table")
except NotFoundError:
    print("table does not exist")
except ConflictError:
    print("unexpected conflict on a read")
except AuthError:
    print("bad credentials")
except QueryError:
    print("server error or malformed request")
```

### By details - read `ConflictError` fields

```mojo
try:
    txn.commit()
except ConflictError:
    print("status=409 code=" + e.code() + " op=" + String(e.op_index()))
```

## Recovery patterns

### Auth failure - do not retry blindly

```mojo
except AuthError:
    print("credentials rejected; refresh token")
```

### Not found - fall back, do not crash

```mojo
try:
    db.schema_for(table_name)
except NotFoundError:
    pass  # table missing - treat as empty
```

### Transient failure - retry with an idempotency key

`QueryError` covers transport and 5xx failures. With an idempotency key,
retrying a transaction is safe (see [transactions.md](transactions.md)).

## Quick reference

```mojo
# Category checks (most specific first):
except AuthError      # 401/403
except NotFoundError  # 404
except ConflictError  # 409
except QueryError     # 400/5xx/network
except MongrelDBError # base
```

## Next steps

- [transactions.md](transactions.md) - constraint handling and retries in context
- [auth.md](auth.md) - credential management
