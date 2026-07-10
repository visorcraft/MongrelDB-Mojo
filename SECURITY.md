# Security

This document describes the security properties of the MongrelDB Mojo client
and how to report vulnerabilities.

## Overview

The MongrelDB Mojo client is a pure-Mojo library that talks to `mongreldb-server`
over HTTP using Python's standard-library `urllib.request` (via Mojo's seamless
Python interop). The client holds no encryption keys and stores no data at rest;
it is a thin request/response layer over the daemon.

## Client security properties

- The client communicates with `mongreldb-server` over plain HTTP. The daemon
  binds to `127.0.0.1` by default. For remote or multi-tenant deployments,
  terminate TLS in a reverse proxy (nginx, Caddy) in front of the daemon.
- The client supports Bearer token and HTTP Basic auth, matching the daemon's
  `--auth-token` and `--auth-users` modes. Credentials are sent only in the
  `Authorization` header and are never logged.
- **CRLF validation:** credentials and request paths are validated to reject CR
  or LF bytes, preventing HTTP header injection through a malicious value.
- The native condition API and query builder accept typed parameters - no string
  interpolation, no SQL injection surface.
- **WARNING - raw SQL:** The `sql()` method sends a raw SQL string to the server.
  It does NOT parameterize or sanitize input. Never interpolate untrusted user
  input into SQL statements.
- **Response size limit:** responses larger than 256 MB are aborted with a
  `QueryError` to guard client memory against a malicious or buggy server.
- Idempotency keys are caller-supplied opaque strings; the client does not
  derive or store them.

## Daemon security (mongreldb-server)

- Binds to `127.0.0.1` only - not accessible from other machines.
- **No authentication by default.** Enable `--auth-token` or `--auth-users` for
  any shared host.
- No TLS - traffic is plaintext on the loopback interface.

For remote access, place a reverse proxy with TLS termination in front. Do not
expose the daemon directly to a network.

## Reporting a vulnerability

**Do not file a public GitHub issue.** Report privately through **GitHub's
private vulnerability reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form.

Please include a description, reproduction steps, the client/Mojo/OS versions,
the `mongreldb-server` version, and any proof-of-concept.

### What to expect

- Acknowledgement within a few days.
- An initial assessment and remediation plan.
- Progress updates through the private advisory thread until resolved.
- Credit for responsible disclosure, unless you prefer anonymity.
