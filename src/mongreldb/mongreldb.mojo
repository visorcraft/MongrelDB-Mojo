# MongrelDB Mojo client.
#
# A pure-Mojo client for a running ``mongreldb-server`` daemon. It uses Python's
# ``urllib.request`` for HTTP (Mojo is a Python superset with seamless interop)
# and ``json``/``base64`` from the standard library - no external packages.
#
# The API mirrors the MongrelDB Java, Ruby, and Go clients: typed CRUD over the
# Kit transaction endpoint, a fluent query builder, idempotent batch
# transactions, full SQL access, and schema introspection.
#
# Connect with a base URL:
#
#     from mongreldb import MongrelDB
#     db = MongrelDB("http://127.0.0.1:8453")
#     print(db.health())   # True

from python import Python, PythonObject
from collections import List, Optional
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


# Default daemon address used when none is supplied.
alias DEFAULT_BASE_URL = "http://127.0.0.1:8453"

# Maximum response body size (256 MB). Bodies larger than this are aborted with
# a QueryError to guard client memory against a malicious or buggy server.
alias MAX_RESPONSE_BYTES = 268435456



fn parse_commit_hlc(raw: PythonObject) raises -> PythonObject:
    """Structural last_commit_hlc dict, or empty dict when physical_micros missing."""
    if not raw:
        return Python.dict()
    var phys = PythonObject()
    try:
        phys = raw["physical_micros"]
    except:
        return Python.dict()
    if phys is None:
        return Python.dict()
    var out = Python.dict()
    out["physical_micros"] = phys
    try:
        out["logical"] = raw["logical"]
    except:
        out["logical"] = 0
    try:
        out["node_tiebreaker"] = raw["node_tiebreaker"]
    except:
        out["node_tiebreaker"] = 0
    return out


fn commit_hlc_from_status(status: PythonObject) raises -> PythonObject:
    """Prefer durable → outcome → top-level last_commit_hlc."""
    for key in List[String]("durable", "outcome"):
        try:
            var nest = status[key]
            var hlc = parse_commit_hlc(nest["last_commit_hlc"])
            if hlc:
                return hlc
        except:
            pass
    try:
        return parse_commit_hlc(status["last_commit_hlc"])
    except:
        return Python.dict()



struct MongrelDB(Copyable, Movable):
    """The MongrelDB HTTP client.

    Construct one with the base URL of a running ``mongreldb-server`` daemon,
    then use its methods for health, table management, CRUD, query, SQL, schema,
    and maintenance.

    MongrelDB instances are cheap to create; build one per identity/config.
    """

    var base_url: String
    var _token: String
    var _username: String
    var _password: String
    var _urllib: PythonObject
    var _json: PythonObject
    var _base64: PythonObject
    var _b64encode: PythonObject
    var _http: PythonObject

    fn __init__(
        out self,
        url: String = DEFAULT_BASE_URL,
        token: String = "",
        username: String = "",
        password: String = "",
    ) raises:
        # Resolve Python's standard-library HTTP/JSON/base64 modules up front.
        self._urllib = Python.import_module("urllib.request")
        self._json = Python.import_module("json")
        self._base64 = Python.import_module("base64")
        self._b64encode = self._base64.b64encode
        self._http = _http_request_helper()
        var base = url
        while base.endswith("/"):
            base = base[: len(base) - 1]
        if len(base) == 0:
            base = DEFAULT_BASE_URL
        self.base_url = base
        self._token = token
        self._username = username
        self._password = password

    # ── Health & tables ────────────────────────────────────────────────────

    fn health(self) -> Bool:
        """Return True if the daemon answered /health with a 2xx, False on any
        error."""
        try:
            _ = self._get("/health")
            return True
        except:
            return False

    fn table_names(self) raises -> List[String]:
        """List all table names in the database."""
        var body = self._get("/tables")
        var data = _decode_json_or(self._json, body, PythonObject())
        var out = List[String]()
        try:
            for item in data:
                if item is None:
                    out.append("")
                else:
                    out.append(String(item))
        except:
            return List[String]()
        return out^

    fn set_history_retention_epochs(self, epochs: Int) raises -> PythonObject:
        """Set the durable MVCC history window and return the full response."""
        if epochs < 0:
            raise QueryError("mongreldb: history retention epochs must be non-negative")
        return _decode_json_or(
            self._json,
            self._request("PUT", "/history/retention", _history_retention_payload(epochs)),
            PythonObject(),
        )

    fn _history_retention(self) raises -> PythonObject:
        """Internal: raw GET /history/retention response."""
        return _decode_json_or(self._json, self._get("/history/retention"), PythonObject())

    fn history_retention_epochs(self) raises -> Int:
        """Return the current history retention window in epochs."""
        var data = self._history_retention()
        try:
            return Int(data["history_retention_epochs"])
        except:
            raise QueryError("mongreldb: malformed history retention response")

    fn earliest_retained_epoch(self) raises -> Int:
        """Return the oldest epoch still readable for time-travel queries."""
        var data = self._history_retention()
        try:
            return Int(data["earliest_retained_epoch"])
        except:
            raise QueryError("mongreldb: malformed history retention response")

    fn create_table(
        self,
        name: String,
        columns: PythonObject,
        constraints: Optional[PythonObject] = None,
        indexes: Optional[PythonObject] = None,
    ) raises -> Int:
        """Create a table with typed columns; return the assigned table id."""
        var payload = _create_table_payload(name, columns, constraints, indexes)
        var body = self._post("/kit/create_table", payload)
        var data = _decode_json_or(self._json, body, PythonObject())
        try:
            return Int(data["table_id"])
        except:
            return 0

    fn drop_table(self, name: String) raises -> None:
        """Drop a table by name."""
        _ = self._delete("/tables/" + _url_path_escape(name))

    fn count(self, table: String) raises -> Int:
        """Return the row count for a table."""
        var body = self._get("/tables/" + _url_path_escape(table) + "/count")
        var data = _decode_json_or(self._json, body, PythonObject())
        try:
            return Int(data["count"])
        except:
            raise QueryError("mongreldb: malformed count response")

    # ── CRUD (via the Kit typed transaction endpoint) ──────────────────────

    fn put(self, table: String, cells: PythonObject, idempotency_key: String = "") raises -> PythonObject:
        """Insert a row. ``cells`` is a column-id-to-value dict, flattened to
        the server's ``[col_id, value, ...]`` array before sending."""
        var flat = _flatten_cells(self._json, cells)
        var op = Python.dict()
        var inner = Python.dict()
        inner["table"] = table
        inner["cells"] = flat
        op["put"] = inner
        var results = self._commit_one(List[PythonObject](op), idempotency_key)
        return _first_result(results)

    fn upsert(
        self,
        table: String,
        cells: PythonObject,
        update_cells: Optional[PythonObject] = None,
        idempotency_key: String = "",
    ) raises -> PythonObject:
        """Insert a row, or update it on a primary-key conflict."""
        var flat = _flatten_cells(self._json, cells)
        var inner = Python.dict()
        inner["table"] = table
        inner["cells"] = flat
        # update_cells non-empty -> add update_cells
        if update_cells and update_cells.value():
            inner["update_cells"] = _flatten_cells(self._json, update_cells.value())
        var op = Python.dict()
        op["upsert"] = inner
        var results = self._commit_one(List[PythonObject](op), idempotency_key)
        return _first_result(results)

    fn delete(self, table: String, row_id: Int) raises -> None:
        """Remove a row by its internal row id."""
        var inner = Python.dict()
        inner["table"] = table
        inner["row_id"] = row_id
        var op = Python.dict()
        op["delete"] = inner
        _ = self._commit_one(List[PythonObject](op), "")

    fn delete_by_pk(self, table: String, pk: PythonObject) raises -> None:
        """Remove a row by its primary-key value."""
        var inner = Python.dict()
        inner["table"] = table
        inner["pk"] = pk
        var op = Python.dict()
        op["delete_by_pk"] = inner
        _ = self._commit_one(List[PythonObject](op), "")

    # ── Query ──────────────────────────────────────────────────────────────

    fn query(self, table: String) -> QueryBuilder:
        """Start a fluent QueryBuilder against ``table``."""
        return QueryBuilder(self, table)

    # ── SQL ────────────────────────────────────────────────────────────────

    fn retrieve_text(
        self,
        table: String,
        embedding_column: Int,
        text: String,
        k: Int = 0,
    ) raises -> PythonObject:
        """Text → embed → ANN retrieve (POST /kit/retrieve_text, 0.64+)."""
        if len(table) == 0:
            raise QueryError("table is required")
        if len(text) == 0:
            raise QueryError("text is required")
        var payload = Python.dict()
        payload["table"] = table
        payload["embedding_column"] = embedding_column
        payload["text"] = text
        if k > 0:
            payload["k"] = k
        var body = self._post("/kit/retrieve_text", payload)
        return _decode_json_or(self._json, body, Python.dict())

    fn query_status(self, query_id: String) raises -> PythonObject:
        """Retained SQL status for durable recovery (GET /queries/{query_id})."""
        if len(query_id) == 0:
            raise QueryError("query_id is required")
        var body = self._get("/queries/" + _url_path_escape(query_id))
        return _decode_json_or(self._json, body, Python.dict())

    fn cancel_query(self, query_id: String) raises -> PythonObject:
        """Request cancellation of a running SQL query."""
        if len(query_id) == 0:
            raise QueryError("query_id is required")
        var body = self._post(
            "/queries/" + _url_path_escape(query_id) + "/cancel",
            Python.dict(),
        )
        return _decode_json_or(self._json, body, Python.dict())

    fn sql(self, sql: String) raises -> PythonObject:
        """Execute a SQL statement via /sql requesting JSON output. Returns a
        Python list of row dicts. Empty list for DDL/DML or Arrow responses."""
        var payload = Python.dict()
        payload["sql"] = sql
        payload["format"] = "json"
        var body = self._post("/sql", payload)
        if len(body) == 0:
            return Python.list()
        var parsed = PythonObject()
        try:
            parsed = self._json.loads(body)
        except:
            return Python.list()
        try:
            var builtins = Python.import_module("builtins")
            if Bool(builtins.isinstance(parsed, builtins.list)):
                return parsed
        except:
            pass
        return Python.list()

    fn sql_arrow(self, sql: String) raises -> PythonObject:
        """Send a SQL statement requesting raw Arrow IPC bytes (format arrow).
        Returns the response body as a Python ``bytes`` object."""
        var payload = Python.dict()
        payload["sql"] = sql
        payload["format"] = "arrow"
        return self._post("/sql", payload)

    # ── Schema ─────────────────────────────────────────────────────────────

    fn schema(self) raises -> PythonObject:
        """Return the full schema catalog (a dict of table name -> descriptor)."""
        var body = self._get("/kit/schema")
        var data = _decode_json_or(self._json, body, PythonObject())
        try:
            var tables = data["tables"]
            if tables is not None:
                return tables
        except:
            pass
        return Python.dict()

    fn schema_for(self, table: String) raises -> PythonObject:
        """Return the descriptor for a single table."""
        var body = self._get("/kit/schema/" + _url_path_escape(table))
        var data = _decode_json_or(self._json, body, PythonObject())
        return data

    # ── Maintenance ────────────────────────────────────────────────────────

    fn compact(self) raises -> PythonObject:
        """Compact (merge sorted runs) across all tables."""
        return self._post_decode("/compact")

    fn compact_table(self, table: String) raises -> PythonObject:
        """Compact a single table."""
        return self._post_decode("/tables/" + _url_path_escape(table) + "/compact")

    # ── Transactions ───────────────────────────────────────────────────────

    fn begin(self) -> Transaction:
        """Begin a batch transaction."""
        return Transaction(self)

    fn _commit_txn(
        self,
        ops: List[PythonObject],
        idempotency_key: String,
    ) raises -> List[PythonObject]:
        """Send a batch of staged operations atomically."""
        if len(ops) == 0:
            return List[PythonObject]()
        var payload = Python.dict()
        payload["ops"] = _to_py_list(ops)
        if len(idempotency_key) > 0:
            payload["idempotency_key"] = idempotency_key
        var body = self._post("/kit/txn", payload)
        return _decode_results(self._json, body)

    # ── Low-level HTTP (shared with QueryBuilder/Transaction) ──────────────

    fn _get(self, path: String) raises -> PythonObject:
        return self._request("GET", path, PythonObject())

    fn _post(self, path: String, body: PythonObject) raises -> PythonObject:
        return self._request("POST", path, body)

    fn _delete(self, path: String) raises -> PythonObject:
        return self._request("DELETE", path, PythonObject())

    fn _request(self, method: String, path: String, body: PythonObject) raises -> PythonObject:
        """Perform one HTTP round trip; return the response body as Python
        ``bytes``. Non-2xx responses raise the typed error for the status."""
        _reject_crlf(path)
        var url = self.base_url + "/" + _strip_leading_slash(path)
        var payload = PythonObject()
        if body is not None and body:
            _reject_crlf_pystr(self._json, body)
            payload = self._json.dumps(body).encode("utf-8")
        var result = self._http(
            self._urllib,
            url,
            method,
            payload,
            self._auth_header(),
            60.0,
        )
        var status = Int(result[0])
        var data = result[1]
        var error_text = result[2]
        if error_text is not None:
            raise QueryError(
                "mongreldb: request " + method + " " + path + " failed: " + String(error_text)
            )
        if len(data) > MAX_RESPONSE_BYTES:
            raise QueryError(
                "mongreldb: response body exceeds maximum size of "
                + String(MAX_RESPONSE_BYTES) + " bytes"
            )
        if status > 0:
            var err = _to_exception(self._json, status, data)
            raise err
        return data

    fn _auth_header(self) raises -> PythonObject:
        """The Authorization header value, or None when no credentials set.
        A bearer token takes precedence over basic auth."""
        if len(self._token) > 0:
            _reject_crlf(self._token)
            return Python.str("Bearer " + self._token)
        if len(self._username) > 0:
            _reject_crlf(self._username)
            _reject_crlf(self._password)
            var creds = self._username + ":" + self._password
            var encoded = self._b64encode(Python.str(creds).encode("utf-8"))
            return Python.str("Basic " + String(encoded.decode("ascii")))
        return PythonObject()

    fn _commit_one(self, ops: List[PythonObject], idempotency_key: String) raises -> List[PythonObject]:
        var payload = Python.dict()
        payload["ops"] = _to_py_list(ops)
        if len(idempotency_key) > 0:
            payload["idempotency_key"] = idempotency_key
        var body = self._post("/kit/txn", payload)
        return _decode_results(self._json, body)

    fn _post_decode(self, path: String) raises -> PythonObject:
        var body = self._post(path, PythonObject())
        var data = _decode_json_or(self._json, body, PythonObject())
        return data


# ── Module-level helpers ────────────────────────────────────────────────────


def _http_request_helper() -> PythonObject:
    """Define the urllib-based request helper and return it.

    Mojo cannot catch Python exceptions by type, so the round trip runs inside
    a small Python function that never raises: it returns
    ``(status, body, error_text)`` where ``status`` is 0 on success, an HTTP
    status code on an HTTP error response, and ``error_text`` carries the
    transport failure message otherwise.
    """
    builtins = Python.import_module("builtins")
    src = (
        "def _mongreldb_http_request(urllib_request, url, method, payload, auth_header, timeout):\n" +
        "    headers = {'Accept': 'application/json'}\n" +
        "    if auth_header is not None:\n" +
        "        headers['Authorization'] = auth_header\n" +
        "    if payload is not None:\n" +
        "        headers['Content-Type'] = 'application/json'\n" +
        "    req = urllib_request.Request(url, payload, headers, method=method)\n" +
        "    try:\n" +
        "        with urllib_request.urlopen(req, timeout=timeout) as response:\n" +
        "            return (0, response.read(), None)\n" +
        "    except Exception as exc:\n" +
        "        status = getattr(exc, 'code', None) or 0\n" +
        "        if status:\n" +
        "            try:\n" +
        "                body = exc.read()\n" +
        "            except Exception:\n" +
        "                body = b''\n" +
        "            return (status, body, None)\n" +
        "        return (0, b'', str(exc))\n"
    )
    ns = Python.dict()
    builtins.exec(src, ns)
    return ns["_mongreldb_http_request"]


def _create_table_payload(
    name: String,
    columns: PythonObject,
    constraints: Optional[PythonObject] = None,
    indexes: Optional[PythonObject] = None,
) -> PythonObject:
    """Build the object posted to /kit/create_table."""
    payload = Python.dict()
    payload["name"] = name
    payload["columns"] = columns
    if constraints:
        payload["constraints"] = constraints.value()
    if indexes:
        payload["indexes"] = indexes.value()
    return payload


def _history_retention_payload(epochs: Int) -> PythonObject:
    """Build the object posted to PUT /history/retention."""
    payload = Python.dict()
    payload["history_retention_epochs"] = epochs
    return payload


def _flatten_cells(json_module: PythonObject, cells: PythonObject) -> PythonObject:
    """Flatten a column-id-to-value dict to the server's [col_id, value, ...]
    list in ascending column-id order. Stable ordering is required for
    idempotency keys: the server hashes the request payload, and unordered
    dict iteration would make two commits of the same cells look like a reuse
    mismatch."""
    out = Python.list()
    # Sort by column id for stable JSON payload hashing.
    builtins = Python.import_module("builtins")
    keys = builtins.sorted(cells.keys(), key=builtins.int)
    for k in keys:
        out.append(k)
        out.append(cells[k])
    return out


def _decode_results(json_module: PythonObject, body: PythonObject) -> List[PythonObject]:
    """Pull the results array out of a /kit/txn response."""
    out = List[PythonObject]()
    if len(body) == 0:
        return out^
    parsed = PythonObject()
    try:
        parsed = json_module.loads(body)
    except:
        raise QueryError("mongreldb: failed to decode transaction response")
    try:
        results = parsed["results"]
        if results is None:
            return out^
        for r in results:
            out.append(r)
    except:
        pass
    return out^


def _first_result(results: List[PythonObject]) -> PythonObject:
    if len(results) == 0:
        return Python.dict()
    return results[0]


def _decode_json_or(json_module: PythonObject, body: PythonObject, fallback: PythonObject) -> PythonObject:
    if len(body) == 0:
        return fallback
    try:
        return json_module.loads(body)
    except:
        return fallback


def _to_py_list(items: List[PythonObject]) -> PythonObject:
    out = Python.list()
    for item in items:
        out.append(item)
    return out


def _reject_crlf(s: String):
    if "\r" in s or "\n" in s:
        raise QueryError("mongreldb: illegal CR/LF in value: " + s)


def _reject_crlf_pystr(json_module: PythonObject, body: PythonObject):
    """Best-effort CRLF check on a payload about to be serialized."""
    text = String("")
    try:
        text = String(json_module.dumps(body))
    except:
        return
    _reject_crlf(text)


def _url_path_escape(segment: String) -> String:
    """Percent-encode a path segment so table names containing '/', '?', '#', or
    spaces cannot inject extra segments. Only RFC 3986 unreserved characters pass
    through; '/' is encoded as %2F."""
    out = String("")
    unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    for c in segment:
        if c in unreserved:
            out += c
        else:
            for b in c.as_bytes():
                out += "%" + _hex(Int(b))
    return out


def _hex(b: Int) -> String:
    n = b & 0xFF
    hi = (n >> 4) & 0x0F
    lo = n & 0x0F
    digits = "0123456789ABCDEF"
    return digits[hi] + digits[lo]


def _strip_leading_slash(s: String) -> String:
    r = s
    while r.startswith("/"):
        r = r[1:]
    return r


fn _to_exception(read json_module: PythonObject, status: Int, read body: PythonObject) raises -> Error:
    """Map an HTTP status + body to a typed error. Best-effort decodes the
    server's JSON error envelope and falls back to the raw body."""
    message = String("")
    code = String("")
    op_index = -1

    trimmed = String("")
    try:
        trimmed = String(String(body.decode("utf-8", "replace")).strip())
    except:
        pass
    if len(trimmed) > 0 and trimmed[0] == "{":
        try:
            obj = json_module.loads(body)
            try:
                err = obj["error"]
                if err is not None:
                    message = _py_str_or(err["message"])
                    code = _py_str_or(err["code"])
                    try:
                        op_index = Int(err["op_index"])
                    except:
                        pass
            except:
                pass
            if len(message) == 0 and len(code) == 0 and op_index == -1:
                try:
                    message = _py_str_or(obj["message"])
                    code = _py_str_or(obj["code"])
                except:
                    pass
        except:
            pass

    if len(message) == 0 and len(body) > 0:
        try:
            message = String(body.decode("utf-8", "replace"))
        except:
            pass

    if len(message) == 0:
        if status == 401 or status == 403:
            message = "authentication failed (" + String(status) + ")"
        elif status == 404:
            message = "resource not found"
        elif status == 409:
            message = "constraint violation"
        else:
            message = "server error (" + String(status) + ")"

    detail = ErrorDetail(status, code, op_index)
    if status == 401 or status == 403:
        return AuthError(message, detail)
    if status == 404:
        return NotFoundError(message, detail)
    if status == 409:
        return ConflictError(message, detail)
    return QueryError(message, detail)


def _py_str_or(value: PythonObject) -> String:
    if value is None:
        return ""
    try:
        return String(value)
    except:
        return ""
