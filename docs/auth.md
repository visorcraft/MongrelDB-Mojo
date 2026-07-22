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
var db = MongrelDB("http://127.0.0.1:8453", "s3cret-token")
var ok = db.health()
if not ok:
    print("bad or missing token, or daemon down")
```

For requests beyond `health` (which swallows errors by design), an
`AuthError`-category error is raised; match the category prefix in the message:

```mojo
try:
    _ = db.schema()
except e:
    if String(e).contains("AuthError"):
        print("bad or missing token")
```

A missing or wrong token surfaces as `AuthError` (HTTP 401/403). Read the token
from the environment rather than hard-coding it:

```mojo
var os_module = Python.import_module("os")
var token = String(os_module.environ.get("MONGRELDB_TOKEN", ""))
var db = MongrelDB("http://127.0.0.1:8453", token)
```

## Basic auth mode

```mojo
var db = MongrelDB("http://127.0.0.1:8453", "", "admin", "s3cret")
```

The client base64-encodes `username:password` and sets `Authorization: Basic ...`
on every request.

## Token takes precedence

If you supply both, `token` wins and Basic credentials are ignored:

```mojo
var db = MongrelDB(url, "overrides-everything", "fallback", "user")
```

## CRLF validation

Credentials and request paths are validated to reject CR or LF bytes. This
prevents HTTP header injection through a malicious value - a value containing a
newline raises `QueryError` at request time.

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these through `db.sql`.

```mojo
_ = db.sql("CREATE USER alice WITH PASSWORD 'hunter2'")
_ = db.sql("ALTER USER alice ADMIN")
_ = db.sql("CREATE ROLE analyst")
_ = db.sql("GRANT SELECT ON orders TO analyst")
_ = db.sql("GRANT analyst TO alice")
_ = db.sql("DROP USER alice")
```

## Common pitfalls

**Auth errors look like other errors without a category check.** A 401/403
raises an `AuthError`-category error; a 404 raises `NotFoundError`. Mojo raises
only the built-in `Error` type, so discriminate by the category prefix in the
message (see [errors.md](errors.md)).

**Token in version control.** Put secrets in the environment, a secret manager,
or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `AuthError` and the rest of the error categories
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
