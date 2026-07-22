# Contributing to MongrelDB Mojo

Thanks for taking the time to help the MongrelDB Mojo client. This document
describes how to propose a change and the standards that apply.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical details,
not the person.

## How to propose a change

The MongrelDB Mojo client uses a standard **fork -> branch -> pull request**
workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-Mojo`](https://github.com/visorcraft/MongrelDB-Mojo).
2. **Clone** your fork and add the upstream remote.
3. **Branch** from `master` with a descriptive, kebab-case name.
4. **Make focused commits.** One logical change per commit.
5. **Open a pull request** against `master`. Fill in: what, why, how to test,
   and risk.

## Before you push: preflight

```sh
mojo run -I src tests/live_test.mojo
```

All steps must pass. To run the live integration suite (requires a running
`mongreldb-server`):

```sh
MONGRELDB_URL=http://127.0.0.1:8453 mojo run -I src tests/live_test.mojo
```

Live tests self-skip when no server is reachable.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. Daemon-dependent coverage: a live test that
  skips cleanly when no server is available.
- The change keeps this repo a thin client over `mongreldb-server`. Don't
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code if the change affects users.
- Commits have clear messages.

## Coding standards

### Mojo

- **Version.** Mojo 24.x. Don't drop the minimum casually.
- **Dependencies.** No external packages - only the Python standard library
  (via interop) and the Mojo standard library. New dependencies must be MIT or
  Apache-2.0 licensed and justified.
- **Errors.** Raise a typed error hierarchy (`MongrelDBError` base, `AuthError`,
  `NotFoundError`, `ConflictError`, `QueryError`) carrying the HTTP status and
  decoded server envelope.
- **Naming.** Idiomatic Mojo: `snake_case` functions and variables, `PascalCase`
  structs/classes.

### Commit messages

- Subject line: imperative mood, <= 72 characters, no trailing period.
- Body: wrap at 72 characters. Explain *why*, not *what*.
- Reference issues with `Fixes #123` / `Refs #123` when applicable.
- **Never** add AI/assistant attribution.

## Issue reports

A useful bug report includes the client version, Mojo version, OS, the
`mongreldb-server` version, the exact reproduction steps, and expected vs
actual results.

## Security

If you find a vulnerability, **do not** open a public GitHub issue. Report it
privately through GitHub's private vulnerability reporting. See
[`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB Mojo client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the same
license. New third-party dependencies must be MIT or Apache-2.0 licensed.
