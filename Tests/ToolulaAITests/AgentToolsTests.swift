import XCTest
@testable import ToolulaAI

/// edit_file / search_files / 护栏 / 参数修复
@MainActor
final class AgentToolsTests: XCTestCase {
    var dir: URL!
    let fm = FileManager.default

    override func setUp() async throws {
        dir = fm.temporaryDirectory.appendingPathComponent("toolula-agent-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? fm.removeItem(at: dir) }

    func ctx(_ allow: Bool = true) -> ToolContext {
        ToolContext(workDir: dir, approve: { _, _ in allow }, photoStore: nil)
    }

    func call(_ name: String, _ args: [String: Any]) -> ToolCall {
        let d = try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return ToolCall(id: "t", name: name, arguments: String(decoding: d, as: UTF8.self))
    }

    func write(_ name: String, _ s: String) throws { try s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    func read(_ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    func testEditExactUnique() async throws {
        try write("a.py", "x = 1\ny = 2\nz = 3\n")
        let out = await Tools.run(call("edit_file", ["path": "a.py", "old_text": "y = 2", "new_text": "y = 20"]), ctx: ctx())
        XCTAssertEqual(try read("a.py"), "x = 1\ny = 20\nz = 3\n")
        XCTAssertTrue(out.contains("已修改"), out)
        XCTAssertTrue(out.contains("    2│ y = 20"), out)
        XCTAssertTrue(out.contains("Python 语法检查通过"), out)
    }

    func testEditAmbiguousIsRefused() async throws {
        try write("a.txt", "foo\nbar\nfoo\n")
        let out = await Tools.run(call("edit_file", ["path": "a.txt", "old_text": "foo", "new_text": "baz"]), ctx: ctx())
        XCTAssertTrue(out.contains("出现了 2 次"), out)
        XCTAssertTrue(out.contains("第 1、3 行"), out)
        XCTAssertEqual(try read("a.txt"), "foo\nbar\nfoo\n")
        _ = await Tools.run(call("edit_file", ["path": "a.txt", "old_text": "foo", "new_text": "baz", "replace_all": true]), ctx: ctx())
        XCTAssertEqual(try read("a.txt"), "baz\nbar\nbaz\n")
    }

    func testEditLooseIndentation() async throws {
        try write("b.py", "def f():\n    if x:\n        return 1\n    return 2\n")
        // 模型抄原文时丢了缩进
        let out = await Tools.run(call("edit_file", ["path": "b.py", "old_text": "if x:\n    return 1", "new_text": "if x and y:\n    return 10"]), ctx: ctx())
        XCTAssertEqual(try read("b.py"), "def f():\n    if x and y:\n        return 10\n    return 2\n", out)
    }

    func testEditNotFoundShowsClosest() async throws {
        try write("c.py", "TAX_RATE = 0.06\nMAX = 5\n")
        let out = await Tools.run(call("edit_file", ["path": "c.py", "old_text": "TAX_RATE = 0.07", "new_text": "TAX_RATE = 0.09"]), ctx: ctx())
        XCTAssertTrue(out.contains("找不到 old_text"), out)
        XCTAssertTrue(out.contains("1│ TAX_RATE = 0.06"), out)
        XCTAssertEqual(try read("c.py"), "TAX_RATE = 0.06\nMAX = 5\n")
    }

    func testEditDeniedAndSyntaxWarning() async throws {
        try write("d.py", "a = 1\n")
        let denied = await Tools.run(call("edit_file", ["path": "d.py", "old_text": "a = 1", "new_text": "a = 2"]), ctx: ctx(false))
        XCTAssertTrue(denied.contains("拒绝"), denied)
        XCTAssertEqual(try read("d.py"), "a = 1\n")
        let bad = await Tools.run(call("edit_file", ["path": "d.py", "old_text": "a = 1", "new_text": "a = (1"]), ctx: ctx())
        XCTAssertTrue(bad.contains("语法检查没通过"), bad)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("__pycache__").path))
    }

    func testReadMissingFileHint() async throws {
        try write("report_2024.txt", "x")
        let out = await Tools.run(call("read_file", ["path": "report_2025.txt"]), ctx: ctx())
        XCTAssertTrue(out.contains("找不到文件"), out)
        XCTAssertTrue(out.contains("report_2024.txt"), out)
        XCTAssertTrue(Tools.looksLikeError(out))
    }

    func testSearchByNameAndText() async throws {
        try fm.createDirectory(at: dir.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try write("src/deep/time_utils.py", "import datetime\n\ndef parse_date(s):\n    return s\n")
        try write("src/main.py", "from time_utils import parse_date\n")
        try write("node_modules/x/parse.py", "def parse_date(): pass\n")
        let byText = FileTools.search(root: dir, name: nil, text: "def parse_date")
        XCTAssertTrue(byText.contains("src/deep/time_utils.py:3: def parse_date(s):"), byText)
        XCTAssertFalse(byText.contains("node_modules"), byText)
        let byName = FileTools.search(root: dir, name: "*.PY", text: nil)
        XCTAssertTrue(byName.contains("找到 2 个文件"), byName)
        let both = FileTools.search(root: dir, name: "main", text: "parse_date")
        XCTAssertTrue(both.contains("src/main.py:1:"), both)
        XCTAssertFalse(both.contains("time_utils.py:3"), both)
        XCTAssertTrue(FileTools.search(root: dir, name: nil, text: "蓝鲸").hasPrefix("没找到"))
        // 不是合法正则就按普通文字找
        XCTAssertTrue(FileTools.search(root: dir, name: nil, text: "parse_date(").contains("time_utils.py:3"))
    }

    func testInvalidArgumentsAreReported() async throws {
        let out = await Tools.run(ToolCall(id: "t", name: "read_file", arguments: "{\"path\": "), ctx: ctx())
        XCTAssertTrue(out.contains("不是合法的 JSON"), out)
    }

    func testRepairArguments() {
        XCTAssertEqual(ToolCall.repairArguments("```json\n{\"a\":1}\n```"), "{\"a\":1}")
        let trailing = ToolCall.repairArguments("{\"a\":[1,2,],}")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(trailing.utf8)) as? [String: Any], trailing)
        XCTAssertEqual(ToolCall.repairArguments("{\"a\":{\"b\":1}"), "{\"a\":{\"b\":1}}")
        XCTAssertEqual(ToolCall.repairArguments("{\"ok\":true}"), "{\"ok\":true}")
    }

    func testExtractToolCallFromText() {
        let x = ToolCall.extractFromText("好的。\n<tool_call>\n{\"name\": \"list_directory\", \"arguments\": {\"path\": \".\"}}\n</tool_call>")
        XCTAssertEqual(x?.calls.first?.name, "list_directory")
        XCTAssertEqual(x?.calls.first?.args["path"] as? String, ".")
        XCTAssertEqual(x?.rest, "好的。")
        XCTAssertNil(ToolCall.extractFromText("普通回答"))
    }

    func testGuardStopsLoops() {
        var g = AgentGuard()
        let ls = call("list_directory", ["path": "."])
        XCTAssertNil(g.before(ls)); _ = g.after(ls, "ok")
        XCTAssertNil(g.before(ls)); _ = g.after(ls, "ok")
        XCTAssertNotNil(g.before(ls))   // 第 3 次: 拦下
        // 中间改过东西, 再看一遍是正常的
        var g2 = AgentGuard()
        XCTAssertNil(g2.before(ls)); _ = g2.after(ls, "ok")
        XCTAssertNil(g2.before(ls)); _ = g2.after(ls, "ok")
        let mv = call("run_shell", ["command": "mv a b"])
        XCTAssertNil(g2.before(mv)); _ = g2.after(mv, "退出码 0\n（没有输出）")
        XCTAssertNil(g2.before(ls))
        // plan 可以一直更新
        var g3 = AgentGuard()
        let p = call("plan", ["steps": ["a"], "current": 1])
        for _ in 0..<5 { XCTAssertNil(g3.before(p)) }
    }

    func testGuardConsecutiveErrorsAndPlanNudge() {
        var g = AgentGuard()
        for i in 0..<3 {
            let c = call("read_file", ["path": "x\(i)"])
            let out = g.after(c, "错误：找不到文件 x")
            XCTAssertEqual(out.contains("连续 3 次出错"), i == 2)
        }
        XCTAssertTrue(g.stuck)
        var turn = [ChatMessage(role: "user", text: "做三件事")]
        var a = ChatMessage(role: "assistant")
        a.toolCalls = [call("plan", ["steps": ["一", "二", "三"], "current": 2])]
        turn.append(a)
        var g2 = AgentGuard()
        let n = g2.finishNudge(turn)
        XCTAssertTrue(n?.contains("2. 二") == true && n?.contains("3. 三") == true, n ?? "nil")
        XCTAssertNil(g2.finishNudge(turn))   // 只提醒一次
        a.toolCalls = [call("plan", ["steps": ["一", "二", "三"], "current": 0])]
        var g3 = AgentGuard()
        XCTAssertNil(g3.finishNudge([turn[0], a]))
    }

    func testShellErrorDetection() {
        XCTAssertTrue(Tools.looksLikeError("退出码 1\nTraceback"))
        XCTAssertFalse(Tools.looksLikeError("退出码 0\nok"))
        XCTAssertFalse(Tools.looksLikeError("已写入 /x"))
    }

    func testChannelFilterMovesThoughtsOut() {
        func run(_ chunks: [String]) -> (String, String) {
            var f = ChannelFilter(), c = "", r = ""
            for ch in chunks { let x = f.feed(ch); c += x.content; r += x.reasoning }
            let t = f.flush(); return (c + t.content, r + t.reasoning)
        }
        XCTAssertEqual(run(["<|channel>thought\n<channel|>5433"]).0, "5433")
        let split = run(["<|chan", "nel>tho", "ught\nLet me add ", "them.<chan", "nel|>The answer", " is 42."])
        XCTAssertEqual(split.0, "The answer is 42.")
        XCTAssertEqual(split.1, "Let me add them.")
        XCTAssertEqual(run(["普通的回答，", "没有标记 <b>"]).0, "普通的回答，没有标记 <b>")
        XCTAssertEqual(run(["a <", "| not a marker"]).0, "a <| not a marker")
    }

    func testPermanentDeleteDetection() {
        // 普通 rm 会被改成移到废纸篓, 不算永久删除
        XCTAssertFalse(Tools.permanentDelete("rm -rf images"))
        XCTAssertTrue(Tools.permanentDelete("/bin/rm -rf images"))
        XCTAssertTrue(Tools.permanentDelete("ls | xargs rm"))
        XCTAssertTrue(Tools.permanentDelete("find . -name '*.tmp' -exec rm {} +"))
        XCTAssertTrue(Tools.permanentDelete("find . -name '*.tmp' -delete"))
        XCTAssertTrue(Tools.permanentDelete("sudo rm x"))
        XCTAssertFalse(Tools.permanentDelete("trash a.txt"))
        XCTAssertFalse(Tools.permanentDelete("ls ~/Documents/rm-notes"))
    }

    func testRmIsRedirectedToTrash() async throws {
        // 不真的删东西: 只确认 AI 的命令里 rm 已经是「移到废纸篓」的函数
        let out = Tools.shell("whence -w rm", cwd: dir, timeout: 10)
        XCTAssertTrue(out.contains("rm: function"), out)
    }

    func testNotFoundPointsToWorkDir() async throws {
        try fm.createDirectory(at: dir.appendingPathComponent("work"), withIntermediateDirectories: true)
        let out = await Tools.run(call("list_directory", ["path": NSHomeDirectory() + "/work-\(UUID().uuidString.prefix(6))"]), ctx: ctx())
        XCTAssertTrue(out.contains("找不到文件夹"), out)
        let hint = FileTools.notFound(URL(fileURLWithPath: "/nonexistent/work"), workDir: dir, folder: true)
        XCTAssertTrue(hint.contains(dir.appendingPathComponent("work").path), hint)
    }

    func testProjectNotes() throws {
        XCTAssertNil(ProjectNotes.prompt(workDir: dir.path))
        try write("AGENTS.md", "用 pnpm，不要用 npm")
        XCTAssertTrue(ProjectNotes.prompt(workDir: dir.path)?.contains("用 pnpm") == true)
        try write("TOOLULA.md", "输出文件放 out/ 文件夹")
        let p = ProjectNotes.prompt(workDir: dir.path) ?? ""
        XCTAssertTrue(p.contains("out/ 文件夹") && !p.contains("pnpm"), p)   // 有 TOOLULA.md 就只用它
    }

    func testInterruptedAndResumeDetection() {
        var c = Conversation(model: "m")
        c.messages = [ChatMessage(role: "user", text: "整理")]
        XCTAssertNil(ChatStore.interrupted(c))
        var a = ChatMessage(role: "assistant"); a.toolCalls = [call("list_directory", ["path": "."])]
        c.messages.append(a)
        XCTAssertNotNil(ChatStore.interrupted(c))
        c.messages.append(ChatMessage(role: "tool", text: "ok", toolCallId: "t", toolName: "list_directory"))
        XCTAssertNotNil(ChatStore.interrupted(c))
        c.messages.append(ChatMessage(role: "assistant", text: "整理好了"))
        XCTAssertNil(ChatStore.interrupted(c))
        var p = ChatMessage(role: "assistant", text: "先停一下"); p.paused = true
        c.messages.append(p)
        XCTAssertNotNil(ChatStore.interrupted(c))
    }

    func testSkillSuggestionNeedsRealWork() {
        var c = Conversation(model: "m")
        c.messages = [ChatMessage(role: "user", text: "做事")]
        var a = ChatMessage(role: "assistant")
        a.toolCalls = (0..<4).map { call("read_file", ["path": "f\($0)"]) }
        c.messages.append(a)
        c.messages.append(ChatMessage(role: "assistant", text: "完成"))
        XCTAssertNil(ConversationView.skillWorthy(c))
        c.messages[1].toolCalls.append(call("run_shell", ["command": "ls"]))
        XCTAssertEqual(ConversationView.skillWorthy(c), c.messages.last?.id)
        c.messages[2].stuck = true
        XCTAssertNil(ConversationView.skillWorthy(c))
    }
}
