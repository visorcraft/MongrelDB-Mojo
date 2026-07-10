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

from python import Python
from .mongreldb import MongrelDB, _url_path_escape  # noqa: F401 (re-export helper)
from .errors import QueryError


struct QueryBuilder:
    """A fluent builder for /kit/query requests.

    Normally created via ``MongrelDB.query(table)``. Use ``where`` to add native
    conditions (AND-ed), ``projection``/``limit`` to shape the result, and
    ``execute`` to send and decode. Read ``truncated`` after ``execute`` to
    detect whether the result was capped by the limit.
    """

    var _client: MongrelDB
    var _table: String
    var _conditions: List[PythonObject]
    var _projection: PythonObject
    var _limit: Int
    var _last_truncated: Bool

    fn __init__(client: MongrelDB, table: String):
        self._client = client
        self._table = table
        self._conditions = List[PythonObject]()
        self._projection = PythonObject()  # None
        self._limit = -1
        self._last_truncated = False

    fn where(self, cond_type: String, params: PythonObject) -> Self:
        """Add a native condition (AND-ed). Friendly aliases are accepted.

        Available condition types include ``pk``, ``bitmap_eq``, ``bitmap_in``,
        ``range``, ``range_f64``, ``is_null``, ``is_not_null``, ``fm_contains``,
        ``fm_contains_all``, ``ann``, ``sparse_match``, ``min_hash_similar``.
        """
        entry = Python.dict()
        entry.__setitem__(cond_type, _normalize_condition(cond_type, params))
        self._conditions.append(entry)
        return self

    fn projection(self, column_ids: PythonObject) -> Self:
        """Set the column ids to return. None means all columns."""
        self._projection = column_ids
        return self

    fn limit(self, n: Int) -> Self:
        """Cap the number of rows returned."""
        self._limit = n
        return self

    fn build(self) -> PythonObject:
        """Build the request payload that will be sent to /kit/query."""
        payload = Python.dict()
        payload.__setitem__("table", Python.str(self._table))
        if len(self._conditions) > 0:
            conds = Python.list()
            for c in self._conditions:
                conds.append(c)
            payload.__setitem__("conditions", conds)
        if self._projection:
            payload.__setitem__("projection", self._projection)
        if self._limit >= 0:
            payload.__setitem__("limit", Python.object(self._limit))
        return payload

    fn execute(self) -> PythonObject:
        """Run the query and return the matching rows. Records the truncated
        flag; check it with ``truncated``."""
        body = self._client._post("/kit/query", self.build())
        out = Python.list()
        truncated = False
        if len(body) > 0:
            try:
                parsed = Python.import_module("json").loads(Python.bytes(body))
                try:
                    rows = parsed.__getitem__("rows")
                    if rows is not None:
                        for r in rows.to_list():
                            out.append(r)
                except:
                    pass
                try:
                    t = parsed.__getitem__("truncated")
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
    items = params.items()
    for kv in items:
        key = String(kv.__getitem__(0))
        value = kv.__getitem__(1)
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
        normalized.__setitem__(canonical, value)
    return normalized
