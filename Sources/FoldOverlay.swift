import AppKit
import MetalKit

/// Borderless panels, one per display, that draw the fold over a captured frame.
/// Modelled on Still's DesktopOverlay: statusBar+1, joined to all spaces, capture-excluded.
final class FoldOverlay {
    private var layers: [(panel: NSPanel, surface: FoldSurfaceView)] = []
    private(set) var lastError: String?

    var isShowing: Bool { !layers.isEmpty }

    func startFrameLink(_ handler: @escaping () -> Void) {
        layers.first?.surface.startFrameLink(handler)
    }

    func stopFrameLink() {
        for layer in layers { layer.surface.stopFrameLink() }
    }

    /// Builds the shader and pipeline off the main thread so the lid gesture never pays for it.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let url = Bundle.main.url(forResource: "Fold", withExtension: "metal"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { return }
            FoldRenderer.prewarm(device: device, shaderSource: source, colorFormat: .bgra8Unorm)
        }
    }

    func show(snapshots: [(image: CGImage, screen: NSScreen)], angle: Double, tuning: FoldTuning,
              onDismiss: (() -> Void)? = nil) throws {
        hide()
        guard let url = Bundle.main.url(forResource: "Fold", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "Fold.metal is missing from the bundle."
            throw NSError(domain: "Sino", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: lastError!])
        }
        for shot in snapshots {
            let surface = FoldSurfaceView(shaderSource: source)
            if let error = surface.setupError {
                lastError = error
                throw NSError(domain: "Sino", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
            }
            let panel = NSPanel(contentRect: shot.screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            // Clear, not black: the panel is ordered front before its first drawable exists, and
            // an opaque background composites as a black frame at every handover.
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            // Excluded from capture so the fold never feeds back into its own snapshot.
            panel.sharingType = .none
            panel.ignoresMouseEvents = true
            panel.contentView = surface
            panel.setFrame(shot.screen.frame, display: false)
            surface.update(image: shot.image, angle: angle, tuning: tuning)
            // Opaque before the first composite: a fade here reads as a blink, and the snapshot
            // is pixel-identical to the desktop anyway.
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            // On-demand drawing: one frame per sensor report. The first request can still land
            // before the layer has a drawable, so retry once shortly after.
            surface.needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak surface] in
                surface?.needsDisplay = true
            }
            layers.append((panel, surface))
        }
    }

    func update(angle: Double, tuning: FoldTuning) {
        for layer in layers {
            // Opaque from the first frame: transparency would show the live desktop through the
            // frozen copy while the fold starts.
            if layer.panel.alphaValue < 1 { layer.panel.alphaValue = 1 }
            layer.surface.angle = angle
            layer.surface.tuning = tuning
            layer.surface.needsDisplay = true
        }
    }

    /// Fades the frozen frame out before removing it, so a stale or point-size last frame blends
    /// into the live desktop instead of snapping to it.
    func hide(fade: TimeInterval = 0) {
        guard fade > 0, !layers.isEmpty else { removeLayers(); return }
        let panels = layers.map(\.panel)
        layers.removeAll()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            for panel in panels { panel.animator().alphaValue = 0 }
        } completionHandler: {
            for panel in panels { panel.orderOut(nil) }
        }
    }

    private func removeLayers() {
        for layer in layers {
            layer.panel.orderOut(nil)
            layer.surface.removeFromSuperview()
        }
        layers.removeAll()
    }
}
