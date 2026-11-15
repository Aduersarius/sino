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
    private var fadeTimer: Timer?
    /// Panels left over from a fade that has not finished. They are still on screen, so anything
    /// that shows again must retire them first instead of abandoning them.
    private var fading: [NSPanel] = []
    private var lastRadius: Double = 0

    var isShowing: Bool { !panels.isEmpty }

    /// False when the window server entry point is missing, so the caller can tell the gate that no
    /// surface exists instead of pretending one does.
    @discardableResult
    func show(angle: Double, working: Double, tuning: FoldTuning) -> Bool {
        guard SkyLightBlur.isAvailable else { return false }
        guard panels.isEmpty else { return true }
        fadeOut?.cancel(); fadeOut = nil
        fadeTimer?.invalidate(); fadeTimer = nil
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
        return true
    }

    func update(angle: Double, working: Double, tuning: FoldTuning) {
        guard !panels.isEmpty else { return }
        let progress = FoldMath.progress(angle: angle, tuning: tuning)
        let radius = Self.radius(for: progress, strength: Prefs.shared.foldBlurStrength)
        lastRadius = radius
        for panel in panels { SkyLightBlur.setRadius(Int32(panel.windowNumber), radius) }
    }

    /// Retires panels whose fade was interrupted: they belong to a timer that is about to be
    /// cancelled, and without this they stay on screen forever.
    private func finishFade() {
        fadeTimer?.invalidate(); fadeTimer = nil
        fadeOut?.cancel(); fadeOut = nil
        for panel in fading {
            SkyLightBlur.setRadius(Int32(panel.windowNumber), 0)
            panel.orderOut(nil)
        }
        if !fading.isEmpty { foldLog("blur fade interrupted, retired \(fading.count) panel(s)") }
        fading = []
    }

    /// Ramps the radius down over `fade` instead of cutting it. The panels themselves must stay
    /// opaque meanwhile: fading their 1% white fill animates nothing at all.
    func hide(fade: TimeInterval = 0) {
        finishFade()
        guard !panels.isEmpty else { return }
        let items = panels
        let start = lastRadius
        panels = []
        fading = items
        let finish = DispatchWorkItem { [weak self] in
            for panel in items {
                SkyLightBlur.setRadius(Int32(panel.windowNumber), 0)
                panel.orderOut(nil)
            }
            self?.fading.removeAll { fading in items.contains { $0 === fading } }
            foldLog("blur hidden")
        }
        fadeOut = finish
        guard fade > 0, start > 0.5 else { finish.perform(); return }

        let steps = max(1, Int(fade / 0.02))
        foldLog(String(format: "blur fading from %.1f pt over %.2f s", start, fade))
        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: fade / Double(steps), repeats: true) { timer in
            step += 1
            let radius = start * (1 - Double(step) / Double(steps))
            for panel in items { SkyLightBlur.setRadius(Int32(panel.windowNumber), radius) }
            if step >= steps {
                timer.invalidate()
                finish.perform()
            }
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

    /// A dlsym miss is not a crash: it means blur mode has nothing to draw. SINO_NO_SKYLIGHT=1
    /// forces that state so the degradation path can be exercised on a machine where it exists.
    static let isAvailable: Bool = {
        if ProcessInfo.processInfo.environment["SINO_NO_SKYLIGHT"] == "1" { return false }
        return setter != nil && connection != 0
    }()

    static func setRadius(_ window: Int32, _ radius: Double) {
        guard isAvailable, let setter else { return }
        _ = setter(connection, window, Int32(radius.rounded()))
    }
}
