import AppKit

/// Capture-based progressive blur: the frozen desktop blurs deeper as the lid closes.
///
/// Measured on this Mac: a layer with a `CIGaussianBlur` filter changes sharpness from 3.94 at
/// radius 0 to 0.12 at 20 and 0.07 at 60, so radius is a real control here — unlike
/// `NSVisualEffectView`, whose material ships one fixed radius whatever you do to it.
final class BlurFold {
    private var panels: [(panel: NSPanel, host: NSView)] = []
    private var fadeOut: DispatchWorkItem?

    var isShowing: Bool { !panels.isEmpty }

    func show(shots: [(image: CGImage, screen: NSScreen)], angle: Double, tuning: FoldTuning) {
        hide()
        for shot in shots {
            let panel = NSPanel(contentRect: shot.screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            // Capturable so the effect can be verified; the live stream is stopped before the
            // panel appears, so it can never feed its own blur back in.
            panel.sharingType = .readOnly
            panel.ignoresMouseEvents = true

            let host = NSView(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
            host.wantsLayer = true
            host.layerUsesCoreImageFilters = true
            host.layer?.contentsGravity = .resize
            host.layer?.contents = shot.image
            if let filter = CIFilter(name: "CIGaussianBlur") {
                filter.setValue(0, forKey: kCIInputRadiusKey)
                host.layer?.filters = [filter]
            }
            panel.contentView = host
            panel.setFrame(shot.screen.frame, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.orderFrontRegardless()
            foldLog("blur panel \(panel.windowNumber) on \(Int(shot.screen.frame.width))x\(Int(shot.screen.frame.height)) visible \(panel.isVisible)")
            panels.append((panel, host))
        }
        update(angle: angle, tuning: tuning)
    }

    func update(angle: Double, tuning: FoldTuning) {
        guard !panels.isEmpty else { return }
        let progress = FoldMath.progress(angle: angle, tuning: tuning)
        let radius = Self.radius(for: progress)
        for item in panels {
            // CALayer copies whatever filter it is given, so mutating a stored instance changes
            // nothing on screen — each update has to install a fresh filter.
            guard let filter = CIFilter(name: "CIGaussianBlur") else { continue }
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            item.host.layer?.filters = [filter]
            item.host.layer?.setNeedsDisplay()
        }
    }

    func hide(fade: TimeInterval = 0) {
        guard !panels.isEmpty else { return }
        let items = panels
        panels = []
        let finish = DispatchWorkItem {
            for item in items { item.panel.orderOut(nil) }
        }
        fadeOut = finish
        guard fade > 0 else { finish.perform(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            for item in items { item.panel.animator().alphaValue = 0 }
        } completionHandler: {
            finish.perform()
        }
    }

    /// 22 pt at full progress: past that the desktop is unreadable, which is the point of the
    /// effect but wastes GPU time on a radius nobody can tell apart.
    static func radius(for progress: Double) -> Double {
        let p = min(1, max(0, progress))
        let eased = p * p * (3 - 2 * p)
        return 22 * eased
    }
}
