import XCTest
@testable import ToolulaAI

final class MarkdownTests: XCTestCase {
    func testHeadingsParagraphRule() {
        let b = MarkdownParser.parse("# 标题\n## 二级 ##\n正文第一行\n正文第二行\n\n---\n#不是标题")
        XCTAssertEqual(b, [.heading(level: 1, text: "标题"), .heading(level: 2, text: "二级"),
                           .paragraph("正文第一行\n正文第二行"), .rule, .paragraph("#不是标题")])
    }

    func testTableWithAlignmentAndEscapes() {
        let md = """
        | 名称 | 数量 | 说明 |
        |:---|:---:|---:|
        | A | 1 | `a|b` |
        | B \\| C | 2 |
        """
        guard case .table(let h, let a, let rows) = MarkdownParser.parse(md).first else { return XCTFail("应是表格") }
        XCTAssertEqual(h, ["名称", "数量", "说明"])
        XCTAssertEqual(a, [.leading, .center, .trailing])
        XCTAssertEqual(rows, [["A", "1", "`a|b`"], ["B | C", "2", ""]])
    }

    func testPipeLineWithoutDelimiterIsParagraph() {
        XCTAssertEqual(MarkdownParser.parse("a | b"), [.paragraph("a | b")])
    }

    func testLists() {
        let b = MarkdownParser.parse("- 一\n- 二\n  - 子\n  续行\n1. 有序\n2) 二\n- [x] 完成\n- [ ] 未完成")
        guard case .list(let items) = b.first, b.count == 1 else { return XCTFail("\(b)") }
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items[2].level, 1)
        XCTAssertEqual(items[2].text, "子\n续行")
        XCTAssertTrue(items[3].ordered); XCTAssertEqual(items[4].number, 2)
        XCTAssertEqual(items[5].checked, true); XCTAssertEqual(items[6].checked, false)
    }

    func testQuoteIsParsedRecursively() {
        XCTAssertEqual(MarkdownParser.parse("> # 引用标题\n> 内容"), [.quote([.heading(level: 1, text: "引用标题"), .paragraph("内容")])])
    }

    func testCodeFenceIncludingUnclosedWhileStreaming() {
        XCTAssertEqual(MarkdownParser.parse("前\n```swift\nlet a = 1\n# 不是标题\n```\n后"),
                       [.paragraph("前"), .code(lang: "swift", text: "let a = 1\n# 不是标题", closed: true), .paragraph("后")])
        XCTAssertEqual(MarkdownParser.parse("```py\nprint(1)"), [.code(lang: "py", text: "print(1)", closed: false)])
    }

    func testMathBlocks() {
        XCTAssertEqual(MarkdownParser.parse("$$\nx^2\n$$"), [.math("x^2")])
        XCTAssertEqual(MarkdownParser.parse("$$a+b$$"), [.math("a+b")])
        XCTAssertEqual(MarkdownParser.parse("\\[\n\\pi\n\\]"), [.math("\\pi")])
    }

    func testMathRendering() {
        XCTAssertEqual(MathText.render("E=mc^2"), "E=mc²")
        XCTAssertEqual(MathText.render("\\alpha \\leq \\frac{1}{2}"), "α ≤ 1/2")
        XCTAssertEqual(MathText.render("x_{i}^{2}"), "xᵢ²")
        XCTAssertEqual(MathText.render("\\sqrt{a+b}"), "√(a+b)")
        XCTAssertEqual(MathText.render("\\mathbb{R}"), "ℝ")
    }

    func testInlineMathDoesNotEatPrices() {
        XCTAssertEqual(MathText.inline("价格 $5 和 $10"), "价格 $5 和 $10")
        XCTAssertEqual(MathText.inline("公式 $x^2$ 结束"), "公式 `x²` 结束")
        XCTAssertEqual(MathText.inline("\\(\\pi\\)"), "`π`")
    }

    func testSyntaxHighlightTokens() {
        let code = "let s = \"hi\" // note\nfunc f() { return 42 }"
        let toks = SyntaxHighlighter.tokens(code, lang: "swift").map { (String(code[$0.0]), $0.1) }
        XCTAssertTrue(toks.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(toks.contains { $0 == ("\"hi\"", .string) })
        XCTAssertTrue(toks.contains { $0 == ("// note", .comment) })
        XCTAssertTrue(toks.contains { $0 == ("42", .number) })
        let json = "{\"k\": true}"
        let jt = SyntaxHighlighter.tokens(json, lang: "json").map { (String(json[$0.0]), $0.1) }
        XCTAssertTrue(jt.contains { $0 == ("\"k\"", .key) })
        XCTAssertTrue(jt.contains { $0 == ("true", .keyword) })
        XCTAssertTrue(SyntaxHighlighter.tokens("abc", lang: "unknownlang").isEmpty)
        let sh = "echo $HOME # c"
        let st = SyntaxHighlighter.tokens(sh, lang: "bash").map { (String(sh[$0.0]), $0.1) }
        XCTAssertTrue(st.contains { $0 == ("# c", .comment) })
        XCTAssertTrue(st.contains { $0 == ("$HOME", .type) })
    }

    func testParseCacheReturnsSameObject() {
        let t = "# 缓存测试 \(UUID())"
        let a = MarkdownText(text: t).parsed, b = MarkdownText(text: t).parsed
        XCTAssertTrue(a === b)
    }

    func testCommandPaletteScoring() {
        let cmds = ["新建对话", "前往：视频", "前往：模型", "对话模型：qwen3"].map { t in PaletteCommand(id: t, kind: .action, icon: "", title: t) {} }
        XCTAssertEqual(PaletteSearch.filter(cmds, "前往 视频").first?.title, "前往：视频")
        XCTAssertEqual(PaletteSearch.filter(cmds, "模型").map(\.title), ["前往：模型", "对话模型：qwen3"])
        XCTAssertEqual(PaletteSearch.filter(cmds, "").count, 4)
        XCTAssertTrue(PaletteSearch.filter(cmds, "zzz").isEmpty)
    }

    func testHotKeyConflicts() {
        XCTAssertNil(HotKey.defaultQuickAsk.systemConflict)
        XCTAssertNotNil(HotKey(keyCode: 49, modifiers: 256).systemConflict)   // ⌘Space
        XCTAssertNotNil(HotKey(keyCode: 0, modifiers: 0).systemConflict)      // 没有修饰键
    }
}
