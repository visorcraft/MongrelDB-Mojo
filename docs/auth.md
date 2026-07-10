# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Mojo client supports all three through the `MongrelDB` constructor.

---

## Bearer token mode

```mojo
let db = MongrelDB("http://127.0.0.1:8453", "s3cret-token")
try:
    let ok = db.health()
    print("healthy: " + String(ok))
except AuthError:
    print("bad or missing token")
```

A missing or wrong token surfaces as `AuthError` (HTTP 401/403). Read the token
from the environment rather than hard-coding it:

```mojo
let os_module = Python.import_module("os")
let token = String(os_module.environ.get("MONGRELDB_TOKEN", ""))
let db = MongrelDB(token)
```

## Basic auth mode

```mojo
let db = MongrelDB("http://127.0.0.1:8453", "", "admin", "s3cret")
```

The client base64-encodes `username:password` and sets `Authorization: Basic ...`
on every request.

## Token takes precedence

If you supply both, `token` wins and Basic credentials are ignored:

```mojo
let db = MongrelDB(url, "overrides-everything", "fallback", "user")
```

## CRLF validation

Credentials and request paths are validated to reject CR or LF bytes. This
prevents HTTP header injection through a malicious value - a value containing a
newline raises `QueryError` at request time.

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these through `db.sql`.

```mojo
db.sql("CREATE USER alice WITH PASSWORD 'hunter2'")
db.sql("ALTER USER alice ADMIN")
db.sql("CREATE ROLE analyst")
db.sql("GRANT SELECT ON orders TO analyst")
db.sql("GRANT analyst TO alice")
db.sql("DROP USER alice")
```

## Common pitfalls

**Auth errors look like other errors without a specific catch.** A 401/403
raises `AuthError`; a 404 raises `NotFoundError`. Always discriminate by type
rather than string-matching the message.

**Token in version control.** Put secrets in the environment, a secret manager,
or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `AuthError` and the rest of the error hierarchy
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
