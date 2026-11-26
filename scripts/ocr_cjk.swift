// 用 Vision 识别截图里的文字, 列出含中文的行 (检查德语/英语界面有没有漏翻译)
// 用法: ocr_cjk 图片.png ...   每行输出: 文件<TAB>识别到的中文文字
import Foundation
import Vision
import AppKit

for path in CommandLine.arguments.dropFirst() {
    guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["zh-Hans", "de-DE", "en-US"]
    req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    for o in req.results ?? [] {
        guard let t = o.topCandidates(1).first?.string else { continue }
        if t.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            let b = o.boundingBox
            print("\(URL(fileURLWithPath: path).lastPathComponent)\t\(Int(b.minX * 100)),\(Int((1 - b.maxY) * 100))%\t\(t)")
        }
    }
}
