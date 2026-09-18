// Claude.app 아이콘에 전환 배지를 합성해 AppIcon.icns를 만든다.
// 사용법: swift scripts/make-icon.swift <원본 icns> <출력 icns>
// 원본 아이콘은 저장소에 포함하지 않고 로컬에 설치된 Claude.app에서 읽는다.
import AppKit
import Foundation

func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "make-icon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: arguments.joined(separator: " ")]) }
}

func badge(size: CGFloat, symbolPoint: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // 그림자 + 크림색 원 + 테라코타 화살표
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.06
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.03)
    shadow.set()
    NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1).setFill()
    NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.06, dy: size * 0.06)).fill()
    NSShadow().set()
    let configuration = NSImage.SymbolConfiguration(pointSize: symbolPoint, weight: .bold)
    guard let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
        image.unlockFocus()
        return image
    }
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let symbolRect = NSRect(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
    tinted.draw(in: symbolRect)
    image.unlockFocus()
    return image
}

func compose(base: NSImage, canvas: CGFloat) -> NSImage {
    let output = NSImage(size: NSSize(width: canvas, height: canvas))
    output.lockFocus()
    base.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), from: .zero, operation: .sourceOver, fraction: 1)
    let badgeSize = canvas * 0.40
    let badgeImage = badge(size: badgeSize, symbolPoint: badgeSize * 0.42)
    // 원본 아이콘의 둥근 사각형은 캔버스의 약 10~90% 영역이므로 오른쪽 아래 모서리에 걸치게 둔다.
    badgeImage.draw(in: NSRect(x: canvas * 0.60, y: canvas * 0.04, width: badgeSize, height: badgeSize), from: .zero, operation: .sourceOver, fraction: 1)
    output.unlockFocus()
    return output
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    representation.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try representation.representation(using: .png, properties: [:])?.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("사용법: swift scripts/make-icon.swift <원본 icns> <출력 icns>")
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])
let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-switch-icon-\(UUID().uuidString)")
let extracted = temp.appendingPathComponent("source.iconset")
let iconset = temp.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try run(["iconutil", "-c", "iconset", source.path, "-o", extracted.path])
guard let base = NSImage(contentsOf: extracted.appendingPathComponent("icon_512x512@2x.png")) else {
    print("원본 1024px 이미지를 찾을 수 없습니다")
    exit(1)
}
let composed = compose(base: base, canvas: 1024)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, pixels) in sizes {
    try writePNG(composed, pixels: pixels, to: iconset.appendingPathComponent("icon_\(name).png"))
}
try run(["iconutil", "-c", "icns", iconset.path, "-o", destination.path])
try writePNG(composed, pixels: 512, to: destination.deletingLastPathComponent().appendingPathComponent("AppIcon-preview.png"))
try? FileManager.default.removeItem(at: temp)
print("생성: \(destination.path)")
