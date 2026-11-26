import XCTest
@testable import ToolulaAI

/// 发送到 Lightroom: 局部调整写成给插件的任务文件
final class LightroomMaskTests: XCTestCase {
    func testJobFile() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("toolula-lr-\(UUID().uuidString).ARW")
        try Data(count: 1234).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        var job = Exporter.Job(url: f, settings: ["Exposure2012": 0.2], isRaw: true, title: "", caption: "", keywords: [], stars: 0)
        job.locals = [
            LocalAdjustment(area: .face, settings: ["Exposure2012": 0.4, "Texture": -15, "Clarity2012": 0]),
            LocalAdjustment(area: .background, settings: ["Exposure2012": -0.5]),
            LocalAdjustment(area: .sky, settings: ["Exposure2012": 0]),   // 全是 0: 不要
        ]
        XCTAssertTrue(job.retouched)
        let text = try XCTUnwrap(Exporter.lightroomMaskJob(job, sent: f))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "path=" + f.path)
        XCTAssertEqual(lines[1], "name=" + f.lastPathComponent)
        XCTAssertEqual(lines[2], "size=1234")
        XCTAssertTrue(lines[3].hasPrefix("created="))
        XCTAssertEqual(Array(lines.dropFirst(4)), [
            "mask=people\tface\tlocal_Exposure=0.40\tlocal_Texture=-15",
            "mask=background\tbackground\tlocal_Exposure=-0.50",
        ])
    }

    func testNoLocalsNoJob() {
        let job = Exporter.Job(url: URL(fileURLWithPath: "/tmp/x.ARW"), settings: [:], isRaw: true, title: "", caption: "", keywords: [], stars: 0)
        XCTAssertNil(Exporter.lightroomMaskJob(job, sent: job.url))
    }

    /// 每个局部参数都要能对应到 Lightroom 的蒙版滑块, 每个区域都要有对应的 AI 蒙版
    func testMappingsComplete() {
        for p in LocalAdjustment.params { XCTAssertNotNil(Exporter.lightroomLocalParam[p.key], p.key) }
        for k in MaskKind.allCases { XCTAssertNotNil(Exporter.lightroomMaskType[k], k.rawValue) }
    }
}
