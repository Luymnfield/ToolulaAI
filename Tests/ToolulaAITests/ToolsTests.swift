import XCTest
@testable import ToolulaAI

/// 合并后的工具写法 (Tools.definitions) 要能换回原来的工具 (Tools.normalize)
final class ToolsTests: XCTestCase {
    func call(_ name: String, _ args: [String: Any]) -> ToolCall {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)
        return ToolCall(id: "1", name: name, arguments: json)
    }

    func norm(_ name: String, _ args: [String: Any]) -> (String, [String: Any]) {
        let c = Tools.normalize(call(name, args))
        return (c.name, c.args)
    }

    func testBrowser() {
        XCTAssertEqual(norm("browser_open", ["url": "https://apple.com"]).0, "browser_open")
        XCTAssertEqual(norm("browser_open", [:]).0, "browser_read")
        XCTAssertEqual(norm("browser_open", ["url": " "]).0, "browser_read")
        XCTAssertEqual(norm("browser_open", ["url": "back"]).0, "browser_back")
        XCTAssertEqual(norm("browser_click", ["element_id": 3]).0, "browser_click")
        let t = norm("browser_click", ["element_id": 3, "text": "你好", "submit": true])
        XCTAssertEqual(t.0, "browser_type")
        XCTAssertEqual(t.1["element_id"] as? Int, 3)
        XCTAssertEqual(t.1["text"] as? String, "你好")
    }

    func testMemoryAndSkills() {
        XCTAssertEqual(norm("memory_save", ["text": "是摄影师"]).0, "memory_save")
        let d = norm("memory_save", ["delete_id": "ab12"])
        XCTAssertEqual(d.0, "memory_delete")
        XCTAssertEqual(d.1["id"] as? String, "ab12")
        XCTAssertEqual(norm("use_skill", ["name": "整理文件夹"]).0, "use_skill")
        XCTAssertEqual(norm("use_skill", ["name": "周报", "description": "写周报时", "instructions": "1. …"]).0, "create_skill")
    }

    func testComputerUse() {
        XCTAssertEqual(norm("open_app", [:]).0, "list_apps")
        XCTAssertEqual(norm("open_app", ["name": "备忘录"]).0, "open_app")
        XCTAssertEqual(norm("run_shortcut", [:]).0, "list_shortcuts")
        XCTAssertEqual(norm("app_click", ["id": 2]).0, "app_click")
        XCTAssertEqual(norm("app_click", ["text": "hi"]).0, "app_type")
        let m = norm("app_key", ["menu": "文件 > 导出…", "app": "预览"])
        XCTAssertEqual(m.0, "app_menu")
        XCTAssertEqual(m.1["path"] as? String, "文件 > 导出…")
        XCTAssertEqual(norm("app_key", ["keys": "cmd+s"]).0, "app_key")
        XCTAssertEqual(norm("chrome_open", [:]).0, "chrome_read")
        XCTAssertEqual(norm("chrome_open", ["url": "tabs"]).0, "chrome_tabs")
        XCTAssertEqual(norm("chrome_open", ["url": "back"]).0, "chrome_back")
        XCTAssertEqual(norm("chrome_open", ["url": "github.com"]).0, "chrome_open")
        XCTAssertEqual(norm("chrome_click", ["id": 4, "text": "x"]).0, "chrome_type")
    }

    /// 旧工具名 (旧对话里的调用) 原样保留
    func testOldNamesUnchanged() {
        for n in ["browser_read", "browser_back", "browser_type", "memory_delete", "create_skill", "list_apps", "list_shortcuts",
                  "app_type", "app_menu", "chrome_tabs", "chrome_read", "chrome_type", "chrome_back", "run_shell", "notify_user"] {
            let c = call(n, ["x": 1])
            XCTAssertEqual(Tools.normalize(c), c, n)
        }
    }
}
