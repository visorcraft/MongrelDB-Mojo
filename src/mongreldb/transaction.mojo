# Transaction for the daemon's /kit/txn endpoint.
#
# Stages operations locally and commits them atomically in a single request.
# The engine enforces unique, foreign-key, check, and trigger constraints at
# commit time; on any violation all operations roll back and commit() raises a
# ConflictError.
#
# A Transaction is single-use: after commit() or rollback() it must not be
# reused.

from python import Python
from .mongreldb import MongrelDB, _flatten_cells
from .errors import QueryError


struct Transaction:
    """Stages operations locally and commits them atomically.

    Normally created via ``MongrelDB.begin()``.
    """

    var _client: MongrelDB
    var _ops: List[PythonObject]
    var _committed: Bool

    fn __init__(client: MongrelDB):
        self._client = client
        self._ops = List[PythonObject]()
        self._committed = False

    fn _ensure_open(self):
        if self._committed:
            raise Error("mongreldb: transaction already committed")

    fn put(self, table: String, cells: PythonObject, returning: Bool = False) -> Self:
        """Stage an insert."""
        self._ensure_open()
        inner = Python.dict()
        inner.__setitem__("table", Python.str(table))
        inner.__setitem__("cells", _flatten_cells(Python.import_module("json"), cells))
        inner.__setitem__("returning", Python.object(returning))
        op = Python.dict()
        op.__setitem__("put", inner)
        self._ops.append(op)
        return self

    fn upsert(
        self,
        table: String,
        cells: PythonObject,
        update_cells: PythonObject = PythonObject(),
        returning: Bool = False,
    ) -> Self:
        """Stage an insert-or-update."""
        self._ensure_open()
        json_module = Python.import_module("json")
        inner = Python.dict()
        inner.__setitem__("table", Python.str(table))
        inner.__setitem__("cells", _flatten_cells(json_module, cells))
        inner.__setitem__("returning", Python.object(returning))
        try:
            _ = update_cells.to_list()
            inner.__setitem__("update_cells", _flatten_cells(json_module, update_cells))
        except:
            pass
        op = Python.dict()
        op.__setitem__("upsert", inner)
        self._ops.append(op)
        return self

    fn delete(self, table: String, row_id: Int) -> Self:
        """Stage a delete by the internal row id."""
        self._ensure_open()
        inner = Python.dict()
        inner.__setitem__("table", Python.str(table))
        inner.__setitem__("row_id", Python.object(row_id))
        op = Python.dict()
        op.__setitem__("delete", inner)
        self._ops.append(op)
        return self

    fn delete_by_pk(self, table: String, pk: PythonObject) -> Self:
        """Stage a delete by primary-key value."""
        self._ensure_open()
        inner = Python.dict()
        inner.__setitem__("table", Python.str(table))
        inner.__setitem__("pk", pk)
        op = Python.dict()
        op.__setitem__("delete_by_pk", inner)
        self._ops.append(op)
        return self

    fn count(self) -> Int:
        """The number of staged operations."""
        return len(self._ops)

    fn commit(self, idempotency_key: String = "") -> List[PythonObject]:
        """Commit all staged operations atomically."""
        if self._committed:
            raise Error("mongreldb: transaction already committed")
        self._committed = True
        if len(self._ops) == 0:
            return List[PythonObject]()
        return self._client._commit_txn(self._ops, idempotency_key)

    fn rollback(self) -> None:
        """Discard all staged operations (local only; nothing sent)."""
        if self._committed:
            raise Error("mongreldb: transaction already committed")
        self._ops.clear()
        self._committed = True
