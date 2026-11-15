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
        // The panel is capturable (that is what makes the blur verifiable), so the live stream
        // must not keep sampling it — a frame with the panel in it would feed the next gesture.
        LiveDesktop.shared.stop()
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
            // The frame is captured at backing size; without this the layer would scale it to
            // point size and every radius would look soft, including zero.
            host.layer?.contentsScale = shot.screen.backingScaleFactor
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
        let radius = Self.radius(for: progress, strength: Prefs.shared.foldBlurStrength)
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
        if LidFold.shared.isArmed, DesktopCapture.hasBuiltInDisplay {
            LiveDesktop.shared.start()
        }
        guard fade > 0 else { finish.perform(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            for item in items { item.panel.animator().alphaValue = 0 }
        } completionHandler: {
            finish.perform()
        }
    }

    /// Measured on this Mac, sharpness stops falling past roughly 10-12 pt: a 22 pt cap spent the
    /// second half of the gesture on a radius nobody can see.
    static func radius(for progress: Double, strength: Double) -> Double {
        let p = min(1, max(0, progress))
        // Measured radius→sharpness on this Mac: 0 -> 3.9, 0.5 -> 1.8, 1 -> 1.2, 2 -> 0.6, 4 -> 0.4.
        // Detail dies in the first point or two, so the ramp has to live there: a quadratic that
        // spends most of the gesture under 1 pt. Strength sets the cap, 1.5 to 6 pt.
        let cap = 1.5 + 4.5 * min(1, max(0, strength))
        return cap * p * p
    }
}
