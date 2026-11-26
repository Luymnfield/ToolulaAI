import XCTest
@testable import ToolulaAI

/// ~/Toolula 搬家用到的几个工具函数 (搬家本身在 App 启动时跑, 用 TOOLULA_TEST_HOME 指向假主目录实测过)
final class StorageLayoutTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("toolula-layout-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func testUniqueNeverOverwrites() throws {
        XCTAssertEqual(AppPaths.unique("a_00001_.png", in: root).lastPathComponent, "a_00001_.png")
        try Data("1".utf8).write(to: root.appendingPathComponent("a_00001_.png"))
        XCTAssertEqual(AppPaths.unique("a_00001_.png", in: root).lastPathComponent, "a_00001_-2.png")
        try Data("2".utf8).write(to: root.appendingPathComponent("a_00001_-2.png"))
        XCTAssertEqual(AppPaths.unique("a_00001_.png", in: root).lastPathComponent, "a_00001_-3.png")
    }

    func testRewriteHandlesEscapedSlashes() throws {
        let f = root.appendingPathComponent("r.json")
        let old = "/Users/x/Pictures/Toolula AI/", new = "/Users/x/Toolula/Images/"
        try Data(#"{"a":"/Users/x/Pictures/Toolula AI/p.png","b":"\/Users\/x\/Pictures\/Toolula AI\/q.png","c":"/other/p.png"}"#.utf8).write(to: f)
        StorageMigration.rewrite(f, [(old, new)])
        let s = try String(contentsOf: f, encoding: .utf8)
        XCTAssertTrue(s.contains(#""a":"/Users/x/Toolula/Images/p.png""#))
        XCTAssertTrue(s.contains(#""b":"\/Users\/x\/Toolula\/Images\/q.png""#))
        XCTAssertTrue(s.contains(#""c":"/other/p.png""#))
    }

    func testMoveMergeIntoExistingFolderKeepsBoth() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: src.appendingPathComponent("x.json"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("x.json"))
        try Data("s".utf8).write(to: src.appendingPathComponent("sub/y.txt"))
        XCTAssertTrue(StorageMigration.moveMerge(src, dst))
        XCTAssertFalse(fm.fileExists(atPath: src.path))
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("x.json"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("x-2.json"), encoding: .utf8), "new")
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("sub/y.txt").path))
    }

    func testMoveMergeIntoNewFolderIsRename() throws {
        let src = root.appendingPathComponent("a"), dst = root.appendingPathComponent("deep/b")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: src.appendingPathComponent("f"))
        XCTAssertTrue(StorageMigration.moveMerge(src, dst))
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("f").path))
    }
}

/// 内存调度的小工具
final class MemoryBrokerTests: XCTestCase {
    func testTenantForModel() {
        XCTAssertNil(MemoryBroker.Tenant.forModel("cloud:abc/gpt"))
        XCTAssertEqual(MemoryBroker.Tenant.forModel("mlx:qwen3.8-27b"), .mlx)
        XCTAssertEqual(MemoryBroker.Tenant.forModel("builtin:qwen"), .builtin)
        XCTAssertEqual(MemoryBroker.Tenant.forModel("qwen/qwen3.8-27b"), .lmstudio("qwen/qwen3.8-27b"))
    }

    func testInstanceBaseId() {
        XCTAssertEqual(MemoryBroker.baseId("qwen/qwen3.8-27b:2"), "qwen/qwen3.8-27b")
        XCTAssertNil(MemoryBroker.baseId("qwen/qwen3.8-27b"))
        XCTAssertNil(MemoryBroker.baseId("model:latest"))
    }
}
