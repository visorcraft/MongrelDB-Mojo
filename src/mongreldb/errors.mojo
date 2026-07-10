# MongrelDB client error hierarchy.
#
# Every non-2xx response from the daemon is mapped to a typed error subclass of
# MongrelDBError. Catch the specific subclass for a category, or MongrelDBError
# for any client failure.

from python import Python


@value
final struct ErrorDetail:
    """HTTP status, structured code, and offending op index carried by errors."""
    var status: Int
    var code: String
    var op_index: Int

    fn __init__() -> Self:
        return Self(status=-1, code="", op_index=-1)

    fn __init__(status: Int, code: String = "", op_index: Int = -1) -> Self:
        return Self(status=status, code=code, op_index=op_index)


class MongrelDBError(Error):
    """Base class for all errors raised by the MongrelDB client.

    Carries an HTTP status, the server's structured error code (e.g.
    ``UNIQUE_VIOLATION``), and the offending op index within a transaction
    (when the daemon reports one).
    """

    var detail: ErrorDetail

    fn __init__(message: String, detail: ErrorDetail = ErrorDetail()):
        super.__init__(message)
        self.detail = detail

    fn status() -> Int:
        """The HTTP status code returned by the daemon, or -1 when unknown."""
        return self.detail.status

    fn code() -> String:
        """The server's structured error code, or "" when absent."""
        return self.detail.code

    fn op_index() -> Int:
        """The offending op index within a batch, or -1 when not reported."""
        return self.detail.op_index


class AuthError(MongrelDBError):
    """Raised for HTTP 401 or 403 responses - bad or missing credentials."""
    pass


class NotFoundError(MongrelDBError):
    """Raised for HTTP 404 responses - a missing table, schema, or resource."""
    pass


class ConflictError(MongrelDBError):
    """Raised for HTTP 409 responses - a unique, foreign-key, check, or trigger
    constraint violation. Carries the server's structured error code and the
    offending op index within the batch."""
    pass


class QueryError(MongrelDBError):
    """Raised for HTTP 400 or 5xx responses, and for any other request-level
    failure not covered by AuthError, NotFoundError, or ConflictError. This is
    the catch-all for malformed queries, server-side errors, and transport
    failures."""
    pass
