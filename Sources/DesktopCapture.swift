import AppKit
import ScreenCaptureKit

/// One ScreenCaptureKit frame per display, with Sino's own windows excluded so the overlay
/// never captures itself.
enum DesktopCapture {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// With the built-in panel asleep and an external display attached there is no hinge to
    /// follow, so the fold is suppressed rather than folding the wrong screen. Uses the online
    /// display list, not NSScreen.screens: during a close macOS can drop the internal panel from
    /// the active list, which would have made this guard refuse to fold on a normal MacBook.
    static var hasBuiltInDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
    }
    static func requestAccess() { CGRequestScreenCaptureAccess() }

    /// Warms the ScreenCaptureKit handshake while the gesture is still armed, so the first
    /// snapshot on lid close does not pay for ShareableContent enumeration.
    static func warm() {
        Task.detached(priority: .utility) {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
    }

    static func snapshots() async throws -> [(image: CGImage, screen: NSScreen)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        var result: [(CGImage, NSScreen)] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let config = SCStreamConfiguration()
            // Captured at backing size so the frozen frame is as close to the live desktop as
            // possible: the handover has to be invisible, and a 1x copy reads as a blur.
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append((image, screen))
        }
        return result
    }
}
