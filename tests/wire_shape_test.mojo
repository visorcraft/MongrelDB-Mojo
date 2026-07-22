from python import Python, PythonObject
from mongreldb import _create_table_payload, MongrelDB
from mongreldb.mongreldb import _history_retention_payload
from mongreldb.errors import MongrelDBError


def assert_contains(body: String, needle: String):
    if needle not in body:
        raise Error("missing " + needle + " in " + body)


def assert_true(cond: Bool):
    if not cond:
        raise Error("assertion failed: expected True")


def test_create_table_wire_shape():
    columns = Python.list()
    status = Python.dict()
    status["id"] = 2
    status["name"] = "status"
    status["ty"] = "enum"
    variants = Python.list()
    variants.append("open")
    variants.append("closed")
    status["enum_variants"] = variants
    columns.append(status)

    created_at = Python.dict()
    created_at["id"] = 3
    created_at["name"] = "created_at"
    created_at["ty"] = "timestamp_nanos"
    created_at["default_expr"] = "now"
    columns.append(created_at)

    attempts = Python.dict()
    attempts["id"] = 4
    attempts["name"] = "attempts"
    attempts["ty"] = "int64"
    attempts["default_value"] = 3
    columns.append(attempts)

    string_default = Python.dict()
    string_default["default_value"] = "draft"
    columns.append(string_default)
    bool_default = Python.dict()
    bool_default["default_value"] = True
    columns.append(bool_default)
    null_default = Python.dict()
    null_default["default_value"] = None
    columns.append(null_default)

    literal_now = Python.dict()
    literal_now["default_value"] = "now"
    columns.append(literal_now)

    check = Python.dict()
    check["id"] = 1
    check["name"] = "id_present"
    expr = Python.dict()
    expr["IsNotNull"] = 1
    check["expr"] = expr
    constraints = Python.dict()
    checks = Python.list()
    checks.append(check)
    constraints["checks"] = checks

    diskann = Python.dict()
    diskann["r"] = 64
    diskann["l"] = 128
    diskann["beam_width"] = 8
    diskann["alpha"] = 120
    ann = Python.dict()
    ann["algorithm"] = "diskann"
    ann["quantization"] = "dense"
    ann["diskann"] = diskann
    options = Python.dict()
    options["ann"] = ann
    index = Python.dict()
    index["name"] = "ann"
    index["column_id"] = 2
    index["kind"] = "ann"
    index["options"] = options
    indexes = Python.list()
    indexes.append(index)

    json = Python.import_module("json")
    body = String(json.dumps(_create_table_payload("events", columns, constraints, indexes)))
    assert_contains(body, "\"enum_variants\"")
    assert_contains(body, "\"default_value\": 3")
    assert_contains(body, "\"default_expr\": \"now\"")
    assert_contains(body, "\"default_value\": \"draft\"")
    assert_contains(body, "\"default_value\": true")
    assert_contains(body, "\"default_value\": null")
    assert_contains(body, "\"default_value\": \"now\"")
    assert_contains(body, "\"constraints\"")
    assert_contains(body, "\"checks\"")
    assert_contains(body, "\"IsNotNull\"")
    assert_contains(body, "\"algorithm\": \"diskann\"")
    assert_contains(body, "\"quantization\": \"dense\"")
    assert_contains(body, "\"beam_width\": 8")


def test_history_retention_wire_shape():
    """The PUT /history/retention body must carry the exact frozen key."""
    json = Python.import_module("json")
    body = String(json.dumps(_history_retention_payload(42)))
    assert_contains(body, "\"history_retention_epochs\"")
    assert_contains(body, "\"history_retention_epochs\": 42")


# ── Transport-layer tests (mock HTTP server) ───────────────────────────────
#
# The tests above only exercise the payload-builder helper. These tests boot a
# tiny Python http.server in a background thread and point a real MongrelDB
# client at it, so the actual set_history_retention_epochs /
# history_retention_epochs methods traverse urllib -> the wire -> response
# decode. They assert the exact HTTP method, the /history/retention path, the
# PUT body key, the GET response keys, and that a non-2xx response surfaces as a
# typed MongrelDBError.


def _boot_mock_retention_server() -> PythonObject:
    """Start a Python http.server on a free port that serves /history/retention.

    Records each request (method/path/body) and returns a Python dict handle
    with `port`, `records`, `controls`, and `stop`. `controls['status_override']`
    can be set to a (code, payload) pair to force a non-2xx response.
    """
    builtins = Python.import_module("builtins")
    src = (
        "import json, threading\n" +
        "from http.server import BaseHTTPRequestHandler, HTTPServer\n" +
        "\n" +
        "records = []\n" +
        "controls = {'status_override': None}\n" +
        "\n" +
        "class Handler(BaseHTTPRequestHandler):\n" +
        "    def log_message(self, *a):\n" +
        "        pass\n" +
        "    def _handle(self, method):\n" +
        "        length = int(self.headers.get('Content-Length') or 0)\n" +
        "        body = self.rfile.read(length) if length > 0 else b''\n" +
        "        records.append({'method': method, 'path': self.path,\n" +
        "                        'body': body.decode('utf-8', 'replace')})\n" +
        "        ov = controls['status_override']\n" +
        "        if ov is not None:\n" +
        "            code, payload = ov\n" +
        "            msg = json.dumps(payload).encode('utf-8')\n" +
        "            self.send_response(code)\n" +
        "            self.send_header('Content-Type', 'application/json')\n" +
        "            self.send_header('Content-Length', str(len(msg)))\n" +
        "            self.end_headers()\n" +
        "            self.wfile.write(msg)\n" +
        "            return\n" +
        "        if self.path == '/history/retention':\n" +
        "            epochs = 42\n" +
        "            if method == 'PUT' and body:\n" +
        "                try:\n" +
        "                    parsed = json.loads(body)\n" +
        "                    if isinstance(parsed, dict):\n" +
        "                        epochs = parsed.get('history_retention_epochs', 42)\n" +
        "                except Exception:\n" +
        "                    pass\n" +
        "            resp = {'history_retention_epochs': epochs,\n" +
        "                    'earliest_retained_epoch': 7}\n" +
        "            msg = json.dumps(resp).encode('utf-8')\n" +
        "            self.send_response(200)\n" +
        "            self.send_header('Content-Type', 'application/json')\n" +
        "            self.send_header('Content-Length', str(len(msg)))\n" +
        "            self.end_headers()\n" +
        "            self.wfile.write(msg)\n" +
        "            return\n" +
        "        self.send_response(404)\n" +
        "        self.send_header('Content-Length', '0')\n" +
        "        self.end_headers()\n" +
        "    def do_GET(self):\n" +
        "        self._handle('GET')\n" +
        "    def do_PUT(self):\n" +
        "        self._handle('PUT')\n" +
        "    def do_POST(self):\n" +
        "        self._handle('POST')\n" +
        "\n" +
        "srv = HTTPServer(('127.0.0.1', 0), Handler)\n" +
        "thread = threading.Thread(target=srv.serve_forever, daemon=True)\n" +
        "thread.start()\n" +
        "\n" +
        "def _stop():\n" +
        "    srv.shutdown()\n" +
        "    srv.server_close()\n" +
        "\n" +
        "handle = {'port': srv.server_address[1], 'records': records,\n" +
        "          'controls': controls, 'stop': _stop}\n"
    )
    ns = Python.dict()
    builtins.exec(src, ns)
    return ns["handle"]


def _stop_mock_server(handle: PythonObject):
    stop = handle["stop"]
    stop()


def test_set_history_retention_uses_put_transport():
    """set_history_retention_epochs must issue PUT /history/retention with the
    history_retention_epochs body key, through the real HTTP transport."""
    handle = _boot_mock_retention_server()
    port = Int(handle["port"])
    db = MongrelDB("http://127.0.0.1:" + String(port))

    resp = db.set_history_retention_epochs(99)
    # Server echoes the PUT value back through the transport decode path.
    assert_true(Int(resp["history_retention_epochs"]) == 99)
    assert_true(Int(resp["earliest_retained_epoch"]) == 7)

    raw = handle["records"]
    assert_true(len(raw) >= 1)
    rec = raw[len(raw) - 1]
    assert_true(String(rec["method"]) == "PUT")
    path = String(rec["path"])
    if "/history/retention" not in path:
        raise Error("expected /history/retention path, got " + path)
    body = String(rec["body"])
    assert_contains(body, "\"history_retention_epochs\"")
    assert_contains(body, "99")

    _stop_mock_server(handle)


def test_history_retention_epochs_uses_get_transport():
    """history_retention_epochs must GET /history/retention and decode both
    response keys through the real transport."""
    handle = _boot_mock_retention_server()
    port = Int(handle["port"])
    db = MongrelDB("http://127.0.0.1:" + String(port))

    epochs = db.history_retention_epochs()
    assert_true(epochs == 42)
    earliest = db.earliest_retained_epoch()
    assert_true(earliest == 7)

    raw = handle["records"]
    assert_true(len(raw) >= 2)
    for i in range(len(raw)):
        rec = raw[i]
        assert_true(String(rec["method"]) == "GET")
        path = String(rec["path"])
        if "/history/retention" not in path:
            raise Error("expected /history/retention path, got " + path)

    _stop_mock_server(handle)


def test_history_retention_propagates_non_2xx():
    """A non-2xx /history/retention response must surface as a typed
    MongrelDBError, proving the transport maps status codes to exceptions."""
    handle = _boot_mock_retention_server()
    port = Int(handle["port"])
    controls = handle["controls"]
    db = MongrelDB("http://127.0.0.1:" + String(port))

    envelope = Python.dict()
    envelope["message"] = "service unavailable"
    override = Python.list()
    override.append(503)
    override.append(envelope)
    controls["status_override"] = override

    var raised = False
    try:
        _ = db.history_retention_epochs()
    except MongrelDBError:
        raised = True
    assert_true(raised)

    _stop_mock_server(handle)


# ── Runner (mojo run; the standalone `mojo test` command no longer exists) ──


fn main() raises:
    test_create_table_wire_shape()
    test_history_retention_wire_shape()
    test_set_history_retention_uses_put_transport()
    test_history_retention_epochs_uses_get_transport()
    test_history_retention_propagates_non_2xx()
    print("wire_shape_test: all tests passed")
