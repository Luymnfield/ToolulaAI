import XCTest
@testable import ToolulaAI

/// MCP 客户端: 用一个临时写出来的 Python MCP 服务器测试 (标准输入输出、HTTP 两种连接)
final class MCPTests: XCTestCase {
    static let server = #"""
import sys, json
TOOLS = [
  {"name": "add", "description": "Add two numbers", "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, "required": ["a", "b"]}, "annotations": {"readOnlyHint": True}},
  {"name": "write note", "description": "Save a note", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
  {"name": "fail", "description": "Always fails", "inputSchema": {"type": "object"}},
]
def handle(m):
    if "id" not in m: return None
    meth, p = m["method"], m.get("params") or {}
    if meth == "initialize":
        r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "echo-test", "version": "1"}}
    elif meth == "tools/list":
        r = {"tools": TOOLS}
    elif meth == "tools/call":
        a = p.get("arguments") or {}
        if p["name"] == "add": r = {"content": [{"type": "text", "text": str(a["a"] + a["b"])}]}
        elif p["name"] == "write note": r = {"content": [{"type": "text", "text": "saved: " + a.get("text", "")}]}
        else: r = {"content": [{"type": "text", "text": "boom"}], "isError": True}
    else:
        return {"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "nope"}}
    return {"jsonrpc": "2.0", "id": m["id"], "result": r}

if len(sys.argv) > 1 and sys.argv[1] == "--http":
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_POST(self):
            m = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            out = handle(m)
            if out is None:
                self.send_response(202); self.end_headers(); return
            body = json.dumps(out)
            sse = m.get("method") == "tools/call"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream" if sse else "application/json")
            self.send_header("Mcp-Session-Id", "s1")
            data = ("event: message\ndata: " + body + "\n\n") if sse else body
            self.send_header("Content-Length", str(len(data.encode())))
            self.end_headers(); self.wfile.write(data.encode())
    srv = HTTPServer(("127.0.0.1", 0), H)
    print(srv.server_port, flush=True)
    srv.serve_forever()
else:
    print("starting", file=sys.stderr, flush=True)
    for line in sys.stdin:
        out = handle(json.loads(line))
        if out: sys.stdout.write(json.dumps(out) + "\n"); sys.stdout.flush()
"""#

    var script: URL!

    override func setUpWithError() throws {
        script = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID().uuidString).py")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: script) }

    func check(_ c: MCPClient) async throws {
        try await c.start()
        XCTAssertEqual(c.tools.map(\.name), ["add", "write note", "fail"])
        XCTAssertEqual(c.tools[0].readOnly, true)
        XCTAssertEqual(c.tools[1].readOnly, false)
        XCTAssertEqual(c.tools[1].exposed, "mcp_t_write_note")
        let sum = await c.call("add", ["a": 2, "b": 3])
        XCTAssertEqual(sum, "5")
        let note = await c.call("write note", ["text": "你好"])
        XCTAssertEqual(note, "saved: 你好")
        let bad = await c.call("fail", [:])
        XCTAssertTrue(bad.hasPrefix("错误：") && bad.contains("boom"), bad)
        XCTAssertTrue(Tools.looksLikeError(bad))
    }

    func testStdioServer() async throws {
        let c = try MCPClient(name: "t", config: MCPServerConfig(command: "/usr/bin/python3", args: [script.path]))
        defer { c.close() }
        try await check(c)
    }

    func testHTTPServerWithSSE() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, "--http"]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        defer { p.terminate() }
        let port = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let c = try MCPClient(name: "t", config: MCPServerConfig(url: "http://127.0.0.1:\(port)/mcp"))
        try await check(c)
    }

    func testServerThatExitsReportsStderr() async throws {
        let c = try MCPClient(name: "t", config: MCPServerConfig(command: "/bin/sh", args: ["-c", "echo 'missing API key' >&2; exit 1"]))
        do { try await c.start(); XCTFail("should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("missing API key"), error.localizedDescription) }
    }

    func testParsePastedConfigs() {
        let full = MCPManager.parse(#"{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "x"]}, "web": {"url": "https://a/mcp"}}}"#)
        XCTAssertEqual(full?.keys.sorted(), ["fs", "web"])
        XCTAssertEqual(full?["fs"]?.args, ["-y", "x"])
        XCTAssertEqual(MCPManager.parse(#"{"command": "uvx", "args": ["mcp-server-time"]}"#, name: "time")?["time"]?.command, "uvx")
        XCTAssertEqual(MCPManager.parse(#"{"a": {"command": "x"}}"#)?.keys.sorted(), ["a"])
        XCTAssertNil(MCPManager.parse("not json"))
        XCTAssertNil(MCPManager.parse(#"{"a": 1}"#))
    }

    func testExposedNames() {
        XCTAssertEqual(MCPManager.exposedName(server: "Google 日历", tool: "list-events"), "mcp_Google____list-events")
        XCTAssertLessThanOrEqual(MCPManager.exposedName(server: String(repeating: "s", count: 50), tool: String(repeating: "t", count: 80)).count, 64)
    }
}

/// 自动化: 新加的触发方式不能让旧的配置文件读不出来
final class AutomationCompatTests: XCTestCase {
    func testOldTaskFileStillDecodes() throws {
        let old = #"[{"id":"7C1D7C5A-8B07-4C0F-9D0B-2B7A6C1E9F10","name":"整理下载","prompt":"整理","model":"m","kind":"每天","intervalMinutes":60,"hour":9,"minute":0,"weekday":2,"folder":"","allowActions":false,"enabled":true,"notify":true,"created":0,"seen":[]}]"#
        let t = try JSONDecoder().decode([AutomationTask].self, from: Data(old.utf8))
        XCTAssertEqual(t.first?.name, "整理下载")
        XCTAssertNil(t.first?.appName)
        var n = t[0]; n.kind = .appLaunched; n.appName = "Lightroom"
        let back = try JSONDecoder().decode(AutomationTask.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back.appName, "Lightroom")
        XCTAssertEqual(back.kind, .appLaunched)
        XCTAssertFalse(back.isDue(Date()))
    }
}

/// 朗读: Markdown 变成适合念的文字
final class SpeakerTextTests: XCTestCase {
    func testPlainText() {
        let md = "## 结果\n- **好评** 9 条\n- 详见 [报告](https://x.com/a)\n```python\nprint(1)\n```\n| a | b |\n|---|---|\n| 1 | 2 |"
        let s = Speaker.plain(md)
        XCTAssertFalse(s.contains("#") || s.contains("**") || s.contains("https") || s.contains("print(1)") || s.contains("---"), s)
        XCTAssertTrue(s.contains("好评") && s.contains("报告") && s.contains("代码略"), s)
        XCTAssertEqual(Speaker.voiceLanguage("zh-Hans"), "zh-CN")
    }
}
