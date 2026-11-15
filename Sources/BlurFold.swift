import AppKit

/// Capture-free progressive blur.
///
/// `CGSSetWindowBackgroundBlurRadius` makes the window server blur whatever is *behind* the window
/// by a given radius, so no pixels are read and no permission is needed. Measured on this Mac:
/// radius 0 → 3.68 sharpness, 1 → 2.84, 2 → 1.76, 4 → 0.75, 8 → 0.37, 30 → 0.09, with mean
/// brightness unchanged — a real blur, not a dimming sheet.
///
/// The panel needs a nearly invisible fill: a fully transparent window is culled and gets no
/// backdrop, which is why earlier radius tests measured nothing.
final class BlurFold {
    private var panels: [NSPanel] = []
    private var fadeOut: DispatchWorkItem?

    var isShowing: Bool { !panels.isEmpty }

    func show(angle: Double, working: Double, tuning: FoldTuning) {
        guard panels.isEmpty else { return }
        fadeOut?.cancel(); fadeOut = nil
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.sharingType = .readOnly
            panel.ignoresMouseEvents = true

            let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            host.wantsLayer = true
            // 1% white: enough that the window is not culled, invisible to the eye.
            host.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.01).cgColor
            panel.contentView = host
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        update(angle: angle, working: working, tuning: tuning)
    }

    func update(angle: Double, working: Double, tuning: FoldTuning) {
        guard !panels.isEmpty else { return }
        let progress = FoldMath.progress(angle: angle, tuning: tuning)
        let radius = Self.radius(for: progress, strength: Prefs.shared.foldBlurStrength)
        for panel in panels { SkyLightBlur.setRadius(Int32(panel.windowNumber), radius) }
    }

    func hide(fade: TimeInterval = 0) {
        guard !panels.isEmpty else { return }
        let items = panels
        panels = []
        for panel in items { SkyLightBlur.setRadius(Int32(panel.windowNumber), 0) }
        let finish = DispatchWorkItem {
            for panel in items { panel.orderOut(nil) }
        }
        fadeOut = finish
        guard fade > 0 else { finish.perform(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            for panel in items { panel.animator().alphaValue = 0 }
        } completionHandler: {
            finish.perform()
        }
    }

    /// Measured: detail is already gone by 8 pt, so the strength cap lives in 2…30 and the curve is
    /// p^1.3 — a quadratic spent most of the gesture below 1 pt, which read as "nothing, then all".
    static func radius(for progress: Double, strength: Double) -> Double {
        let p = min(1, max(0, progress))
        let cap = 2 + 28 * min(1, max(0, strength))
        return cap * pow(p, 1.3)
    }
}

/// Thin wrapper over the private entry point, resolved once. Absent symbol = no effect on screen,
/// which is logged rather than silently ignored.
enum SkyLightBlur {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let setter: SetFn? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW),
              let set = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return unsafeBitCast(set, to: SetFn.self)
    }()

    private static let connection: Int32 = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW),
              let sym = dlsym(handle, "SLSMainConnectionID") else { return 0 }
        return unsafeBitCast(sym, to: ConnFn.self)()
    }()

    static func setRadius(_ window: Int32, _ radius: Double) {
        guard let setter, connection != 0 else {
            foldLog("skylight: window blur unavailable, no effect")
            return
        }
        _ = setter(connection, window, Int32(radius.rounded()))
    }
}
