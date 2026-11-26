import Foundation

/// 一次任务里的护栏 (对话和自动化共用):
/// - 原地打转: 同样的调用 (工具名 + 参数完全相同) 中间没改过任何东西, 第 3 次起不再执行, 让模型换办法;
/// - 连续出错 3 次: 在结果后面提醒先想清楚原因、换思路, 做不到就如实说;
/// - 模型要结束时, 计划 (plan) 里还有没完成的步骤: 提醒一次。
/// 本地模型比较容易在这几处卡住, 有了提醒能自己绕出来。
struct AgentGuard {
    private var seen: [String: Int] = [:]
    private(set) var consecutiveErrors = 0
    private(set) var loops = 0
    private var nudged = false

    /// 这一轮是不是卡住了 (界面上会建议换更强的模型)
    var stuck: Bool { consecutiveErrors >= 3 || loops >= 2 }

    /// 只读的工具: 不会改变任何东西
    static let readOnly: Set<String> = ["list_directory", "read_file", "search_files", "web_search", "browser_read", "chrome_read", "chrome_tabs",
                                        "app_read", "screenshot", "list_apps", "list_shortcuts", "use_skill", "plan"]
    /// 重复调用是正常的 (界面可能变了、计划要更新)
    static let repeatable: Set<String> = ["plan", "screenshot", "app_read", "browser_read", "chrome_read", "chrome_tabs"]

    private func key(_ call: ToolCall) -> String {
        let c = Tools.normalize(call)
        let args = (try? JSONSerialization.jsonObject(with: Data(c.arguments.utf8)))
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) } ?? c.arguments
        return c.name + "|" + args
    }

    /// 执行前检查: 返回非 nil 就不执行, 把这段话当作工具结果
    mutating func before(_ call: ToolCall) -> String? {
        let name = Tools.normalize(call).name
        guard !Self.repeatable.contains(name) else { return nil }
        let k = key(call)
        let n = (seen[k] ?? 0) + 1
        seen[k] = n
        guard n >= 3 else { return nil }
        loops += 1
        return "这个调用（\(name)，参数和前面完全相同）已经做过 \(n - 1) 次，结果不会变，这次没有执行。请换一个办法；如果确实做不到，就停下来告诉用户卡在哪里、需要什么帮助。"
    }

    /// 执行后: 记录出错次数, 必要时在结果后面加提醒
    mutating func after(_ call: ToolCall, _ output: String) -> String {
        let name = Tools.normalize(call).name
        let failed = Tools.looksLikeError(output)
        consecutiveErrors = failed ? consecutiveErrors + 1 : 0
        // 改过东西之后, 同样的查看操作再做一遍是正常的 (比如改完再列目录核对)
        if !failed, !Self.readOnly.contains(name) {
            let k = key(call)
            seen = [k: seen[k] ?? 1]
        }
        if consecutiveErrors == 3 {
            return output + "\n\n（已经连续 3 次出错。先停下来想清楚原因：换个思路，或者先用只读工具查清楚情况；实在做不到就如实告诉用户。）"
        }
        return output
    }

    /// 模型准备结束时调用 (只看这一轮的消息): 计划没做完就返回一段提醒 (只提醒一次)
    mutating func finishNudge(_ turn: [ChatMessage]) -> String? {
        guard !nudged, let p = PlanState.latest(turn), p.current > 0, p.current <= p.steps.count else { return nil }
        nudged = true
        let left = p.steps.indices.dropFirst(p.current - 1).map { "\($0 + 1). \(p.steps[$0])" }.joined(separator: "\n")
        return "（系统提醒）计划里这些步骤还没标记完成：\n\(left)\n如果其实已经做完了：先核对结果，再调用 plan 把 current 设为 0，然后向用户汇报。如果还没做：接着做完。"
    }
}

extension ToolCall {
    /// 模型写坏的参数 JSON 尽量修好: 去掉 ``` 代码块、多余的逗号, 补上漏掉的右括号
    static func repairArguments(_ s: String) -> String {
        func valid(_ t: String) -> Bool { (try? JSONSerialization.jsonObject(with: Data(t.utf8))) is [String: Any] }
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || valid(t) { return s }
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
                 .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            if valid(t) { return t }
        }
        let noTrailing = t.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        if valid(noTrailing) { return noTrailing }
        for suffix in ["}", "\"}", "]}", "}}"] where valid(noTrailing + suffix) { return noTrailing + suffix }
        return s
    }

    /// 有的模型把工具调用写在正文里 (<tool_call>{"name":…,"arguments":{…}}</tool_call>), 引擎没认出来: 从正文里取出来
    static func extractFromText(_ content: String) -> (calls: [ToolCall], rest: String)? {
        guard content.contains("<tool_call>"),
              let re = try? NSRegularExpression(pattern: #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#, options: [.dotMatchesLineSeparators]) else { return nil }
        var calls: [ToolCall] = []
        let ns = content as NSString
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let json = repairArguments(ns.substring(with: m.range(at: 1)))
            guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let name = o["name"] as? String else { continue }
            let args = o["arguments"] ?? o["parameters"] ?? [String: Any]()
            let argStr: String
            if let s = args as? String { argStr = repairArguments(s) }
            else { argStr = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
            calls.append(ToolCall(id: "call_" + UUID().uuidString.prefix(8), name: name, arguments: argStr))
        }
        guard !calls.isEmpty else { return nil }
        let rest = re.stringByReplacingMatches(in: content, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (calls, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
