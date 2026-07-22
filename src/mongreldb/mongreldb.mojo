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

from python import Python
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
const DEFAULT_BASE_URL = "http://127.0.0.1:8453"

# Maximum response body size (256 MB). Bodies larger than this are aborted with
# a QueryError to guard client memory against a malicious or buggy server.
const MAX_RESPONSE_BYTES = 268435456



fn parse_commit_hlc(raw: PythonObject) raises -> PythonObject:
    """Structural last_commit_hlc dict, or empty dict when physical_micros missing."""
    if not raw:
        return Python.dict()
    try:
        phys = raw["physical_micros"]
    except Exception:
        return Python.dict()
    if phys is None:
        return Python.dict()
    out = Python.dict()
    out["physical_micros"] = phys
    try:
        out["logical"] = raw["logical"]
    except Exception:
        out["logical"] = 0
    try:
        out["node_tiebreaker"] = raw["node_tiebreaker"]
    except Exception:
        out["node_tiebreaker"] = 0
    return out


fn commit_hlc_from_status(status: PythonObject) raises -> PythonObject:
    """Prefer durable → outcome → top-level last_commit_hlc."""
    for key in ("durable", "outcome"):
        try:
            nest = status[key]
            hlc = parse_commit_hlc(nest["last_commit_hlc"])
            if hlc:
                return hlc
        except Exception:
            pass
    try:
        return parse_commit_hlc(status["last_commit_hlc"])
    except Exception:
        return Python.dict()



struct MongrelDB:
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

    fn __init__(
        url: String = DEFAULT_BASE_URL,
        token: String = "",
        username: String = "",
        password: String = "",
    ):
        # Resolve Python's standard-library HTTP/JSON/base64 modules up front.
        self._urllib = Python.import_module("urllib.request")
        self._json = Python.import_module("json")
        self._base64 = Python.import_module("base64")
        self._b64encode = self._base64.b64encode
        base = url
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
            self._get("/health")
            return True
        except:
            return False

    fn table_names(self) -> List[String]:
        """List all table names in the database."""
        body = self._get("/tables")
        data = _decode_json_or(self._json, body, PythonObject())
        try:
            raw = data.to_list()
            out = List[String]()
            for item in raw:
                out.append(String(item) if item is not None else "")
            return out
        except:
            return List[String]()

    fn set_history_retention_epochs(self, epochs: Int) -> PythonObject:
        """Set the durable MVCC history window and return the full response."""
        if epochs < 0:
            raise QueryError("mongreldb: history retention epochs must be non-negative")
        return _decode_json_or(
            self._json,
            self._request("PUT", "/history/retention", _history_retention_payload(epochs)),
            PythonObject(),
        )

    fn _history_retention(self) -> PythonObject:
        """Internal: raw GET /history/retention response."""
        return _decode_json_or(self._json, self._get("/history/retention"), PythonObject())

    fn history_retention_epochs(self) -> Int:
        """Return the current history retention window in epochs."""
        data = self._history_retention()
        try:
            return Int(data.__getitem__("history_retention_epochs"))
        except:
            raise QueryError("mongreldb: malformed history retention response")

    fn earliest_retained_epoch(self) -> Int:
        """Return the oldest epoch still readable for time-travel queries."""
        data = self._history_retention()
        try:
            return Int(data.__getitem__("earliest_retained_epoch"))
        except:
            raise QueryError("mongreldb: malformed history retention response")

    fn create_table(
        self,
        name: String,
        columns: PythonObject,
        constraints: PythonObject = PythonObject(),
        indexes: PythonObject = PythonObject(),
    ) -> Int:
        """Create a table with typed columns; return the assigned table id."""
        payload = _create_table_payload(name, columns, constraints, indexes)
        body = self._post("/kit/create_table", payload)
        data = _decode_json_or(self._json, body, PythonObject())
        try:
            return Int(data.__getitem__("table_id"))
        except:
            return 0

    fn drop_table(self, name: String) -> None:
        """Drop a table by name."""
        self._delete("/tables/" + _url_path_escape(name))

    fn count(self, table: String) -> Int:
        """Return the row count for a table."""
        body = self._get("/tables/" + _url_path_escape(table) + "/count")
        data = _decode_json_or(self._json, body, PythonObject())
        try:
            return Int(data.__getitem__("count"))
        except:
            raise QueryError("mongreldb: malformed count response")

    # ── CRUD (via the Kit typed transaction endpoint) ──────────────────────

    fn put(self, table: String, cells: PythonObject, idempotency_key: String = "") -> PythonObject:
        """Insert a row. ``cells`` is a column-id-to-value dict, flattened to
        the server's ``[col_id, value, ...]`` array before sending."""
        flat = _flatten_cells(self._json, cells)
        op = Python.dict()
        inner = Python.dict()
        inner.__setitem__("table", Python.str(table))
        inner.__setitem__("cells", flat)
        op.__setitem__("put", inner)
        results = self._commit_one([op], idempotency_key)
        return _first_result(results)

    fn upsert(
        self,
        table: String,
        cells: PythonObject,
        update_cells: PythonObject = PythonObject(),
        idempotency_key: String = "",
    ) -> PythonObject:
        """Insert a row, or update it on a primary-key conflict."""
        flat = _flatten_cells(self._json, cells)
        inner = Python.dict()
        inner.__setitem__("table", Python.str(table))
        inner.__setitem__("cells", flat)
        try:
            # update_cells non-empty -> add update_cells
            _ = update_cells.to_list()
            inner.__setitem__("update_cells", _flatten_cells(self._json, update_cells))
        except:
            pass
        op = Python.dict()
        op.__setitem__("upsert", inner)
        results = self._commit_one([op], idempotency_key)
        return _first_result(results)

    fn delete(self, table: String, row_id: Int) -> None:
        """Remove a row by its internal row id."""
        inner = Python.dict()
        inner.__setitem__("table", Python.str(table))
        inner.__setitem__("row_id", Python.object(row_id))
        op = Python.dict()
        op.__setitem__("delete", inner)
        self._commit_one([op], "")

    fn delete_by_pk(self, table: String, pk: PythonObject) -> None:
        """Remove a row by its primary-key value."""
        inner = Python.dict()
        inner.__setitem__("table", Python.str(table))
        inner.__setitem__("pk", pk)
        op = Python.dict()
        op.__setitem__("delete_by_pk", inner)
        self._commit_one([op], "")

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
    ) -> PythonObject:
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

    fn query_status(self, query_id: String) -> PythonObject:
        """Retained SQL status for durable recovery (GET /queries/{query_id})."""
        if len(query_id) == 0:
            raise QueryError("query_id is required")
        var body = self._get("/queries/" + _url_path_escape(query_id))
        return _decode_json_or(self._json, body, Python.dict())

    fn cancel_query(self, query_id: String) -> PythonObject:
        """Request cancellation of a running SQL query."""
        if len(query_id) == 0:
            raise QueryError("query_id is required")
        var body = self._post(
            "/queries/" + _url_path_escape(query_id) + "/cancel",
            Python.dict(),
        )
        return _decode_json_or(self._json, body, Python.dict())

    fn sql(self, sql: String) -> PythonObject:
        """Execute a SQL statement via /sql requesting JSON output. Returns a
        Python list of row dicts. Empty list for DDL/DML or Arrow responses."""
        payload = Python.dict()
        payload.__setitem__("sql", Python.str(sql))
        payload.__setitem__("format", "json")
        body = self._post("/sql", payload)
        if len(body) == 0:
            return Python.list()
        try:
            parsed = self._json.loads(Python.bytes(body))
        except:
            return Python.list()
        try:
            return parsed.to_list()
        except:
            return Python.list()

    fn sql_arrow(self, sql: String) -> Bytes:
        """Send a SQL statement requesting raw Arrow IPC bytes (format arrow)."""
        payload = Python.dict()
        payload.__setitem__("sql", Python.str(sql))
        payload.__setitem__("format", "arrow")
        return Bytes(self._post("/sql", payload))

    # ── Schema ─────────────────────────────────────────────────────────────

    fn schema(self) -> PythonObject:
        """Return the full schema catalog (a dict of table name -> descriptor)."""
        body = self._get("/kit/schema")
        data = _decode_json_or(self._json, body, PythonObject())
        try:
            tables = data.__getitem__("tables")
            return tables if tables is not None else Python.dict()
        except:
            return Python.dict()

    fn schema_for(self, table: String) -> PythonObject:
        """Return the descriptor for a single table."""
        body = self._get("/kit/schema/" + _url_path_escape(table))
        data = _decode_json_or(self._json, body, PythonObject())
        return data

    # ── Maintenance ────────────────────────────────────────────────────────

    fn compact(self) -> PythonObject:
        """Compact (merge sorted runs) across all tables."""
        return self._post_decode("/compact")

    fn compact_table(self, table: String) -> PythonObject:
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
    ) -> List[PythonObject]:
        """Send a batch of staged operations atomically."""
        if len(ops) == 0:
            return List[PythonObject]()
        payload = Python.dict()
        payload.__setitem__("ops", _to_py_list(ops))
        if len(idempotency_key) > 0:
            payload.__setitem__("idempotency_key", Python.str(idempotency_key))
        body = self._post("/kit/txn", payload)
        return _decode_results(self._json, body)

    # ── Low-level HTTP (shared with QueryBuilder/Transaction) ──────────────

    fn _get(self, path: String) -> Bytes:
        return self._request("GET", path, PythonObject())

    fn _post(self, path: String, body: PythonObject) -> Bytes:
        return self._request("POST", path, body)

    fn _delete(self, path: String) -> Bytes:
        return self._request("DELETE", path, PythonObject())

    fn _request(self, method: String, path: String, body: PythonObject) -> Bytes:
        _reject_crlf(path)
        url = self.base_url + "/" + _strip_leading_slash(path)
        request_builder = self._urllib.Request
        kw = Python.dict()
        kw.__setitem__("method", Python.str(method))
        if body is not None and body:
            _reject_crlf_pystr(self._json, body)
            payload_bytes = Python.bytes(self._json.dumps(body).encode("utf-8"))
            req = request_builder(Python.str(url), payload_bytes, kw)
            req.add_header("Content-Type", "application/json")
        else:
            req = request_builder(Python.str(url), kw=kw)
        req.add_header("Accept", "application/json")
        self._apply_auth(req)

        try:
            with self._urllib.urlopen(req, timeout=60.0) as response:
                data = Bytes(response.read())
        except PythonObject as e:
            # urllib raises HTTPError (a subclass of URLError) for non-2xx; it
            # carries the status code and body.
            status = _extract_http_status(e)
            if status > 0:
                body_bytes = _extract_http_body(e)
                if len(body_bytes) > MAX_RESPONSE_BYTES:
                    raise QueryError(
                        "mongreldb: response body exceeds maximum size of "
                        + String(MAX_RESPONSE_BYTES) + " bytes"
                    )
                raise _to_exception(self._json, status, body_bytes)
            raise QueryError("mongreldb: request " + method + " " + path + " failed: " + str(e))

        if len(data) > MAX_RESPONSE_BYTES:
            raise QueryError(
                "mongreldb: response body exceeds maximum size of "
                + String(MAX_RESPONSE_BYTES) + " bytes"
            )
        return data

    fn _apply_auth(self, req: PythonObject):
        # A bearer token takes precedence over basic auth.
        if len(self._token) > 0:
            _reject_crlf(self._token)
            req.add_header("Authorization", "Bearer " + self._token)
        elif len(self._username) > 0:
            _reject_crlf(self._username)
            _reject_crlf(self._password)
            creds = self._username + ":" + self._password
            encoded = self._b64encode(creds.encode("utf-8"))
            req.add_header("Authorization", "Basic " + String(encoded.decode("ascii")))

    fn _commit_one(self, ops: List[PythonObject], idempotency_key: String) -> List[PythonObject]:
        payload = Python.dict()
        payload.__setitem__("ops", _to_py_list(ops))
        if len(idempotency_key) > 0:
            payload.__setitem__("idempotency_key", Python.str(idempotency_key))
        body = self._post("/kit/txn", payload)
        return _decode_results(self._json, body)

    fn _post_decode(self, path: String) -> PythonObject:
        body = self._post(path, PythonObject())
        data = _decode_json_or(self._json, body, PythonObject())
        return data


# ── Module-level helpers ────────────────────────────────────────────────────


def _create_table_payload(
    name: String,
    columns: PythonObject,
    constraints: PythonObject = PythonObject(),
    indexes: PythonObject = PythonObject(),
) -> PythonObject:
    """Build the object posted to /kit/create_table."""
    payload = Python.dict()
    payload.__setitem__("name", Python.str(name))
    payload.__setitem__("columns", columns)
    if constraints is not None:
        payload.__setitem__("constraints", constraints)
    if indexes is not None:
        payload.__setitem__("indexes", indexes)
    return payload


def _history_retention_payload(epochs: Int) -> PythonObject:
    """Build the object posted to PUT /history/retention."""
    payload = Python.dict()
    payload.__setitem__("history_retention_epochs", Python.object(epochs))
    return payload


def _flatten_cells(json_module: PythonObject, cells: PythonObject) -> PythonObject:
    """Flatten a column-id-to-value dict to the server's [col_id, value, ...]
    list in ascending column-id order. Stable ordering is required for
    idempotency keys: the server hashes the request payload, and unordered
    dict iteration would make two commits of the same cells look like a reuse
    mismatch."""
    out = json_module.list()
    # Sort by column id for stable JSON payload hashing.
    keys = list(cells.keys())
    keys.sort(key=lambda k: int(k))
    for k in keys:
        out.append(k)
        out.append(cells.__getitem__(k))
    return out


def _decode_results(json_module: PythonObject, body: Bytes) -> List[PythonObject]:
    """Pull the results array out of a /kit/txn response."""
    out = List[PythonObject]()
    if len(body) == 0:
        return out
    try:
        parsed = json_module.loads(Python.bytes(body))
    except:
        raise QueryError("mongreldb: failed to decode transaction response")
    try:
        results = parsed.__getitem__("results")
        if results is None:
            return out
        for r in results.to_list():
            out.append(r)
    except:
        pass
    return out


def _first_result(results: List[PythonObject]) -> PythonObject:
    if len(results) == 0:
        return Python.dict()
    return results[0]


def _decode_json_or(json_module: PythonObject, body: Bytes, fallback: PythonObject) -> PythonObject:
    if len(body) == 0:
        return fallback
    try:
        return json_module.loads(Python.bytes(body))
    except:
        return fallback


def _to_py_list(items: List[PythonObject]) -> PythonObject:
    out = Python.list()
    for item in items:
        out.append(item)
    return out


def _reject_crlf(s: String):
    if s.count("\r") > 0 or s.count("\n") > 0:
        raise QueryError("mongreldb: illegal CR/LF in value: " + s)


def _reject_crlf_pystr(json_module: PythonObject, body: PythonObject):
    """Best-effort CRLF check on a payload about to be serialized."""
    try:
        _reject_crlf(String(json_module.dumps(body)))
    except QueryError:
        raise
    except:
        pass


def _url_path_escape(segment: String) -> String:
    """Percent-encode a path segment so table names containing '/', '?', '#', or
    spaces cannot inject extra segments. Only RFC 3986 unreserved characters pass
    through; '/' is encoded as %2F."""
    out = String("")
    unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    for c in segment:
        if unreserved.contains(c):
            out += c
        else:
            for b in c.encode("utf-8").to_list():
                out += "%" + _hex(b)
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


def _extract_http_status(err: PythonObject) -> Int:
    try:
        return Int(err.code)
    except:
        return 0


def _extract_http_body(err: PythonObject) -> Bytes:
    try:
        return Bytes(err.read())
    except:
        return Bytes()


def _to_exception(json_module: PythonObject, status: Int, body: Bytes) -> MongrelDBError:
    """Map an HTTP status + body to a typed exception. Best-effort decodes the
    server's JSON error envelope and falls back to the raw body."""
    message = ""
    code = ""
    op_index = -1

    trimmed = String(body)
    trimmed = trimmed.strip()
    if len(trimmed) > 0 and trimmed[0] == "{":
        try:
            obj = json_module.loads(Python.bytes(body))
            try:
                err = obj.__getitem__("error")
                if err is not None:
                    message = _py_str_or(err.__getitem__("message"))
                    code = _py_str_or(err.__getitem__("code"))
                    try:
                        op_index = Int(err.__getitem__("op_index"))
                    except:
                        pass
            except:
                pass
            if len(message) == 0 and len(code) == 0 and op_index == -1:
                try:
                    message = _py_str_or(obj.__getitem__("message"))
                    code = _py_str_or(obj.__getitem__("code"))
                except:
                    pass
        except:
            pass

    if len(message) == 0 and len(body) > 0:
        message = String(body)

    if len(message) == 0:
        if status == 401 or status == 403:
            message = "authentication failed (" + String(status) + ")"
        elif status == 404:
            message = "resource not found"
        elif status == 409:
            message = "constraint violation"
        else:
            message = "server error (" + String(status) + ")"

    detail = ErrorDetail(status=status, code=code, op_index=op_index)
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
