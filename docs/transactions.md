# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it - a one-shot single
op, and a staged batch - plus idempotency keys for safe retries, typed
constraint-violation handling, and rollback.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op becomes visible.

---

## Single puts vs. batch transactions

### Single op: `db.put`

```mojo
let res = db.put("orders", cells(1, 1, 2, "Alice", 3, 99.5))
```

`upsert`, `delete`, and `delete_by_pk` are the same shape.

### Batch: `db.begin()` + `Transaction`

```mojo
let txn = db.begin()
txn.put("orders", cells(1, 10, 2, "Dave", 3, 50.0))
txn.put("orders", cells(1, 11, 2, "Eve",  3, 75.0))
txn.delete_by_pk("orders", 2)

let results = txn.commit()
print("committed " + String(len(results)) + " ops")
```

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon replays the
**original** result on a duplicate commit, even across restarts.

```mojo
fn charge(db: MongrelDB, order_id: Int) -> List[PythonObject]:
    let txn = db.begin()
    txn.put("charges", cells(1, order_id, 2, 199.0))
    # Use a stable, business-meaningful key derived from the request.
    return txn.commit("charge:" + String(order_id))
```

Rules for keys:

- Any non-empty string works. Prefer content-derived, globally-unique values.
- An empty string (the default) disables idempotency - a retry will commit again.
- The key scopes the **entire batch**, not individual ops.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to `ConflictError`. It carries
the structured `code` and the offending `op_index`:

```mojo
try:
    let txn = db.begin()
    txn.put("orders", cells(1, 1))
    txn.commit()
except ConflictError:
    print("constraint violated")
```

The error envelope from the daemon:

```json
{"status": "aborted", "error": {"code": "UNIQUE_VIOLATION", "message": "...", "op_index": 0}}
```

## Rollback after failure

1. **Server-side.** When `commit` raises `ConflictError`, the engine has already
   discarded the entire batch. Nothing was written.
2. **Client-side.** `txn.rollback()` clears the locally staged ops. Call it to
   release the `Transaction` when you decide not to commit (before ever sending).

```mojo
let txn = db.begin()
txn.put("orders", cells(1, 1, 2, "Iris", 3, 5.0))

if not business_rule_ok:
    txn.rollback()  # throw the staged ops away locally; nothing sent
else:
    try:
        txn.commit()
    except ConflictError:
        pass  # server already rolled back
```

`rollback` and `commit` both raise an error if the transaction was already
committed.

## Summary

| Goal | Use |
|------|-----|
| One independent write | `put` / `upsert` / `delete` / `delete_by_pk` |
| Several writes that must commit together | `begin()` + `commit(idempotency_key)` |
| Retry safely after a network blip | `commit(idempotency_key)` with a stable key |
| Distinguish constraint classes | catch `ConflictError`, read `.code()` and `.op_index()` |
| Abort before sending | `rollback()` |

See [errors.md](errors.md) for the full error hierarchy and [queries.md](queries.md)
for read patterns.
