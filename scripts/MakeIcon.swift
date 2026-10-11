// Draws the Nab app icon at every .iconset size and builds Resources/AppIcon.icns.
// Usage: swift scripts/MakeIcon.swift <out-dir>   (writes <out-dir>/AppIcon.iconset, then runs iconutil)
// Optional: NAB_ICON_PREVIEW=<path.png> also writes a 512 px preview.
import AppKit
import CoreGraphics
import Foundation

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Continuous-corner rounded rect (corner curve spans 1.2x the radius along each edge).
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k = radius * 1.2
    let f: CGFloat = 0.4
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + k, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
    p.addCurve(
        to: CGPoint(x: r.maxX, y: r.minY + k), control1: CGPoint(x: r.maxX - k * f, y: r.minY),
        control2: CGPoint(x: r.maxX, y: r.minY + k * f))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
    p.addCurve(
        to: CGPoint(x: r.maxX - k, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - k * f),
        control2: CGPoint(x: r.maxX - k * f, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
    p.addCurve(
        to: CGPoint(x: r.minX, y: r.maxY - k), control1: CGPoint(x: r.minX + k * f, y: r.maxY),
        control2: CGPoint(x: r.minX, y: r.maxY - k * f))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
    p.addCurve(
        to: CGPoint(x: r.minX + k, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + k * f),
        control2: CGPoint(x: r.minX + k * f, y: r.minY))
    p.closeSubpath()
    return p
}

func render(px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: s, y: s)  // work in 1024 space, y up

    let body = squircle(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: rgb(0x000000, 0.30))
    ctx.setFillColor(rgb(0x121417))
    ctx.addPath(body)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x2B2E34), rgb(0x121417)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    // 2 px inner rim
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
    ctx.setLineWidth(4)
    ctx.addPath(body)
    ctx.strokePath()
    ctx.restoreGState()

    // Viewfinder glyph: its 18x18 box scaled to 500x500, centered
    let g: CGFloat = 500 / 18
    ctx.saveGState()
    ctx.translateBy(x: 262, y: 262)
    ctx.scaleBy(x: g, y: g)
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0xE0622A))
    ctx.move(to: CGPoint(x: 3, y: 10.5))
    ctx.addLine(to: CGPoint(x: 3, y: 15))
    ctx.addLine(to: CGPoint(x: 7.5, y: 15))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 15, y: 7.5))
    ctx.addLine(to: CGPoint(x: 15, y: 3))
    ctx.addLine(to: CGPoint(x: 10.5, y: 3))
    ctx.strokePath()
    ctx.setFillColor(rgb(0xF3F4F6))
    ctx.fillEllipse(in: CGRect(x: 6.6, y: 6.6, width: 4.8, height: 4.8))
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: swift scripts/MakeIcon.swift <out-dir>\n".utf8))
    exit(2)
}
let fm = FileManager.default
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = out.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(px: base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(px: base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let p = ProcessInfo.processInfo.environment["NAB_ICON_PREVIEW"] {
    try render(px: 512).write(to: URL(fileURLWithPath: p))
}

// Script lives in <repo>/scripts; icns goes to <repo>/Resources.
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icns = repo.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
