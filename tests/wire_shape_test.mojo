from python import Python
from mongreldb import _create_table_payload
from mongreldb.mongreldb import _history_retention_payload


def assert_contains(body: String, needle: String):
    if not body.contains(needle):
        raise Error("missing " + needle + " in " + body)


def test_create_table_wire_shape():
    columns = Python.list()
    status = Python.dict()
    status.__setitem__("id", 2)
    status.__setitem__("name", "status")
    status.__setitem__("ty", "enum")
    variants = Python.list()
    variants.append("open")
    variants.append("closed")
    status.__setitem__("enum_variants", variants)
    columns.append(status)

    created_at = Python.dict()
    created_at.__setitem__("id", 3)
    created_at.__setitem__("name", "created_at")
    created_at.__setitem__("ty", "timestamp_nanos")
    created_at.__setitem__("default_expr", "now")
    columns.append(created_at)

    attempts = Python.dict()
    attempts.__setitem__("id", 4)
    attempts.__setitem__("name", "attempts")
    attempts.__setitem__("ty", "int64")
    attempts.__setitem__("default_value", 3)
    columns.append(attempts)

    string_default = Python.dict()
    string_default.__setitem__("default_value", "draft")
    columns.append(string_default)
    bool_default = Python.dict()
    bool_default.__setitem__("default_value", True)
    columns.append(bool_default)
    null_default = Python.dict()
    null_default.__setitem__("default_value", None)
    columns.append(null_default)

    check = Python.dict()
    check.__setitem__("id", 1)
    check.__setitem__("name", "id_present")
    expr = Python.dict()
    expr.__setitem__("IsNotNull", 1)
    check.__setitem__("expr", expr)
    constraints = Python.dict()
    checks = Python.list()
    checks.append(check)
    constraints.__setitem__("checks", checks)

    json = Python.import_module("json")
    body = String(json.dumps(_create_table_payload("events", columns, constraints)))
    assert_contains(body, "\"enum_variants\"")
    assert_contains(body, "\"default_value\": 3")
    assert_contains(body, "\"default_expr\": \"now\"")
    assert_contains(body, "\"default_value\": \"draft\"")
    assert_contains(body, "\"default_value\": true")
    assert_contains(body, "\"default_value\": null")
    assert_contains(body, "\"constraints\"")
    assert_contains(body, "\"checks\"")
    assert_contains(body, "\"IsNotNull\"")


def test_history_retention_wire_shape():
    """The PUT /history/retention body must carry the exact frozen key."""
    json = Python.import_module("json")
    body = String(json.dumps(_history_retention_payload(42)))
    assert_contains(body, "\"history_retention_epochs\"")
    assert_contains(body, "\"history_retention_epochs\": 42")
