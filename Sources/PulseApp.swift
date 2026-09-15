import AppKit
import Combine
import SwiftUI

@main
enum Sino {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = App.shared
        app.run()
    }
}

final class App: NSObject, NSApplicationDelegate, ObservableObject {
    static let shared = App()
    let sampler = Sampler()
    let prefs = Prefs.shared
    @Published var theme: String = UserDefaults.standard.string(forKey: "theme") ?? "system"
    @Published var settingsPage = "general"
    @Published var panel: Panel?
    enum Panel: Equatable { case cpu, ram, storage, net, fans, battery, gpu }
    // ponytail: screen rect of each main-column card → detail Y
    var cardFrames: [Panel: NSRect] = [:]

    private var item: NSStatusItem!
    private var drop: NSPanel!
    private var host: NSHostingController<Dashboard>!
    private var detail: NSPanel!
    private var detailHost: NSHostingController<Dashboard>!
    private var extra: ExtraView!
    private var bag = Set<AnyCancellable>()
    private var hidePanel: DispatchWorkItem?
    private var clickMon: Any?
    private var barClickMon: Any?
    private var catcher: NSPanel?
    private var hoverMon: Any?
    private var settingsWC: NSWindowController?
    private var dropOpen = false
    private var ignoreClicksUntil = Date.distantPast
    private var lastDark = false
    private var appearObs: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        lastDark = currentScheme == .dark
        appearObs = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self, self.theme == "system" else { return }
            let dark = self.currentScheme == .dark
            guard dark != self.lastDark else { return }
            self.prefs.writeSlot(self.lastDark)
            self.lastDark = dark
            self.prefs.loadSlot(dark)
            self.applyStroke()
        }
        Updater.shared.start()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sino", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sino", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        extra = ExtraView(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
        // ponytail: chips live in button.image so NSStatusBarButton.highlight is visible
        barClickMon = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            guard let self, let button = self.item.button, e.window == button.window else { return e }
            let p = button.convert(e.locationInWindow, from: nil)
            guard button.bounds.contains(p) else { return e }
            if e.type == .leftMouseDown {
                self.toggle()
                return nil
            }
            if self.dropOpen { self.holdHighlight() }
            return e
        }

        host = NSHostingController(rootView: Dashboard(app: self, mode: .main))
        drop = makeGlass(host, size: NSSize(width: 268, height: 400))
        detailHost = NSHostingController(rootView: Dashboard(app: self, mode: .detail))
        detail = makeGlass(detailHost, size: NSSize(width: 268, height: 400))
        drop.orderOut(nil)
        detail.orderOut(nil)

        sampler.$snap
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.refreshMenu()
            }
            .store(in: &bag)
        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.applyStroke()
                self?.refreshMenu()
            }
            .store(in: &bag)
        refreshMenu()
    }

    var currentScheme: ColorScheme {
        if theme == "light" { return .light }
        if theme == "dark" { return .dark }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    func makeGlass(_ vc: NSViewController, size: NSSize) -> NSPanel {
        vc.view.wantsLayer = true
        vc.view.layer?.backgroundColor = NSColor.clear.cgColor
        vc.view.layer?.cornerRadius = 10
        vc.view.layer?.cornerCurve = .continuous
        vc.view.layer?.masksToBounds = true
        applyStroke(to: vc.view)
        let p = DropPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentViewController = vc
        return p
    }

    func applyStroke(to view: NSView? = nil) {
        let px = 1.0 / (NSScreen.main?.backingScaleFactor ?? 2)
        let cg = prefs.strokeNS.cgColor
        let views: [NSView] = view.map { [$0] } ?? [host?.view, detailHost?.view].compactMap { $0 }
        for v in views {
            v.wantsLayer = true
            v.layer?.borderWidth = px
            v.layer?.borderColor = cg
        }
    }

    func refreshMenu() {
        guard extra != nil, let button = item?.button else { return }
        extra.chips = menuChips()
        let h = max(button.bounds.height, 22)
        extra.frame = NSRect(origin: .zero, size: NSSize(width: extra.fittingWidth, height: h))
        item.length = extra.fittingWidth + 10
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = extra.makeImage()
        }
        if dropOpen { holdHighlight() } else {
            button.isHighlighted = false
            button.highlight(false)
        }
        if dropOpen { sizePopover() }
    }

    func holdHighlight() {
        guard dropOpen, let button = item.button else { return }
        button.isHighlighted = true
        button.highlight(true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dropOpen, let b = self.item.button else { return }
            b.isHighlighted = true
            b.highlight(true)
        }
    }

    func menuChips() -> [MenuChip] {
        let s = sampler.snap
        func pct(_ v: Double) -> String { "\(Int((min(1, max(0, v)) * 100).rounded()))%" }
        func chip(_ id: String) -> MenuChip? {
            switch id {
            case "ram": return MenuChip(label: "MEM", value: pct(s.ramPressure))
            case "cpu": return MenuChip(label: "CPU", value: pct(s.cpuUser + s.cpuSystem))
            case "gpu": return MenuChip(label: "GPU", value: pct(s.gpuUsage))
            case "storage": return MenuChip(label: "SSD", value: pct(s.diskUsedPct))
            case "net": return MenuChip(label: "↑ \(rate(s.netOut))", value: "↓ \(rate(s.netIn))", isNet: true)
            case "fans":
                guard let f = s.fans.first else { return nil }
                return MenuChip(label: "FAN", value: "\(Int(f.rpm))")
            case "battery":
                let n = Int((min(1, max(0, s.battCharge)) * 100).rounded())
                return MenuChip(label: "BAT", value: "\(n)", batteryFrac: s.battCharge, charging: s.charging)
            default: return nil
            }
        }
        var out: [MenuChip] = []
        for id in prefs.barOrder where prefs.bar.contains(id) {
            if let c = chip(id) { out.append(c) }
        }
        if out.isEmpty {
            out.append(MenuChip(label: "MEM", value: pct(s.ramPressure)))
            out.append(MenuChip(label: "CPU", value: pct(s.cpuUser + s.cpuSystem)))
        }
        return out
    }

    func sizePopover() {
        guard host != nil, drop != nil else { return }
        host.rootView = Dashboard(app: self, mode: .main)
        host.view.layoutSubtreeIfNeeded()
        var h = host.view.fittingSize.height
        if h < 80 { h = 120 }
        h = min(h, 780)
        positionDrop(NSSize(width: 268, height: h))
        if panel != nil { showDetail() } else { hideDetail() }
    }

    func positionDrop(_ size: NSSize) {
        guard let button = item.button, let bwin = button.window else {
            drop.setContentSize(size)
            return
        }
        let br = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        var x = br.midX - size.width / 2
        var y = br.minY - size.height - 5
        if let vis = (bwin.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vis.minX + 6), vis.maxX - size.width - 6)
            if y < vis.minY { y = br.maxY + 5 }
        }
        drop.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    func showDetail() {
        guard drop.isVisible, let panel, detail != nil else { return }
        host.view.layoutSubtreeIfNeeded()
        refreshCardFrames(host.view)
        detailHost.rootView = Dashboard(app: self, mode: .detail)
        detailHost.view.layoutSubtreeIfNeeded()
        var h = detailHost.view.fittingSize.height
        if h < 80 { h = 120 }
        h = min(h, 780)
        let w: CGFloat = 268
        let gap: CGFloat = 6
        var x = drop.frame.minX - w - gap
        let top = cardFrames[panel]?.maxY ?? drop.frame.maxY
        var y = top - h
        if let vis = (drop.screen ?? NSScreen.main)?.visibleFrame {
            if x < vis.minX + 6 {
                x = drop.frame.maxX + gap
            }
            x = min(max(x, vis.minX + 6), vis.maxX - w - 6)
            y = min(max(y, vis.minY + 6), vis.maxY - h - 6)
        }
        detail.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if !detail.isVisible { detail.orderFrontRegardless() }
        if let c = catcher { detail.order(.above, relativeTo: c.windowNumber) }
        armTrack(detail)
    }

    func refreshCardFrames(_ v: NSView) {
        if let p = v as? FrameProbe { p.save() }
        v.subviews.forEach(refreshCardFrames)
    }

    func hideDetail() {
        detail?.orderOut(nil)
    }

    func setTheme(_ t: String) {
        prefs.writeSlot(currentScheme == .dark)
        theme = t
        UserDefaults.standard.set(t, forKey: "theme")
        lastDark = currentScheme == .dark
        prefs.loadSlot(lastDark)
        applyTheme()
        applyStroke()
    }

    func cycleInterval() {
        let steps: [Double] = [0.5, 1, 2, 5]
        let i = steps.firstIndex { abs($0 - prefs.interval) < 0.05 } ?? 1
        prefs.setInterval(steps[(i + 1) % steps.count])
    }

    func cycleTheme() {
        let next = ["system", "light", "dark"].drop(while: { $0 != theme }).dropFirst().first ?? "system"
        setTheme(next)
    }

    func openUtil(_ name: String) {
        let paths = [
            "/System/Applications/Utilities/\(name).app",
            "/System/Applications/\(name).app",
            "/Applications/Utilities/\(name).app"
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
            return
        }
    }

    func openBatterySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.Battery",
            "x-apple.systempreferences:com.apple.preference.battery"
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
        openUtil("System Settings")
    }

    func openCustomApp() {
        let path = prefs.customApp
        if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
            prefs.pickCustomApp()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func applyTheme() {
        switch theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func setPanel(_ v: Panel?) {
        hidePanel?.cancel()
        hidePanel = nil
        if let v {
            let changed = panel != v
            panel = v
            if changed || detail?.isVisible != true {
                DispatchQueue.main.async { self.showDetail() }
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel != nil else { return }
            self.panel = nil
            self.hideDetail()
        }
        hidePanel = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func quitPid(_ pid: pid_t) {
        guard pid > 1, pid != getpid() else { return }
        if let running = NSRunningApplication(processIdentifier: pid) {
            if !running.terminate() { running.forceTerminate() }
        } else {
            kill(pid, SIGTERM)
        }
    }

    @objc func toggle() {
        if dropOpen {
            hideDrop()
        } else {
            ignoreClicksUntil = Date().addingTimeInterval(0.35)
            dropOpen = true
            sampler.runHeavy()
            refreshMenu()
            sizePopover()
            drop.orderFrontRegardless()
            startClickMon()
        }
    }

    func hideDrop() {
        hideDetail()
        drop.orderOut(nil)
        panel = nil
        dropOpen = false
        sampler.stopHeavy()
        item.button?.isHighlighted = false
        item.button?.highlight(false)
        stopClickMon()
    }

    func startClickMon() {
        stopClickMon()
        clickMon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideDrop()
        }
        // ponytail: WindowServer skips fully-clear pixels — 1/255 is enough to hit-test
        let screen = (item.button?.window?.screen ?? NSScreen.main)?.frame ?? .zero
        let p = NSPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(1.0 / 255.0)
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.level = NSWindow.Level(rawValue: drop.level.rawValue - 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        let v = CatcherView(frame: NSRect(origin: .zero, size: screen.size))
        v.autoresizingMask = [.width, .height]
        v.onDown = { [weak self] in self?.hideDrop() }
        p.contentView = v
        p.setFrame(screen, display: false)
        p.orderFrontRegardless()
        catcher = p
        // ponytail: catcher stays one level below; re-front drop so hover hits cards
        drop.order(.above, relativeTo: p.windowNumber)
        if detail.isVisible { detail.order(.above, relativeTo: p.windowNumber) }
        startHoverMon()
    }

    func startHoverMon() {
        stopHoverMon()
        armTrack(drop)
        armTrack(detail)
        hoverMon = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in
            self?.pickHover()
            return e
        }
        pickHover()
    }

    func armTrack(_ w: NSWindow?) {
        guard let v = w?.contentView else { return }
        v.trackingAreas.filter { $0.owner === self }.forEach(v.removeTrackingArea)
        v.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @objc func mouseEntered(with event: NSEvent) { pickHover() }
    @objc func mouseExited(with event: NSEvent) { pickHover() }
    @objc func mouseMoved(with event: NSEvent) { pickHover() }

    func stopHoverMon() {
        if let hoverMon { NSEvent.removeMonitor(hoverMon) }
        hoverMon = nil
        for w in [drop, detail] as [NSWindow?] {
            guard let v = w?.contentView else { continue }
            v.trackingAreas.filter { $0.owner === self }.forEach(v.removeTrackingArea)
        }
    }

    func pickHover() {
        guard dropOpen else { return }
        let loc = NSEvent.mouseLocation
        if detail.isVisible, detail.frame.contains(loc) {
            if let panel { setPanel(panel) }
            return
        }
        if let id = cardFrames.first(where: { $0.value.contains(loc) })?.key {
            setPanel(id)
            return
        }
        if drop.frame.contains(loc) { setPanel(nil) }
    }

    func stopClickMon() {
        if let clickMon { NSEvent.removeMonitor(clickMon) }
        clickMon = nil
        stopHoverMon()
        catcher?.orderOut(nil)
        catcher = nil
    }

    func closeIfOutside() {
        guard dropOpen else { return }
        if Date() < ignoreClicksUntil { return }
        let loc = NSEvent.mouseLocation
        if drop.frame.contains(loc) { return }
        if detail.isVisible, detail.frame.contains(loc) { return }
        if let button = item.button, let w = button.window {
            let br = w.convertToScreen(button.convert(button.bounds, to: nil))
            if br.contains(loc) { return }
        }
        if let sw = settingsWC?.window, sw.isVisible, sw.frame.contains(loc) { return }
        hideDrop()
    }

    func openSettings() {
        hideDrop()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if settingsWC == nil {
            let vc = NSHostingController(rootView: SettingsRoot(app: self, prefs: prefs))
            let w = NSWindow(contentViewController: vc)
            w.title = "Sino"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.setContentSize(NSSize(width: 600, height: 360))
            w.center()
            settingsWC = NSWindowController(window: w)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.settingsWC = nil
                NSApp.setActivationPolicy(.accessory)
            }
        }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        settingsWC?.window?.orderFrontRegardless()
    }
}

final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class CatcherView: NSView {
    var onDown: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(1.0 / 255.0).setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) { onDown?() }
    override func rightMouseDown(with event: NSEvent) { onDown?() }
}

struct MenuChip {
    var label: String
    var value: String
    var batteryFrac: Double? = nil
    var charging = false
    var isNet = false
}

final class ExtraView: NSView {
    var chips: [MenuChip] = []
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    func makeImage() -> NSImage {
        let size = bounds.size.width > 0 ? bounds.size : NSSize(width: fittingWidth, height: 22)
        return NSImage(size: size, flipped: true) { rect in
            NSColor.clear.set()
            rect.fill(using: .copy)
            self.draw(rect)
            return true
        }
    }

    // ponytail: name/% stack; battery = Stats xl 26×14, width 30 either way
    private let gap: CGFloat = 5
    private var labelFont: NSFont { .systemFont(ofSize: 8, weight: .regular) }
    private var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    private var labelAttrs: [NSAttributedString.Key: Any] {
        [.font: labelFont, .foregroundColor: NSColor.labelColor]
    }
    private var valueAttrs: [NSAttributedString.Key: Any] {
        [.font: valueFont, .foregroundColor: NSColor.labelColor]
    }

    private var netFont: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .medium) }
    private var netAttrs: [NSAttributedString.Key: Any] {
        [.font: netFont, .foregroundColor: NSColor.labelColor]
    }
    private let netUpColor = NSColor(srgbRed: 1, green: 0.38, blue: 0.38, alpha: 1)
    private let netDownColor = NSColor(srgbRed: 0.35, green: 0.80, blue: 0.95, alpha: 1)

    private func netLine(_ s: String, up: Bool) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: netAttrs)
        if !s.isEmpty {
            a.addAttribute(.foregroundColor, value: up ? netUpColor : netDownColor, range: NSRange(location: 0, length: 1))
        }
        return a
    }

    func chipWidth(_ c: MenuChip) -> CGFloat {
        if c.batteryFrac != nil { return 30 } // body+cap; bolt packs inside, width fixed
        if c.isNet {
            return ceil(("↑ 1023 KB/s" as NSString).size(withAttributes: netAttrs).width + 2)
        }
        let lw = (c.label as NSString).size(withAttributes: labelAttrs).width
        let vw = (c.value as NSString).size(withAttributes: valueAttrs).width
        return ceil(max(lw, vw) + 2)
    }

    var fittingWidth: CGFloat {
        guard !chips.isEmpty else { return 40 }
        return chips.map(chipWidth).reduce(0, +) + CGFloat(chips.count - 1) * gap + 4
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelH: CGFloat = 9
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        var x: CGFloat = 2
        for c in chips {
            let cw = chipWidth(c)
            if let frac = c.batteryFrac {
                drawBattery(NSRect(x: x, y: 0, width: cw, height: bounds.height), frac: frac, text: c.value, charging: c.charging)
            } else if c.isNet {
                let half = floor(bounds.height / 2)
                netLine(c.label, up: true).draw(with: NSRect(x: x, y: 1, width: cw, height: half), options: opts)
                netLine(c.value, up: false).draw(with: NSRect(x: x, y: half, width: cw, height: bounds.height - half), options: opts)
            } else {
                (c.label as NSString).draw(with: NSRect(x: x, y: 0, width: cw, height: labelH), options: opts, attributes: labelAttrs)
                (c.value as NSString).draw(with: NSRect(x: x, y: labelH, width: cw, height: bounds.height - labelH), options: opts, attributes: valueAttrs)
            }
            x += cw + gap
        }
    }

    private func drawBolt(_ box: NSRect, color: NSColor) {
        guard let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6.5, weight: .bold).applying(.init(paletteColors: [color])))
        else { return }
        img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawBattery(_ r: NSRect, frac: Double, text: String, charging: Bool) {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = dark ? NSColor.white : NSColor.black
        let f = CGFloat(min(1, max(0, frac)))
        // Stats Kit/Widgets/Battery.swift xl: 26×14, r=3, 2×4 cap
        let bw: CGFloat = 26
        let bh: CGFloat = 14
        let y = ((r.height - bh) / 2).rounded()
        let body = NSRect(x: r.minX + 0.5, y: y, width: bw, height: bh)
        let rad: CGFloat = 3
        ink.withAlphaComponent(0.55).setStroke()
        let outline = NSBezierPath(roundedRect: body, xRadius: rad, yRadius: rad)
        outline.lineWidth = 1
        outline.stroke()
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX, y: body.midY - 2, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).addClip()
        ink.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: NSRect(x: inner.minX, y: inner.minY, width: inner.width * f, height: inner.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        let boltW: CGFloat = charging ? 5 : 0
        let pack = sz.width + boltW
        let x0 = (body.midX - pack / 2).rounded()
        let y0 = (body.midY - sz.height / 2).rounded()
        s.draw(
            with: NSRect(x: x0, y: y0, width: ceil(sz.width), height: ceil(sz.height)),
            options: [.usesLineFragmentOrigin],
            attributes: attrs
        )
        if charging {
            drawBolt(NSRect(x: x0 + sz.width, y: (body.midY - 3.5).rounded(), width: 5, height: 7), color: ink)
        }
    }
}

struct HoverPad: NSViewRepresentable {
    var selected = false
    func makeNSView(context: Context) -> HoverBG {
        let v = HoverBG()
        v.radius = 6
        v.selected = selected
        v.captureHits = false
        return v
    }
    func updateNSView(_ v: HoverBG, context: Context) {
        v.selected = selected
        v.captureHits = false
        v.needsDisplay = true
        v.updateTrackingAreas()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HoverBG, context: Context) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
}

struct Frost: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var behind: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        updateNSView(v, context: context)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = behind ? .behindWindow : .withinWindow
    }
}

struct ScreenFrame: NSViewRepresentable {
    let id: App.Panel
    func makeNSView(context: Context) -> FrameProbe {
        let v = FrameProbe()
        v.id = id
        return v
    }
    func updateNSView(_ v: FrameProbe, context: Context) {
        v.id = id
        DispatchQueue.main.async { v.save() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FrameProbe, context: Context) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class FrameProbe: NSView {
    var id: App.Panel?
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        DispatchQueue.main.async { [weak self] in self?.save() }
    }
    override func layout() {
        super.layout()
        save()
        updateTrackingAreas()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        save()
        updateTrackingAreas()
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
    override func mouseEntered(with event: NSEvent) {
        save()
        if let id { App.shared.setPanel(id) }
    }
    override func mouseMoved(with event: NSEvent) {
        if let id { App.shared.setPanel(id) }
    }
    override func mouseExited(with event: NSEvent) {
        App.shared.setPanel(nil)
    }
    func save() {
        guard let id, let w = window, bounds.width > 1, bounds.height > 1 else { return }
        let inWindow: NSRect = convert(bounds, to: nil)
        App.shared.cardFrames[id] = w.convertToScreen(inWindow)
    }
}

struct Dashboard: View {
    @ObservedObject var app: App
    var mode: Kind = .main
    enum Kind { case main, detail }
    var snap: Snapshot { app.sampler.snap }
    var pal: Palette { Palette(scheme: app.currentScheme, prefs: app.prefs) }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if mode == .main { mainColumn }
                else { sideColumn }
            }
            .padding(6)
        }
        .frame(width: 268)
        .background {
            ZStack {
                Frost(material: app.prefs.frostMaterial, behind: app.prefs.frostBehind)
                if app.prefs.frostTint > 0 {
                    Color(nsColor: app.prefs.nsColor("tint", fallback: .black))
                        .opacity(app.prefs.frostTint)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .preferredColorScheme(pal.scheme)
    }

    var mainColumn: some View {
        VStack(spacing: 4) {
            if shown("cpu") {
                Card("CPU", "cpu", pal, panel: .cpu, active: app.panel == .cpu) {
                    Sparkline(values: snap.cpuHistory, color: pal.accent)
                        .frame(height: 22)
                        .padding(.bottom, 1)
                    MetricRow("User", pct0(snap.cpuUser), snap.cpuUser, pal)
                    MetricRow("System", pct0(snap.cpuSystem), snap.cpuSystem, pal)
                    MetricRow("Idle", pct0(max(0, 1 - snap.cpuUser - snap.cpuSystem)), max(0, 1 - snap.cpuUser - snap.cpuSystem), pal)
                }
            }
            if shown("ram") {
                Card("RAM", "memorychip", pal, panel: .ram, active: app.panel == .ram) {
                    Bar(snap.ramPressure, pal.accent, pal.track).padding(.bottom, 1)
                    HStack {
                        Text("Pressure").font(Palette.body)
                        Spacer()
                        Text(pct0(snap.ramPressure)).font(Palette.body).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Used").font(Palette.body)
                        Spacer()
                        Text("\(bytesGB(snap.ramUsed)) / \(bytesGB(snap.ramTotal))").font(Palette.body).foregroundStyle(.secondary)
                    }
                }
            }
            if shown("gpu") {
                Card("GPU", "display", pal, panel: .gpu, active: app.panel == .gpu) {
                    Text(snap.gpuName).font(Palette.body)
                    Bar(snap.gpuUsage, pal.accent, pal.track)
                    HStack {
                        Text(pct0(snap.gpuUsage)).font(Palette.body).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            if shown("storage") {
                Card("STORAGE", "internaldrive", pal, panel: .storage, active: app.panel == .storage) {
                    HStack {
                        Text(snap.diskName).font(Palette.body)
                        Spacer()
                        Image(systemName: "heart.fill").foregroundStyle(.pink).font(.system(size: 11))
                    }
                    Bar(snap.diskUsedPct, pal.accent, pal.track)
                    HStack {
                        Text("\(bytesGB(snap.diskAvail, giB: false)) available").font(Palette.body)
                        Spacer()
                        Text(pct0(snap.diskUsedPct)).font(Palette.body).foregroundStyle(.secondary)
                    }
                }
            }
            if shown("net") {
                Card("NETWORK", snap.wifi ? "wifi" : "cable.connector", pal, panel: .net, active: app.panel == .net) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rate(snap.netOut)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                            Text("Upload").font(Palette.tiny).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(rate(snap.netIn)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                            Text("Download").font(Palette.tiny).foregroundStyle(.secondary)
                        }
                    }
                    NetChart(up: snap.netOutHistory, down: snap.netInHistory)
                        .frame(height: 36)
                    HStack {
                        Image(systemName: snap.wifi ? "wifi" : "cable.connector").foregroundStyle(NetChart.downCol)
                        Text(snap.netSSID != "—" ? snap.netSSID : snap.netName).font(Palette.body)
                        Spacer()
                    }
                }
            }
            if shown("fans"), !snap.fans.isEmpty {
                Card("FANS", "fan", pal, panel: .fans, active: app.panel == .fans) {
                    ForEach(snap.fans) { f in
                        HStack {
                            Text(f.name).font(Palette.body)
                            Spacer()
                            Text("\(Int(f.rpm.rounded())) RPM")
                                .font(Palette.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Bar(f.maxRPM > 0 ? min(1, f.rpm / f.maxRPM) : 0, pal.accent, pal.track)
                                .frame(width: 52)
                        }
                    }
                }
            }
            if shown("battery") {
                Card("BATTERY", "battery.100percent", pal, panel: .battery, active: app.panel == .battery) {
                    HStack {
                        Text("Charge").font(Palette.body)
                        Spacer()
                        Text(pct0(snap.battCharge)).font(Palette.body).foregroundStyle(.secondary)
                        Bar(snap.battCharge, pal.green, pal.track).frame(width: 52)
                    }
                    HStack {
                        Text("Health").font(Palette.body)
                        Spacer()
                        Text(pct0(snap.battHealth)).font(Palette.body).foregroundStyle(.secondary)
                        Bar(snap.battHealth, pal.green.opacity(0.45), pal.track).frame(width: 52)
                    }
                    HStack {
                        Text("Battery Cycles").font(Palette.body)
                        Spacer()
                        Text("\(snap.battCycles)").font(Palette.body).foregroundStyle(.secondary)
                    }
                }
            }
            toolbar
        }
        .frame(width: 256)
    }

    func shown(_ id: String) -> Bool { app.prefs.drop.contains(id) }

    var sideColumn: some View {
        VStack(spacing: 4) {
            switch app.panel {
            case .cpu: cpuSide
            case .ram: ramSide
            case .gpu: gpuSide
            case .storage: storageSide
            case .net: netSide
            case .fans: fansSide
            case .battery: batterySide
            case nil: EmptyView()
            }
        }
        .frame(width: 256)
        .contentShape(Rectangle())
    }

    var cpuSide: some View {
        Group {
            Card("CPU CORES", "cpu", pal) {
                ForEach(snap.cores) { c in
                    HStack {
                        Text(c.name).font(Palette.body)
                        Spacer()
                        Bar(c.usage, pal.accent, pal.track).frame(width: 64)
                    }
                }
            }
            Card("CPU USAGE", "square.grid.2x2", pal) {
                ForEach(snap.processes) { p in
                    HStack(spacing: 5) {
                        icon(p.icon)
                        Text(p.name).font(Palette.body).lineLimit(1)
                        Spacer()
                        Text(pct1(p.cpu)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Card("GPU", "display", pal) {
                Text(snap.gpuName).font(Palette.body)
                Bar(snap.gpuUsage, pal.accent, pal.track)
                HStack {
                    Text("Usage").font(Palette.body)
                    Spacer()
                    Text(pct0(snap.gpuUsage)).font(Palette.body).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Memory").font(Palette.body)
                    Spacer()
                    Text(bytesGB(snap.gpuMemUsed)).font(Palette.body).foregroundStyle(.secondary)
                }
            }
        }
    }

    var ramSide: some View {
        Group {
            Card("MEMORY", "memorychip", pal) {
                MetricRow("Used", bytesGB(snap.ramUsed), snap.ramTotal == 0 ? 0 : Double(snap.ramUsed) / Double(snap.ramTotal), pal)
                MetricRow("Wired", bytesGB(snap.ramWired), snap.ramTotal == 0 ? 0 : Double(snap.ramWired) / Double(snap.ramTotal), pal)
                MetricRow("Compressed", bytesGB(snap.ramCompressed), snap.ramTotal == 0 ? 0 : Double(snap.ramCompressed) / Double(snap.ramTotal), pal)
                MetricRow(
                    "Free",
                    bytesGB(snap.ramTotal > snap.ramUsed ? snap.ramTotal - snap.ramUsed : 0),
                    snap.ramTotal == 0 ? 0 : Double(snap.ramTotal > snap.ramUsed ? snap.ramTotal - snap.ramUsed : 0) / Double(snap.ramTotal),
                    pal
                )
                MetricRow(
                    "Swap",
                    bytesGB(snap.ramSwapUsed),
                    snap.ramSwapTotal == 0 ? 0 : Double(snap.ramSwapUsed) / Double(snap.ramSwapTotal),
                    pal
                )
            }
            Card("PRESSURE", "gauge", pal) {
                Bar(snap.ramPressure, pal.accent, pal.track)
                HStack {
                    Text("Pressure").font(Palette.body)
                    Spacer()
                    Text(pct0(snap.ramPressure)).font(Palette.body).foregroundStyle(.secondary)
                }
            }
            Card("PROCESSES", "square.grid.2x2", pal) {
                ForEach(snap.memProcesses) { p in
                    HStack(spacing: 5) {
                        icon(p.icon)
                        Text(p.name).font(Palette.body).lineLimit(1)
                        Spacer()
                        Text(bytesGB(p.mem)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                        Button {
                            App.shared.quitPid(p.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Quit \(p.name)")
                    }
                }
            }
        }
    }

    var gpuSide: some View {
        Card("GPU", "display", pal) {
            HStack {
                Text(snap.gpuName).font(Palette.body)
                Spacer()
                if snap.gpuCores > 0 {
                    Text("\(snap.gpuCores) cores").font(Palette.body).foregroundStyle(.secondary)
                }
            }
            if !snap.gpuVendor.isEmpty {
                HStack {
                    Text("Vendor").font(Palette.body)
                    Spacer()
                    Text(snap.gpuVendor).font(Palette.body).foregroundStyle(.secondary)
                }
            }
            MetricRow("Device", pct0(snap.gpuUsage), snap.gpuUsage, pal)
            MetricRow("Renderer", pct0(snap.gpuRenderer), snap.gpuRenderer, pal)
            MetricRow("Tiler", pct0(snap.gpuTiler), snap.gpuTiler, pal)
            MetricRow(
                "Memory in use",
                bytesGB(snap.gpuMemUsed),
                snap.gpuMemAlloc == 0 ? 0 : Double(snap.gpuMemUsed) / Double(snap.gpuMemAlloc),
                pal
            )
            HStack {
                Text("Allocated").font(Palette.body)
                Spacer()
                Text(bytesGB(snap.gpuMemAlloc > 0 ? snap.gpuMemAlloc : snap.gpuMemTotal))
                    .font(Palette.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    var storageSide: some View {
        Card("VOLUMES", "internaldrive", pal) {
            ForEach(snap.volumes) { v in
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.name).font(Palette.body)
                    MetricRow("Used", bytesGB(v.total > v.avail ? v.total - v.avail : 0, giB: false), v.usedPct, pal)
                    HStack {
                        Text("\(bytesGB(v.avail, giB: false)) free").font(Palette.tiny).foregroundStyle(.secondary)
                        Spacer()
                        Text(bytesGB(v.total, giB: false)).font(Palette.tiny).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    var netSide: some View {
        Group {
            Card("NETWORK", snap.wifi ? "wifi" : "cable.connector", pal) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rate(snap.netOut)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        Text("Upload").font(Palette.tiny).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(rate(snap.netIn)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        Text("Download").font(Palette.tiny).foregroundStyle(.secondary)
                    }
                }
                NetChart(up: snap.netOutHistory, down: snap.netInHistory)
                    .frame(height: 52)
                HStack(spacing: 4) {
                    Circle().fill(NetChart.upCol).frame(width: 6, height: 6)
                    Text("Peak ↑").font(Palette.tiny).foregroundStyle(.secondary)
                    Text(rate(snap.netOutPeak)).font(Palette.tiny.monospacedDigit())
                    Spacer()
                    Circle().fill(NetChart.downCol).frame(width: 6, height: 6)
                    Text("Peak ↓").font(Palette.tiny).foregroundStyle(.secondary)
                    Text(rate(snap.netInPeak)).font(Palette.tiny.monospacedDigit())
                }
                HStack {
                    Image(systemName: snap.wifi ? "wifi" : "cable.connector").foregroundStyle(NetChart.downCol)
                    Text(snap.netSSID != "—" ? snap.netSSID : snap.netName).font(Palette.body)
                    Spacer()
                }
            }
            Card("ADDRESSES", "globe", pal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PUBLIC IP ADDRESSES").font(Palette.tiny).foregroundStyle(NetChart.downCol)
                    Text(snap.publicIP).font(Palette.body.monospaced())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("IP ADDRESSES").font(Palette.tiny).foregroundStyle(NetChart.downCol)
                    Text(snap.netIPv4).font(Palette.body.monospaced())
                    if snap.netIPv6 != "—" {
                        Text(snap.netIPv6).font(Palette.tiny.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack {
                    Text("Router").font(Palette.body)
                    Spacer()
                    Text(snap.netRouter).font(Palette.body.monospaced()).foregroundStyle(.secondary)
                }
                HStack {
                    Text("MAC").font(Palette.body)
                    Spacer()
                    Text(snap.mac).font(Palette.body.monospaced()).foregroundStyle(.secondary)
                }
            }
            if snap.netTopName != "—" {
                Card("TOP PROCESS", "square.grid.2x2", pal) {
                    HStack(spacing: 5) {
                        icon(snap.netTopIcon)
                        Text(snap.netTopName).font(Palette.body).lineLimit(1)
                        Spacer()
                        Text(rate(snap.netTopBps)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var fansSide: some View {
        Group {
            Card("FANS", "fan", pal) {
                ForEach(snap.fans) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(f.name).font(Palette.body)
                            Spacer()
                            Text("\(Int(f.rpm.rounded())) RPM").font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Bar(f.maxRPM > 0 ? min(1, f.rpm / f.maxRPM) : 0, pal.accent, pal.track)
                    }
                }
            }
            if !snap.temps.isEmpty {
                Card("SENSORS", "thermometer", pal) {
                    ForEach(snap.temps) { t in
                        HStack {
                            Text(t.name).font(Palette.body)
                            Spacer()
                            Text(String(format: "%.1f °C", t.c))
                                .font(Palette.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    var batterySide: some View {
        Group {
            Card("BATTERY", "battery.100percent", pal) {
                MetricRow("Charge", pct0(snap.battCharge), snap.battCharge, pal)
                MetricRow("Health", pct0(snap.battHealth), snap.battHealth, pal)
                HStack {
                    Text("Cycles").font(Palette.body)
                    Spacer()
                    Text("\(snap.battCycles)").font(Palette.body).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Power").font(Palette.body)
                    Spacer()
                    Text(snap.charging ? "Charging" : "On battery").font(Palette.body).foregroundStyle(.secondary)
                }
            }
            Card("ENERGY", "bolt.fill", pal) {
                ForEach(snap.energyProcesses) { p in
                    HStack(spacing: 5) {
                        icon(p.icon)
                        Text(p.name).font(Palette.body).lineLimit(1)
                        Spacer()
                        Text(watts(p.energyW)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var toolbar: some View {
        HStack(spacing: 4) {
            tool("bolt.fill", "Battery settings", selected: true) { App.shared.openBatterySettings() }
            tool("waveform.path.ecg", "Activity Monitor") { App.shared.openUtil("Activity Monitor") }
            tool("exclamationmark.triangle.fill", "Console", tint: .yellow) { App.shared.openUtil("Console") }
            tool("terminal.fill", "Terminal") { App.shared.openUtil("Terminal") }
            customTool
            Button {
                App.shared.cycleInterval()
            } label: {
                Text(intervalLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .background(pal.track, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .overlay { HoverPad() }
            .help("Refresh interval — click to cycle")
            tool("circle.lefthalf.filled", "Theme") { App.shared.cycleTheme() }
            tool("gearshape.fill", "Settings") { app.openSettings() }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(pal.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var customTool: some View {
        Button { App.shared.openCustomApp() } label: {
            Group {
                if let img = app.prefs.customAppIcon {
                    Image(nsImage: img).resizable().interpolation(.high).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "plus.app")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pal.track))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .overlay { HoverPad() }
        .help(app.prefs.customApp.isEmpty ? "Set toolbar app" : app.prefs.customAppName)
        .contextMenu {
            Button("Choose App…") { app.prefs.pickCustomApp() }
            if !app.prefs.customApp.isEmpty {
                Button("Clear", role: .destructive) { app.prefs.clearCustomApp() }
            }
        }
    }

    var intervalLabel: String {
        let v = app.prefs.interval
        return v < 1 ? String(format: "%.1fs", v) : String(format: "%.0fs", v)
    }

    func tool(_ name: String, _ tip: String, selected: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? (selected ? pal.accent : Color.primary.opacity(0.75)))
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? pal.accent.opacity(0.12) : pal.track)
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .overlay { HoverPad(selected: selected) }
        .help(tip)
    }

    func icon(_ img: NSImage?) -> some View {
        Group {
            if let img { Image(nsImage: img).resizable() }
            else { Image(systemName: "app.fill").resizable() }
        }
        .frame(width: 14, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let pal: Palette
    var panel: App.Panel?
    var active: Bool
    let content: Content

    init(_ title: String, _ symbol: String, _ pal: Palette, panel: App.Panel? = nil, active: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.pal = pal
        self.panel = panel
        self.active = active
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .textCase(.uppercase)
                .tracking(0.3)
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? pal.cardHover : pal.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { if let panel { ScreenFrame(id: panel) } }
    }
}

struct MetricRow: View {
    let title: String
    let value: String
    let frac: Double
    let pal: Palette
    init(_ title: String, _ value: String, _ frac: Double, _ pal: Palette) {
        self.title = title; self.value = value; self.frac = frac; self.pal = pal
    }
    var body: some View {
        HStack {
            Text(title).font(Palette.body)
            Spacer()
            Text(value).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
            Bar(frac, pal.accent, pal.track).frame(width: 52)
        }
    }
}

struct Bar: View {
    let frac: Double
    let fill: Color
    let track: Color
    init(_ frac: Double, _ fill: Color, _ track: Color) {
        self.frac = frac; self.fill = fill; self.track = track
    }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill)
                    .frame(width: max(0, g.size.width * CGFloat(min(1, max(0, frac)))))
            }
        }
        .frame(height: 4)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let n = max(values.count, 1)
            let w = size.width / CGFloat(n)
            let bw = max(1.2, w * 0.62)
            for (i, v) in values.enumerated() {
                let h = max(1, CGFloat(v) * size.height)
                let r = CGRect(x: CGFloat(i) * w, y: size.height - h, width: bw, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(color))
            }
        }
    }
}

struct NetChart: View {
    let up: [Double]
    let down: [Double]
    static let upCol = Color(red: 1.0, green: 0.38, blue: 0.38)
    static let downCol = Color(red: 0.35, green: 0.80, blue: 0.95)
    var body: some View {
        Canvas { ctx, size in
            let n = max(up.count, down.count, 1)
            let w = size.width / CGFloat(n)
            let bw = max(1.2, w * 0.62)
            var peak = 1.0
            for i in 0..<n {
                if i < up.count { peak = max(peak, up[i]) }
                if i < down.count { peak = max(peak, down[i]) }
            }
            let mid = size.height / 2
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: mid - 0.4, width: 2.4, height: 0.8)), with: .color(.secondary.opacity(0.45)))
                x += 5
            }
            for i in 0..<n {
                let u = i < up.count ? up[i] : 0
                let d = i < down.count ? down[i] : 0
                let px = CGFloat(i) * w
                let uh = CGFloat(u / peak) * (mid - 1)
                let dh = CGFloat(d / peak) * (mid - 1)
                if uh > 0.4 {
                    ctx.fill(Path(roundedRect: CGRect(x: px, y: mid - uh, width: bw, height: uh), cornerRadius: 0.8), with: .color(Self.upCol))
                }
                if dh > 0.4 {
                    ctx.fill(Path(roundedRect: CGRect(x: px, y: mid, width: bw, height: dh), cornerRadius: 0.8), with: .color(Self.downCol))
                }
            }
        }
    }
}

struct Palette {
    let scheme: ColorScheme
    let prefs: Prefs
    var accent: Color {
        prefs.swiftColor("accent", fallback: NSColor(srgbRed: 0.04, green: 0.48, blue: 1, alpha: 1))
    }
    var card: Color {
        prefs.swiftColor("card", fallback: scheme == .dark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.white.withAlphaComponent(0.62))
    }
    var cardHover: Color {
        prefs.swiftColor("hover", fallback: scheme == .dark
            ? NSColor.white.withAlphaComponent(0.20)
            : NSColor(srgbRed: 0.88, green: 0.93, blue: 1, alpha: 1))
    }
    var track: Color {
        prefs.swiftColor("track", fallback: scheme == .dark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.08))
    }
    var green: Color {
        prefs.swiftColor("green", fallback: NSColor(srgbRed: 0.40, green: 0.78, blue: 0.35, alpha: 1))
    }
    static let body = Font.system(size: 12)
    static let tiny = Font.system(size: 10)
}

private let pctFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    return f
}()
private let pct1Formatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 1
    f.maximumFractionDigits = 1
    return f
}()
private let gbFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

private func pct0(_ v: Double) -> String {
    (pctFormatter.string(from: NSNumber(value: (v * 100).rounded())) ?? "0") + " %"
}
private func pct1(_ v: Double) -> String {
    (pct1Formatter.string(from: NSNumber(value: v * 100)) ?? "0.0") + " %"
}
private func bytesGB(_ b: UInt64, giB: Bool = true) -> String {
    let gb = Double(b) / (giB ? 1_073_741_824.0 : 1_000_000_000.0)
    return (gbFormatter.string(from: NSNumber(value: gb)) ?? "0") + " GB"
}
private func rate(_ bps: Double) -> String {
    let v = max(bps, 0)
    if v < 1024 { return String(format: "%.0f B/s", v) }
    if v < 1024 * 1024 {
        let kb = v / 1024
        return String(format: kb >= 10 ? "%.0f KB/s" : "%.1f KB/s", kb)
    }
    let mb = v / (1024 * 1024)
    if mb < 1024 { return String(format: mb >= 10 ? "%.0f MB/s" : "%.1f MB/s", mb) }
    return String(format: "%.1f GB/s", mb / 1024)
}
private func shortRate(_ bps: Double) -> String {
    if bps < 1024 { return String(format: "%.0fB", max(bps, 0)) }
    if bps < 1024 * 1024 { return String(format: "%.0fK", bps / 1024) }
    return String(format: "%.1fM", bps / (1024 * 1024))
}
private func watts(_ w: Double) -> String {
    if w < 1 { return String(format: "%.0f mW", w * 1000) }
    return String(format: "%.2f W", w)
}
