import XCTest
@testable import ToolulaAI

/// 分支、搜索、导出、文档附件
@MainActor
final class ChatToolsTests: XCTestCase {
    var root: URL!
    var store: ChatStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toolula-chattools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ChatStore(root: root)
    }

    override func tearDown() async throws {
        store.storage.flush()
        try? FileManager.default.removeItem(at: root)
    }

    func sample() -> Conversation {
        var c = Conversation(model: "main")
        c.title = "旅行计划"
        c.messages = [
            ChatMessage(role: "user", text: "帮我规划杭州三日游"),
            ChatMessage(role: "assistant", text: "第一天去西湖，第二天去灵隐寺。"),
            ChatMessage(role: "user", text: "预算多少合适？"),
            ChatMessage(role: "assistant", text: "大约 **2000 元**。"),
        ]
        return c
    }

    func testBranchKeepsUpToMessageAndLeavesOriginal() {
        let c = sample()
        store.conversations = [c]
        let nid = store.branch(c.id, upTo: c.messages[1].id)
        XCTAssertNotNil(nid)
        XCTAssertEqual(store.conversations.count, 2)
        let n = store.conversations.first { $0.id == nid }!
        XCTAssertEqual(n.messages.map(\.text), ["帮我规划杭州三日游", "第一天去西湖，第二天去灵隐寺。"])
        XCTAssertTrue(n.title.contains("旅行计划"))
        XCTAssertEqual(store.selected, nid)
        XCTAssertEqual(store.conversations.first { $0.id == c.id }!.messages.count, 4)
    }

    func testBranchDropsDanglingToolCall() {
        var c = sample()
        c.messages.append(ChatMessage(role: "assistant", text: "", toolCalls: [ToolCall(id: "t1", name: "run_shell", arguments: "{}")]))
        store.conversations = [c]
        let nid = store.branch(c.id, upTo: c.messages.last!.id)!
        XCTAssertEqual(store.conversations.first { $0.id == nid }!.messages.count, 4)
    }

    func testSearchMatchesTitleAndBody() {
        let c = sample()
        XCTAssertEqual(ChatSearch.match(c, ""), "")
        XCTAssertEqual(ChatSearch.match(c, "旅行"), "")            // 标题命中: 不显示片段
        XCTAssertEqual(ChatSearch.match(c, "灵隐寺")?.contains("灵隐寺"), true)
        XCTAssertNil(ChatSearch.match(c, "北京"))
    }

    func testSearchMatchesAttachmentName() {
        var c = sample()
        c.messages[0].docs = [DocAttachment(name: "合同草案.pdf", source: "/x", textPath: "/nope", chars: 10)]
        XCTAssertEqual(ChatSearch.match(c, "合同")?.contains("合同草案.pdf"), true)
    }

    func testMarkdownExport() {
        var c = sample()
        c.messages[0].docs = [DocAttachment(name: "行程.docx", source: "/x", textPath: "/nope", chars: 10)]
        let md = ChatExport.markdown(c)
        XCTAssertTrue(md.hasPrefix("# 旅行计划"))
        XCTAssertTrue(md.contains("📎 行程.docx"))
        XCTAssertTrue(md.contains("大约 **2000 元**。"))
        XCTAssertEqual(md.components(separatedBy: "## Toolula AI").count - 1, 2)
    }

    func testPDFExport() throws {
        let url = root.appendingPathComponent("a.pdf")
        try ChatExport.writePDF(sample(), to: url)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
    }

    func testDocPromptBlockShortAndLong() throws {
        let short = root.appendingPathComponent("s.txt")
        try Data("合同金额 30 万元".utf8).write(to: short)
        let d = DocAttachment(name: "s.txt", source: short.path, textPath: short.path, chars: 9)
        XCTAssertFalse(d.isLong)
        XCTAssertTrue(d.promptBlock().contains("合同金额 30 万元"))

        let long = root.appendingPathComponent("l.txt")
        let text = String(repeating: "城市交通研究的数据分析方法。", count: 3000)
        try Data(text.utf8).write(to: long)
        var l = DocAttachment(name: "l.txt", source: long.path, textPath: long.path, chars: text.count)
        l.digest = "这是一份交通研究报告。"
        XCTAssertTrue(l.isLong)
        let b = l.promptBlock()
        XCTAssertTrue(b.contains("这是一份交通研究报告。"))
        XCTAssertTrue(b.contains("read_file"))
        XCTAssertLessThan(b.count, 5000)
    }

    func testPlainTextAndXlsxExtraction() throws {
        let csv = root.appendingPathComponent("a.csv")
        try Data("城市,销售额\n杭州,128".utf8).write(to: csv)
        XCTAssertEqual(try DocReader.extract(csv).text, "城市,销售额\n杭州,128")
        let bin = root.appendingPathComponent("a.bin")
        try Data([0, 1, 2, 0, 5]).write(to: bin)
        XCTAssertThrowsError(try DocReader.extract(bin))
    }
}
