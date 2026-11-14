import AppKit

/// Capture-free fold: the compositor blurs the desktop behind the panel, and the strength follows
/// the hinge angle. No Screen Recording, no shader, no frozen frame — the live desktop stays live,
/// it just loses focus as the lid comes down.
final class BlurFold {
    private var panels: [(panel: NSPanel, effect: NSVisualEffectView, tint: NSView)] = []
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
            panel.sharingType = .none
            panel.ignoresMouseEvents = true

            let effect = NSVisualEffectView(frame: screen.frame)
            effect.blendingMode = .behindWindow
            effect.material = .fullScreenUI
            effect.state = .active
            effect.autoresizingMask = [.width, .height]

            let tint = NSView(frame: screen.frame)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.black.cgColor
            tint.autoresizingMask = [.width, .height]

            let host = NSView(frame: screen.frame)
            host.addSubview(effect)
            host.addSubview(tint)
            panel.contentView = host
            panel.setFrame(screen.frame, display: false)
            apply(progress: progress(angle: angle, working: working, tuning: tuning),
                  effect: effect, tint: tint)
            panel.orderFrontRegardless()
            panels.append((panel, effect, tint))
        }
    }

    func update(angle: Double, working: Double, tuning: FoldTuning) {
        guard !panels.isEmpty else { return }
        let p = progress(angle: angle, working: working, tuning: tuning)
        for item in panels { apply(progress: p, effect: item.effect, tint: item.tint) }
    }

    /// Fades out so the panel never snaps off a blurred desktop.
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

    private func progress(angle: Double, working: Double, tuning: FoldTuning) -> Double {
        FoldMath.progress(angle: angle, tuning: tuning)
    }

    /// Frost arrives with the first few degrees and saturates quickly — a lid that has moved past
    /// half its travel has already lost the desktop behind it.
    private func apply(progress: Double, effect: NSVisualEffectView, tint: NSView) {
        let p = min(1, max(0, progress * 1.6))
        effect.alphaValue = p
        tint.layer?.opacity = Float(p * 0.45)
    }
}
