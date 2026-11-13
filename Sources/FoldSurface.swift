import AppKit
import Metal
import MetalKit

/// Uniform block shared with Fold.metal. Eight floats; keep the order identical.
private struct FoldUniforms {
    var angle: Float
    var workingAngle: Float
    var perspective: Float
    var frost: Float
    var shade: Float
    var fadeAngle: Float
    var aspect: Float
    var padding: Float = 0
}

/// Draws the iPhone Duo fold: a full-screen triangle warped by the inverse projection in Fold.metal.
/// The shader is compiled from source at launch so the .metal file ships as a plain resource.
final class FoldRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?

    // Compiling the shader and building the pipeline costs ~100 ms; doing it once per panel at
    // lid-close time is what makes the first frames stutter. Both are cached per device+format
    // and warmed when Awake arms, so the gesture starts on an already-built pipeline.
    private static var libraryCache: [String: MTLLibrary] = [:]
    private static var pipelineCache: [String: MTLRenderPipelineState] = [:]
    private static let cacheLock = NSLock()

    static func program(device: MTLDevice, shaderSource: String,
                        colorFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = "\(ObjectIdentifier(device).hashValue)-\(colorFormat.rawValue)-\(shaderSource.hashValue)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = pipelineCache[key] { return cached }
        let library: MTLLibrary
        if let cached = libraryCache[key] {
            library = cached
        } else {
            library = try device.makeLibrary(source: shaderSource, options: nil)
            libraryCache[key] = library
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelineCache[key] = state
        return state
    }

    init(device: MTLDevice, shaderSource: String, colorFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Sino", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal command queue."])
        }
        self.queue = queue
        pipeline = try Self.program(device: device, shaderSource: shaderSource, colorFormat: colorFormat)
    }

    /// Builds the pipeline ahead of the gesture. Safe to call repeatedly and from any thread.
    static func prewarm(device: MTLDevice, shaderSource: String, colorFormat: MTLPixelFormat) {
        _ = try? program(device: device, shaderSource: shaderSource, colorFormat: colorFormat)
    }

    static func systemRenderer() throws -> FoldRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "Sino", code: 2, userInfo: [NSLocalizedDescriptionKey: "Metal is not available."])
        }
        guard let url = Bundle.main.url(forResource: "Fold", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "Sino", code: 3, userInfo: [NSLocalizedDescriptionKey: "Fold.metal is missing from the bundle."])
        }
        return try FoldRenderer(device: device, shaderSource: source)
    }

    func setImage(_ image: CGImage?) throws {
        guard let image else { texture = nil; return }
        texture = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: false, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft
        ])
    }

    /// Encodes the fold into an existing render pass. Returns false when there is nothing to draw.
    @discardableResult
    func encode(into encoder: MTLRenderCommandEncoder, angle: Double, tuning: FoldTuning) -> Bool {
        guard let texture else { return false }
        let t = tuning.validated
        var uniforms = FoldUniforms(
            angle: Float(angle),
            workingAngle: Float(t.workingAngle),
            perspective: Float(t.perspective),
            frost: Float(t.frost),
            shade: Float(t.shade),
            fadeAngle: Float(t.fadeAngle),
            aspect: Float(texture.width) / Float(texture.height)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }

    /// Render without reading the result back, so a timing measurement reflects GPU cost only.
    @discardableResult
    func renderOnly(angle: Double, tuning: FoldTuning, size: CGSize) -> Bool {
        guard texture != nil else { return false }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encode(into: encoder, angle: angle, tuning: tuning)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return true
    }

    /// Offscreen render, for previews and tests.
    func image(angle: Double, tuning: FoldTuning, size: CGSize) -> CGImage? {
        guard texture != nil, size.width >= 1, size.height >= 1 else { return nil }
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(into: encoder, angle: angle, tuning: tuning)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                  | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// MTKView wrapper that draws the fold on demand. Used once the desktop overlay lands.
final class FoldSurfaceView: MTKView {
    private var renderer: FoldRenderer?
    private var queue: MTLCommandQueue?
    private(set) var setupError: String?
    var angle: Double = 105 { didSet { applyScale(); needsDisplay = true } }
    var tuning = FoldTuning() { didSet { applyScale(); needsDisplay = true } }

    /// At rest the frame must be pixel-identical to the desktop it replaces, so the handover is
    /// invisible. Once the fold is moving, the 12-tap frost hides a point-size drawable and the
    /// per-frame cost drops ~7x.
    private var frameLink: CADisplayLink?
    private var hasMoved = false
    private var frameHandler: (() -> Void)?

    /// Backing size only while the fold is essentially unfolded — that is the frame the frozen
    /// copy is judged against, and an upscaled one reads as a sharpness jump at the start and at
    /// the reveal. Once the warp and frost are doing work, point size is invisible and ~7x cheaper.
    /// The reallocation lands on a moving frame, where it is hidden, never at the endpoints.
    private func applyScale() {
        let progress = FoldMath.progress(angle: angle, tuning: tuning)
        // Sharp only on the way in. Once the fold has actually moved, the drawable stays at point
        // size for the rest of the gesture: resizing again as the lid rises was the visible jump
        // just before the raise finished. The exit is masked by fading the panel out instead.
        if progress >= 0.05 { hasMoved = true }
        let sharp = !hasMoved && progress < 0.05
        let scale = sharp ? (window?.backingScaleFactor ?? 2) : 1
        let target = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard target.width >= 1, target.height >= 1, drawableSize != target else { return }
        // A resized CAMetalLayer hands back fresh, undrawn buffers; if the panel is on screen the
        // compositor can present one and flash. Hide it for a frame — at this progress the content
        // is within a few degrees of the desktop, so the gap is invisible.
        let visible = window?.alphaValue ?? 0
        if visible > 0 { window?.alphaValue = 0 }
        drawableSize = target
        needsDisplay = true
        if visible > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.window?.alphaValue = visible
            }
        }
    }

    init(shaderSource: String) {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        // The frost is a 12-tap blur: at 2x Retina it costs ~14 ms a frame, at 1x ~2 ms.
        // Rendering the drawable at point size keeps 60 fps and is invisible under the blur.
        autoResizeDrawable = false
        do {
            guard let device else {
                throw NSError(domain: "Sino", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is not available."])
            }
            renderer = try FoldRenderer(device: device, shaderSource: shaderSource, colorFormat: colorPixelFormat)
            queue = device.makeCommandQueue()
        } catch {
            setupError = error.localizedDescription
        }
    }

    required init(coder: NSCoder) { fatalError("Use init(shaderSource:)") }

    func update(image: CGImage?, angle: Double, tuning: FoldTuning) {
        self.angle = angle
        self.tuning = tuning
        try? renderer?.setImage(image)
        needsDisplay = true
    }

    /// Vsync-locked frame source: no timer coalescing, and it stops when the display does.
    func startFrameLink(_ handler: @escaping () -> Void) {
        stopFrameLink()
        frameHandler = handler
        let link = displayLink(target: self, selector: #selector(frameLinkFired))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    func stopFrameLink() {
        frameLink?.invalidate()
        frameLink = nil
        frameHandler = nil
    }

    @objc private func frameLinkFired() { frameHandler?() }

    override func layout() {
        super.layout()
        applyScale()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderer, let queue, let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        renderer.encode(into: encoder, angle: angle, tuning: tuning)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
