// 比较两张 PNG: 输出变化像素的百分比, 并生成标红的差异图
// 用法: imgdiff old.png new.png diff.png  ->  打印 "<百分比> <说明>"
import AppKit
import CoreGraphics

func load(_ p: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}
func rgba(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}
let a = CommandLine.arguments
guard a.count >= 4, let i1 = load(a[1]), let i2 = load(a[2]) else { print("-1 无法读取图片"); exit(2) }
if i1.width != i2.width || i1.height != i2.height { print("100 尺寸不同 \(i1.width)x\(i1.height) -> \(i2.width)x\(i2.height)"); exit(0) }
let w = i2.width, h = i2.height
let p1 = rgba(i1, w, h)
var p2 = rgba(i2, w, h)
var changed = 0
for i in stride(from: 0, to: p1.count, by: 4) {
    let d = max(abs(Int(p1[i]) - Int(p2[i])), abs(Int(p1[i+1]) - Int(p2[i+1])), abs(Int(p1[i+2]) - Int(p2[i+2])))
    if d > 24 {
        changed += 1
        p2[i] = 255; p2[i+1] = 0; p2[i+2] = 0; p2[i+3] = 255
    } else {
        // 没变的地方调淡, 突出变化
        p2[i] = UInt8((Int(p2[i]) + 255 * 2) / 3); p2[i+1] = UInt8((Int(p2[i+1]) + 255 * 2) / 3); p2[i+2] = UInt8((Int(p2[i+2]) + 255 * 2) / 3)
    }
}
let pct = Double(changed) * 100 / Double(w * h)
if changed > 0 {
    let ctx = CGContext(data: &p2, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let img = ctx.makeImage() {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[3]))
    }
}
print(String(format: "%.3f", pct), "\(changed) 像素变化")
