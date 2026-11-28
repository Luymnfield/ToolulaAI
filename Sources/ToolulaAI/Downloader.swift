import Foundation
import SwiftUI

/// Hugging Face 上的一个模型
struct HFModel: Identifiable, Hashable {
    let id: String              // 例如 lmstudio-community/Qwen3.8-27B-MLX-8bit
    let downloads: Int
    var size: Int64?            // 文件总大小 (字节)
    var installed: Bool
}

/// 正在下载的模型
@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    let id: String
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var state = String(localized: "准备中…")
    @Published var done = false
    @Published var failed = false
    var task: Task<Void, Never>?
    var finishedBytes: Int64 = 0
    var quant: String?
    var dest: URL?                  // 下载到哪个文件夹 (nil = LM Studio 的模型文件夹)
    var parts: [String: Int64] = [:]
    func update() { received = finishedBytes + parts.values.reduce(0, +) }
    var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    init(id: String) { self.id = id }
}

/// 从 Hugging Face 下载 MLX 模型到 LM Studio 的模型文件夹
@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published var results: [HFModel] = []
    @Published var searching = false
    @Published var jobs: [DownloadJob] = []
    @Published var searchError: String?

    static let modelsDir = URL(fileURLWithPath: NSHomeDirectory() + "/.lmstudio/models")

    static func isInstalled(_ id: String) -> Bool {
        if BuiltinEngine.isInstalled(repo: id) { return true }
        let dir = modelsDir.appendingPathComponent(id)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return files.contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".gguf") }
            && !files.contains { $0.hasSuffix(".part") || $0.hasSuffix(".download") }
    }

    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        searching = true
        searchError = nil
        Task {
            defer { searching = false }
            var comps = URLComponents(string: "https://huggingface.co/api/models")!
            comps.queryItems = [URLQueryItem(name: "filter", value: "mlx"), URLQueryItem(name: "sort", value: "downloads"),
                                URLQueryItem(name: "limit", value: "40")]
            if !q.isEmpty { comps.queryItems?.append(URLQueryItem(name: "search", value: q)) }
            do {
                let (data, _) = try await URLSession.shared.data(from: comps.url!)
                let list = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
                results = list.compactMap { m in
                    guard let id = (m["id"] ?? m["modelId"]) as? String else { return nil }
                    return HFModel(id: id, downloads: m["downloads"] as? Int ?? 0, size: nil, installed: Self.isInstalled(id))
                }
                for r in results.prefix(25) { fetchSize(r.id) }
            } catch {
                searchError = error.localizedDescription
            }
        }
    }

    func loadRecommended() {
        var seen = Set<String>()
        let ids = Recommender.picks().flatMap { [$0.best, $0.alt] }.compactMap { $0?.id }.filter { seen.insert($0).inserted }
        results = ids.map { HFModel(id: $0, downloads: 0, size: nil, installed: Self.isInstalled($0)) }
        for r in results { fetchSize(r.id) }
    }

    private func fetchSize(_ id: String) {
        Task {
            guard let files = await Self.files(id) else { return }
            let total = files.reduce(Int64(0)) { $0 + $1.1 }
            if let i = results.firstIndex(where: { $0.id == id }) { results[i].size = total }
        }
    }

    /// 仓库里要下载的文件 (路径, 大小)
    nonisolated static func files(_ id: String, quant: String? = nil) async -> [(String, Int64)]? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(id)/tree/main?recursive=true") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [(String, Int64)] = list.compactMap { f in
            guard f["type"] as? String == "file", let path = f["path"] as? String,
                  ![".gitattributes", "README.md"].contains(path), !path.hasPrefix("."), !path.hasSuffix(".md") else { return nil }
            let size = (f["size"] as? Int64) ?? Int64(f["size"] as? Int ?? 0)
            return (path, size)
        }
        // GGUF 仓库里有好几种量化版本, 只下需要的那一个 (加上看图用的 mmproj)
        if out.contains(where: { $0.0.hasSuffix(".gguf") }) {
            let q = quant ?? "Q4_K_M"
            out = out.filter { !$0.0.hasSuffix(".gguf") || $0.0.contains(q) || $0.0.lowercased().hasPrefix("mmproj") }
        }
        return out
    }

    func download(_ id: String, quant: String? = nil) {
        guard !jobs.contains(where: { $0.id == id && !$0.done && !$0.failed }) else { return }
        jobs.removeAll { $0.id == id }
        let job = DownloadJob(id: id)
        jobs.insert(job, at: 0)
        job.quant = quant
        // 没装 LM Studio 时, GGUF 模型下载给 Leonix 内置引擎
        if LocalEngine.preferred == .builtin, quant != nil || id.lowercased().hasSuffix("gguf") {
            job.dest = EnginePaths.models.appendingPathComponent(BuiltinEngine.folderName(forRepo: id))
        }
        job.task = Task { await run(job) }
    }

    func cancel(_ job: DownloadJob) {
        job.task?.cancel()
        job.failed = true
        job.state = String(localized: "已取消")
    }

    private func run(_ job: DownloadJob) async {
        guard let files = await Self.files(job.id, quant: job.quant) else {
            job.failed = true; job.state = String(localized: "获取文件列表失败"); return
        }
        job.total = files.reduce(Int64(0)) { $0 + $1.1 }
        let dir = job.dest ?? Self.modelsDir.appendingPathComponent(job.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 同一个模型换了量化版本: 删掉旧的, 一个文件夹只放一个模型文件
        if job.dest != nil {
            let keep = Set(files.map { ($0.0 as NSString).lastPathComponent })
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".gguf") && !keep.contains(f) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        job.state = String(localized: "下载中…")
        // 小文件先下, 大文件最多 4 个同时下
        let sorted = files.sorted { $0.1 < $1.1 }
        do {
            try await withThrowingTaskGroup(of: (String, Int64).self) { group in
                var running = 0
                for (path, size) in sorted {
                    if running >= 4, let r = try await group.next() { running -= 1; job.finishedBytes += r.1; job.parts[r.0] = nil }
                    running += 1
                    let dest = dir.appendingPathComponent(job.dest != nil ? (path as NSString).lastPathComponent : path)
                    group.addTask {
                        try await Self.fetch(repo: job.id, path: path, to: dest, expected: size) { got in
                            Task { @MainActor in
                                job.parts[path] = got
                                job.update()
                            }
                        }
                        return (path, size)
                    }
                }
                for try await r in group { job.finishedBytes += r.1; job.parts[r.0] = nil; job.update() }
            }
            job.received = job.total
            job.done = true
            job.state = String(localized: "完成，可以在模型列表里使用了")
            if job.dest != nil { await BuiltinEngine.shared.reload() }
            ModelManager.shared.refresh()
            if let i = results.firstIndex(where: { $0.id == job.id }) { results[i].installed = true }
        } catch {
            if !job.failed {
                job.failed = true
                job.state = String(localized: "下载失败：\(error.localizedDescription)（再点下载会接着下）")
            }
        }
    }

    /// 按完整网址下载一个文件 (断点续传; 已经下完的跳过)
    nonisolated static func fetch(url: URL, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { return }
        let partial = dest.appendingPathExtension("download")
        var have: Int64 = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else { throw URLError(.badServerResponse) }
        if code == 200 { have = 0; try? fm.removeItem(at: partial) }
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var buffer = Data()
        buffer.reserveCapacity(4 << 20)
        var got = have
        var last = Date()
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 4 << 20 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                got += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(last) > 0.5 { progress(got); last = Date() }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); got += Int64(buffer.count) }
        try handle.close()
        try fm.moveItem(at: partial, to: dest)
        progress(got)
    }

    /// 下载一个文件 (已经完整下过的跳过), 支持断点续传
    nonisolated static func fetch(repo: String, path: String, to dest: URL, expected: Int64,
                                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           (attrs[.size] as? Int64 ?? -1) == expected { progress(expected); return }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = dest.appendingPathExtension("download")
        var have: Int64 = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        if have > expected { try? FileManager.default.removeItem(at: partial); have = 0 }
        var req = URLRequest(url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")!)
        req.timeoutInterval = 120
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else { throw URLError(.badServerResponse) }
        if code == 200 { have = 0; try? FileManager.default.removeItem(at: partial) }
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var buffer = Data()
        buffer.reserveCapacity(4 << 20)
        var got = have
        var lastReport = Date()
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 4 << 20 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                got += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.5 { progress(got); lastReport = Date() }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); got += Int64(buffer.count) }
        try handle.close()
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: partial, to: dest)
        progress(got)
    }
}
