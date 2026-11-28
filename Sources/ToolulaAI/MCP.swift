import AppKit
import Foundation

// MCP (Model Context Protocol): 接上别人做好的工具服务器 (日历、Notion、GitHub、数据库……), AI 就能直接用里面的工具。
// 配置文件 ~/Toolula/Data/mcp.json, 格式和 Claude Desktop 一样:
//   {"mcpServers": {"名字": {"command": "npx", "args": ["-y", "某个包"], "env": {…}}  或  {"url": "https://…", "headers": {…}}}}

struct MCPServerConfig: Codable, Hashable {
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var url: String?
    var headers: [String: String]?
    var disabled: Bool?

    var summary: String {
        if let url { return url }
        return ([command ?? ""] + (args ?? [])).joined(separator: " ")
    }
}

struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig] = [:]
}

enum MCPError: LocalizedError {
    case badConfig, timeout(String), closed(String), server(String)
    var errorDescription: String? {
        switch self {
        case .badConfig: return String(localized: "配置不完整：要有 command（本机程序）或 url（网络服务）")
        case .timeout(let m): return String(localized: "等待回应超时（\(m)）")
        case .closed(let m): return String(localized: "服务器程序退出了") + (m.isEmpty ? "" : "：\(m)")
        case .server(let m): return m
        }
    }
}

// MARK: - 传输

protocol MCPTransport: AnyObject, Sendable {
    func request(_ method: String, _ params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any]
    func notify(_ method: String, _ params: [String: Any]?) async
    func close()
}

/// 本机程序: 通过标准输入输出, 一行一条 JSON-RPC 消息
final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextId = 1
    private var buffer = Data()
    private var stderrTail = ""
    private var exited = false

    init(command: String, args: [String], env: [String: String]) throws {
        // 用登录 shell 启动: npx、uvx 等装在 Homebrew 里的命令才找得到
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\"", command] + args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        process.environment = e
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.received(d)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock()
            self.stderrTail = String((self.stderrTail + String(decoding: d, as: UTF8.self)).suffix(2000))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in self?.failAll() }
        try process.run()
    }

    private func received(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(msg)
        }
    }

    private func handle(_ msg: [String: Any]) {
        if let method = msg["method"] as? String, let id = msg["id"] {
            // 服务器发来的请求: 只回应 ping, 其他的说不支持
            let reply: [String: Any] = method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported"]]
            write(reply)
            return
        }
        guard let id = (msg["id"] as? Int) ?? (msg["id"] as? String).flatMap(Int.init) else { return }
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        if let err = msg["error"] as? [String: Any] {
            cont?.resume(throwing: MCPError.server(err["message"] as? String ?? "\(err)"))
        } else {
            cont?.resume(returning: msg["result"] as? [String: Any] ?? [:])
        }
    }

    private func write(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: d)
    }

    private func failAll() {
        lock.lock()
        exited = true
        let all = pending; pending = [:]
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        for c in all.values { c.resume(throwing: MCPError.closed(String(tail.suffix(400)))) }
    }

    func request(_ method: String, _ params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        lock.lock()
        if exited { let t = stderrTail; lock.unlock(); throw MCPError.closed(String(t.suffix(400))) }
        let id = nextId; nextId += 1
        lock.unlock()
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.lock.lock(); let c = self.pending.removeValue(forKey: id); self.lock.unlock()
            c?.resume(throwing: MCPError.timeout(method))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending[id] = cont; lock.unlock()
            write(msg)
        }
    }

    func notify(_ method: String, _ params: [String: Any]?) async {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        write(msg)
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

/// 网络服务 (Streamable HTTP): 每条请求 POST 一次, 回应可能是 JSON, 也可能是 SSE 事件流
final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    let url: URL
    let headers: [String: String]
    private var session: String?
    private var protocolVersion: String?
    private var nextId = 1
    private let lock = NSLock()

    init(url: URL, headers: [String: String]) { self.url = url; self.headers = headers }

    private func post(_ msg: [String: Any], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        lock.lock()
        if let s = session { req.setValue(s, forHTTPHeaderField: "Mcp-Session-Id") }
        if let v = protocolVersion { req.setValue(v, forHTTPHeaderField: "MCP-Protocol-Version") }
        lock.unlock()
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.server("no response") }
        if let s = http.value(forHTTPHeaderField: "Mcp-Session-Id") { lock.lock(); session = s; lock.unlock() }
        if http.statusCode == 401 || http.statusCode == 403 { throw MCPError.server(String(localized: "服务器要求登录或授权（HTTP \(String(http.statusCode))），请在 headers 里填上令牌")) }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.server("HTTP \(http.statusCode): \(String(decoding: d.prefix(300), as: UTF8.self))") }
        return (d, http)
    }

    func request(_ method: String, _ params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        lock.lock(); let id = nextId; nextId += 1; lock.unlock()
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        let (d, http) = try await post(msg, timeout: timeout)
        var replies: [[String: Any]] = []
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            for line in String(decoding: d, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
                if let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] { replies.append(o) }
            }
        } else if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            replies = [o]
        }
        guard let r = replies.first(where: { ($0["id"] as? Int) == id }) else { throw MCPError.server("no reply for \(method)") }
        if let err = r["error"] as? [String: Any] { throw MCPError.server(err["message"] as? String ?? "\(err)") }
        let result = r["result"] as? [String: Any] ?? [:]
        if method == "initialize", let v = result["protocolVersion"] as? String { lock.lock(); protocolVersion = v; lock.unlock() }
        return result
    }

    func notify(_ method: String, _ params: [String: Any]?) async {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        _ = try? await post(msg, timeout: 15)
    }

    func close() {}
}

// MARK: - 客户端

struct MCPTool: Identifiable {
    let server: String
    let name: String
    let title: String
    let description: String
    let schema: [String: Any]
    let readOnly: Bool
    /// 给模型看的名字: mcp_服务器_工具
    let exposed: String
    var id: String { exposed }
}

final class MCPClient: @unchecked Sendable {
    let name: String
    let transport: MCPTransport
    private(set) var tools: [MCPTool] = []
    private(set) var serverName = ""

    init(name: String, config: MCPServerConfig) throws {
        self.name = name
        if let u = config.url, let url = URL(string: u) {
            transport = MCPHTTPTransport(url: url, headers: config.headers ?? [:])
        } else if let c = config.command, !c.isEmpty {
            transport = try MCPStdioTransport(command: c, args: config.args ?? [], env: config.env ?? [:])
        } else {
            throw MCPError.badConfig
        }
    }

    /// 握手并读取工具列表 (第一次用 npx 启动可能要下载, 给足时间)
    func start() async throws {
        let info = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let r = try await transport.request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Leonix", "version": info],
        ], timeout: 120)
        serverName = (r["serverInfo"] as? [String: Any])?["name"] as? String ?? name
        await transport.notify("notifications/initialized", nil)
        var all: [MCPTool] = []
        var cursor: String?
        repeat {
            let res = try await transport.request("tools/list", cursor.map { ["cursor": $0] }, timeout: 60)
            for t in res["tools"] as? [[String: Any]] ?? [] {
                guard let n = t["name"] as? String else { continue }
                let ann = t["annotations"] as? [String: Any]
                all.append(MCPTool(server: name, name: n, title: (t["title"] as? String) ?? (ann?["title"] as? String) ?? n,
                                   description: t["description"] as? String ?? "",
                                   schema: t["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()],
                                   readOnly: ann?["readOnlyHint"] as? Bool ?? false,
                                   exposed: MCPManager.exposedName(server: name, tool: n)))
            }
            cursor = res["nextCursor"] as? String
        } while cursor != nil && all.count < 500
        tools = all
    }

    /// 调用工具, 把结果整理成给模型看的文字
    func call(_ tool: String, _ args: [String: Any]) async -> String {
        do {
            let r = try await transport.request("tools/call", ["name": tool, "arguments": args], timeout: 300)
            var parts: [String] = []
            for c in r["content"] as? [[String: Any]] ?? [] {
                switch c["type"] as? String {
                case "text": parts.append(c["text"] as? String ?? "")
                case "image": parts.append(String(localized: "（返回了一张图片）"))
                case "resource":
                    let res = c["resource"] as? [String: Any]
                    parts.append(res?["text"] as? String ?? (res?["uri"] as? String ?? ""))
                case "resource_link": parts.append((c["uri"] as? String) ?? "")
                default: break
                }
            }
            if parts.isEmpty, let s = r["structuredContent"],
               let d = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]) { parts.append(String(decoding: d, as: UTF8.self)) }
            let text = Tools.truncate(parts.joined(separator: "\n"))
            return (r["isError"] as? Bool == true ? "错误：" : "") + (text.isEmpty ? String(localized: "（没有输出）") : text)
        } catch {
            return "错误：" + error.localizedDescription
        }
    }

    func close() { transport.close() }
}

// MARK: - 管理

@MainActor
final class MCPManager: ObservableObject {
    static let shared = MCPManager()

    enum Status: Equatable { case off, starting, ready, failed(String) }

    @Published private(set) var config = MCPConfigFile()
    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var tools: [MCPTool] = []
    private var clients: [String: MCPClient] = [:]

    static var file: URL {
        #if TOOLULA_SELFTEST
        // 评测用自己的配置文件, 不碰用户的
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--mcp-config"), i + 1 < a.count { return URL(fileURLWithPath: a[i + 1]) }
        #endif
        return AppPaths.dataFile("mcp.json")
    }

    init() { load() }

    var names: [String] { config.mcpServers.keys.sorted() }

    func load() {
        if let d = try? Data(contentsOf: Self.file), let c = try? JSONDecoder().decode(MCPConfigFile.self, from: d) { config = c }
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(config) { try? d.write(to: Self.file, options: .atomic) }
    }

    /// 给模型看的工具名: 只能有字母数字下划线横线, 最长 64
    nonisolated static func exposedName(server: String, tool: String) -> String {
        func clean(_ s: String) -> String {
            String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        }
        return String(("mcp_" + clean(server).prefix(20) + "_" + clean(tool)).prefix(64))
    }

    // MARK: 启动 / 停止

    /// 重新读配置文件 (用户手动改过之后)
    func reload() {
        for n in Array(clients.keys) { stop(n) }
        status = [:]
        load()
        startAll()
    }

    /// 打开配置文件 (还没有就先建一个空的)
    func openFile() {
        if !FileManager.default.fileExists(atPath: Self.file.path) { save() }
        NSWorkspace.shared.open(Self.file)
    }

    func startAll() {
        for n in names where config.mcpServers[n]?.disabled != true { start(n) }
    }

    func start(_ name: String) {
        guard let cfg = config.mcpServers[name], cfg.disabled != true else { status[name] = .off; return }
        stop(name)
        status[name] = .starting
        Task {
            do {
                let c = try MCPClient(name: name, config: cfg)
                try await c.start()
                // 期间被关掉或删除了
                guard config.mcpServers[name] != nil, config.mcpServers[name]?.disabled != true else { c.close(); return }
                clients[name] = c
                status[name] = .ready
            } catch {
                status[name] = .failed(error.localizedDescription)
            }
            refreshTools()
        }
    }

    func stop(_ name: String) {
        clients[name]?.close()
        clients[name] = nil
        status[name] = .off
        refreshTools()
    }

    private func refreshTools() {
        tools = names.flatMap { clients[$0]?.tools ?? [] }
    }

    // MARK: 增删改

    func add(_ name: String, _ cfg: MCPServerConfig) {
        config.mcpServers[name] = cfg
        save()
        start(name)
    }

    func remove(_ name: String) {
        stop(name)
        config.mcpServers[name] = nil
        status[name] = nil
        save()
    }

    func setEnabled(_ name: String, _ on: Bool) {
        config.mcpServers[name]?.disabled = on ? nil : true
        save()
        if on { start(name) } else { stop(name) }
    }

    /// 粘贴的配置: 整个 {"mcpServers": {…}}、只有 {"名字": {…}}、或单个服务器 {"command": …} (要另给名字)
    nonisolated static func parse(_ text: String, name: String? = nil) -> [String: MCPServerConfig]? {
        guard let d = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func decode(_ o: Any) -> MCPServerConfig? {
            guard o is [String: Any], let dd = try? JSONSerialization.data(withJSONObject: o),
                  let c = try? JSONDecoder().decode(MCPServerConfig.self, from: dd), c.command != nil || c.url != nil else { return nil }
            return c
        }
        if let servers = obj["mcpServers"] as? [String: Any] { return servers.compactMapValues(decode) }
        if obj["command"] != nil || obj["url"] != nil { return decode(obj).map { [name ?? "server": $0] } }
        let many = obj.compactMapValues(decode)
        return many.isEmpty ? nil : many
    }

    /// 从 Claude Desktop 的配置里导入 (不覆盖同名的), 返回导入了几个
    @discardableResult
    func importFrom(_ file: URL) -> Int {
        guard let s = try? String(contentsOf: file, encoding: .utf8), let servers = Self.parse(s) else { return 0 }
        var n = 0
        for (k, v) in servers where config.mcpServers[k] == nil {
            config.mcpServers[k] = v; n += 1
            start(k)
        }
        save()
        return n
    }

    static var claudeDesktopConfig: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    // MARK: 给 AI 用

    func definitions() -> [[String: Any]] {
        tools.map { t in
            var desc = t.description.isEmpty ? t.title : t.description
            if desc.count > 400 { desc = String(desc.prefix(400)) + "…" }
            return ["type": "function", "function": ["name": t.exposed, "description": "[\(t.server)] " + desc, "parameters": t.schema]]
        }
    }

    func tool(_ exposed: String) -> MCPTool? { tools.first { $0.exposed == exposed } }

    func run(_ call: ToolCall, ctx: ToolContext) async -> String {
        guard let t = tool(call.name), let c = clients[t.server] else { return "错误：外部工具 \(call.name) 现在没有连接" }
        if !t.readOnly {
            let args = String(call.arguments.prefix(300))
            guard await ctx.approve(call, String(localized: "使用「\(t.server)」的工具 \(t.title)") + "\n" + args) else { return String(localized: "用户拒绝执行这条命令。") }
        }
        return await c.call(t.name, call.args)
    }
}
