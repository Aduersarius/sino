import AppKit
import Carbon
import Combine
import IOKit.pwr_mgt
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
    @Published var cleaningRAM = false
    @Published var cleanFeedback: String? = nil
    @Published var fetchingIP = false
    @Published var confirmingKillPid: pid_t? = nil
    @Published var isAwakeActive = false
    @Published var preventDisplaySleep = true
    @Published var awakeRemainingSeconds: Int? = nil // nil = indefinite
    private var awakeAssertionID: IOPMAssertionID = 0
    private var awakeTimer: Timer? = nil
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
    var settingsWC: NSWindowController?
    private var dropOpen = false
    private var ignoreClicksUntil = Date.distantPast
    private var lastDark = false
    private var appearObs: NSKeyValueObservation?
    private var lastChips: [MenuChip] = []

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
            self.lastChips = []
            self.refreshMenu()
        }
        Updater.shared.start()
        HotKeyManager.shared.update(keyCode: prefs.awakeShortcutKeyCode, modifiers: prefs.awakeShortcutModifiers)
        if let img = NSImage(named: "AppIcon") { NSApp.applicationIconImage = img }
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sino", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sino", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopAwake()
        }
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
                if self.dropOpen {
                    self.objectWillChange.send()
                }
                self.refreshMenu()
            }
            .store(in: &bag)
        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.applyStroke()
                self.lastChips = []
                self.refreshMenu()
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
        let chips = menuChips()
        extra.chips = chips
        let h = max(button.bounds.height, 22)
        let w = extra.fittingWidth
        if abs(extra.frame.width - w) > 0.5 || abs(extra.frame.height - h) > 0.5 {
            extra.frame = NSRect(origin: .zero, size: NSSize(width: w, height: h))
        }
        let len = w + 4
        if abs(item.length - len) > 0.5 {
            item.length = len
        }
        if chips != lastChips || button.image == nil {
            lastChips = chips
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.image = extra.makeImage()
            }
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
        if let c = catcher { drop.order(.above, relativeTo: c.windowNumber) }
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
        let next = NSRect(x: x, y: y, width: size.width, height: size.height)
        let f = drop.frame
        if abs(f.minX - next.minX) > 0.5 || abs(f.minY - next.minY) > 0.5
            || abs(f.width - next.width) > 1 || abs(f.height - next.height) > 2 {
            drop.setFrame(next, display: true)
        }
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
        lastChips = []
        refreshMenu()
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

    // ponytail: IOPMAssertion sleep prevention (amphetamine) -> upgrade: lid-closed clamshell mode
    func toggleAwake(duration: TimeInterval? = nil) {
        if isAwakeActive {
            stopAwake()
        } else {
            startAwake(duration: duration)
        }
    }

    func startAwake(duration: TimeInterval? = nil) {
        stopAwake()
        let type = preventDisplaySleep ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let ret = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sino Awake" as CFString,
            &id
        )
        if ret == kIOReturnSuccess {
            awakeAssertionID = id
            isAwakeActive = true
            if let duration, duration > 0 {
                awakeRemainingSeconds = Int(duration)
                awakeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if let rem = self.awakeRemainingSeconds, rem > 1 {
                        self.awakeRemainingSeconds = rem - 1
                    } else {
                        self.stopAwake()
                    }
                }
            } else {
                awakeRemainingSeconds = nil
            }
        }
    }

    func stopAwake() {
        awakeTimer?.invalidate()
        awakeTimer = nil
        awakeRemainingSeconds = nil
        if awakeAssertionID != 0 {
            IOPMAssertionRelease(awakeAssertionID)
            awakeAssertionID = 0
        }
        isAwakeActive = false
    }

    func setPreventDisplaySleep(_ prevent: Bool) {
        preventDisplaySleep = prevent
        if isAwakeActive {
            let dur: TimeInterval? = awakeRemainingSeconds.map { TimeInterval($0) }
            startAwake(duration: dur)
        }
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

    func openCustomApp(slot: Int = 1) {
        let path = slot == 2 ? prefs.customApp2 : prefs.customApp
        if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
            hideDrop()
            DispatchQueue.main.async { self.prefs.pickCustomApp(slot: slot) }
            return
        }
        hideDrop()
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
        quitPids([pid])
    }

    func quitPids(_ pids: [pid_t]) {
        for pid in pids {
            guard pid > 1, pid != getpid() else { continue }
            if let running = NSRunningApplication(processIdentifier: pid) {
                if !running.terminate() { running.forceTerminate() }
            } else {
                kill(pid, SIGTERM)
            }
        }
    }

    @objc func toggle() {
        if dropOpen {
            hideDrop()
        } else {
            ignoreClicksUntil = Date().addingTimeInterval(0.35)
            dropOpen = true
            sampler.runHeavy()
            objectWillChange.send()
            refreshMenu()
            sizePopover()
            drop.orderFrontRegardless()
            startClickMon()
        }
    }

    func hideDrop() {
        TooltipManager.shared.hideImmediately()
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
            self?.closeIfOutside()
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
        v.onDown = { [weak self] in self?.closeIfOutside() }
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
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.minSize = NSSize(width: 600, height: 320)
            w.maxSize = NSSize(width: 600, height: 1200)
            w.setContentSize(NSSize(width: 600, height: 420))
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

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            DispatchQueue.main.async {
                App.shared.toggleAwake()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }

    func update(keyCode: Int, modifiers: UInt) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        guard keyCode >= 0 else { return }
        let hotKeyID = EventHotKeyID(signature: 0x53494E4F, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        }
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

struct MenuChip: Equatable {
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
    private let gap: CGFloat = 2
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
        if c.batteryFrac != nil { return 30 }
        if c.isNet { return 66 }
        let lw = (c.label as NSString).size(withAttributes: labelAttrs).width
        if c.label == "FAN" {
            let fw = ("99999" as NSString).size(withAttributes: valueAttrs).width
            return ceil(max(lw, fw) + 2)
        }
        let vw = ("100%" as NSString).size(withAttributes: valueAttrs).width
        return ceil(max(lw, vw) + 2)
    }

    var fittingWidth: CGFloat {
        guard !chips.isEmpty else { return 40 }
        return chips.map(chipWidth).reduce(0, +) + CGFloat(chips.count - 1) * gap + 2
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

final class TooltipPanel: NSPanel {
    private let frost: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }()

    private let label: NSTextField = {
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 11, weight: .medium)
        t.textColor = .labelColor
        t.drawsBackground = false
        t.isBordered = false
        t.alignment = .center
        return t
    }()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        frost.addSubview(label)
        contentView = frost
    }

    func update(text: String, for view: NSView, in win: NSWindow) {
        label.stringValue = text
        label.sizeToFit()
        let padX: CGFloat = 8
        let padY: CGFloat = 4
        let w = ceil(label.frame.width) + padX * 2
        let h = ceil(label.frame.height) + padY * 2
        let sz = NSSize(width: max(w, 28), height: max(h, 18))

        frost.material = Prefs.shared.frostMaterial
        let px = 1.0 / (win.backingScaleFactor > 0 ? win.backingScaleFactor : 2.0)
        frost.layer?.borderWidth = px
        frost.layer?.borderColor = Prefs.shared.strokeNS.cgColor
        frost.layer?.cornerRadius = 6

        let y0 = ((sz.height - ceil(label.frame.height)) / 2).rounded()
        label.frame = NSRect(x: padX, y: y0, width: ceil(label.frame.width), height: ceil(label.frame.height))
        frost.frame = NSRect(origin: .zero, size: sz)
        setContentSize(sz)

        level = NSWindow.Level(rawValue: win.level.rawValue + 1)

        let top = NSPoint(x: view.bounds.midX, y: view.isFlipped ? 0 : view.bounds.height)
        let inWin = view.convert(top, to: nil)
        let scr = win.convertToScreen(NSRect(origin: inWin, size: .zero)).origin

        var x = (scr.x - sz.width / 2).rounded()
        let y = scr.y + 6

        if let screen = win.screen {
            let minX = screen.visibleFrame.minX + 4
            let maxX = screen.visibleFrame.maxX - sz.width - 4
            x = max(minX, min(x, maxX))
        }

        setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true)
        invalidateShadow()
        orderFrontRegardless()
    }
}

final class TooltipManager {
    static let shared = TooltipManager()
    private var tipPanel: TooltipPanel?
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private weak var currentView: NSView?
    private(set) var isShowing = false

    func show(_ text: String, for view: NSView) {
        hideTimer?.invalidate()
        hideTimer = nil

        if currentView === view && isShowing { return }
        currentView = view

        showTimer?.invalidate()

        if isShowing {
            display(text, for: view)
        } else {
            showTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self, weak view] _ in
                guard let self, let view, self.currentView === view else { return }
                self.display(text, for: view)
            }
        }
    }

    func hide(for view: NSView? = nil) {
        if let view, currentView !== view { return }
        showTimer?.invalidate()
        showTimer = nil

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tipPanel?.orderOut(nil)
            self.isShowing = false
            self.currentView = nil
        }
    }

    func hideImmediately() {
        showTimer?.invalidate()
        showTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        tipPanel?.orderOut(nil)
        isShowing = false
        currentView = nil
    }

    private func display(_ text: String, for view: NSView) {
        guard let win = view.window, !text.isEmpty else { hideImmediately(); return }
        let panel = tipPanel ?? TooltipPanel()
        tipPanel = panel
        panel.update(text: text, for: view, in: win)
        isShowing = true
    }
}

struct HoverPad: NSViewRepresentable {
    var tip: String? = nil
    var selected = false
    var captureHits = false
    var onClick: (() -> Void)? = nil
    func makeNSView(context: Context) -> HoverBG {
        let v = HoverBG()
        v.radius = 6
        v.selected = selected
        v.captureHits = captureHits
        v.onClick = onClick
        v.tip = tip
        return v
    }
    func updateNSView(_ v: HoverBG, context: Context) {
        v.selected = selected
        v.captureHits = captureHits
        v.onClick = onClick
        v.tip = tip
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
                    let u = max(0, snap.cpuUser)
                    let s = max(0, snap.cpuSystem)
                    CPULoadBar(user: u, system: s, accent: NSColor(pal.accent), track: NSColor(pal.track))
                        .frame(height: 8)
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
                    if snap.ramSwapTotal > 0 {
                        HStack {
                            Text("Swap").font(Palette.body)
                            Spacer()
                            Text("\(bytesGB(snap.ramSwapUsed)) / \(bytesGB(snap.ramSwapTotal))").font(Palette.body).foregroundStyle(.secondary)
                        }
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
                    HStack {
                        Text("Write \(rate(snap.diskWrite))").font(Palette.tiny).foregroundStyle(NetChart.upCol)
                        Spacer()
                        Text("Read \(rate(snap.diskRead))").font(Palette.tiny).foregroundStyle(NetChart.downCol)
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
                        Bar(snap.battCharge, chargeColor(snap.battCharge), pal.track, charging: snap.charging).frame(width: 52)
                    }
                    HStack {
                        Text(snap.charging ? "Until Full" : "Time Left").font(Palette.body)
                        Spacer()
                        Text(batteryTimeRemainingText).font(Palette.body).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Battery Cycles").font(Palette.body)
                        Spacer()
                        Text("\(snap.battCycles)").font(Palette.body).foregroundStyle(.secondary)
                    }
                    if snap.systemLoadW > 0 || snap.adapterPowerW > 0 {
                        HStack {
                            Text("System Load").font(Palette.body)
                            Spacer()
                            Text(watts(snap.systemLoadW)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            toolbar
        }
        .frame(width: 256)
    }

    var batteryTimeRemainingText: String {
        if snap.charging {
            if snap.battMinutesRemaining > 0 {
                return formatMinutes(snap.battMinutesRemaining)
            }
            return snap.battCharge >= 0.99 ? "Charged" : "Charging…"
        }
        if snap.battMinutesRemaining > 0 {
            return formatMinutes(snap.battMinutesRemaining)
        }
        return "Calculating…"
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
                let pCores = snap.cores.filter { $0.name.contains("Performance") }
                let eCores = snap.cores.filter { $0.name.contains("Efficiency") }
                let maxCol = max(1, min(max(pCores.count, eCores.count), 6))
                let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: maxCol)

                if !pCores.isEmpty || !eCores.isEmpty {
                    if !pCores.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PERFORMANCE (%)")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: cols, spacing: 6) {
                                ForEach(pCores) { c in
                                    CoreGaugeCell(core: c, accent: pal.accent, track: pal.track)
                                }
                            }
                        }
                    }
                    if !eCores.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("EFFICIENCY (%)")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: cols, spacing: 6) {
                                ForEach(eCores) { c in
                                    CoreGaugeCell(core: c, accent: Color(red: 0.20, green: 0.78, blue: 0.45), track: pal.track)
                                }
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(snap.cores.count, 4)), spacing: 6) {
                        ForEach(snap.cores) { c in
                            CoreGaugeCell(core: c, accent: pal.accent, track: pal.track)
                        }
                    }
                }
            }
            Card("CPU USAGE", "square.grid.2x2", pal) {
                ForEach(snap.processes) { p in
                    HStack(spacing: 5) {
                        icon(p.icon)
                        HStack(spacing: 4) {
                            Text(p.name).font(Palette.body).lineLimit(1)
                            if p.count > 1 {
                                Text("\(p.count)")
                                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 0.5)
                                    .background(pal.track, in: Capsule())
                            }
                        }
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
                Sparkline(values: snap.ramHistory, color: pal.accent)
                    .frame(height: 38)
                Bar(snap.ramPressure, pal.accent, pal.track)
                HStack {
                    Text("Pressure").font(Palette.tiny).foregroundStyle(.secondary)
                    Spacer()
                    Text(pct0(snap.ramPressure)).font(Palette.tiny.monospacedDigit()).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 2)
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
                    "\(bytesGB(snap.ramSwapUsed)) / \(bytesGB(snap.ramSwapTotal))",
                    snap.ramSwapTotal == 0 ? 0 : Double(snap.ramSwapUsed) / Double(snap.ramSwapTotal),
                    pal
                )
            } headerTrailing: {
                HStack(spacing: 5) {
                    if let fb = app.cleanFeedback {
                        Text(fb)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.12), in: Capsule())
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    Button {
                        guard !app.cleaningRAM else { return }
                        app.cleaningRAM = true
                        app.cleanFeedback = nil
                        app.sampler.cleanRAM { freed in
                            app.cleaningRAM = false
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if freed >= 1024 * 1024 * 1024 {
                                    app.cleanFeedback = String(format: "Freed %.2f GB", Double(freed) / (1024 * 1024 * 1024))
                                } else if freed > 0 {
                                    app.cleanFeedback = "Freed \(freed / (1024 * 1024)) MB"
                                } else {
                                    app.cleanFeedback = "Optimized"
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    app.cleanFeedback = nil
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            TimelineView(.animation(minimumInterval: 0.016, paused: !app.cleaningRAM)) { tl in
                                let angle: Double = app.cleaningRAM ? (tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8) * 360.0 : 0.0
                                Image(systemName: app.cleaningRAM ? "arrow.triangle.2.circlepath" : "sparkles")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .rotationEffect(.degrees(angle))
                            }
                            Text(app.cleaningRAM ? "Cleaning..." : "Clean")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(app.cleaningRAM ? pal.accent : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pal.track.opacity(0.8), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Quick RAM Clean (evacuate purgeable caches)")
                }
            }
            Card("PROCESSES", "square.grid.2x2", pal) {
                ForEach(snap.memProcesses.prefix(app.prefs.ramProcCount)) { p in
                    HStack(spacing: 5) {
                        icon(p.icon)
                        HStack(spacing: 4) {
                            Text(p.name).font(Palette.body).lineLimit(1)
                            if p.count > 1 {
                                Text("\(p.count)")
                                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 0.5)
                                    .background(pal.track, in: Capsule())
                            }
                        }
                        Spacer()
                        Text(bytesGB(p.mem)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                        ProcessKillButton(process: p, app: app, pal: pal)
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
        Group {
            Card("STORAGE ACTIVITY", "externaldrive.connected.to.line.below", pal) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rate(snap.diskWrite)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        Text("Write").font(Palette.tiny).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(rate(snap.diskRead)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        Text("Read").font(Palette.tiny).foregroundStyle(.secondary)
                    }
                }
                NetChart(up: snap.diskWriteHistory, down: snap.diskReadHistory)
                    .frame(height: 48)
                HStack(spacing: 4) {
                    Circle().fill(NetChart.upCol).frame(width: 6, height: 6)
                    Text("Peak Write").font(Palette.tiny).foregroundStyle(.secondary)
                    Text(rate(snap.diskWritePeak)).font(Palette.tiny.monospacedDigit())
                    Spacer()
                    Circle().fill(NetChart.downCol).frame(width: 6, height: 6)
                    Text("Peak Read").font(Palette.tiny).foregroundStyle(.secondary)
                    Text(rate(snap.diskReadPeak)).font(Palette.tiny.monospacedDigit())
                }
            }
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
                    Text(snap.netInterface).font(Palette.tiny.monospaced()).foregroundStyle(.secondary)
                }
            }
            if snap.wifi {
                Card("WI-FI DETAILS", "wifi.badge.checkmark", pal) {
                    if snap.netSSID != "—" {
                        GeoInfoRow(icon: "network", title: "Network Name", value: snap.netSSID)
                    }
                    if snap.netBSSID != "—" {
                        GeoInfoRow(icon: "point.3.filled.connected.trianglepath.dotted", title: "BSSID", value: snap.netBSSID)
                    }
                    if snap.netRSSI != 0 {
                        let signalText = snap.netNoise != 0 ? "\(snap.netRSSI) dBm (Noise: \(snap.netNoise) dBm)" : "\(snap.netRSSI) dBm"
                        GeoInfoRow(icon: "waveform", title: "RSSI", value: signalText)
                    }
                    if snap.netChannel != "—" {
                        GeoInfoRow(icon: "antenna.radiowaves.left.and.right", title: "Channel", value: snap.netChannel)
                    }
                    if snap.netStandard != "—" {
                        GeoInfoRow(icon: "dot.radiowaves.left.and.right", title: "Standard", value: snap.netStandard)
                    }
                    if snap.netTxRate > 0 {
                        GeoInfoRow(icon: "arrow.up.right.circle", title: "Transmit Rate", value: "\(Int(round(snap.netTxRate))) Mbps")
                    }
                    GeoInfoRow(icon: "cable.connector.horizontal", title: "Interface", value: snap.netInterface)
                }
            }
            Card("ADDRESSES", "globe", pal) {
                // Local IPv4 pill
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .center)
                    Text("Local IPv4")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(snap.netIPv4)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(pal.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Public IPv4
                GeoInfoRow(icon: "globe", title: "Public IPv4", value: snap.netGeo.publicIPv4 != "—" ? snap.netGeo.publicIPv4 : snap.publicIP)

                // Location
                if snap.netGeo.location != "—" {
                    GeoInfoRow(icon: "map", title: "Location", value: snap.netGeo.location)
                }

                // GeoCoordinates
                if snap.netGeo.geoCoordinates != "—" {
                    GeoInfoRow(icon: "mappin.and.ellipse", title: "GeoCoordinates", value: snap.netGeo.geoCoordinates)
                }

                // Timezone
                if snap.netGeo.timezone != "—" {
                    GeoInfoRow(icon: "clock", title: "Timezone", value: snap.netGeo.timezone)
                }

                // AS
                if snap.netGeo.asName != "—" {
                    GeoInfoRow(icon: "point.3.filled.connected.trianglepath.dotted", title: "AS", value: snap.netGeo.asName)
                }

                // ISP
                if snap.netGeo.isp != "—" {
                    GeoInfoRow(icon: "antenna.radiowaves.left.and.right", title: "ISP", value: snap.netGeo.isp)
                }

                // Organization
                if snap.netGeo.organization != "—" {
                    GeoInfoRow(icon: "building.2", title: "Organization", value: snap.netGeo.organization)
                }

                if snap.netRouter != "—" {
                    Divider().padding(.vertical, 1)
                    HStack {
                        Text("Router").font(Palette.tiny).foregroundStyle(.secondary)
                        Spacer()
                        Text(snap.netRouter).font(Palette.tiny.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } headerTrailing: {
                Button {
                    guard !app.fetchingIP else { return }
                    app.fetchingIP = true
                    app.sampler.refreshPublicIP {
                        app.fetchingIP = false
                    }
                } label: {
                    TimelineView(.animation(minimumInterval: 0.016, paused: !app.fetchingIP)) { tl in
                        let angle: Double = app.fetchingIP ? (tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8) * 360.0 : 0.0
                        Image(systemName: app.fetchingIP ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(app.fetchingIP ? pal.accent : .secondary)
                            .rotationEffect(.degrees(angle))
                    }
                }
                .buttonStyle(.plain)
                .help("Refresh Public IP & Geolocation")
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
                Sparkline(values: snap.fanHistory, color: pal.accent)
                    .frame(height: 38)
                    .padding(.bottom, 2)
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
                HStack {
                    Text("Charge").font(Palette.body)
                    Spacer()
                    Text(pct0(snap.battCharge)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                    Bar(snap.battCharge, chargeColor(snap.battCharge), pal.track, charging: snap.charging).frame(width: 52)
                }
                HStack {
                    Text(snap.charging ? "Until Full" : "Time Left").font(Palette.body)
                    Spacer()
                    Text(batteryTimeRemainingText).font(Palette.body).foregroundStyle(.secondary)
                }
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
                if snap.systemLoadW > 0 || snap.adapterPowerW > 0 {
                    Divider().padding(.vertical, 2)
                    HStack {
                        Text("System Load").font(Palette.body)
                        Spacer()
                        Text(watts(snap.systemLoadW)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    PowerSankeyView(
                        adapterW: snap.adapterPowerW,
                        batteryW: snap.batteryPowerW,
                        systemW: snap.systemLoadW,
                        charging: snap.charging,
                        accent: pal.accent
                    )
                    .frame(height: 84)
                    .padding(.top, 2)
                }
            }
            Card("ENERGY", "bolt.fill", pal) {
                ForEach(snap.energyProcesses) { p in
                    HStack(spacing: 5) {
                        icon(p.icon)
                        HStack(spacing: 4) {
                            Text(p.name).font(Palette.body).lineLimit(1)
                            if p.count > 1 {
                                Text("\(p.count)")
                                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 0.5)
                                    .background(pal.track, in: Capsule())
                            }
                        }
                        Spacer()
                        Text(watts(p.energyW)).font(Palette.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var toolbar: some View {
        HStack(spacing: 4) {
            tool("waveform.path.ecg", "Activity Monitor") { App.shared.openUtil("Activity Monitor") }
            tool("terminal.fill", "Terminal") { App.shared.openUtil("Terminal") }
            Text(intervalLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(pal.track, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay { HoverPad(tip: "Refresh interval — click to cycle", captureHits: true, onClick: { App.shared.cycleInterval() }) }
                .help("Refresh interval — click to cycle")
                .accessibilityAddTraits(.isButton)
            tool(themeIcon, "Theme") { App.shared.cycleTheme() }
            awakeTool
            customTool(1)
            customTool(2)
            customTool(3)
            tool("gearshape.fill", "Settings") { app.openSettings() }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(pal.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func customTool(_ slot: Int) -> some View {
        let path = slot == 3 ? app.prefs.customApp3 : (slot == 2 ? app.prefs.customApp2 : app.prefs.customApp)
        let tip = path.isEmpty ? "Set toolbar app" : app.prefs.customAppName(slot: slot)
        return Group {
            if let img = app.prefs.customAppIcon(slot: slot) {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: 14, height: 14)
            } else {
                Image(systemName: "plus.app")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pal.track))
        .overlay { HoverPad(tip: tip, captureHits: true, onClick: { App.shared.openCustomApp(slot: slot) }) }
        .help(tip)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Choose App…") {
                App.shared.hideDrop()
                DispatchQueue.main.async { self.app.prefs.pickCustomApp(slot: slot) }
            }
            if !path.isEmpty {
                Button("Clear", role: .destructive) { app.prefs.clearCustomApp(slot: slot) }
            }
        }
    }

    var intervalLabel: String {
        let v = app.prefs.interval
        return v < 1 ? String(format: "%.1fs", v) : String(format: "%.0fs", v)
    }

    var themeIcon: String {
        switch app.theme {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "laptopcomputer"
        }
    }

    var awakeTool: some View {
        let active = app.isAwakeActive
        let tip: String
        if active {
            if let rem = app.awakeRemainingSeconds {
                let h = rem / 3600
                let m = (rem % 3600) / 60
                let s = rem % 60
                let tStr = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
                tip = "Awake: \(tStr) remaining (right-click options)"
            } else {
                tip = "Awake: Indefinite (right-click options)"
            }
        } else {
            tip = "Prevent Sleep (right-click for timer / options)"
        }
        return Image(systemName: active ? "cup.and.saucer.fill" : "cup.and.saucer")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(active ? pal.accent : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? pal.accent.opacity(0.18) : pal.track)
            )
            .overlay {
                HoverPad(tip: tip, selected: active, captureHits: true, onClick: {
                    app.toggleAwake()
                })
            }
            .help(tip)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Awake mode")
            .contextMenu {
                if active {
                    Button("Deactivate") {
                        app.stopAwake()
                    }
                    Divider()
                } else {
                    Button("Keep Awake Indefinitely") {
                        app.startAwake(duration: nil)
                    }
                }
                Menu("Keep Awake For…") {
                    Button("15 minutes") { app.startAwake(duration: 15 * 60) }
                    Button("30 minutes") { app.startAwake(duration: 30 * 60) }
                    Button("1 hour") { app.startAwake(duration: 60 * 60) }
                    Button("2 hours") { app.startAwake(duration: 2 * 60 * 60) }
                    Button("4 hours") { app.startAwake(duration: 4 * 60 * 60) }
                    Button("8 hours") { app.startAwake(duration: 8 * 60 * 60) }
                }
                Divider()
                Toggle("Prevent Display Sleep", isOn: Binding(
                    get: { app.preventDisplaySleep },
                    set: { app.setPreventDisplaySleep($0) }
                ))
            }
    }

    func tool(_ name: String, _ tip: String, selected: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint ?? (selected ? pal.accent : Color.primary.opacity(0.75)))
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? pal.accent.opacity(0.12) : pal.track)
            )
            .overlay { HoverPad(tip: tip, selected: selected, captureHits: true, onClick: action) }
            .help(tip)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(tip)
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

struct GeoInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct ProcessKillButton: View {
    let process: ProcSample
    @ObservedObject var app: App
    let pal: Palette

    var isConfirming: Bool {
        app.confirmingKillPid == process.id
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                if isConfirming {
                    app.confirmingKillPid = nil
                    app.quitPids(process.pids.isEmpty ? [process.id] : process.pids)
                } else {
                    app.confirmingKillPid = process.id
                }
            }
        } label: {
            HStack(spacing: 3) {
                if isConfirming {
                    Text("Kill")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, isConfirming ? 7 : 0)
            .padding(.vertical, isConfirming ? 2.5 : 0)
            .background(
                isConfirming ? Color.red : Color.clear,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(isConfirming ? "Click again to terminate \(process.name)" : "Kill \(process.name)")
    }
}

struct Card<Content: View, HeaderTrailing: View>: View {
    let title: String
    let symbol: String
    let pal: Palette
    var panel: App.Panel?
    var active: Bool
    let headerTrailing: HeaderTrailing?
    let content: Content

    init(
        _ title: String,
        _ symbol: String,
        _ pal: Palette,
        panel: App.Panel? = nil,
        active: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder headerTrailing: () -> HeaderTrailing
    ) {
        self.title = title
        self.symbol = symbol
        self.pal = pal
        self.panel = panel
        self.active = active
        self.content = content()
        self.headerTrailing = headerTrailing()
    }

    init(
        _ title: String,
        _ symbol: String,
        _ pal: Palette,
        panel: App.Panel? = nil,
        active: Bool = false,
        @ViewBuilder content: () -> Content
    ) where HeaderTrailing == EmptyView {
        self.title = title
        self.symbol = symbol
        self.pal = pal
        self.panel = panel
        self.active = active
        self.content = content()
        self.headerTrailing = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .textCase(.uppercase)
                    .tracking(0.3)
                if let headerTrailing {
                    Spacer()
                    headerTrailing
                }
            }
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? pal.cardHover : pal.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { if let panel { ScreenFrame(id: panel) } }
    }
}

struct CoreGaugeCell: View {
    let core: CoreSample
    let accent: Color
    let track: Color

    var shortName: String {
        if core.name.hasPrefix("Performance Core #") {
            return "P" + core.name.replacingOccurrences(of: "Performance Core #", with: "")
        } else if core.name.hasPrefix("Efficiency Core #") {
            return "E" + core.name.replacingOccurrences(of: "Efficiency Core #", with: "")
        } else if core.name.hasPrefix("Core #") {
            return core.name.replacingOccurrences(of: "Core #", with: "")
        }
        return "\(core.id + 1)"
    }

    var body: some View {
        VStack(spacing: 2.5) {
            ZStack {
                Circle()
                    .stroke(track, lineWidth: 2.8)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0.001, core.usage))))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text(String(format: "%.0f", core.usage * 100))
                    .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 32, height: 32)

            Text(shortName)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help("\(core.name): \(Int(round(core.usage * 100)))%")
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
    var charging: Bool = false
    init(_ frac: Double, _ fill: Color, _ track: Color, charging: Bool = false) {
        self.frac = frac; self.fill = fill; self.track = track; self.charging = charging
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016, paused: !charging)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let cycle = 2.4
            // primary shimmer: 2.4s calm sweep
            let phase1 = CGFloat(t.truncatingRemainder(dividingBy: cycle) / cycle)
            // secondary shimmer: offset by half period
            let phase2 = CGFloat((t + cycle * 0.5).truncatingRemainder(dividingBy: cycle) / cycle)
            let center1 = -0.30 + phase1 * 1.60
            let center2 = -0.30 + phase2 * 1.60
            // glow pulse: calm 2.4s breathe
            let glow = charging ? CGFloat(0.5 + 0.5 * sin(t * .pi * 2.0 / cycle)) : 0
            GeometryReader { g in
                let filled = max(0, g.size.width * CGFloat(min(1, max(0, frac))))
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    // glow backing when charging
                    if charging && filled > 0 {
                        Capsule()
                            .fill(fill.opacity(0.25 * glow))
                            .frame(width: filled)
                            .blur(radius: 3)
                    }
                    Capsule().fill(fill).frame(width: filled)
                    // primary & secondary seamless shimmer
                    if charging && filled > 0 {
                        let hw1: CGFloat = 0.22
                        Capsule()
                            .fill(LinearGradient(stops: [
                                .init(color: .clear, location: center1 - hw1),
                                .init(color: Color.white.opacity(0.55), location: center1),
                                .init(color: .clear, location: center1 + hw1),
                            ], startPoint: .leading, endPoint: .trailing))
                            .frame(width: filled)
                            .blendMode(.plusLighter)
                        let hw2: CGFloat = 0.25
                        Capsule()
                            .fill(LinearGradient(stops: [
                                .init(color: .clear, location: center2 - hw2),
                                .init(color: Color.white.opacity(0.25), location: center2),
                                .init(color: .clear, location: center2 + hw2),
                            ], startPoint: .leading, endPoint: .trailing))
                            .frame(width: filled)
                            .blendMode(.plusLighter)
                    }
                }
            }
            .frame(height: 4)
        }
    }
}

struct CPULoadBar: NSViewRepresentable {
    var user: Double
    var system: Double
    var accent: NSColor
    var track: NSColor
    func makeNSView(context: Context) -> CPULoadView {
        let v = CPULoadView()
        v.user = user; v.system = system; v.accent = accent; v.track = track
        v.frost = Prefs.shared.frostMaterial
        v.stroke = Prefs.shared.strokeNS
        return v
    }
    func updateNSView(_ v: CPULoadView, context: Context) {
        v.user = user; v.system = system; v.accent = accent; v.track = track
        v.frost = Prefs.shared.frostMaterial
        v.stroke = Prefs.shared.strokeNS
        v.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CPULoadView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 200, height: 8)
    }
}

final class CPULoadView: NSView {
    var user = 0.0
    var system = 0.0
    var accent = NSColor.systemBlue
    var track = NSColor.white.withAlphaComponent(0.12)
    var frost = NSVisualEffectView.Material.hudWindow
    var stroke = NSColor.labelColor.withAlphaComponent(0.22)
    private var hover = 0 { didSet { if oldValue != hover { needsDisplay = true; updateTip() } } }
    private var tip: NSPanel?
    private let tipFrost: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }()
    private let tipLab: NSTextField = {
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 12, weight: .regular)
        t.textColor = .secondaryLabelColor
        t.drawsBackground = false
        t.isBordered = false
        t.alignment = .center
        return t
    }()
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }
    override func layout() {
        super.layout()
        updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        hover = seg(at: x)
    }
    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) { hover = 0 }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideTip() }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit { hideTip() }
    private func seg(at x: CGFloat) -> Int {
        let w = max(bounds.width, 1)
        let u = CGFloat(min(1, max(0, user))) * w
        let s = CGFloat(min(1, max(0, system))) * w
        if x < u { return 1 }
        if x < u + s { return 2 }
        return 3
    }
    private func hideTip() {
        tip?.orderOut(nil)
    }
    private func updateTip() {
        guard hover != 0, let win = window else { hideTip(); return }
        let u = Int((user * 100).rounded())
        let s = Int((system * 100).rounded())
        let i = max(0, 100 - u - s)
        let text: String
        switch hover {
        case 1: text = "User \(u)%"
        case 2: text = "System \(s)%"
        default: text = "Idle \(i)%"
        }
        tipLab.stringValue = text
        tipLab.sizeToFit()
        let padX: CGFloat = 10
        let padY: CGFloat = 5
        let sz = NSSize(width: tipLab.frame.width + padX * 2, height: tipLab.frame.height + padY * 2)
        tipLab.frame = NSRect(x: padX, y: padY, width: tipLab.frame.width, height: tipLab.frame.height)
        tipFrost.material = frost
        let px = 1 / (window?.backingScaleFactor ?? 2)
        tipFrost.layer?.borderWidth = px
        tipFrost.layer?.borderColor = stroke.cgColor
        if tip == nil {
            tipFrost.addSubview(tipLab)
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: sz),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = tipFrost
            tip = p
        }
        tipFrost.frame = NSRect(origin: .zero, size: sz)
        tip?.setContentSize(sz)
        tip?.level = NSWindow.Level(rawValue: win.level.rawValue + 1)
        let uw = CGFloat(min(1, max(0, user))) * bounds.width
        let sw = CGFloat(min(1, max(0, system))) * bounds.width
        let mid: CGFloat
        switch hover {
        case 1: mid = uw / 2
        case 2: mid = uw + sw / 2
        default: mid = uw + sw + max(0, bounds.width - uw - sw) / 2
        }
        let top = NSPoint(x: mid, y: isFlipped ? 0 : bounds.height)
        let inWin = convert(top, to: nil)
        let scr = win.convertToScreen(NSRect(origin: inWin, size: .zero)).origin
        let x = scr.x - sz.width / 2
        let y = scr.y + 8
        tip?.setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true)
        tip?.orderFrontRegardless()
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let rad = r.height / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).addClip()
        track.setFill(); r.fill()
        let u = CGFloat(min(1, max(0, user))) * r.width
        let s = CGFloat(min(1, max(0, system))) * r.width
        accent.withAlphaComponent(0.45).setFill()
        NSRect(x: r.minX, y: r.minY, width: u + s, height: r.height).fill()
        accent.setFill()
        NSRect(x: r.minX, y: r.minY, width: u, height: r.height).fill()
        if hover != 0 {
            NSColor.white.withAlphaComponent(0.28).setFill()
            let x0: CGFloat
            let w: CGFloat
            switch hover {
            case 1: x0 = r.minX; w = u
            case 2: x0 = r.minX + u; w = s
            default: x0 = r.minX + u + s; w = r.width - u - s
            }
            NSRect(x: x0, y: r.minY, width: max(w, 0), height: r.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
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

private func chargeColor(_ v: Double) -> Color {
    let clamped = min(1.0, max(0.0, v))
    if clamped < 0.20 {
        return Color(red: 0.95, green: 0.24, blue: 0.24)
    } else if clamped < 0.50 {
        let t = (clamped - 0.20) / 0.30
        return Color(red: 0.95, green: 0.24 + 0.56 * t, blue: 0.20)
    } else {
        let t = (clamped - 0.50) / 0.50
        return Color(red: 0.95 * (1.0 - t) + 0.22 * t, green: 0.80 + (0.78 - 0.80) * t, blue: 0.20 * (1.0 - t) + 0.40 * t)
    }
}

private func formatMinutes(_ m: Int) -> String {
    if m <= 0 { return "Calculating…" }
    let h = m / 60
    let mins = m % 60
    if h > 0 {
        return String(format: "%dh %02dm", h, mins)
    }
    return String(format: "%dm", mins)
}

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
// MARK: - Power Sankey

struct PowerSankeyView: View {
    let adapterW: Double
    let batteryW: Double  // positive = charging, negative = discharging
    let systemW: Double
    let charging: Bool
    let accent: Color

    // Apple-grade palette colors
    private static let blueStart   = Color(red: 0.12, green: 0.52, blue: 0.98) // Apple system blue
    private static let blueEnd     = Color(red: 0.28, green: 0.68, blue: 1.00)
    private static let greenStart  = Color(red: 0.16, green: 0.78, blue: 0.42) // Apple emerald
    private static let greenEnd    = Color(red: 0.28, green: 0.92, blue: 0.56) // Bright electric emerald
    private static let orangeStart = Color(red: 1.00, green: 0.56, blue: 0.00) // Apple orange
    private static let orangeEnd   = Color(red: 1.00, green: 0.72, blue: 0.18)

    var body: some View {
        let (srcTitle, srcSymbol, srcWatts, sysWatts, chgWatts) = computeData()

        HStack(spacing: 8) {
            // Left column: Source (Adapter / Battery)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    Text(srcTitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: srcSymbol)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(charging ? Self.greenStart : Self.orangeStart)
                }
                Text(srcWatts)
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 58, height: 68, alignment: .trailing)

            // Flow Ribbons with smooth curves & luminous animation
            TimelineView(.animation(minimumInterval: 0.016, paused: !charging)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ribbonsCanvas(time: t)
            }

            // Right column: Sinks (System, and optional Charging)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Self.blueStart)
                        Text("System")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(sysWatts)
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }

                if charging && batteryW > 0 {
                    Spacer(minLength: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Self.greenStart)
                            Text("Charging")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(chgWatts)
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(width: 62, height: 68, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }

    private func computeData() -> (String, String, String, String, String) {
        let srcW = charging ? (adapterW > 0 ? adapterW : systemW) : (systemW > 0 ? systemW : abs(batteryW))
        let srcTitle = charging ? "Adapter" : "Battery"
        let srcSymbol = charging ? "powerplug.fill" : "battery.100"
        let chgW = (charging && batteryW > 0) ? batteryW : 0.0
        return (srcTitle, srcSymbol, watts(srcW), watts(max(systemW, 0.5)), watts(chgW))
    }

    // ponytail: 2-sink partition (system + charging) with dual-phase additive shimmer & specular edge glint
    private func ribbonsCanvas(time: Double) -> some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            let pillW: CGFloat = 4.5
            let srcX: CGFloat = 2
            let dstX: CGFloat = max(2, W - pillW - 2)

            let sourceW = charging ? (adapterW > 0 ? adapterW : systemW) : (systemW > 0 ? systemW : abs(batteryW))
            let sysW = max(systemW, 0.5)
            let chargeW = (charging && batteryW > 0) ? batteryW : 0.0
            let totalSink = sysW + chargeW
            let total = max(sourceW, totalSink, 0.5)

            let maxRibbonH: CGFloat = min(H * 0.76, 56)

            let srcH = max(6, CGFloat(sourceW / total) * maxRibbonH)
            let sysH = max(5, CGFloat(sysW / total) * maxRibbonH)
            let chgH = chargeW > 0 ? max(5, CGFloat(chargeW / total) * maxRibbonH) : 0

            let srcMidY = H / 2
            let srcTop  = srcMidY - srcH / 2
            let srcBot  = srcMidY + srcH / 2

            // Right side distribution with smooth gap
            let gap: CGFloat = chgH > 0 ? 6.0 : 0
            let totalRightH = sysH + chgH + gap
            let rightTop = H / 2 - totalRightH / 2
            let sysTop = rightTop
            let sysBot = sysTop + sysH
            let chgTop = chgH > 0 ? sysBot + gap : sysBot
            let chgBot = chgTop + chgH

            // Source split: proportional to sinks to avoid overflow or gap
            let sysRatio = totalSink > 0 ? CGFloat(sysW / totalSink) : 1.0
            let sysSliceH = chgH > 0 ? min(srcH - 3, max(3, srcH * sysRatio)) : srcH

            let x0 = srcX + pillW
            let x1 = dstX
            let midX = (x0 + x1) * 0.5

            // Helper for monotonic horizontal-tangent S-curve
            func addSCurve(to path: inout Path, from p0: CGPoint, to p1: CGPoint) {
                path.addCurve(to: p1,
                              control1: CGPoint(x: midX, y: p0.y),
                              control2: CGPoint(x: midX, y: p1.y))
            }

            // Smooth cubic ribbon generator
            func makeRibbon(srcY0: CGFloat, srcY1: CGFloat, dstY0: CGFloat, dstY1: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: x0, y: srcY0))
                p.addCurve(to: CGPoint(x: x1, y: dstY0),
                           control1: CGPoint(x: midX, y: srcY0),
                           control2: CGPoint(x: midX, y: dstY0))
                p.addLine(to: CGPoint(x: x1, y: dstY1))
                p.addCurve(to: CGPoint(x: x0, y: srcY1),
                           control1: CGPoint(x: midX, y: dstY1),
                           control2: CGPoint(x: midX, y: srcY1))
                p.closeSubpath()
                return p
            }

            // 1. System Ribbon
            let sysPath = makeRibbon(srcY0: srcTop, srcY1: srcTop + sysSliceH, dstY0: sysTop, dstY1: sysBot)
            let sysSourceCol = charging ? Self.greenStart : Self.orangeStart
            let sysGrad = Gradient(colors: [
                sysSourceCol.opacity(0.30),
                Self.blueEnd.opacity(0.42)
            ])
            ctx.fill(sysPath, with: .linearGradient(sysGrad, startPoint: CGPoint(x: x0, y: srcMidY), endPoint: CGPoint(x: x1, y: (sysTop + sysBot)/2)))

            // Top specular highlight on System ribbon
            var sysTopLine = Path()
            sysTopLine.move(to: CGPoint(x: x0, y: srcTop))
            addSCurve(to: &sysTopLine, from: CGPoint(x: x0, y: srcTop), to: CGPoint(x: x1, y: sysTop))
            let sysTopGrad = Gradient(colors: [sysSourceCol.opacity(0.60), Self.blueEnd.opacity(0.70)])
            ctx.stroke(sysTopLine, with: .linearGradient(sysTopGrad, startPoint: CGPoint(x: x0, y: srcTop), endPoint: CGPoint(x: x1, y: sysTop)), style: StrokeStyle(lineWidth: 1.0))

            // Bottom edge line on System ribbon
            var sysBotLine = Path()
            sysBotLine.move(to: CGPoint(x: x0, y: srcTop + sysSliceH))
            addSCurve(to: &sysBotLine, from: CGPoint(x: x0, y: srcTop + sysSliceH), to: CGPoint(x: x1, y: sysBot))
            ctx.stroke(sysBotLine, with: .color(Self.blueEnd.opacity(0.25)), style: StrokeStyle(lineWidth: 0.6))

            // 2. Charging Ribbon & Luminous Shimmer
            if chgH > 0 {
                let chgPath = makeRibbon(srcY0: srcTop + sysSliceH, srcY1: srcBot, dstY0: chgTop, dstY1: chgBot)
                let chgGrad = Gradient(colors: [
                    Self.greenStart.opacity(0.36),
                    Self.greenEnd.opacity(0.50)
                ])
                ctx.fill(chgPath, with: .linearGradient(chgGrad, startPoint: CGPoint(x: x0, y: srcMidY), endPoint: CGPoint(x: x1, y: (chgTop + chgBot)/2)))

                // Top specular highlight on Charging ribbon
                var chgTopLine = Path()
                chgTopLine.move(to: CGPoint(x: x0, y: srcTop + sysSliceH))
                addSCurve(to: &chgTopLine, from: CGPoint(x: x0, y: srcTop + sysSliceH), to: CGPoint(x: x1, y: chgTop))
                let chgTopGrad = Gradient(colors: [Self.greenStart.opacity(0.65), Self.greenEnd.opacity(0.80)])
                ctx.stroke(chgTopLine, with: .linearGradient(chgTopGrad, startPoint: CGPoint(x: x0, y: srcTop + sysSliceH), endPoint: CGPoint(x: x1, y: chgTop)), style: StrokeStyle(lineWidth: 1.0))

                // Bottom highlight sheen on Charging ribbon
                var chgBotLine = Path()
                chgBotLine.move(to: CGPoint(x: x0, y: srcBot))
                addSCurve(to: &chgBotLine, from: CGPoint(x: x0, y: srcBot), to: CGPoint(x: x1, y: chgBot))
                ctx.stroke(chgBotLine, with: .color(Self.greenEnd.opacity(0.35)), style: StrokeStyle(lineWidth: 0.7))

                // Luminous shimmering pulse wave sweeping along charging ribbon
                if charging {
                    let cycle = 2.4
                    let p1 = CGFloat(time.truncatingRemainder(dividingBy: cycle) / cycle)
                    let p2 = CGFloat((time + cycle * 0.5).truncatingRemainder(dividingBy: cycle) / cycle)
                    let flowStart = CGPoint(x: x0, y: (srcTop + sysSliceH + srcBot) * 0.5)
                    let flowEnd   = CGPoint(x: x1, y: (chgTop + chgBot) * 0.5)

                    // Primary luminous wave
                    let c1 = -0.30 + p1 * 1.60
                    let hw1: CGFloat = 0.22
                    let waveGrad1 = Gradient(stops: [
                        .init(color: .clear, location: c1 - hw1),
                        .init(color: Color(red: 0.40, green: 1.0, blue: 0.65).opacity(0.35), location: c1 - hw1 * 0.5),
                        .init(color: Color.white.opacity(0.85), location: c1),
                        .init(color: Color(red: 0.40, green: 1.0, blue: 0.65).opacity(0.35), location: c1 + hw1 * 0.5),
                        .init(color: .clear, location: c1 + hw1)
                    ])

                    // Secondary trailing softer wave
                    let c2 = -0.30 + p2 * 1.60
                    let hw2: CGFloat = 0.30
                    let waveGrad2 = Gradient(stops: [
                        .init(color: .clear, location: c2 - hw2),
                        .init(color: Self.greenEnd.opacity(0.30), location: c2 - hw2 * 0.5),
                        .init(color: Color.white.opacity(0.40), location: c2),
                        .init(color: Self.greenEnd.opacity(0.30), location: c2 + hw2 * 0.5),
                        .init(color: .clear, location: c2 + hw2)
                    ])

                    // Specular highlight glint along the top curve
                    let glintGrad = Gradient(stops: [
                        .init(color: .clear, location: c1 - hw1 * 0.7),
                        .init(color: Color.white.opacity(0.95), location: c1),
                        .init(color: .clear, location: c1 + hw1 * 0.7)
                    ])

                    ctx.drawLayer { shimmer in
                        shimmer.blendMode = .plusLighter
                        shimmer.fill(chgPath, with: .linearGradient(waveGrad1, startPoint: flowStart, endPoint: flowEnd))
                        shimmer.fill(chgPath, with: .linearGradient(waveGrad2, startPoint: flowStart, endPoint: flowEnd))
                        shimmer.stroke(chgTopLine, with: .linearGradient(glintGrad, startPoint: CGPoint(x: x0, y: srcTop + sysSliceH), endPoint: CGPoint(x: x1, y: chgTop)), style: StrokeStyle(lineWidth: 1.4))
                    }
                }
            }

            // 3. Apple-style rounded pill nodes with specular sheen & ambient glow
            let srcPill = CGRect(x: srcX, y: srcTop, width: pillW, height: srcH)
            let sysPill = CGRect(x: dstX, y: sysTop, width: pillW, height: sysH)
            let srcCol = charging ? Self.greenStart : Self.orangeStart

            // Ambient glow behind active nodes
            if charging {
                ctx.drawLayer { g in
                    g.blendMode = .plusLighter
                    g.addFilter(.blur(radius: 3.0))
                    g.fill(Path(roundedRect: srcPill, cornerRadius: pillW / 2), with: .color(srcCol.opacity(0.40)))
                    if chgH > 0 {
                        let chgPill = CGRect(x: dstX, y: chgTop, width: pillW, height: chgH)
                        let breathe = CGFloat(0.35 + 0.15 * sin(time * .pi * 2.0 / 1.8))
                        g.fill(Path(roundedRect: chgPill, cornerRadius: pillW / 2), with: .color(Self.greenEnd.opacity(breathe)))
                    }
                }
            }

            // Node fills: vertical linear gradients
            ctx.fill(
                Path(roundedRect: srcPill, cornerRadius: pillW / 2),
                with: .linearGradient(Gradient(colors: [srcCol, srcCol.opacity(0.80)]), startPoint: CGPoint(x: 0, y: srcTop), endPoint: CGPoint(x: 0, y: srcBot))
            )
            ctx.stroke(Path(roundedRect: srcPill, cornerRadius: pillW / 2), with: .color(Color.white.opacity(0.30)), style: StrokeStyle(lineWidth: 0.5))

            ctx.fill(
                Path(roundedRect: sysPill, cornerRadius: pillW / 2),
                with: .linearGradient(Gradient(colors: [Self.blueEnd, Self.blueStart]), startPoint: CGPoint(x: 0, y: sysTop), endPoint: CGPoint(x: 0, y: sysBot))
            )
            ctx.stroke(Path(roundedRect: sysPill, cornerRadius: pillW / 2), with: .color(Color.white.opacity(0.30)), style: StrokeStyle(lineWidth: 0.5))

            if chgH > 0 {
                let chgPill = CGRect(x: dstX, y: chgTop, width: pillW, height: chgH)
                ctx.fill(
                    Path(roundedRect: chgPill, cornerRadius: pillW / 2),
                    with: .linearGradient(Gradient(colors: [Self.greenEnd, Self.greenStart]), startPoint: CGPoint(x: 0, y: chgTop), endPoint: CGPoint(x: 0, y: chgBot))
                )
                ctx.stroke(Path(roundedRect: chgPill, cornerRadius: pillW / 2), with: .color(Color.white.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5))
            }
        }
    }
}

private func watts(_ w: Double) -> String {
    if w < 1 { return String(format: "%.0f mW", w * 1000) }
    return String(format: "%.2f W", w)
}
