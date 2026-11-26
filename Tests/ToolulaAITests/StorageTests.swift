import XCTest
@testable import ToolulaAI

final class StorageTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toolula-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func files(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    func sample(_ n: Int) -> [Conversation] {
        (0..<n).map { i in
            var c = Conversation(model: "m")
            c.title = "对话\(i)"
            c.messages = [ChatMessage(role: "user", text: "问题\(i)"), ChatMessage(role: "assistant", text: "回答\(i)")]
            return c
        }
    }

    // MARK: 迁移

    func testMigratesLegacyFileWithBackupAndKeepsOrder() throws {
        let list = sample(3)
        try JSONEncoder().encode(list).write(to: root.appendingPathComponent("conversations.json"))
        let st = ConversationStorage(root: root)
        let loaded = st.load()
        XCTAssertEqual(loaded.map(\.id), list.map(\.id))
        XCTAssertEqual(loaded.map(\.messages), list.map(\.messages))
        // 原文件: 备份一份, 改名保留, 不删
        XCTAssertTrue(files(st.backups).contains { $0.hasPrefix("conversations-legacy-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations.json").path))
        XCTAssertTrue(files(root).contains { $0.hasPrefix("conversations.json.migrated-") })
        XCTAssertEqual(files(st.dir).filter { $0 != "index.json" }.count, 3)
        // 再读一次结果一样
        XCTAssertEqual(ConversationStorage(root: root).load().map(\.id), list.map(\.id))
    }

    func testCorruptLegacyFileIsLeftUntouched() throws {
        let legacy = root.appendingPathComponent("conversations.json")
        try Data("{broken".utf8).write(to: legacy)
        let st = ConversationStorage(root: root)
        XCTAssertEqual(st.load().count, 0)
        XCTAssertEqual(try Data(contentsOf: legacy), Data("{broken".utf8), "读不出来的旧文件不能被改动")
        XCTAssertTrue(files(st.backups).contains { $0.hasPrefix("conversations-legacy-") })
    }

    // MARK: 只写改动过的

    func testSaveOnlyWritesChangedConversations() throws {
        let st = ConversationStorage(root: root)
        var list = sample(3)
        _ = st.load()
        st.save(list, sync: true)
        let f0 = st.file(list[0].id), f1 = st.file(list[1].id)
        // 把文件时间改旧, 看哪个被重写
        let old = Date(timeIntervalSince1970: 1_000_000)
        for f in [f0, f1] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path) }
        list[1].messages.append(ChatMessage(role: "user", text: "新消息"))
        st.save(list, sync: true)
        let m0 = try FileManager.default.attributesOfItem(atPath: f0.path)[.modificationDate] as! Date
        let m1 = try FileManager.default.attributesOfItem(atPath: f1.path)[.modificationDate] as! Date
        XCTAssertEqual(m0, old, "没改的对话不应重写")
        XCTAssertGreaterThan(m1, old)
        // 删除: 文件也删掉
        let removed = list.removeFirst()
        st.save(list, sync: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: st.file(removed.id).path))
        XCTAssertEqual(ConversationStorage(root: root).load().map(\.id), list.map(\.id))
    }

    func testCorruptConversationFileIsMovedAside() throws {
        let st = ConversationStorage(root: root)
        let list = sample(2)
        _ = st.load()
        st.save(list, sync: true)
        try Data("garbage".utf8).write(to: st.file(list[0].id))
        let loaded = ConversationStorage(root: root).load()
        XCTAssertEqual(loaded.map(\.id), [list[1].id])
        XCTAssertEqual(files(st.dir.appendingPathComponent("corrupt")).count, 1)
    }

    func testBackupKeepsOnlyRecentCopies() throws {
        let st = ConversationStorage(root: root)
        st.keepBackups = 2
        _ = st.load()
        st.save(sample(1), sync: true)
        for _ in 0..<3 {
            // 备份名精确到秒: 手动造旧备份
            let fake = st.backups.appendingPathComponent("conversations-2000010\(Int.random(in: 1...9))-00000\(Int.random(in: 0...9))")
            try? FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        }
        XCTAssertNotNil(st.backup())
        XCTAssertEqual(st.backupList.count, 2)
        XCTAssertNil(st.backup(minInterval: 3600), "刚备份过就跳过")
    }

    // MARK: SafeJSON

    func testSafeJSONPreservesCorruptCopy() throws {
        let f = root.appendingPathComponent("memory.json")
        try Data("not json".utf8).write(to: f)
        XCTAssertNil(SafeJSON.load([String].self, from: f))
        XCTAssertTrue(files(root).contains { $0.hasPrefix("memory.corrupt-") })
        XCTAssertTrue(SafeJSON.save(["a", "b"], to: f))
        XCTAssertEqual(SafeJSON.load([String].self, from: f), ["a", "b"])
    }

    // MARK: 诊断报告的脱敏

    func testDiagnosticsSanitize() {
        let s = Diagnostics.sanitize("""
        Authorization: Bearer sk-abcdefghijklmnop1234
        api_key=hf_ABCDEFGHIJKLMNOPQRSTUV
        {"messages":[{"role":"user","content":"我的秘密问题"}],"prompt":"私密"}
        promptTokens=120 genTokens=5
        """)
        XCTAssertFalse(s.contains("sk-abcdefghijklmnop1234"))
        XCTAssertFalse(s.contains("hf_ABCDEFGHIJKLMNOPQRSTUV"))
        XCTAssertFalse(s.contains("我的秘密问题"))
        XCTAssertFalse(s.contains("私密"))
        XCTAssertTrue(s.contains("promptTokens=120"))
        XCTAssertFalse(s.contains(NSHomeDirectory() + "/"))
    }
}
