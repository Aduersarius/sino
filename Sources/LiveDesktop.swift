import AppKit
import ScreenCaptureKit
import CoreMedia

/// Short-lived ScreenCaptureKit stream over the built-in display, kept only while the lid is
/// moving. Its newest frame is the identity frame, so the fold starts on a current picture
/// instead of paying 80–170 ms for a one-shot capture at the threshold.
final class LiveDesktop: NSObject {
    static let shared = LiveDesktop()

    private var stream: SCStream?
    private var latestBuffer: CVPixelBuffer?
    private var latestAt = Date.distantPast
    private var starting = false
    private let queue = DispatchQueue(label: "com.lov3u.sino.live")
    private let context = CIContext(options: [.cacheIntermediates: false])

    private override init() { super.init() }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil, !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 })
                else { return }
                let own = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingWindows: own)
                let config = SCStreamConfiguration()
                // Backing size: the identity frame is what the frozen copy is compared against,
                // and a point-size one upscales into a visible sharpness jump at the endpoints.
                let scale = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                        == display.displayID
                }?.backingScaleFactor ?? 2
                config.width = Int(Double(display.width) * scale)
                config.height = Int(Double(display.height) * scale)
                // Low rate while armed: the frame is only needed as the identity picture at the
                // start of a fold, so 10 fps is enough and costs almost nothing. A per-gesture
                // stream lost the race with a fast close.
                config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                config.queueDepth = 3
                config.showsCursor = false
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
                foldLog("live stream started")
            } catch {
                foldLog("live stream failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        latestBuffer = nil
        Task { try? await stream.stopCapture() }
    }

    /// Newest frame, only if it is recent enough to stand in for the live desktop.
    func freshImage(maxAge: TimeInterval = 0.35) -> CGImage? {
        guard Date().timeIntervalSince(latestAt) <= maxAge, let buffer = latestBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }
}

extension LiveDesktop: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestBuffer = buffer
        latestAt = Date()
    }
}
