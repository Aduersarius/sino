#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #file).deletingLastPathComponent()
let outDir = root

func squircle(in rect: CGRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 360
    let cx = rect.midX, cy = rect.midY
    let rx = rect.width / 2, ry = rect.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + rx * copysign(pow(abs(c), 2 / n), c)
        let y = cy + ry * copysign(pow(abs(s), 2 / n), s)
        let p = NSPoint(x: x, y: y)
        if i == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

func drawMark(size: CGFloat, simple: Bool) {
    let s = size
    let mid: CGFloat = 0.50
    let nx = s * 0.26
    let ny = s * mid
    let nr = s * (simple ? 0.12 : 0.085)
    let lw = simple ? max(2, s * 0.09) : s * 0.048

    NSColor.white.set()

    if !simple {
        let ro = nr * 1.72
        let ri = nr * 1.28
        let ring = NSBezierPath()
        ring.appendOval(in: NSRect(x: nx - ro, y: ny - ro, width: ro * 2, height: ro * 2))
        ring.appendOval(in: NSRect(x: nx - ri, y: ny - ri, width: ri * 2, height: ri * 2))
        ring.windingRule = .evenOdd
        ring.fill()
    }
    NSBezierPath(ovalIn: NSRect(x: nx - nr, y: ny - nr, width: nr * 2, height: nr * 2)).fill()

    let x0 = nx + (simple ? nr : nr * 1.72) - lw * 0.2
    let x1 = s * 0.88
    let amp = s * 0.17
    let n = simple ? 24 : 100
    let wave = NSBezierPath()
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let p = NSPoint(x: x0 + (x1 - x0) * t, y: ny - amp * sin(2 * .pi * t))
        if i == 0 { wave.move(to: p) } else { wave.line(to: p) }
    }
    wave.lineJoinStyle = .round
    wave.lineCapStyle = .round
    wave.lineWidth = lw
    wave.stroke()
}

func render(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: s)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: s, height: s).fill()

    let inset = s * 0.04
    let plate = squircle(in: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset))
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 28 / 255, green: 38 / 255, blue: 56 / 255, alpha: 1),
        NSColor(calibratedRed: 8 / 255, green: 10 / 255, blue: 16 / 255, alpha: 1),
    ])!
    grad.draw(in: plate, angle: -90)

    drawMark(size: s, simple: size <= 32)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let pairs: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
var cache: [Int: NSBitmapImageRep] = [:]
for (sz, name) in pairs {
    if cache[sz] == nil { cache[sz] = render(size: sz) }
    writePNG(cache[sz]!, to: iconset.appendingPathComponent(name))
}
writePNG(cache[1024]!, to: outDir.appendingPathComponent("AppIcon-1024.png"))
fputs("wrote \(iconset.path)\n", stderr)
