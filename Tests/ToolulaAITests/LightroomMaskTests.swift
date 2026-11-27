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
            "mask=people:2\tface\tlocal_Exposure=0.40\tlocal_Texture=-15",
            "mask=background\tbackground\tlocal_Exposure=-0.50",
        ])
    }

    /// 人像精修里 Lightroom 能表达的部分 (磨皮、眼睛、牙齿、嘴唇) 也变成人物蒙版的部位
    func testPortraitRetouchJob() throws {
        var job = Exporter.Job(url: URL(fileURLWithPath: "/tmp/x.ARW"), settings: [:], isRaw: true, title: "", caption: "", keywords: [], stars: 0)
        job.portrait["smooth"] = 40
        job.portrait["eyes"] = 50
        job.portrait["blemish"] = 70        // 像素级: 不进任务文件
        XCTAssertTrue(job.portrait.hasPixelOnly)
        let text = try XCTUnwrap(Exporter.lightroomMaskJob(job, sent: job.url))
        let masks = text.split(separator: "\n").filter { $0.hasPrefix("mask=") }.map(String.init)
        XCTAssertEqual(masks, [
            "mask=people:2\tskin\tlocal_Clarity=-5\tlocal_Texture=-18",
            "mask=people:8\teyes\tlocal_Exposure=0.15\tlocal_Saturation=-15",
            "mask=people:3\teyes\tlocal_Clarity=18\tlocal_Exposure=0.07",
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

/// 和 Lightroom 对齐的渲染校准
final class LightroomMatchTests: XCTestCase {
    func testVignetteShapeMatchesLightroom() {
        // Lightroom -50 实测: 中间不变, 半径 0.65 处约 0.48, 四角约 0.12
        XCTAssertEqual(Renderer.vignetteFactor(r: 0.1, amount: -50), 1, accuracy: 1e-9)
        XCTAssertEqual(Renderer.vignetteFactor(r: 0.65, amount: -50), 0.48, accuracy: 0.06)
        XCTAssertEqual(Renderer.vignetteFactor(r: 0.95, amount: -50), 0.12, accuracy: 0.03)
        // 强度按档: -100 比 -50 暗得多, -25 比 -50 亮; 正值变亮
        XCTAssertLessThan(Renderer.vignetteFactor(r: 0.95, amount: -100), Renderer.vignetteFactor(r: 0.95, amount: -50))
        XCTAssertGreaterThan(Renderer.vignetteFactor(r: 0.95, amount: -25), Renderer.vignetteFactor(r: 0.95, amount: -50))
        XCTAssertGreaterThan(Renderer.vignetteFactor(r: 0.95, amount: 50), 1)
        XCTAssertEqual(Renderer.vignetteFactor(r: 0.95, amount: 0), 1, accuracy: 1e-9)
    }

    func testSliderCalibration() {
        let m = SliderCalibration.map(["Contrast2012": 50, "Exposure2012": -1, "Saturation": -20, "SplitToningHighlightHue": 45])
        XCTAssertEqual(m["Contrast2012"]!, 70, accuracy: 1e-9)
        XCTAssertEqual(m["Exposure2012"]!, -1.2, accuracy: 1e-9)
        XCTAssertEqual(m["Saturation"]!, -20, accuracy: 1e-9)          // 没校准的不变
        XCTAssertEqual(m["SplitToningHighlightHue"]!, 45, accuracy: 1e-9) // 色相不缩放
    }

    func testPortraitRetouchValues() {
        var p = PortraitRetouch()
        XCTAssertTrue(p.isEmpty)
        p["smooth"] = 150          // 限制在 0~100
        XCTAssertEqual(p["smooth"], 100)
        p["smooth"] = 0            // 0 = 不做 (不留在字典里)
        XCTAssertTrue(p.isEmpty)
        XCTAssertNil(p.values["smooth"])
        p["eyes"] = 20
        XCTAssertFalse(p.hasPixelOnly)
        p["sculpt"] = 10
        XCTAssertTrue(p.hasPixelOnly)
    }

    func testRawLookDefaults() {
        let l = Renderer.RawLook.lightroom
        XCTAssertEqual(l.saturation, 0.815, accuracy: 1e-9)
        XCTAssertEqual(l.noiseReduction, 0, accuracy: 1e-9)
    }
}
