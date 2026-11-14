import AppKit

/// Capture-free fold: the frost sweeps down the screen as the lid closes.
///
/// Every public `NSVisualEffectView` material is already heavily blurred and its radius cannot be
/// changed; masking a layer does not clip a behind-window backdrop either (measured: the whole
/// screen fogged at once). Area is the only lever that works — each screen band is its own window,
/// so the compositor blurs only the bands that have been revealed.
final class BlurFold {
    private static let bands = 6

    private struct Screen {
        let panels: [(panel: NSPanel, tint: NSView)]
    }

    private var screens: [Screen] = []
    private var fadeOut: DispatchWorkItem?

    var isShowing: Bool { !screens.isEmpty }

    func show(angle: Double, working: Double, tuning: FoldTuning) {
        guard screens.isEmpty else { return }
        fadeOut?.cancel(); fadeOut = nil
        for screen in NSScreen.screens {
            let bandHeight = screen.frame.height / CGFloat(Self.bands)
            var panels: [(NSPanel, NSView)] = []
            for index in 0..<Self.bands {
                // Index 0 is the top band: it is the one nearest the hinge.
                let rect = NSRect(x: screen.frame.minX,
                                  y: screen.frame.maxY - CGFloat(index + 1) * bandHeight,
                                  width: screen.frame.width,
                                  height: bandHeight)
                let panel = NSPanel(contentRect: rect,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                // Nothing here reads the screen, so the panels can stay capturable.
                panel.sharingType = .readOnly
                panel.ignoresMouseEvents = true

                let host = NSView(frame: NSRect(origin: .zero, size: rect.size))
                let effect = NSVisualEffectView(frame: host.bounds)
                effect.material = .hudWindow
                effect.blendingMode = .behindWindow
                // Sino is an accessory app and is never frontmost; without this the view renders
                // its material without sampling the desktop.
                effect.state = .active
                effect.autoresizingMask = [.width, .height]
                host.addSubview(effect)

                let tint = NSView(frame: host.bounds)
                tint.wantsLayer = true
                tint.layer?.backgroundColor = NSColor.black.cgColor
                tint.autoresizingMask = [.width, .height]
                host.addSubview(tint)

                panel.contentView = host
                panel.setFrame(rect, display: false)
                panels.append((panel, tint))
            }
            screens.append(Screen(panels: panels))
        }
        update(angle: angle, working: working, tuning: tuning)
    }

    func update(angle: Double, working: Double, tuning: FoldTuning) {
        guard !screens.isEmpty else { return }
        let p = FoldMath.progress(angle: angle, tuning: tuning)
        let eased = p * p * (3 - 2 * p)
        // A band is revealed once the wave has passed its upper edge, plus a soft trailing band so
        // the boundary reads as the lid moving rather than a wipe.
        let wave = eased * Double(Self.bands + 1)
        for screen in screens {
            for (index, item) in screen.panels.enumerated() {
                let revealed = wave - Double(index)
                if revealed > 0 {
                    if item.panel.isVisible == false { item.panel.orderFrontRegardless() }
                    item.tint.layer?.opacity = Float(min(1, revealed / 1.5) * 0.12 * p)
                } else if item.panel.isVisible {
                    item.panel.orderOut(nil)
                }
            }
        }
    }

    /// Fades only at teardown, where the frost has already covered the screen and the desktop is
    /// live again — a hard cut there reads as a flash.
    func hide(fade: TimeInterval = 0) {
        guard !screens.isEmpty else { return }
        let all = screens.flatMap(\.panels).map(\.panel)
        screens = []
        let finish = DispatchWorkItem {
            for panel in all { panel.orderOut(nil) }
        }
        fadeOut = finish
        guard fade > 0 else { finish.perform(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            for panel in all { panel.animator().alphaValue = 0 }
        } completionHandler: {
            finish.perform()
        }
    }
}
