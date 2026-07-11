from python import Python
from mongreldb import _create_table_payload


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
    created_at.__setitem__("default_value", "now")
    columns.append(created_at)

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
    assert_contains(body, "\"default_value\"")
    assert_contains(body, "\"constraints\"")
    assert_contains(body, "\"checks\"")
    assert_contains(body, "\"IsNotNull\"")
