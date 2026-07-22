# QueryBuilder for the daemon's /kit/query endpoint.
#
# Conditions push down to the engine's specialized indexes for sub-millisecond
# lookups. Condition parameters accept friendly aliases that are translated to
# the server's exact on-wire keys before sending:
#
#   column        -> column_id
#   min / max     -> lo / hi
#   min_inclusive -> lo_inclusive
#   max_inclusive -> hi_inclusive
#
# The server's canonical keys are accepted directly too.

from python import Python, PythonObject
from collections import List
from .mongreldb import MongrelDB, _url_path_escape  # noqa: F401 (re-export helper)
from .errors import QueryError


struct QueryBuilder(Copyable, Movable):
    """A fluent builder for /kit/query requests.

    Normally created via ``MongrelDB.query(table)``. Use ``where`` to add native
    conditions (AND-ed), ``projection``/``limit`` to shape the result, and
    ``execute`` to send and decode. Read ``truncated`` after ``execute`` to
    detect whether the result was capped by the limit.

    Builder methods return a new builder (Mojo value semantics): bind the
    result, e.g. ``var q = db.query(t).where("pk", params)``.
    """

    var _client: MongrelDB
    var _table: String
    var _conditions: List[PythonObject]
    var _projection: PythonObject
    var _limit: Int
    var _offset: Int
    var _has_offset: Bool
    var _last_truncated: Bool

    fn __init__(out self, client: MongrelDB, table: String):
        self._client = client.copy()
        self._table = table
        self._conditions = List[PythonObject]()
        self._projection = PythonObject()  # None
        self._limit = -1
        self._offset = -1
        self._has_offset = False
        self._last_truncated = False

    fn where(read self, cond_type: String, params: PythonObject) raises -> Self:
        """Add a native condition (AND-ed). Friendly aliases are accepted.

        Available condition types include ``pk``, ``bitmap_eq``, ``bitmap_in``,
        ``range``, ``range_f64``, ``is_null``, ``is_not_null``, ``fm_contains``,
        ``fm_contains_all``, ``ann``, ``sparse_match``, ``min_hash_similar``.
        """
        var copy = self.copy()
        var entry = Python.dict()
        entry[cond_type] = _normalize_condition(cond_type, params)
        copy._conditions.append(entry)
        return copy^

    fn projection(read self, column_ids: PythonObject) -> Self:
        """Set the column ids to return. None means all columns."""
        var copy = self.copy()
        copy._projection = column_ids
        return copy^

    fn limit(read self, n: Int) -> Self:
        """Cap the number of rows returned."""
        var copy = self.copy()
        copy._limit = n
        return copy^

    fn offset(read self, n: Int) -> Self:
        """Skip matching rows before applying the limit."""
        var copy = self.copy()
        copy._offset = n
        copy._has_offset = True
        return copy^

    fn build(self) raises -> PythonObject:
        """Build the request payload that will be sent to /kit/query."""
        var payload = Python.dict()
        payload["table"] = self._table
        if len(self._conditions) > 0:
            var conds = Python.list()
            for c in self._conditions:
                conds.append(c)
            payload["conditions"] = conds
        if self._projection:
            payload["projection"] = self._projection
        if self._limit >= 0:
            payload["limit"] = self._limit
        if self._has_offset:
            payload["offset"] = self._offset
        return payload

    fn execute(mut self) raises -> PythonObject:
        """Run the query and return the matching rows. Records the truncated
        flag; check it with ``truncated``."""
        var body = self._client._post("/kit/query", self.build())
        var out = Python.list()
        var truncated = False
        if len(body) > 0:
            try:
                var parsed = Python.import_module("json").loads(body)
                try:
                    var rows = parsed["rows"]
                    if rows is not None:
                        for r in rows:
                            out.append(r)
                except:
                    pass
                try:
                    var t = parsed["truncated"]
                    if t:
                        truncated = Bool(t)
                except:
                    pass
            except:
                pass
        self._last_truncated = truncated
        return out

    fn truncated(self) -> Bool:
        """Whether the most recent execute result was capped by the limit.
        Returns False until execute has been called."""
        return self._last_truncated


# ── Module-level helpers ────────────────────────────────────────────────────


def _normalize_condition(cond_type: String, params: PythonObject) -> PythonObject:
    """Translate friendly parameter aliases to the server's canonical on-wire
    keys. The value->pattern alias applies only to FTS conditions."""
    normalized = Python.dict()
    for kv in params.items():
        key = String(kv[0])
        value = kv[1]
        canonical = key
        if key == "column":
            canonical = "column_id"
        elif key == "min":
            canonical = "lo"
        elif key == "max":
            canonical = "hi"
        elif key == "min_inclusive":
            canonical = "lo_inclusive"
        elif key == "max_inclusive":
            canonical = "hi_inclusive"
        elif key == "value":
            if cond_type == "fm_contains" or cond_type == "fm_contains_all":
                canonical = "pattern"
        normalized[canonical] = value
    return normalized
