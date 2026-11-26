import Foundation

#if TOOLULA_SELFTEST
/// 智能体评测 (只在自测构建里): 跑一道 Evals/tasks.py 里的题。
/// spec 是 JSON: {"prompt", "workdir", "timeout", "out", "model"?}; 结果写到 out (JSON), 由 Evals/run_eval.py 打分。
/// 需要确认的操作按「只能动沙盒文件夹」自动批准或拒绝, 不碰沙盒以外的东西。
@MainActor
enum EvalTask {
    struct Spec: Decodable {
        var prompt: String
        var workdir: String
        var timeout: Double?
        var out: String
        var model: String?
    }

    static func run(spec url: URL, chat: ChatStore, app: AppState) async -> String {
        guard let d = try? Data(contentsOf: url), let spec = try? JSONDecoder().decode(Spec.self, from: d) else { return "eval: bad spec\n" }
        app.section = .chat
        // 有 MCP 配置的题: 等外部工具连上 (最多 30 秒)
        if CommandLine.arguments.contains("--mcp-config") {
            for _ in 0..<60 where MCPManager.shared.tools.isEmpty { try? await Task.sleep(for: .seconds(0.5)) }
        }
        let id = chat.newConversation()
        chat.update(id) { c in
            c.workDir = spec.workdir
            c.agent = true
            c.autoApprove = false
            if let m = spec.model, !m.isEmpty { c.model = m }
        }
        var denied: [String] = [], approved: [String] = []
        let t0 = Date()
        var timedOut = false
        chat.send(spec.prompt, to: id)
        try? await Task.sleep(for: .seconds(0.5))
        while chat.running.contains(id) {
            if let a = chat.approval, a.conversationId == id {
                let ok = allowed(a.call, sandbox: spec.workdir)
                (ok ? { approved.append("\(a.call.name) \(a.call.arguments.prefix(300))") } : { denied.append("\(a.call.name) \(a.call.arguments.prefix(300))") })()
                chat.approval = nil
                a.continuation.resume(returning: ok)
            }
            if Date().timeIntervalSince(t0) > (spec.timeout ?? 300) { timedOut = true; chat.stop(id); break }
            try? await Task.sleep(for: .seconds(0.3))
        }
        let secs = Date().timeIntervalSince(t0)
        let c = chat.conversations.first { $0.id == id }
        var msgs: [[String: Any]] = []
        var calls = 0, errors = 0
        var models = Set<String>()
        for m in c?.messages ?? [] {
            var o: [String: Any] = ["role": m.role, "text": m.text]
            if m.role == "assistant" { models.insert(m.model ?? c?.model ?? "") }
            if let e = m.error { o["error"] = e }
            if let n = m.toolName { o["tool"] = n }
            if !m.toolCalls.isEmpty {
                o["calls"] = m.toolCalls.map { ["name": $0.name, "arguments": $0.arguments] }
                calls += m.toolCalls.count
            }
            if m.role == "tool", Tools.looksLikeError(m.text) { errors += 1 }
            msgs.append(o)
        }
        let answer = c?.messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text ?? ""
        let result: [String: Any] = [
            "answer": answer, "messages": msgs, "tool_calls": calls, "tool_errors": errors,
            "seconds": secs, "timed_out": timedOut, "denied": denied, "approved": approved,
            "models": Array(models).sorted(), "main_model": c?.model ?? "",
            "error": c?.messages.last?.error ?? "",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: spec.out))
        }
        chat.delete(id)
        return "eval: done \(Int(secs))s calls=\(calls) errors=\(errors) timeout=\(timedOut)\n"
    }

    /// 只批准动沙盒里文件的操作
    static func allowed(_ original: ToolCall, sandbox: String) -> Bool {
        let call = Tools.normalize(original)
        let a = call.args
        let home = NSHomeDirectory()
        switch call.name {
        case "write_file", "edit_file":
            let p = Tools.expand(a["path"] as? String ?? "", base: URL(fileURLWithPath: sandbox)).standardizedFileURL.path
            return p.hasPrefix(sandbox + "/") || ("/private" + p).hasPrefix(sandbox + "/")
        case "run_shell":
            let cmd = a["command"] as? String ?? ""
            if cmd.range(of: #"\bsudo\b|\bmkfs|\bdiskutil\b|\bshutdown\b|\breboot\b|\bosascript\b|\blaunchctl\b"#, options: .regularExpression) != nil { return false }
            // 沙盒以外的主目录路径一律不许 (读也不许, 题目都在沙盒里)
            let rest = cmd.replacingOccurrences(of: sandbox, with: "").replacingOccurrences(of: sandbox.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"), with: "")
            if rest.contains(home) || rest.contains("~") || rest.contains("$HOME") || rest.contains("${HOME}") { return false }
            if rest.range(of: #"rm\s+-\w*\s+/(\s|$)"#, options: .regularExpression) != nil { return false }
            return true
        default:
            return false   // run_applescript、run_shortcut、生成视频等: 评测里不做
        }
    }
}
#endif
