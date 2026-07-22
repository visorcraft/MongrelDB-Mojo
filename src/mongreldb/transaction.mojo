# Transaction for the daemon's /kit/txn endpoint.
#
# Stages operations locally and commits them atomically in a single request.
# The engine enforces unique, foreign-key, check, and trigger constraints at
# commit time; on any violation all operations roll back and commit() raises a
# ConflictError.
#
# A Transaction is single-use: after commit() or rollback() it must not be
# reused.

from python import Python, PythonObject
from collections import List, Optional
from .mongreldb import MongrelDB, _flatten_cells
from .errors import QueryError


struct Transaction(Copyable, Movable):
    """Stages operations locally and commits them atomically.

    Normally created via ``MongrelDB.begin()``. Staging methods mutate the
    transaction in place and also return it, so both statement-style
    (``txn.put(...)``) and bound-style use work.
    """

    var _client: MongrelDB
    var _ops: List[PythonObject]
    var _committed: Bool

    fn __init__(out self, client: MongrelDB):
        self._client = client.copy()
        self._ops = List[PythonObject]()
        self._committed = False

    fn _ensure_open(self) raises:
        if self._committed:
            raise Error("mongreldb: transaction already committed")

    fn put(mut self, table: String, cells: PythonObject, returning: Bool = False) raises -> Self:
        """Stage an insert."""
        self._ensure_open()
        var inner = Python.dict()
        inner["table"] = table
        inner["cells"] = _flatten_cells(Python.import_module("json"), cells)
        inner["returning"] = returning
        var op = Python.dict()
        op["put"] = inner
        self._ops.append(op)
        return self.copy()

    fn upsert(
        mut self,
        table: String,
        cells: PythonObject,
        update_cells: Optional[PythonObject] = None,
        returning: Bool = False,
    ) raises -> Self:
        """Stage an insert-or-update."""
        self._ensure_open()
        var json_module = Python.import_module("json")
        var inner = Python.dict()
        inner["table"] = table
        inner["cells"] = _flatten_cells(json_module, cells)
        inner["returning"] = returning
        # update_cells non-empty -> add update_cells
        if update_cells and update_cells.value():
            inner["update_cells"] = _flatten_cells(json_module, update_cells.value())
        var op = Python.dict()
        op["upsert"] = inner
        self._ops.append(op)
        return self.copy()

    fn delete(mut self, table: String, row_id: Int) raises -> Self:
        """Stage a delete by the internal row id."""
        self._ensure_open()
        var inner = Python.dict()
        inner["table"] = table
        inner["row_id"] = row_id
        var op = Python.dict()
        op["delete"] = inner
        self._ops.append(op)
        return self.copy()

    fn delete_by_pk(mut self, table: String, pk: PythonObject) raises -> Self:
        """Stage a delete by primary-key value."""
        self._ensure_open()
        var inner = Python.dict()
        inner["table"] = table
        inner["pk"] = pk
        var op = Python.dict()
        op["delete_by_pk"] = inner
        self._ops.append(op)
        return self.copy()

    fn count(self) -> Int:
        """The number of staged operations."""
        return len(self._ops)

    fn commit(mut self, idempotency_key: String = "") raises -> List[PythonObject]:
        """Commit all staged operations atomically."""
        if self._committed:
            raise Error("mongreldb: transaction already committed")
        self._committed = True
        if len(self._ops) == 0:
            return List[PythonObject]()
        return self._client._commit_txn(self._ops, idempotency_key)

    fn rollback(mut self) raises -> None:
        """Discard all staged operations (local only; nothing sent)."""
        if self._committed:
            raise Error("mongreldb: transaction already committed")
        self._ops.clear()
        self._committed = True
