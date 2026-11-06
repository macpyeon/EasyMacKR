// 맥편해 앱 아이콘을 그린다. 실행: swift scripts/make-icon.swift Resources/AppIcon.icns
// 디자인: 남색→파란색 바탕 위 흰 키캡, 그 위에 '편'.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // 바탕: macOS 아이콘 격자(824pt 정사각형, 모서리 185pt)
    let base = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let basePath = NSBezierPath(roundedRect: base, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.36, alpha: 1).setFill()
    basePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.95, alpha: 1),
    ])!.draw(in: basePath, angle: 70)

    // 키캡 아랫면(두께감)
    let cap = NSRect(x: 252 * s, y: 236 * s, width: 520 * s, height: 520 * s)
    let side = NSBezierPath(roundedRect: cap.offsetBy(dx: 0, dy: -34 * s), xRadius: 110 * s, yRadius: 110 * s)
    NSColor(calibratedRed: 0.72, green: 0.77, blue: 0.90, alpha: 1).setFill()
    side.fill()
    // 키캡 윗면
    let top = NSBezierPath(roundedRect: cap, xRadius: 110 * s, yRadius: 110 * s)
    NSGradient(colors: [NSColor.white, NSColor(calibratedRed: 0.93, green: 0.95, blue: 1.0, alpha: 1)])!.draw(in: top, angle: -90)

    // '편'
    let font = NSFont.systemFont(ofSize: 330 * s, weight: .heavy)
    let text = NSAttributedString(string: "편", attributes: [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.14, green: 0.22, blue: 0.58, alpha: 1),
    ])
    let bounds = text.boundingRect(with: NSSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin])
    text.draw(at: NSPoint(x: cap.midX - bounds.width / 2, y: cap.midY - bounds.height / 2 + 6 * s))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "MacPyeon-\(UUID().uuidString).iconset"
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: px).representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: iconset + "/" + name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", output]
try! p.run()
p.waitUntilExit()
// 미리보기용 PNG도 남긴다.
try! drawIcon(size: 512).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "docs/icon-preview.png"))
try? fm.removeItem(atPath: iconset)
print(p.terminationStatus == 0 ? "✓ \(output)" : "✗ iconutil 실패")
