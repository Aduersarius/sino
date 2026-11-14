import AppKit

/// Capture-free fold: the compositor blurs the desktop behind the panel, and the blur deepens with
/// the hinge angle. No Screen Recording, no shader, no frozen frame.
///
/// A single NSVisualEffectView has a fixed radius, so depth comes from a stack: the bottom layer
/// blurs the desktop, each layer above blurs what is behind it inside the window, and the number of
/// visible layers follows the angle. The panel itself never fades — only how far the blur reaches.
final class BlurFold {
    private static let steps = 3

    private var panels: [(panel: NSPanel, layers: [NSVisualEffectView], tint: NSView)] = []
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
            // Unlike the fold, nothing here reads the screen, so the panel can stay capturable —
            // that is what lets a screenshot show the blur it applies.
            panel.sharingType = .readOnly
            panel.ignoresMouseEvents = true

            let host = NSView(frame: screen.frame)
            var layers: [NSVisualEffectView] = []
            for index in 0..<Self.steps {
                let effect = NSVisualEffectView(frame: screen.frame)
                // The first layer samples the desktop; the rest sample the blur underneath them,
                // which is what makes the stack compound instead of repeating one radius.
                effect.blendingMode = index == 0 ? .behindWindow : .withinWindow
                effect.material = .hudWindow
                effect.state = .active
                effect.autoresizingMask = [.width, .height]
                host.addSubview(effect)
                layers.append(effect)
            }

            let tint = NSView(frame: screen.frame)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.black.cgColor
            tint.autoresizingMask = [.width, .height]
            host.addSubview(tint)

            panel.contentView = host
            panel.setFrame(screen.frame, display: false)
            apply(progress: progress(angle: angle, tuning: tuning), layers: layers, tint: tint)
            panel.orderFrontRegardless()
            panels.append((panel, layers, tint))
        }
    }

    func update(angle: Double, working: Double, tuning: FoldTuning) {
        guard !panels.isEmpty else { return }
        let p = progress(angle: angle, tuning: tuning)
        for item in panels { apply(progress: p, layers: item.layers, tint: item.tint) }
    }

    /// Fades only at teardown, where the blur has already reached its deepest and the desktop is
    /// live again — a hard cut there reads as a flash.
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

    private func progress(angle: Double, tuning: FoldTuning) -> Double {
        FoldMath.progress(angle: angle, tuning: tuning)
    }

    /// Steps are cross-faded one into the next, so the blur grows continuously rather than in six
    /// visible jumps: layer i is fully on once progress passes i / steps.
    private func apply(progress: Double, layers: [NSVisualEffectView], tint: NSView) {
        let p = min(1, max(0, progress))
        for (index, layer) in layers.enumerated() {
            let scaled = p * Double(layers.count) - Double(index)
            layer.alphaValue = max(0, min(1, scaled))
        }
        tint.layer?.opacity = Float(p * 0.4)
    }
}
