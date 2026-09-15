import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let srcUrl = root.appendingPathComponent("Assets/gen/q3-area.png")
let outDir = root.appendingPathComponent("Assets")
let iconsetDir = outDir.appendingPathComponent("AppIcon.iconset")

guard let srcImg = NSImage(contentsOf: srcUrl),
      let srcRep = srcImg.representations.first as? NSBitmapImageRep else {
    fputs("Error: Could not load source image from \(srcUrl.path)\n", stderr)
    exit(1)
}

let W = srcRep.pixelsWide
let H = srcRep.pixelsHigh
guard let srcData = srcRep.bitmapData else {
    fputs("Error: Could not access source bitmap data\n", stderr)
    exit(1)
}

let bpr = srcRep.bytesPerRow
let spp = srcRep.samplesPerPixel

// Fast flood fill to find white background pixels
var isBg = [Bool](repeating: false, count: W * H)
var queue = [Int]()
queue.reserveCapacity(W * H / 3)

func isWhitePixel(_ x: Int, _ y: Int) -> Bool {
    let offset = y * bpr + x * (srcRep.bitsPerPixel / 8)
    let r = srcData[offset]
    let g = srcData[offset + 1]
    let b = srcData[offset + 2]
    return r > 245 && g > 245 && b > 245
}

func tryAdd(_ x: Int, _ y: Int) {
    let idx = y * W + x
    if !isBg[idx] && isWhitePixel(x, y) {
        isBg[idx] = true
        queue.append(idx)
    }
}

// Seed corners and edges
for x in 0..<W {
    tryAdd(x, 0)
    tryAdd(x, H - 1)
}
for y in 0..<H {
    tryAdd(0, y)
    tryAdd(W - 1, y)
}

var head = 0
while head < queue.count {
    let idx = queue[head]
    head += 1
    let x = idx % W
    let y = idx / W
    
    if x > 0 { tryAdd(x - 1, y) }
    if x < W - 1 { tryAdd(x + 1, y) }
    if y > 0 { tryAdd(x, y - 1) }
    if y < H - 1 { tryAdd(x, y + 1) }
}

print("Flood fill identified \(queue.count) canvas background pixels")

// Create RGBA 2048x2048 buffer
let outRep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: W,
    pixelsHigh: H,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: W * 4,
    bitsPerPixel: 32
)!

guard let dstData = outRep.bitmapData else {
    fputs("Error: Could not access destination bitmap data\n", stderr)
    exit(1)
}

let rimR: UInt8 = 48
let rimG: UInt8 = 52
let rimB: UInt8 = 63
let rimLum: Double = 0.20

for y in 0..<H {
    let rowStart = y * W
    let dstRowOffset = y * (W * 4)
    let srcRowOffset = y * bpr
    let bpp = srcRep.bitsPerPixel / 8
    
    for x in 0..<W {
        let idx = rowStart + x
        let dstOffset = dstRowOffset + x * 4
        
        if isBg[idx] {
            dstData[dstOffset] = 0
            dstData[dstOffset + 1] = 0
            dstData[dstOffset + 2] = 0
            dstData[dstOffset + 3] = 0
        } else {
            let srcOffset = srcRowOffset + x * bpp
            let r = srcData[srcOffset]
            let g = srcData[srcOffset + 1]
            let b = srcData[srcOffset + 2]
            
            // Check boundary
            var nearBg = false
            for dy in -2...2 {
                let ny = y + dy
                if ny >= 0 && ny < H {
                    for dx in -2...2 {
                        let nx = x + dx
                        if nx >= 0 && nx < W {
                            if isBg[ny * W + nx] {
                                nearBg = true
                                break
                            }
                        }
                    }
                }
                if nearBg { break }
            }
            
            if nearBg {
                let lum = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255.0
                let alpha = max(0.0, min(1.0, (1.0 - lum) / (1.0 - rimLum)))
                if alpha <= 0.05 {
                    dstData[dstOffset] = 0
                    dstData[dstOffset + 1] = 0
                    dstData[dstOffset + 2] = 0
                    dstData[dstOffset + 3] = 0
                } else {
                    dstData[dstOffset] = rimR
                    dstData[dstOffset + 1] = rimG
                    dstData[dstOffset + 2] = rimB
                    dstData[dstOffset + 3] = UInt8(round(alpha * 255.0))
                }
            } else {
                dstData[dstOffset] = r
                dstData[dstOffset + 1] = g
                dstData[dstOffset + 2] = b
                dstData[dstOffset + 3] = 255
            }
        }
    }
}

let highResImg = NSImage(size: NSSize(width: W, height: H))
highResImg.addRepresentation(outRep)

func render(size: Int) -> NSBitmapImageRep {
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
    
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    highResImg.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                    from: .zero,
                    operation: .copy,
                    fraction: 1.0)
    
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

// Generate AppIcon-1024.png
let rep1024 = render(size: 1024)
let icon1024Url = outDir.appendingPathComponent("AppIcon-1024.png")
writePNG(rep1024, to: icon1024Url)
print("Saved \(icon1024Url.path)")

// Generate iconset
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

var cache: [Int: NSBitmapImageRep] = [1024: rep1024]
for (sz, name) in pairs {
    if cache[sz] == nil {
        cache[sz] = render(size: sz)
    }
    writePNG(cache[sz]!, to: iconsetDir.appendingPathComponent(name))
}
print("Generated all icons in \(iconsetDir.path)")

// Run iconutil
let icnsUrl = outDir.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsUrl.path]
try! proc.run()
proc.waitUntilExit()

if proc.terminationStatus == 0 {
    print("Successfully built \(icnsUrl.path)")
} else {
    fputs("Error running iconutil (status \(proc.terminationStatus))\n", stderr)
    exit(1)
}
