import XCTest
@testable import ToolulaAI

/// 第一阶段: 实际变化、撤销、算数检查
@MainActor
final class ReliabilityTests: XCTestCase {
    var dir: URL!
    let fm = FileManager.default

    override func setUp() async throws {
        // 放在主目录外的临时文件夹 (主目录不会被拍快照/克隆)
        dir = fm.temporaryDirectory.appendingPathComponent("toolula-rel-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? fm.removeItem(at: dir) }

    func call(_ name: String, _ args: [String: Any]) -> ToolCall {
        let d = try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return ToolCall(id: "t", name: name, arguments: String(decoding: d, as: UTF8.self))
    }
    func ctx() -> ToolContext { ToolContext(workDir: dir, approve: { _, _ in true }, photoStore: nil) }
    func write(_ n: String, _ s: String) throws {
        let u = dir.appendingPathComponent(n)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }

    func testShellReportsRealChanges() async throws {
        for n in ["a.jpg", "b.png", "c.txt"] { try write(n, n) }
        // 经典错误: 先建子文件夹, 再 mv * 到 others, 子文件夹也被挪进去了
        let out = await Tools.run(call("run_shell", ["command": "mkdir images others && mv a.jpg images/ && mv * others/"]), ctx: ctx())
        XCTAssertTrue(out.contains("【实际变化】"), out)
        XCTAssertTrue(out.contains("others/"), out)
        XCTAssertTrue(out.contains("不见了") && out.contains("c.txt"), out)
        // 只是查看的命令, 不报
        let ls = await Tools.run(call("run_shell", ["command": "ls"]), ctx: ctx())
        XCTAssertFalse(ls.contains("实际变化"), ls)
        // 想改却什么都没改
        let noop = await Tools.run(call("run_shell", ["command": "mv nothing.txt x/ 2>/dev/null; true"]), ctx: ctx())
        XCTAssertTrue(noop.contains("没有任何文件变化"), noop)
    }

    func testEditReportsModifiedFile() async throws {
        try write("x.py", "a = 1\n")
        let out = await Tools.run(call("edit_file", ["path": "x.py", "old_text": "a = 1", "new_text": "a = 2"]), ctx: ctx())
        XCTAssertTrue(out.contains("内容变了 1 项：x.py"), out)
    }

    func testUndoRestoresWholeFolder() async throws {
        try write("keep.txt", "原来的")
        try write("sub/b.txt", "b")
        let turn = UUID()
        var c = ctx()
        c.beforeChange = { call in await UndoStore.shared.prepare(turn: turn, conversation: UUID(), workDir: self.dir, call: call) }
        _ = await Tools.run(call("run_shell", ["command": "mv sub \(NSTemporaryDirectory())moved-\(UUID().uuidString) && echo 新的 > keep.txt && touch new.txt"]), ctx: c)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("sub").path))
        XCTAssertEqual(UndoStore.shared.record(for: turn)?.dirs.count, 1)
        let msg = UndoStore.shared.undo(turn)
        XCTAssertTrue(msg.contains("已撤销"), msg)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("keep.txt"), encoding: .utf8), "原来的")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("sub/b.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("new.txt").path))
        XCTAssertNil(UndoStore.shared.record(for: turn))   // 只能撤销一次
    }

    func testNeedsCalc() {
        XCTAssertTrue(AgentGuard.needsCalc("今天距离 2027 年 12 月 31 日还有多少天？"))
        XCTAssertTrue(AgentGuard.needsCalc("甲比乙大 3 岁，乙比丙小 2 岁，丙今年 20 岁。甲今年几岁？"))
        XCTAssertFalse(AgentGuard.needsCalc("讲个笑话"))
        XCTAssertFalse(AgentGuard.needsCalc("把这句话翻译成英文：今天天气很好"))
        var g = AgentGuard()
        let turn = [ChatMessage(role: "user", text: "1 到 100 的和是多少"), ChatMessage(role: "assistant", text: "5050")]
        XCTAssertNotNil(g.calcNudge(turn))
        XCTAssertNil(g.calcNudge(turn))
    }

    func testTurnEnds() {
        var c = Conversation(model: "m")
        let u1 = ChatMessage(role: "user", text: "整理")
        var a1 = ChatMessage(role: "assistant"); a1.toolCalls = [call("list_directory", ["path": "."])]
        let t1 = ChatMessage(role: "tool", text: "ok", toolCallId: "t", toolName: "list_directory")
        let a2 = ChatMessage(role: "assistant", text: "好了")
        var hidden = ChatMessage(role: "user", text: "（核查发现问题）"); hidden.hidden = true
        let a3 = ChatMessage(role: "assistant", text: "修好了")
        let u2 = ChatMessage(role: "user", text: "谢谢")
        let a4 = ChatMessage(role: "assistant", text: "不客气")
        c.messages = [u1, a1, t1, a2, hidden, a3, u2, a4]
        let e = ChatStore.turnEnds(c)
        XCTAssertNil(e[a2.id])            // 后面还有核查后的回答
        XCTAssertEqual(e[a3.id], u1.id)
        XCTAssertEqual(e[a4.id], u2.id)
    }
}

/// 第二阶段: 自动化的权限范围、在对话里新建
@MainActor
final class AutomationScopeTests: XCTestCase {
    func call(_ name: String, _ args: [String: Any]) -> ToolCall {
        let d = try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return ToolCall(id: "t", name: name, arguments: String(decoding: d, as: UTF8.self))
    }

    func testScope() {
        let f = ["~/Downloads"]
        XCTAssertTrue(AutomationScope.allowed(call("run_shell", ["command": "trash ~/Downloads/old.dmg"]), folders: f))
        XCTAssertTrue(AutomationScope.allowed(call("run_shell", ["command": "mv \"\(NSHomeDirectory())/Downloads/a.pkg\" ~/Downloads/Installers/"]), folders: f))
        XCTAssertTrue(AutomationScope.allowed(call("run_shell", ["command": "/usr/bin/python3 -c 'x' ~/Downloads/a 2>/dev/null"]), folders: f))
        XCTAssertFalse(AutomationScope.allowed(call("run_shell", ["command": "trash ~/Documents/a.txt"]), folders: f))
        XCTAssertFalse(AutomationScope.allowed(call("run_shell", ["command": "ls"]), folders: f))              // 没写路径
        XCTAssertTrue(AutomationScope.allowed(call("run_shell", ["command": "rm ~/Downloads/a.dmg"]), folders: f))   // rm 会移到废纸篓
        XCTAssertFalse(AutomationScope.allowed(call("run_shell", ["command": "/bin/rm ~/Downloads/a.dmg"]), folders: f))  // 真删除
        XCTAssertFalse(AutomationScope.allowed(call("run_shell", ["command": "mv ~/Downloads/../Documents/x ~/Downloads"]), folders: f))
        XCTAssertTrue(AutomationScope.allowed(call("write_file", ["path": "~/Downloads/r.md", "content": "x"]), folders: f))
        XCTAssertFalse(AutomationScope.allowed(call("write_file", ["path": "~/Desktop/r.md", "content": "x"]), folders: f))
    }

    func testCreateFromTool() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("auto-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AutomationStore(folder: tmp)
        let before = store.tasks.count
        let (t, msg) = store.create(from: ["name": "清理安装包", "prompt": "把旧的 dmg 移到废纸篓", "trigger": "weekly", "time": "08:30",
                                          "weekday": 1, "allow_actions": true, "allowed_folders": ["~/Downloads"]])
        defer { if let t { store.delete(t.id) } }
        XCTAssertNotNil(t, msg)
        XCTAssertEqual(t?.kind, .weekly)
        XCTAssertEqual(t?.weekday, 2)          // 周一 (Calendar: 周日=1)
        XCTAssertEqual(t?.hour, 8); XCTAssertEqual(t?.minute, 30)
        XCTAssertEqual(t?.trial, true)
        XCTAssertEqual(t?.allowedFolders, [NSHomeDirectory() + "/Downloads"])
        XCTAssertEqual(store.tasks.count, before + 1)
        XCTAssertNil(store.create(from: ["name": "x", "prompt": "y", "trigger": "hourly"]).0)
        XCTAssertNil(store.create(from: ["name": "x", "prompt": "y", "trigger": "app"]).0)
    }

    func testReadOnlyShell() {
        XCTAssertTrue(ReadOnlyShell.allowed("sips -g pixelWidth -g pixelHeight thumb.png"))
        XCTAssertTrue(ReadOnlyShell.allowed("ls -la images | wc -l"))
        XCTAssertTrue(ReadOnlyShell.allowed("cd out && cat a.txt 2>/dev/null"))
        XCTAssertTrue(ReadOnlyShell.allowed("unzip -l docs.zip"))
        XCTAssertFalse(ReadOnlyShell.allowed("sips -z 100 100 a.png"))
        XCTAssertFalse(ReadOnlyShell.allowed("echo x > a.txt"))
        XCTAssertFalse(ReadOnlyShell.allowed("find . -name '*.tmp' -delete"))
        XCTAssertFalse(ReadOnlyShell.allowed("ls; mv a b"))
        XCTAssertFalse(ReadOnlyShell.allowed("python3 -c 'open(\"x\",\"w\")'"))
        XCTAssertFalse(ReadOnlyShell.allowed("cat $(rm x)"))
        XCTAssertFalse(ReadOnlyShell.allowed("unzip docs.zip"))
    }
}
