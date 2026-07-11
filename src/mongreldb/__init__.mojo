"""MongrelDB Mojo client - a pure-Mojo HTTP client for mongreldb-server.

The public API surface is re-exported here for ``from mongreldb import ...``.
"""

from .mongreldb import (
    MongrelDB,
    DEFAULT_BASE_URL,
    MAX_RESPONSE_BYTES,
    _url_path_escape,
    _flatten_cells,
    _create_table_payload,
)
from .errors import (
    MongrelDBError,
    AuthError,
    NotFoundError,
    ConflictError,
    QueryError,
    ErrorDetail,
)
from .query_builder import QueryBuilder
from .transaction import Transaction
