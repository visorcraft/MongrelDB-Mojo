# MongrelDB client error hierarchy.
#
# Every non-2xx response from the daemon is mapped to a typed error category
# matching the other MongrelDB language clients. Mojo can only raise the
# built-in ``Error`` type (exception subclassing does not exist), so the
# categories are modelled as ``Error`` constructors: each embeds the category
# name plus the HTTP status, structured code, and offending op index in the
# message. Catch with ``except`` and inspect the message, or match on the
# category prefix.

struct ErrorDetail(Copyable, Movable):
    """HTTP status, structured code, and offending op index carried by errors."""
    var status: Int
    var code: String
    var op_index: Int

    fn __init__(out self):
        self.status = -1
        self.code = ""
        self.op_index = -1

    fn __init__(out self, status: Int, code: String = "", op_index: Int = -1):
        self.status = status
        self.code = code
        self.op_index = op_index


fn _format_error(category: String, message: String, detail: ErrorDetail) -> Error:
    var text = category + ": " + message
    if detail.status >= 0:
        text += " (status=" + String(detail.status)
        if len(detail.code) > 0:
            text += ", code=" + detail.code
        if detail.op_index >= 0:
            text += ", op_index=" + String(detail.op_index)
        text += ")"
    return Error(text)


fn MongrelDBError(message: String, detail: ErrorDetail = ErrorDetail()) -> Error:
    """Base category for all errors raised by the MongrelDB client.

    Carries an HTTP status, the server's structured error code (e.g.
    ``UNIQUE_VIOLATION``), and the offending op index within a transaction
    (when the daemon reports one).
    """
    return _format_error("MongrelDBError", message, detail)


fn AuthError(message: String, detail: ErrorDetail = ErrorDetail()) -> Error:
    """Raised for HTTP 401 or 403 responses - bad or missing credentials."""
    return _format_error("AuthError", message, detail)


fn NotFoundError(message: String, detail: ErrorDetail = ErrorDetail()) -> Error:
    """Raised for HTTP 404 responses - a missing table, schema, or resource."""
    return _format_error("NotFoundError", message, detail)


fn ConflictError(message: String, detail: ErrorDetail = ErrorDetail()) -> Error:
    """Raised for HTTP 409 responses - a unique, foreign-key, check, or trigger
    constraint violation. Carries the server's structured error code and the
    offending op index within the batch."""
    return _format_error("ConflictError", message, detail)


fn QueryError(message: String, detail: ErrorDetail = ErrorDetail()) -> Error:
    """Raised for HTTP 400 or 5xx responses, and for any other request-level
    failure not covered by AuthError, NotFoundError, or ConflictError. This is
    the catch-all for malformed queries, server-side errors, and transport
    failures."""
    return _format_error("QueryError", message, detail)
