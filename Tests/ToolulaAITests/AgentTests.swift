import XCTest
@testable import ToolulaAI

final class AgentTests: XCTestCase {
    func msg(_ role: String, _ text: String, images: [String] = [], calls: [ToolCall] = [], callId: String? = nil) -> ChatMessage {
        ChatMessage(role: role, text: text, images: images, toolCalls: calls, toolCallId: callId, toolName: callId == nil ? nil : "run_shell")
    }

    // MARK: estimateTokens

    func testEstimateTokensCJKAndLatin() {
        XCTAssertEqual(Agent.estimateTokens([]), 0)
        // 4 (每条消息) + 10 个汉字 * 0.7 = 11
        XCTAssertEqual(Agent.estimateTokens([["role": "user", "content": "一二三四五六七八九十"]]), 11)
        // 4 + 35 个英文字符 / 3.5 = 14
        XCTAssertEqual(Agent.estimateTokens([["role": "user", "content": String(repeating: "a", count: 35)]]), 14)
        // 图片按 1200 算
        let img: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": ""], ["type": "image_url", "image_url": ["url": "x"]]]]]
        XCTAssertEqual(Agent.estimateTokens(img), 1204)
    }

    func testEstimateTokensCountsToolCalls() {
        let m: [[String: Any]] = [["role": "assistant", "content": "", "tool_calls": [["function": ["name": "run_shell", "arguments": "{\"command\":\"ls\"}"]]]]]
        XCTAssertGreaterThan(Agent.estimateTokens(m), 4)
    }

    // MARK: apiMessages 瘦身

    func testOldToolResultsAreShrunkButCurrentTurnKept() {
        let long = String(repeating: "x", count: 5000)
        let call = ToolCall(id: "c1", name: "run_shell", arguments: "{}")
        let call2 = ToolCall(id: "c2", name: "run_shell", arguments: "{}")
        let msgs = [
            msg("user", "第一问"),
            msg("assistant", "", calls: [call]),
            msg("tool", long, callId: "c1"),
            msg("assistant", "答一"),
            msg("user", "第二问"),
            msg("assistant", "", calls: [call2]),
            msg("tool", long, callId: "c2"),
        ]
        let out = Agent.apiMessages(system: "SYS", messages: msgs, vision: false)
        XCTAssertEqual(out.first?["content"] as? String, "SYS")
        let tools = out.filter { $0["role"] as? String == "tool" }
        XCTAssertEqual(tools.count, 2)
        let first = tools[0]["content"] as! String, second = tools[1]["content"] as! String
        XCTAssertLessThan(first.count, 1000, "上一轮的长工具结果应被缩短")
        XCTAssertTrue(first.contains("已省略"))
        XCTAssertEqual(second.count, 5000, "这一轮的工具结果保持完整")
    }

    func testAggressiveKeepsOnlyLastFourToolResults() {
        var msgs = [msg("user", "做事")]
        for i in 0..<6 {
            msgs.append(msg("assistant", "", calls: [ToolCall(id: "c\(i)", name: "run_shell", arguments: "{}")]))
            msgs.append(msg("tool", String(repeating: "y", count: 3000), callId: "c\(i)"))
        }
        let normal = Agent.apiMessages(system: "", messages: msgs, vision: false)
        let aggr = Agent.apiMessages(system: "", messages: msgs, vision: false, aggressive: true)
        let fullNormal = normal.filter { ($0["content"] as? String)?.count == 3000 }.count
        let fullAggr = aggr.filter { ($0["content"] as? String)?.count == 3000 }.count
        XCTAssertEqual(fullNormal, 6)
        XCTAssertEqual(fullAggr, 4)
        XCTAssertLessThan(Agent.estimateTokens(aggr), Agent.estimateTokens(normal))
    }

    func testSummaryReplacesCompressedPart() {
        let msgs = [msg("user", "早期问题A"), msg("assistant", "早期回答A"), msg("user", "最近问题"), msg("assistant", "最近回答")]
        let out = Agent.apiMessages(system: "S", messages: msgs, vision: false, summary: "摘要内容", summaryUntil: msgs[1].id)
        let texts = out.compactMap { $0["content"] as? String }
        XCTAssertTrue(texts.contains { $0.contains("摘要内容") })
        XCTAssertFalse(texts.contains("早期问题A"))
        XCTAssertTrue(texts.contains("最近问题"))
    }

    func testDoesNotStartWithOrphanToolMessage() {
        let msgs = [msg("tool", "孤立结果", callId: "zz"), msg("user", "你好")]
        let out = Agent.apiMessages(system: "", messages: msgs, vision: false)
        XCTAssertEqual(out.map { $0["role"] as? String }, ["system", "user"])
    }

    func testOnlyLastTwoUserImagesKeptForVision() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = dir.appendingPathComponent("a.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: img)
        let msgs = (0..<3).flatMap { i in [msg("user", "图\(i)", images: [img.path]), msg("assistant", "好")] }
        let out = Agent.apiMessages(system: "", messages: msgs, vision: true)
        let withParts = out.filter { $0["content"] is [[String: Any]] }
        XCTAssertEqual(withParts.count, 2)
        XCTAssertTrue((out[1]["content"] as? String ?? "").contains("较早的图片已省略"))
    }

    func testShrinkToolOutputLeavesShortTextAlone() {
        XCTAssertEqual(Agent.shrinkToolOutput("short"), "short")
        XCTAssertEqual(Agent.shrinkToolOutput(String(repeating: "z", count: 800)).count, 800)
        XCTAssertTrue(Agent.shrinkToolOutput(String(repeating: "z", count: 2000)).hasPrefix(String(repeating: "z", count: 600)))
    }

    // MARK: compressThreshold

    func testCompressThreshold() {
        XCTAssertEqual(ModelManager.compressThreshold(8192), 6144)        // 75%
        XCTAssertEqual(ModelManager.compressThreshold(32768), 24576)
        XCTAssertEqual(ModelManager.compressThreshold(262144), 32000)     // 上限 3.2 万
        XCTAssertEqual(ModelManager.compressThreshold(0), 0)
    }
}

@MainActor
final class ChatStoreTests: XCTestCase {
    var root: URL!
    var store: ChatStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toolula-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ChatStore(root: root)
    }

    override func tearDown() async throws {
        store.storage.flush()
        try? FileManager.default.removeItem(at: root)
    }

    func conv(_ texts: [(String, String)]) -> Conversation {
        var c = Conversation(model: "main")
        c.messages = texts.map { ChatMessage(role: $0.0, text: $0.1) }
        return c
    }

    // MARK: compressibleRange

    func testCompressibleRangeNeedsThreeUserTurns() {
        XCTAssertNil(store.compressibleRange(conv([("user", "1"), ("assistant", "a"), ("user", "2"), ("assistant", "b")])))
        let c = conv([("user", "1"), ("assistant", "a"), ("user", "2"), ("assistant", "b"), ("user", "3"), ("assistant", "c")])
        // 保留最近两轮 (从第二个 user 开始)
        XCTAssertEqual(store.compressibleRange(c), 0..<2)
    }

    func testCompressibleRangeStartsAfterPreviousSummary() {
        var c = conv([("user", "1"), ("assistant", "a"), ("user", "2"), ("assistant", "b"), ("user", "3"), ("assistant", "c"), ("user", "4"), ("assistant", "d"), ("user", "5")])
        c.summaryUntil = c.messages[1].id
        XCTAssertEqual(store.compressibleRange(c), 2..<6)
        c.summaryUntil = c.messages[5].id
        XCTAssertNil(store.compressibleRange(c))   // 摘要之后只有两轮
    }

    // MARK: routeModel

    func testRouteModel() {
        let mm = ModelManager.shared
        let saved = (mm.models, mm.fastModel, mm.autoRoute)
        defer { mm.models = saved.0; mm.fastModel = saved.1; mm.autoRoute = saved.2 }
        mm.models = [LMModel(id: "main", type: "llm", loaded: true, context: 32768, toolUse: true),
                     LMModel(id: "fast", type: "llm", loaded: true, context: 32768, toolUse: true)]
        mm.fastModel = "fast"
        mm.autoRoute = true
        func route(_ q: String) -> String { store.routeModel(conv([("user", q)])) }
        XCTAssertEqual(route("你好"), "fast")
        XCTAssertEqual(route("讲个笑话"), "fast")
        XCTAssertEqual(route("帮我整理一下下载文件夹"), "main")
        XCTAssertEqual(route("写一个 Python 脚本批量改名"), "main")
        XCTAssertEqual(route("打开 Chrome 搜索天气"), "main")
        XCTAssertEqual(route(String(repeating: "长", count: 200)), "main")
        // 上一轮用了工具: 继续用主模型
        var c = conv([("user", "看看"), ("assistant", "")])
        c.messages[1].toolCalls = [ToolCall(id: "t", name: "run_shell", arguments: "{}")]
        c.messages.append(ChatMessage(role: "user", text: "好的"))
        XCTAssertEqual(store.routeModel(c), "main")
        // 关掉分流
        mm.autoRoute = false
        XCTAssertEqual(route("你好"), "main")
    }
}
