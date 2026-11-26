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
    private var calcNudged = false

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

    /// 问题要计算 (日期差、求和、几岁……), 模型却没用工具就报了数: 要它用 python 算一遍 (只提醒一次)
    mutating func calcNudge(_ turn: [ChatMessage]) -> String? {
        guard !calcNudged, let q = turn.first(where: { $0.role == "user" && $0.hidden != true })?.text,
              let a = turn.last(where: { $0.role == "assistant" })?.text,
              !turn.contains(where: { !$0.toolCalls.isEmpty }),
              a.range(of: #"\d"#, options: .regularExpression) != nil, Self.needsCalc(q) else { return nil }
        calcNudged = true
        return "（系统提醒）这个问题要算准，请用 run_shell 运行 python3 把答案算出来（日期用 datetime），确认后再回答，不要心算。"
    }

    static func needsCalc(_ q: String) -> Bool {
        let t = q.lowercased()
        let words = ["计算", "算一下", "多少天", "几天", "多少周", "多少小时", "统计", "总共", "合计", "求和", "之和", "平均", "百分之", "利息", "汇率",
                     "how many days", "calculate", "sum of", "average"]
        if words.contains(where: { t.contains($0) }) { return true }
        // 题目里有两个以上的数字, 又在问「多少 / 几」: 多半要算
        let numbers = (try? NSRegularExpression(pattern: #"\d+(\.\d+)?"#))?.numberOfMatches(in: t, range: NSRange(t.startIndex..., in: t)) ?? 0
        return numbers >= 2 && (t.contains("多少") || t.contains("几") || t.contains("how many") || t.contains("how much"))
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


/// 独立核查: 会改动文件的任务做完后, 另开一个只能查看的助手, 对照「用户的要求」检查实际结果。
/// 专门防「其实没做好却说做好了」(本地模型常见); 发现问题就让原来的助手先修好再汇报。
enum AgentVerifier {
    /// 最近几次核查的结论 (诊断、评测用)
    @MainActor static var reports: [String] = []

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "verifyTasks") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "verifyTasks") }
    }

    /// 这一轮动过文件 (写文件、改文件、看起来会改文件的命令)
    static func changedFiles(_ turn: [ChatMessage]) -> Bool {
        turn.flatMap(\.toolCalls).contains { c in
            let n = Tools.normalize(c).name
            return n == "write_file" || n == "edit_file" || (n == "run_shell" && Tools.mayChangeFiles(c.args["command"] as? String ?? ""))
        }
    }

    /// 返回发现的问题; 没问题 (或核查本身没做成) 返回 nil
    @MainActor
    static func check(turn: [ChatMessage], model: String, workDir: String, progress: ((String) -> Void)? = nil) async -> String? {
        guard let request = turn.first(where: { $0.role == "user" && $0.hidden != true }),
              let answer = turn.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text else { return nil }
        let changes = turn.filter { $0.role == "tool" }.compactMap { m -> String? in
            guard let r = m.text.range(of: "【实际变化】") else { return nil }
            return String(m.text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.hasPrefix("没有任何") }.joined(separator: "\n")
        let readOnly: Set<String> = ["list_directory", "read_file", "search_files", "run_shell"]
        let tools = Tools.definitions(photo: false).filter { readOnly.contains((($0["function"] as? [String: Any])?["name"] as? String) ?? "") }
        let system = Agent.systemPrompt(workDir: workDir, tools: true, extra: "\n\n你是核查员：只检查、不修改任何东西，也不要提问。")
        let prompt = """
            用户的要求：\((request.expanded ?? request.text).prefix(3000))

            助手做完后的汇报：\(answer.prefix(3000))

            程序记录到的实际文件变化：\(changes.isEmpty ? "（没有记录）" : String(changes.prefix(3000)))

            请用 list_directory、read_file、search_files，以及只读命令（run_shell 只能用 ls、cat、wc、file、sips -g、md5、unzip -l、grep 这类查看命令）检查实际结果是否真的满足用户的要求：该有的文件在不在、位置对不对、内容对不对、汇报里的数字和事实是否属实。只检查要求里明确提到的事，不挑写法和风格。数字和计算结果只有用工具实际查到不一样时才算错，不能靠心算判定；代码是否正确以文件现在的内容为准（修好后原来的 bug 本来就不在了）。
            最后单独一行写结论：「核查通过」，或「核查未通过：具体哪里不对」。
            """
        var ctx = ToolContext(workDir: URL(fileURLWithPath: workDir), approve: { call, _ in
            Tools.normalize(call).name == "run_shell" && ReadOnlyShell.allowed(call.args["command"] as? String ?? "")
        }, photoStore: nil)
        ctx.progress = progress
        let r = await AgentRunner.run(prompt: prompt, model: model, system: system, tools: tools, ctx: ctx, maxSteps: 10)
        reports.append(r.text.split(separator: "\n").last.map(String.init) ?? "")
        guard r.ok, let line = r.text.split(separator: "\n").last(where: { $0.contains("核查") }) else { return nil }
        guard line.contains("未通过") else { return nil }
        let reason = line.split(separator: "：", maxSplits: 1).dropFirst().first.map(String.init) ?? String(line)
        return reason.trimmingCharacters(in: .whitespaces)
    }
}


/// 只查看、不改动任何东西的命令 (给核查员用)
enum ReadOnlyShell {
    static let commands: Set<String> = ["ls", "cat", "head", "tail", "wc", "file", "stat", "du", "df", "md5", "shasum", "grep", "egrep", "rg", "find",
                                        "sort", "uniq", "cut", "tr", "awk", "diff", "cmp", "echo", "printf", "pwd", "date", "basename", "dirname",
                                        "sips", "mdls", "unzip", "zipinfo", "tar", "plutil", "jq", "xxd", "column", "nl", "comm", "test", "[", "realpath", "readlink"]

    static func allowed(_ cmd: String) -> Bool {
        // 不许: 写文件的重定向 (除了 2>/dev/null)、命令替换、后台
        let stripped = cmd.replacingOccurrences(of: #"\d?>\s*/dev/null"#, with: "", options: .regularExpression)
        if stripped.contains(">") || stripped.contains("`") || stripped.contains("$(") || stripped.contains("&") && !stripped.contains("&&") { return false }
        // 会改东西的选项
        if cmd.range(of: #"\s-(delete|exec|execdir|ok|fprint)\b|\bsips\b.*\s-(s|z|Z|r|f|c|p|-out|o)\b|\bunzip\b(?!.*\s-l)|\btar\b(?!.*\s-?t)|\bplutil\b.*\s-(convert|insert|replace|remove)\b|\bsort\b.*\s-o\b"#,
                     options: .regularExpression) != nil { return false }
        let segments = cmd.split(whereSeparator: { $0 == "|" || $0 == ";" || $0 == "&" || $0 == "\n" })
        for seg in segments {
            let words = seg.split(separator: " ").map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
            guard let first = words.first else { continue }
            let name = (first as NSString).lastPathComponent
            if name == "cd" { continue }
            if !commands.contains(name) { return false }
        }
        return true
    }
}
