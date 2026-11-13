import Foundation
import AppKit

// CPU preview of the fold: the same projection as Fold.metal with a four-tap stand-in for the
// frost, so the settings card can show the angle and the blur without a Metal pass.

enum FoldRender {
    static let width = 180
    static let height = 112

    private static var cachedKey = Int.min
    private static var cached: NSImage?
    private static let desktop = makeDesktop()

    static func image(angle: Double, tuning: FoldTuning) -> NSImage {
        let key = Int((angle * 10).rounded()) ^ (Int((tuning.frost * 100).rounded()) << 16)
        if key == cachedKey, let cached { return cached }
        let t = tuning.validated
        let aspect = Double(width) / Double(height)
        var out = [UInt8](repeating: 255, count: width * height * 4)
        let fade = smoothstep(t.fadeAngle, t.fadeAngle + 12, angle)
        let easing = smoothstep(0, 7, t.workingAngle - angle)
        let blend = t.perspective * easing

        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                var color: (Double, Double, Double)
                if let (pu, pv) = FoldMath.sourceUV(u: u, v: v, angle: angle,
                                                    workingAngle: t.workingAngle, aspect: aspect) {
                    // Same as Fold.metal: mix(uv, projected, perspective * easing).
                    let su = u + (pu - u) * blend, sv = v + (pv - v) * blend
                    if su >= 0, su <= 1, sv >= 0, sv <= 1 {
                        // Four rotated taps at the shader's frost radius: enough to preview the
                        // blur slider without a Metal pass.
                        let soft = smoothstep(0, 0.5, FoldMath.progress(angle: angle, tuning: t))
                        let radius = t.frost * soft * (0.016 + 0.05 * (1 - v))
                        if radius > 0.0005 {
                            let dx = radius / aspect * 0.7, dy = radius * 0.7
                            let a = sample(su + dx, sv + dy), b = sample(su - dx, sv + dy)
                            let c = sample(su + dx, sv - dy), d = sample(su - dx, sv - dy)
                            color = ((a.0 + b.0 + c.0 + d.0) / 4,
                                     (a.1 + b.1 + c.1 + d.1) / 4,
                                     (a.2 + b.2 + c.2 + d.2) / 4)
                        } else {
                            color = sample(su, sv)
                        }
                    } else {
                        color = glassColor(angle: angle, tuning: t)
                    }
                } else {
                    color = glassColor(angle: angle, tuning: t)
                }
                let shade = 1 - t.shade * FoldMath.progress(angle: angle, tuning: t) * (0.25 + 0.60 * pow(1 - v, 2))
                let i = (y * width + x) * 4
                out[i] = UInt8(max(0, min(255, color.0 * shade * fade * 255)))
                out[i + 1] = UInt8(max(0, min(255, color.1 * shade * fade * 255)))
                out[i + 2] = UInt8(max(0, min(255, color.2 * shade * fade * 255)))
            }
        }

        cachedKey = key
        cached = nsImage(from: out)
        return cached ?? NSImage()
    }

    private static func glassColor(angle: Double, tuning: FoldTuning) -> (Double, Double, Double) {
        let glass = 1 - 0.55 * FoldMath.progress(angle: angle, tuning: tuning)
        return (0.075 * glass, 0.085 * glass, 0.11 * glass)
    }

    private static func sample(_ u: Double, _ v: Double) -> (Double, Double, Double) {
        let cu = min(1, max(0, u)), cv = min(1, max(0, v))
        let x = Int(cu * Double(width - 1)), y = Int(cv * Double(height - 1))
        let i = (y * width + x) * 4
        return (Double(desktop[i]) / 255, Double(desktop[i + 1]) / 255, Double(desktop[i + 2]) / 255)
    }

    private static func makeDesktop() -> [UInt8] {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Double(y) / Double(height), u = Double(x) / Double(width)
                var r = 0.10 + 0.16 * (1 - v), g = 0.13 + 0.18 * (1 - v), b = 0.20 + 0.26 * (1 - v)
                // A window and a few bars, so the fold has something to bend.
                if u > 0.12, u < 0.72, v > 0.18, v < 0.78 {
                    r = 0.20; g = 0.22; b = 0.27
                    if v < 0.27 { r = 0.30; g = 0.32; b = 0.38 }
                    if v > 0.34, v < 0.40, u < 0.60 { r = 0.55; g = 0.58; b = 0.64 }
                    if v > 0.46, v < 0.50, u < 0.50 { r = 0.45; g = 0.48; b = 0.56 }
                }
                if u > 0.80, v > 0.70, v < 0.88 { r = 0.85; g = 0.52; b = 0.22 }
                let i = (y * width + x) * 4
                px[i] = UInt8(r * 255); px[i + 1] = UInt8(g * 255); px[i + 2] = UInt8(b * 255)
            }
        }
        return px
    }

    private static func nsImage(from pixels: [UInt8]) -> NSImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        guard let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}
