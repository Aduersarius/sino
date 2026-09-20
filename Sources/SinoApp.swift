import AppKit
import Carbon
import Combine
import IOKit.pwr_mgt
import SwiftUI

@main
enum Sino {
    static func main() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lov3u.sino"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }

        if !siblings.isEmpty {
            // Already running: activate existing instance and exit
            if #available(macOS 14.0, *) {
                siblings.first?.activate()
            } else {
                siblings.first?.activate(options: [.activateIgnoringOtherApps])
            }
            exit(0)
        }

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
    @Published var lowPowerMode = false
    @Published var lpmBusy = false
    @Published var fetchingIP = false
    @Published var confirmingKillPid: pid_t? = nil
    @Published var vanish: [pid_t: Date] = [:]
    @Published var vanishGhosts: [pid_t: ProcSample] = [:]
    @Published var killedIds: Set<pid_t> = []
    @Published var procQuery = ""
    @Published var procSearchFocused = false
    var activeKillButton: NSView?
    @Published var isAwakeActive = false
    @Published var awakeRemainingSeconds: Int? = nil // nil = indefinite
    @Published var fanMode: FanMode = .auto
    @Published var fanTargets: [Int: Double] = [:]
    @Published var fanCtlBusy = false
    private var fanHold: Timer?
    private var awakeAssertionID: IOPMAssertionID = 0
    private var awakeTimer: Timer? = nil
    enum Panel: String, Equatable, CaseIterable { case cpu, ram, storage, net, fans, battery, gpu }
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
    private var dropClickMon: Any?
    private var flashTimer: Timer?
    private var catchers: [NSPanel] = []
    private var hoverMon: Any?
    var settingsWC: NSWindowController?
    var onboardingWC: NSWindowController?
    private var dropOpen = false
    private var ignoreClicksUntil = Date.distantPast
    private var lastDark = false
    private var appearObs: NSKeyValueObservation?
    private var lastChips: [MenuChip] = []
    private var catTimer: Timer?
    private var lastCatFrame = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        lastDark = currentScheme == .dark
        refreshLowPowerMode()
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLowPowerMode()
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--render-settings-png"), idx + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if let w = self?.settingsWC?.window, let view = w.contentView {
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: out))
                        print("Saved to \(out)")
                    }
                }
                exit(0)
            }
            return
        } else if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.openSettings()
            }
        }
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
            self?.stopAwake(resetPMSet: true, sync: true)
            self?.releaseFans()
        }
        if PMSetHelper.isSleepDisabled {
            DispatchQueue.global(qos: .utility).async {
                PMSetHelper.setSleepDisabled(false)
            }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        extra = ExtraView(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
        // ponytail: chips live in button.image so NSStatusBarButton.highlight is visible
        barClickMon = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] e in
            guard let self, let button = self.item.button, e.window == button.window else { return e }
            let p = button.convert(e.locationInWindow, from: nil)
            guard button.bounds.contains(p) else { return e }
            if e.type == .rightMouseDown {
                if self.prefs.rightClickAwake {
                    self.toggleAwakeWithFlash()
                    return nil
                }
                return e
            }
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
        if !prefs.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openOnboarding()
            }
        }
    }

    var currentScheme: ColorScheme {
        if theme == "light" { return .light }
        if theme == "dark" { return .dark }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    func makeGlass(_ vc: NSViewController, size: NSSize) -> NSPanel {
        vc.view.wantsLayer = true
        vc.view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
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
        p.backgroundColor = NSColor.black.withAlphaComponent(1.0 / 255.0)
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
        extra.catAnimated = true
        armCatAnim()
        let h = max(button.bounds.height, 22)
        let w = extra.fittingWidth
        if abs(extra.frame.width - w) > 0.5 || abs(extra.frame.height - h) > 0.5 {
            extra.frame = NSRect(origin: .zero, size: NSSize(width: w, height: h))
        }
        let len = w
        if abs(item.length - len) > 0.5 {
            item.length = len
        }
        let catF = extra.catFrame
        if chips != lastChips || (prefs.bar.contains("cat") && catF != lastCatFrame) || button.image == nil || extra.flashAlpha > 0 {
            lastChips = chips
            lastCatFrame = catF
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.image = extra.makeImage()
            }
        }
        if dropOpen { holdHighlight() } else {
            button.isHighlighted = false
            button.highlight(false)
        }
        if dropOpen {
            if !killedIds.isEmpty {
                let live = Set(sampler.snap.memProcesses.map(\.id))
                killedIds = killedIds.filter { live.contains($0) }
            }
            sizePopover()
        }
    }

    func armCatAnim() {
        let on = prefs.bar.contains("cat")
        if on {
            guard catTimer == nil else { return }
            let t = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                self?.tickCat()
            }
            RunLoop.main.add(t, forMode: .common)
            catTimer = t
        } else {
            catTimer?.invalidate()
            catTimer = nil
            extra.catTick = 0
        }
    }

    func tickCat() {
        extra.catTick += 1
        guard let button = item?.button else { return }
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = extra.makeImage()
        }
        if dropOpen { holdHighlight() }
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

    func releaseFans() {
        fanHold?.invalidate()
        fanHold = nil
        fanMode = .auto
        fanTargets = [:]
        sino_fan_ctl_auto()
        sino_fan_ctl_close()
    }

    func setFanManual(_ on: Bool) {
        setFanMode(on ? .manual : .auto)
    }

    func setFanMode(_ mode: FanMode) {
        if fanCtlBusy { return }
        if mode == .auto {
            releaseFans()
            return
        }
        if sino_fan_ctl_open() == 0 {
            armFans(mode)
            return
        }
        fanCtlBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = FanCtl.install() && sino_fan_ctl_open() == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.fanCtlBusy = false
                if ok { self.armFans(mode) }
            }
        }
    }

    private func armFans(_ mode: FanMode) {
        fanMode = mode
        if mode == .manual {
            for f in sampler.snap.fans {
                let t = fanTargets[f.id] ?? f.rpm
                fanTargets[f.id] = t
            }
        }
        fanHold?.invalidate()
        fanHold = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.reassertFans()
        }
        reassertFans()
    }

    func setFanTarget(_ id: Int, _ rpm: Double) {
        guard fanMode == .manual else { return }
        fanTargets[id] = rpm
        _ = sino_fan_ctl_set(Int32(id), Float(rpm))
    }

    func hottestTemp() -> Double {
        sampler.snap.temps.map(\.c).max() ?? 0
    }

    func curveTarget() -> Double {
        FanCurves.rpm(hottestTemp(), prefs.fanCurve)
    }

    func reassertFans() {
        switch fanMode {
        case .auto: return
        case .manual:
            for (id, rpm) in fanTargets {
                if sino_fan_ctl_set(Int32(id), Float(rpm)) != 0 { break }
            }
        case .curve:
            let rpm = curveTarget()
            for f in sampler.snap.fans {
                fanTargets[f.id] = rpm
                if sino_fan_ctl_set(Int32(f.id), Float(rpm)) != 0 { break }
            }
        }
    }

    func menuChips() -> [MenuChip] {
        let s = sampler.snap
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
            case "cat":
                return MenuChip(label: "CAT", value: "", isCat: true)
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
        host.view.layoutSubtreeIfNeeded()
        var h = host.view.fittingSize.height
        if h < 80 { h = 120 }
        h = min(h, 780)
        positionDrop(NSSize(width: 268, height: h))
        for c in catchers { drop.order(.above, relativeTo: c.windowNumber) }
        refreshCardFrames(host.view)
        if dropOpen { pickHover() }
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
        let next = NSRect(x: x, y: y, width: w, height: h)
        let f = detail.frame
        if abs(f.minX - next.minX) > 0.5 || abs(f.minY - next.minY) > 0.5
            || abs(f.width - next.width) > 1 || abs(f.height - next.height) > 2 {
            detail.setFrame(next, display: true)
        }
        if !detail.isVisible { detail.orderFrontRegardless() }
        for c in catchers { detail.order(.above, relativeTo: c.windowNumber) }
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

    func toggleAwakeWithFlash() {
        toggleAwake()
        flashMenuBarItem(active: isAwakeActive)
    }

    func flashMenuBarItem(active: Bool) {
        flashTimer?.invalidate()
        flashTimer = nil
        let color = active
            ? NSColor(srgbRed: 0.20, green: 0.82, blue: 0.38, alpha: 1.0) // ON: Green
            : NSColor(srgbRed: 1.00, green: 0.32, blue: 0.30, alpha: 1.0) // OFF: Red
        extra?.flashColor = color
        extra?.flashAlpha = 1.0

        if let button = item?.button {
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.image = extra?.makeImage()
            }
        }

        let startTime = Date()
        let duration: TimeInterval = 0.35
        if let button = item?.button {
            button.isHighlighted = true
            button.highlight(true)
        }
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self, let extra = self.extra, let button = self.item?.button else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= duration {
                timer.invalidate()
                self.flashTimer = nil
                extra.flashAlpha = 0
                extra.flashColor = nil
                if !self.dropOpen {
                    button.isHighlighted = false
                    button.highlight(false)
                }
                button.effectiveAppearance.performAsCurrentDrawingAppearance {
                    button.image = extra.makeImage()
                }
            } else {
                extra.flashAlpha = CGFloat(1.0 - (elapsed / duration))
                button.effectiveAppearance.performAsCurrentDrawingAppearance {
                    button.image = extra.makeImage()
                }
            }
        }
        if let flashTimer {
            RunLoop.main.add(flashTimer, forMode: .common)
        }
    }
    func toggleAwake(duration: TimeInterval? = nil) {
        if isAwakeActive {
            stopAwake()
        } else {
            startAwake(duration: duration)
        }
    }

    var preventDisplaySleep: Bool {
        get { prefs.preventDisplaySleep }
        set { setPreventDisplaySleep(newValue) }
    }

    var preventLidSleep: Bool {
        get { prefs.preventLidSleep }
        set { setPreventLidSleep(newValue) }
    }

    func startAwake(duration: TimeInterval? = nil) {
        stopAwake(resetPMSet: false)
        let type = prefs.preventDisplaySleep ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
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
            if prefs.preventLidSleep {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let ok = PMSetHelper.setSleepDisabled(true)
                    if !ok {
                        DispatchQueue.main.async {
                            self?.prefs.setPreventLidSleep(false)
                        }
                    }
                }
            }
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

    func stopAwake(resetPMSet: Bool = true, sync: Bool = false) {
        awakeTimer?.invalidate()
        awakeTimer = nil
        awakeRemainingSeconds = nil
        if awakeAssertionID != 0 {
            IOPMAssertionRelease(awakeAssertionID)
            awakeAssertionID = 0
        }
        if resetPMSet && (prefs.preventLidSleep || PMSetHelper.isSleepDisabled) {
            if sync {
                PMSetHelper.setSleepDisabled(false)
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    PMSetHelper.setSleepDisabled(false)
                }
            }
        }
        isAwakeActive = false
    }

    func setPreventDisplaySleep(_ prevent: Bool) {
        prefs.setPreventDisplaySleep(prevent)
        if isAwakeActive {
            let dur: TimeInterval? = awakeRemainingSeconds.map { TimeInterval($0) }
            startAwake(duration: dur)
        }
    }

    func setPreventLidSleep(_ prevent: Bool) {
        prefs.setPreventLidSleep(prevent)
        if isAwakeActive {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = PMSetHelper.setSleepDisabled(prevent)
                if !ok && prevent {
                    DispatchQueue.main.async {
                        self?.prefs.setPreventLidSleep(false)
                    }
                }
            }
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
        let path = prefs.customAppPath(slot: slot)
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

    func selectSettingsPage(_ page: String) {
        settingsPage = page
    }

    func pinHudAboveSettings(_ on: Bool) {
        let lv: NSWindow.Level = on ? .popUpMenu : .statusBar
        drop?.level = lv
        detail?.level = lv
        if on {
            settingsWC?.window?.level = .statusBar
            onboardingWC?.window?.level = .statusBar
            restackChrome()
        } else {
            settingsWC?.window?.level = .normal
            onboardingWC?.window?.level = .normal
        }
    }

    func restackChrome() {
        guard drop != nil else { return }
        for c in catchers {
            c.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            drop.order(.above, relativeTo: c.windowNumber)
            if detail.isVisible { detail.order(.above, relativeTo: c.windowNumber) }
        }
        if let sw = settingsWC?.window, sw.isVisible {
            drop.order(.above, relativeTo: sw.windowNumber)
            if detail.isVisible { detail.order(.above, relativeTo: sw.windowNumber) }
        }
        if let ow = onboardingWC?.window, ow.isVisible {
            drop.order(.above, relativeTo: ow.windowNumber)
            if detail.isVisible { detail.order(.above, relativeTo: ow.windowNumber) }
        }
    }

    func setPanel(_ v: Panel?) {
        hidePanel?.cancel()
        hidePanel = nil
        if let v {
            let changed = panel != v
            panel = v
            if changed || detail?.isVisible != true {
                showDetail()
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

    func snapKill(_ p: ProcSample) {
        confirmingKillPid = nil
        activeKillButton = nil
        vanish[p.id] = Date()
        vanishGhosts[p.id] = p
        killedIds.insert(p.id)
        quitPids(p.pids.isEmpty ? [p.id] : p.pids)
        let id = p.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                self?.vanish.removeValue(forKey: id)
                self?.vanishGhosts.removeValue(forKey: id)
            }
        }
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

    func cleanRAM() {
        guard !cleaningRAM else { return }
        cleaningRAM = true
        cleanFeedback = nil
        sampler.cleanRAM { freed in
            self.cleaningRAM = false
            withAnimation(.easeInOut(duration: 0.2)) {
                if freed >= 1024 * 1024 * 1024 {
                    self.cleanFeedback = String(format: "Freed %.2f GB", Double(freed) / (1024 * 1024 * 1024))
                } else if freed > 0 {
                    self.cleanFeedback = "Freed \(freed / (1024 * 1024)) MB"
                } else {
                    self.cleanFeedback = "Optimized"
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.cleanFeedback = nil
                }
            }
        }
    }

    func refreshLowPowerMode() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled || PMSetHelper.isLowPowerMode
    }

    func toggleLowPowerMode() {
        guard !lpmBusy else { return }
        lpmBusy = true
        let next = !lowPowerMode
        lowPowerMode = next
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = PMSetHelper.setLowPowerMode(next)
            DispatchQueue.main.async {
                self?.lpmBusy = false
                self?.refreshLowPowerMode()
                if !ok { self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
            }
        }
    }

    // ponytail: first orderFront of a never-shown transparent NSPanel has no WindowServer hit mask.
    // User's first open must be the second orderFront. Off-screen + alpha 0 so it doesn't flash.
    func primeHUD(_ p: NSPanel) {
        p.alphaValue = 0
        p.setFrame(NSRect(x: -8000, y: -8000, width: 268, height: 400), display: true)
        p.orderFrontRegardless()
        p.displayIfNeeded()
        p.orderOut(nil)
        p.alphaValue = 1
    }

    func hudAtPointer() -> NSPanel? {
        let loc = NSEvent.mouseLocation
        if drop.frame.contains(loc) { return drop }
        if detail.isVisible, detail.frame.contains(loc) { return detail }
        return nil
    }

    private var forwardingClick = false

    func forwardClick(_ e: NSEvent, to w: NSPanel) {
        guard !forwardingClick else { return }
        forwardingClick = true
        defer { forwardingClick = false }
        let pt = w.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let ev = NSEvent.mouseEvent(
            with: e.type,
            location: pt,
            modifierFlags: e.modifierFlags,
            timestamp: e.timestamp,
            windowNumber: w.windowNumber,
            context: nil,
            eventNumber: e.eventNumber,
            clickCount: e.clickCount,
            pressure: 1
        ) else { return }
        w.sendEvent(ev)
    }

    func showDrop() {
        guard !dropOpen else { return }
        cardFrames.removeAll()
        ignoreClicksUntil = Date().addingTimeInterval(0.35)
        dropOpen = true
        refreshLowPowerMode()
        sampler.runHeavy()
        objectWillChange.send()
        refreshMenu()
        sizePopover()
        drop.orderFrontRegardless()
        host.rootView = Dashboard(app: self, mode: .main)
        finishShow(clicks: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dropOpen else { return }
            self.sizePopover()
            self.restackChrome()
        }
    }

    func finishShow(clicks: Bool) {
        host.view.layoutSubtreeIfNeeded()
        sizePopover()
        refreshCardFrames(host.view)
        if clicks { startClickMon() }
        if settingsWC?.window?.isVisible == true || onboardingWC?.window?.isVisible == true {
            pinHudAboveSettings(true)
        }
    }

    @objc func toggle() {
        if dropOpen {
            hideDrop()
        } else {
            showDrop()
        }
    }

    func hideDrop() {
        guard drop != nil else { return }
        pinHudAboveSettings(false)
        TooltipManager.shared.hideImmediately()
        hideDetail()
        cardFrames.removeAll()
        procQuery = ""
        procSearchFocused = false
        vanish.removeAll()
        vanishGhosts.removeAll()
        killedIds.removeAll()
        procFieldHost.field.removeFromSuperview()
        if let p = detail as? DropPanel { p.allowKey = false }
        drop.orderOut(nil)
        panel = nil
        dropOpen = false
        sampler.stopHeavy()
        item.button?.isHighlighted = false
        item.button?.highlight(false)
        stopClickMon()
    }

    private lazy var procFieldHost = ProcFieldHost()

    func focusProcSearch(from pad: NSView) {
        guard dropOpen, let win = pad.window ?? detail else { return }
        procSearchFocused = true
        if let p = win as? DropPanel {
            p.allowKey = true
            p.becomesKeyOnlyIfNeeded = false
        }
        win.makeKey()
        let f = procFieldHost.field
        f.stringValue = procQuery
        f.textColor = .clear
        f.backgroundColor = .clear
        f.alphaValue = 0
        guard let cv = win.contentView else { return }
        f.frame = pad.convert(pad.bounds, to: cv)
        if f.superview !== cv { cv.addSubview(f) }
        win.makeFirstResponder(f)
        if let tv = f.currentEditor() as? NSTextView {
            tv.insertionPointColor = .clear
        }
    }

    func blurProcSearch() {
        procQuery = ""
        procSearchFocused = false
        procFieldHost.field.removeFromSuperview()
        if let p = detail as? DropPanel { p.allowKey = false }
    }

    func startClickMon() {
        stopClickMon()
        clickMon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeIfOutside()
        }
        let screens = NSScreen.screens.isEmpty ? [(item.button?.window?.screen ?? NSScreen.main)].compactMap { $0 } : NSScreen.screens
        catchers = screens.map { s in
            let p = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = NSColor.black.withAlphaComponent(1.0 / 255.0)
            p.hasShadow = false
            p.ignoresMouseEvents = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            let v = CatcherView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.autoresizingMask = [.width, .height]
            v.onDown = { [weak self] in
                guard let self else { return }
                let loc = NSEvent.mouseLocation
                if self.drop.frame.contains(loc) { return }
                if self.detail.isVisible, self.detail.frame.contains(loc) { return }
                self.closeIfOutside()
            }
            p.contentView = v
            p.setFrame(s.frame, display: false)
            p.orderFrontRegardless()
            return p
        }
        for c in catchers {
            c.order(.below, relativeTo: drop.windowNumber)
            if detail.isVisible { c.order(.below, relativeTo: detail.windowNumber) }
        }
        restackChrome()
        startHoverMon()
        dropClickMon = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            if self.forwardingClick { return e }
            if let w = self.hudAtPointer(), e.window !== w {
                self.forwardClick(e, to: w)
                return nil
            }
            if self.confirmingKillPid != nil {
                if let btn = self.activeKillButton, let win = btn.window, e.window == win {
                    let hit = win.contentView?.hitTest(e.locationInWindow)
                    let loc = btn.convert(e.locationInWindow, from: nil)
                    let onBtn = (hit === btn) || (hit?.isDescendant(of: btn) == true) || btn.bounds.insetBy(dx: -4, dy: -4).contains(loc)
                    if !onBtn {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            self.confirmingKillPid = nil
                            self.activeKillButton = nil
                        }
                    }
                } else if e.window !== self.drop && e.window !== self.detail {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        self.confirmingKillPid = nil
                        self.activeKillButton = nil
                    }
                }
            }
            if e.window !== self.drop, e.window !== self.detail {
                self.closeIfOutside()
            }
            return e
        }
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
        // Gap between main plate and detail is 6pt — keep the side panel alive while crossing it.
        if detail.isVisible, detail.frame.insetBy(dx: -8, dy: -8).contains(loc) {
            if let panel { setPanel(panel) }
            return
        }
        for idStr in prefs.dropOrder {
            guard prefs.drop.contains(idStr), let p = Panel(rawValue: idStr) else { continue }
            if let frame = cardFrames[p], frame.contains(loc), drop.frame.intersects(frame) {
                setPanel(p)
                return
            }
        }
        setPanel(nil)
    }

    func stopClickMon() {
        if let clickMon { NSEvent.removeMonitor(clickMon) }
        clickMon = nil
        if let dropClickMon { NSEvent.removeMonitor(dropClickMon) }
        dropClickMon = nil
        stopHoverMon()
        catchers.forEach { $0.orderOut(nil) }
        catchers.removeAll()
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
        if let ow = onboardingWC?.window, ow.isVisible, ow.frame.contains(loc) { return }
        hideDrop()
    }

final class SettingsWindow: NSWindow {
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        adjustButtons()
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
        super.setFrame(frameRect, display: displayFlag)
        adjustButtons()
    }

    private func adjustButtons() {
        guard let close = standardWindowButton(.closeButton),
              let minB = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton) else { return }
        close.frame.origin.x = 20
        close.frame.origin.y = 4
        minB.frame.origin.x = close.frame.maxX + 6
        minB.frame.origin.y = 4
        zoom.frame.origin.x = minB.frame.maxX + 6
        zoom.frame.origin.y = 4
        zoom.isEnabled = false
    }
}

    func openSettings() {
        hideDrop()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if settingsWC == nil {
            let vc = NSHostingController(rootView: SettingsRoot(app: self, prefs: prefs, sampler: sampler))
            let w = SettingsWindow(contentViewController: vc)
            w.title = "Sino"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = .windowBackgroundColor
            w.minSize = NSSize(width: 640, height: 520)
            w.maxSize = NSSize(width: 640, height: 1200)
            w.setContentSize(NSSize(width: 640, height: 680))
            w.center()
            settingsWC = NSWindowController(window: w)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.hideDrop()
                self?.settingsWC = nil
                if self?.onboardingWC == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        settingsWC?.window?.orderFrontRegardless()
    }

    func openOnboarding() {
        hideDrop()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if onboardingWC == nil {
            let vc = NSHostingController(rootView: OnboardingView(app: self, prefs: prefs))
            let w = NSWindow(contentViewController: vc)
            w.title = "Welcome to Sino"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.setContentSize(NSSize(width: 480, height: 430))
            w.center()
            onboardingWC = NSWindowController(window: w)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.prefs.setHasCompletedOnboarding(true)
                self?.onboardingWC = nil
                if self?.settingsWC == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        onboardingWC?.showWindow(nil)
        onboardingWC?.window?.makeKeyAndOrderFront(nil)
        onboardingWC?.window?.orderFrontRegardless()
    }

    func closeOnboarding() {
        prefs.setHasCompletedOnboarding(true)
        onboardingWC?.close()
        onboardingWC = nil
        if settingsWC == nil {
            NSApp.setActivationPolicy(.accessory)
        }
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
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

final class CatcherView: NSView {
    var onDown: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(1.0 / 255.0).setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) { onDown?() }
    override func rightMouseDown(with event: NSEvent) { onDown?() }
    override func otherMouseDown(with event: NSEvent) { onDown?() }
}

struct MenuChip: Equatable {
    var label: String
    var value: String
    var batteryFrac: Double? = nil
    var charging = false
    var isNet = false
    var isCat = false
}

final class ExtraView: NSView {
    var chips: [MenuChip] = []
    var flashColor: NSColor?
    var flashAlpha: CGFloat = 0
    var catTick = 0
    var catAnimated = true
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    func makeImage() -> NSImage {
        let size = NSSize(width: fittingWidth, height: max(bounds.height, 22))
        let img = NSImage(size: size)
        img.lockFocusFlipped(true)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill(using: .copy)
        draw(NSRect(origin: .zero, size: size))
        img.unlockFocus()
        return img
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
        if c.isCat { return 21 }
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

    private let catGap: CGFloat = 14

    var fittingWidth: CGFloat {
        guard !chips.isEmpty else { return 40 }
        var w = chips.map(chipWidth).reduce(0, +) + 4
        for (i, c) in chips.enumerated() {
            if i < chips.count - 1 {
                w += c.isCat ? catGap : gap
            }
        }
        return w
    }

    override func draw(_ dirtyRect: NSRect) {
        if flashAlpha > 0, let color = flashColor {
            let selRect = NSRect(x: 0, y: 0.5, width: bounds.width, height: bounds.height - 1)
            let path = NSBezierPath(roundedRect: selRect, xRadius: 4, yRadius: 4)
            color.withAlphaComponent(flashAlpha * 0.45).setFill()
            path.fill()
        }

        let labelH: CGFloat = 9
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        var x: CGFloat = 2
        for (i, c) in chips.enumerated() {
            let cw = chipWidth(c)
            if c.isCat {
                drawCat(NSRect(x: x, y: 0, width: cw, height: bounds.height))
            } else if let frac = c.batteryFrac {
                drawBattery(NSRect(x: x, y: 0, width: cw, height: bounds.height), frac: frac, text: c.value, charging: c.charging)
            } else if c.isNet {
                let half = floor(bounds.height / 2)
                netLine(c.label, up: true).draw(with: NSRect(x: x, y: 1, width: cw, height: half), options: opts)
                netLine(c.value, up: false).draw(with: NSRect(x: x, y: half, width: cw, height: bounds.height - half), options: opts)
            } else {
                (c.label as NSString).draw(with: NSRect(x: x, y: 0, width: cw, height: labelH), options: opts, attributes: labelAttrs)
                (c.value as NSString).draw(with: NSRect(x: x, y: labelH, width: cw, height: bounds.height - labelH), options: opts, attributes: valueAttrs)
            }
            let g = (c.isCat && i < chips.count - 1) ? catGap : gap
            x += cw + g
        }
    }

    // ponytail: 22×22 @ 1pt orange sitting tabby. No shadow.
    var catFrame: Int {
        guard catAnimated else { return 0 }
        let t = catTick % 1000
        if t < 495 {
            let sub = t % 125
            if (10...12).contains(sub) { return 1 }
            if (22...28).contains(sub) {
                return (23...26).contains(sub) ? 8 : 7
            }
            if (38...53).contains(sub) {
                switch sub - 38 {
                case 0, 1, 12, 13: return 2
                case 4, 5, 8, 9:   return 10
                case 6, 7:         return 11
                default:           return 0
                }
            }
            if (60...72).contains(sub) {
                switch sub {
                case 60, 61, 72: return 5
                case 62...65, 70, 71: return 6
                case 66...69: return 9
                default: return 0
                }
            }
            return 0
        }
        if t < 500 { return 16 }
        if t < 995 {
            let sleepSub = (t - 500) % 60
            if sleepSub < 36 { return 17 }
            if (36..<44).contains(sleepSub) { return 18 }
            if (44..<52).contains(sleepSub) { return 19 }
            return 18
        }
        return 16
    }

    private static let catIdle = [
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOKKOOOOKKOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOOKKKOOOOK..",
        "......KKKOOOOOOOOK...",
        "..KK...KDDOOOOOODK...",
        ".KOOK..KDOOOLLOOODK..",
        ".KDDK..KDDOOLLLLODK..",
        ".KOOK..KDDOOLLLLODK..",
        "KDDK..KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catBlink = [
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOOKKKOOOOK..",
        "......KKKOOOOOOOOK...",
        "..KK...KDDOOOOOODK...",
        ".KOOK..KDOOOLLOOODK..",
        ".KDDK..KDDOOLLLLODK..",
        ".KOOK..KDDOOLLLLODK..",
        "KDDK..KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catTailWaveLeft = [
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOKKOOOOKKOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOOKKKOOOOK..",
        "......KKKOOOOOOOOK...",
        ".KK....KDDOOOOOODK...",
        "KOOK...KDOOOLLOOODK..",
        "KDDK...KDDOOLLLLODK..",
        "KOOK...KDDOOLLLLODK..",
        "KDDK..KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catEarDrag1 = [
        ".......KK........KK..",
        "......KOOK.......KKK.",
        "......KODOK.....KODOK",
        "......KODDOKKKKKODDOK",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOKKOOOOKKOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOOKKKOOOOK..",
        "......KKKOOOOOOOOK...",
        "..KK...KDDOOOOOODK...",
        ".KOOK..KDOOOLLOOODK..",
        ".KDDK..KDDOOLLLLODK..",
        ".KOOK..KDDOOLLLLODK..",
        "KDDK..KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catEarDrag2 = [
        ".......KK............",
        "......KOOK.......KK..",
        "......KODOK....KKDOK.",
        "......KODDOKKKKOOODK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOKKOOOOOOOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOOKKKOOOOK..",
        "......KKKOOOOOOOOK...",
        "..KK...KDDOOOOOODK...",
        ".KOOK..KDOOOLLOOODK..",
        ".KDDK..KDDOOLLLLODK..",
        ".KOOK..KDDOOLLLLODK..",
        "KDDK..KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catLick1 = [
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOKTTKOOOOK..",
        "......KKKOOOOOOOOK...",
        "..KK...KDDOOOOOODK...",
        ".KOOK..KDOOOLLOOODK..",
        ".KDDK..KDDOOLLLLODK..",
        ".KOOK..KDDOOLLLLODK..",
        "KDDK..KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catLick2 = [
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOKTTKOOOOK..",
        "......KKKOOTTTOOOK...",
        "..KK...KDDOOTTOODK...",
        ".KOOK..KDOOOLLOOODK..",
        ".KDDK..KDDOOLLLLODK..",
        ".KOOK..KDDOOLLLLODK..",
        "KDDK..KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catLick3 = [
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOTTTTOOOOK..",
        "......KKKOOOOOOOOK...",
        "..KK...KDDOOOOOODK...",
        ".KOOK..KDOOOLLOOODK..",
        ".KDDK..KDDOOLLLLODK..",
        ".KOOK..KDDOOLLLLODK..",
        "KDDK..KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catTailWaveRight = [
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOKKOOOOKKOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOOKKKOOOOK..",
        "......KKKOOOOOOOOK...",
        "...KK..KDDOOOOOODK...",
        "..KOOK.KDOOOLLOOODK..",
        "..KDDK.KDDOOLLLLODK..",
        "..KOOK.KDDOOLLLLODK..",
        ".KDDK.KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catTailWaveTip = [
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOKKOOOOKKOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOOKKKOOOOK..",
        "......KKKOOOOOOOOK...",
        "....KK.KDDOOOOOODK...",
        "...KOOKKDOOOLLOOODK..",
        "..KDDK.KDDOOLLLLODK..",
        "..KOOK.KDDOOLLLLODK..",
        ".KDDK.KDOOOOLLLLODK..",
        "KOOK..KDDOOOLLLOODK..",
        "KDDK.KDOOODOOOKOODK..",
        "KOOK.KDDDOKDDOKODDK..",
        "KDDK.KDDDOKDDOKODDK..",
        "KOODKKOOOOKOOOKOODK..",
        "KDDDDKOOOOKDDOOKODDK.",
        ".KDDKDODDKDOOOKOOODK.",
        "..KKKKDOOKDOODKODDK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catLieDownTransition = [
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        "......KDOOODODODOODK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOOOOOOOOOOOK.",
        "......KOOKKOOOOKKOOK.",
        ".....KKDOKKOOOOKKODKK",
        "......KOOOOOKKOOOOOK.",
        ".....KKDDOOOKOOOOOODK",
        "......KOOOOKKKOOOOK..",
        "..KK...KDDOOOOOODK...",
        ".KOOK..KDOOOLLOOODK..",
        ".KDDK..KDDOOLLLLODK..",
        "KOOK..KKDDOOLLLLODK..",
        "KDDK.KDOOOOOLLLOODK..",
        "KOODKKOOODOOOKOODK...",
        "KDDDDKDDDOKDDOKODDK..",
        ".KDDKKOOOOKOOOKOODK..",
        "..KKKKDODDKDDOOKODK..",
        "......KKKKKKKKKKKKK.."
    ]

    private static let catSleepPoseA = [
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        ".....KKDOOODODODOODK.",
        "...KKDDOOOOOOOOOOOOK.",
        "..KDOOODODODODODDDOK.",
        ".KDOOOOOOOOOOOOOOOODK",
        ".KDOOOOOODOKKOOOOKKOD",
        "KDOOOOOOOOOOOKKOOOOOD",
        "KDDOOOOOODDDOOOKOOOOOD",
        "KOOKKDOOOOOOKKKOOOOOD",
        "KDDKKDOODDOOLLLLODKOD",
        "KOODKKDDKDDOLLLLODKOD",
        "KDDDDKKKDOOKKKKOODK..",
        ".KDDKDODDKDDOOOKODDK.",
        "..KKKKKKKKKKKKKKKKK.."
    ]

    private static let catSleepPoseB = [
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        ".....KKDOOODODODOODK.",
        "...KKDDOOOOOOOOOOOOK.",
        "..KDOOODODODODODDDOK.",
        ".KDOOOOOOOOOOOOOOOODK",
        ".KDOOOOOODOKKOOOOKKOD",
        "KDOOOOOOOOOOOKKOOOOOD",
        "KDDOOOOOODDDOOOKOOOOOD",
        "...KKDOOOOOOKKKOOOOOD",
        ".KOOKDOODDOOLLLLODKOD",
        "KDDKKKDDKDDOLLLLODKOD",
        "KOODKKKKDOOKKKKOODK..",
        "KDDDDKODDKDDOOOKODDK.",
        ".KKKKKKKKKKKKKKKKKK.."
    ]

    private static let catSleepPoseC = [
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".....................",
        ".......KK........KK..",
        "......KOOK......KOOK.",
        "......KODOK....KODOK.",
        "......KODDOKKKKODDOK.",
        "......KODDODODODDDOK.",
        ".....KKDOOODODODOODK.",
        "...KKDDOOOOOOOOOOOOK.",
        "..KDOOODODODODODDDOK.",
        ".KDOOOOOOOOOOOOOOOODK",
        ".KDOOOOOODOKKOOOOKKOD",
        "KDOOOOOOOOOOOKKOOOOOD",
        "KDDOOOOOODDDOOOKOOOOOD",
        "KDDOOOOOODDDOOOKOOOOOD",
        "......KOODDOOLLLLODKOD",
        "...KK.KDDKDDOLLLLODKOD",
        ".KOODKKKDOOKKKKOODK..",
        "KDDDDKODDKDDOOOKODDK.",
        ".KKKKKKKKKKKKKKKKKK.."
    ]

    private func currentCatSprite() -> [String] {
        switch catFrame {
        case 1: return Self.catBlink
        case 2: return Self.catTailWaveLeft
        case 5: return Self.catLick1
        case 6: return Self.catLick2
        case 7: return Self.catEarDrag1
        case 8: return Self.catEarDrag2
        case 9: return Self.catLick3
        case 10: return Self.catTailWaveRight
        case 11: return Self.catTailWaveTip
        case 16: return Self.catLieDownTransition
        case 17: return Self.catSleepPoseA
        case 18: return Self.catSleepPoseB
        case 19: return Self.catSleepPoseC
        default: return Self.catIdle
        }
    }

    private func drawCat(_ r: NSRect) {
        let sprite = currentCatSprite()
        let rows = CGFloat(sprite.count)
        let cols = CGFloat(sprite.first?.count ?? 21)
        let maxH: CGFloat = 21.0
        let s = min(maxH / rows, (r.width - 2) / cols)
        let ox = (r.minX + (r.width - cols * s) / 2).rounded()
        let oy = (r.minY + (r.height - rows * s) / 2).rounded()
        let outline = NSColor(srgbRed: 0.14, green: 0.13, blue: 0.17, alpha: 1)
        let orange = NSColor(srgbRed: 0.97, green: 0.58, blue: 0.19, alpha: 1)
        let dark = NSColor(srgbRed: 0.85, green: 0.41, blue: 0.14, alpha: 1)
        let light = NSColor(srgbRed: 0.98, green: 0.73, blue: 0.41, alpha: 1)
        let tongue = NSColor(srgbRed: 0.93, green: 0.33, blue: 0.39, alpha: 1)
        let map: [Character: NSColor] = [
            "K": outline, "O": orange, "D": dark, "L": light, "T": tongue
        ]
        for (j, row) in sprite.enumerated() {
            for (i, ch) in row.enumerated() {
                guard let color = map[ch] else { continue }
                color.setFill()
                NSRect(x: ox + CGFloat(i) * s, y: oy + CGFloat(j) * s, width: s, height: s).fill()
            }
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
        if parent != win {
            parent?.removeChildWindow(self)
            win.addChildWindow(self, ordered: .above)
        }
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
        if let p = tipPanel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
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

struct FanSlider: NSViewRepresentable {
    var min: Double
    var max: Double
    var value: Double
    var onChange: (Double) -> Void

    final class Knob: NSSlider {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    final class Coord: NSObject {
        var onChange: (Double) -> Void = { _ in }
        @objc func changed(_ s: NSSlider) { onChange(s.doubleValue) }
    }
    func makeCoordinator() -> Coord { Coord() }
    func makeNSView(context: Context) -> NSSlider {
        let s = Knob()
        s.minValue = min
        s.maxValue = max
        s.doubleValue = value
        s.isContinuous = true
        s.controlSize = .small
        s.target = context.coordinator
        s.action = #selector(Coord.changed(_:))
        context.coordinator.onChange = onChange
        return s
    }
    func updateNSView(_ s: NSSlider, context: Context) {
        context.coordinator.onChange = onChange
        if abs(s.minValue - min) > 0.5 { s.minValue = min }
        if abs(s.maxValue - max) > 0.5 { s.maxValue = max }
        if abs(s.doubleValue - value) > 8 { s.doubleValue = value }
    }
}

struct ClickPad: NSViewRepresentable {
    var action: () -> Void
    var onAttach: ((ClickView) -> Void)? = nil
    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        v.action = action
        onAttach?(v)
        return v
    }
    func updateNSView(_ v: ClickView, context: Context) {
        v.action = action
        onAttach?(v)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClickView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 20, height: proposal.height ?? 20)
    }
}

final class ClickView: NSView {
    var action: (() -> Void)?
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.width, .height]
        if let s = superview { frame = s.bounds }
    }
    override func layout() {
        super.layout()
        if let s = superview { frame = s.bounds }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        var r = bounds
        if r.width < 2 || r.height < 2, let s = superview {
            r = convert(s.bounds, from: s)
        }
        return r.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        action?()
    }
}

struct HoverPad: NSViewRepresentable {
    var tip: String? = nil
    var selected = false
    var captureHits = false
    var onClick: (() -> Void)? = nil
    var radius: CGFloat = 6
    func makeNSView(context: Context) -> HoverBG {
        let v = HoverBG()
        v.radius = radius
        v.selected = selected
        v.captureHits = captureHits
        v.onClick = onClick
        v.tip = tip
        return v
    }
    func updateNSView(_ v: HoverBG, context: Context) {
        v.radius = radius
        v.selected = selected
        v.captureHits = captureHits
        v.onClick = onClick
        v.tip = tip
        v.needsDisplay = true
        v.syncHover()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HoverBG, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 20, height: proposal.height ?? 20)
    }
}

// ponytail: HoverPad click (proven in this HUD) + key monitor. NSSearchField crashed / never got first-mouse.
struct ProcSearchField: View {
    @ObservedObject var app = App.shared
    var pal: Palette
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            if app.procSearchFocused {
                HStack(spacing: 0) {
                    if !app.procQuery.isEmpty {
                        Text(app.procQuery)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    BlinkCaret()
                }
            } else if app.procQuery.isEmpty {
                Text("Search")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.55))
            } else {
                Text(app.procQuery)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
        .background(app.procSearchFocused ? pal.cardHover : pal.track, in: Capsule())
        .overlay {
            SearchPad()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct BlinkCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { tl in
            let on = Int(tl.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Rectangle()
                .fill(Color.primary.opacity(on ? 0.45 : 0))
                .frame(width: 1, height: 10)
        }
    }
}

struct SearchPad: NSViewRepresentable {
    func makeNSView(context: Context) -> SearchPadView { SearchPadView() }
    func updateNSView(_ v: SearchPadView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SearchPadView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 80, height: proposal.height ?? 18)
    }
}

final class SearchPadView: NSView {
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        App.shared.focusProcSearch(from: self)
    }
    override func mouseUp(with event: NSEvent) {}
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }
}

final class ProcFieldHost: NSObject, NSTextFieldDelegate {
    let field: NSTextField
    override init() {
        field = NSTextField()
        super.init()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 10)
        (field.cell as? NSTextFieldCell)?.isScrollable = true
        (field.cell as? NSTextFieldCell)?.wraps = false
        field.delegate = self
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        if let tv = field.currentEditor() as? NSTextView {
            tv.insertionPointColor = .clear
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        App.shared.procQuery = field.stringValue
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            App.shared.blurProcSearch()
            return true
        }
        return false
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
        CGSize(width: proposal.width ?? 256, height: proposal.height ?? 80)
    }
}

final class FrameProbe: NSView {
    var id: App.Panel?
    // Hits pass through to CPU segments / header chips. Hover uses tracking + pickHover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let id { App.shared.cardFrames.removeValue(forKey: id) }
            trackingAreas.forEach(removeTrackingArea)
            return
        }
        armTracking()
        save()
    }
    override func layout() {
        super.layout()
        save()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        save()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        armTracking()
    }
    private func armTracking() {
        if trackingAreas.contains(where: { $0.owner === self }) { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .assumeInside],
            owner: self,
            userInfo: nil
        ))
    }
    override func mouseEntered(with event: NSEvent) {
        save()
        App.shared.pickHover()
    }
    override func mouseMoved(with event: NSEvent) {
        App.shared.pickHover()
    }
    override func mouseExited(with event: NSEvent) {
        // Layout/rebuild synthesizes exited while the cursor is still on the card.
        App.shared.pickHover()
    }
    func save() {
        guard let id, let w = window, bounds.width > 1, bounds.height > 1 else { return }
        let inWindow: NSRect = convert(bounds, to: nil)
        App.shared.cardFrames[id] = w.convertToScreen(inWindow)
    }
}

struct Dashboard: View {
    @ObservedObject var app: App
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var updater = Updater.shared
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
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
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
            ForEach(app.prefs.dropOrder, id: \.self) { id in
                if id == "toolbar" {
                    if prefs.updateBanner, let ver = updater.availableVersion {
                        updateBanner(ver)
                    }
                    if shown(id) {
                        toolbar
                    }
                } else if shown(id) {
                    mainCard(for: id)
                }
            }
        }
        .frame(width: 256)
    }

    @ViewBuilder
    func mainCard(for id: String) -> some View {
        switch id {
        case "cpu":
            Card("CPU", "cpu", pal, panel: .cpu, active: app.panel == .cpu) {
                Sparkline(values: snap.cpuHistory, color: pal.accent)
                    .frame(height: 22)
                    .padding(.bottom, 1)
                let u = max(0, snap.cpuUser)
                let s = max(0, snap.cpuSystem)
                CPULoadBar(user: u, system: s, accent: NSColor(pal.accent), track: NSColor(pal.track))
                    .frame(height: 8)
            } headerTrailing: {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Text("MIN").foregroundStyle(.secondary.opacity(0.65))
                        AnimatingIntText(value: snap.cpuMin * 100, font: .system(size: 8.5, weight: .semibold).monospacedDigit(), color: .secondary)
                        Text("%").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 2) {
                        Text("AVG").foregroundStyle(.secondary.opacity(0.65))
                        AnimatingIntText(value: snap.cpuAvg * 100, font: .system(size: 8.5, weight: .semibold).monospacedDigit(), color: .secondary)
                        Text("%").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 2) {
                        Text("MAX").foregroundStyle(.secondary.opacity(0.65))
                        AnimatingIntText(value: snap.cpuMax * 100, font: .system(size: 8.5, weight: .semibold).monospacedDigit(), color: .secondary)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
                .animation(pal.anim, value: snap.cpuAvg)
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
            }
        case "ram":
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
        case "gpu":
            Card("GPU", "display", pal, panel: .gpu, active: app.panel == .gpu) {
                Text(snap.gpuName).font(Palette.body)
                Bar(snap.gpuUsage, pal.accent, pal.track)
                HStack {
                    Text(pct0(snap.gpuUsage)).font(Palette.body).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        case "storage":
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
        case "net":
            Card("NETWORK", "network", pal, panel: .net, active: app.panel == .net) {
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
            }
        case "fans":
            if !snap.fans.isEmpty {
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
        case "battery":
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
            } headerTrailing: {
                let on = app.lowPowerMode
                HStack(spacing: 3) {
                    Image(systemName: on ? "leaf.fill" : "leaf")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text("Low Power")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(on ? pal.accent : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(on ? pal.accent.opacity(0.18) : pal.track.opacity(0.8), in: Capsule())
                .overlay {
                    HoverPad(
                        tip: on ? "Turn off Low Power Mode" : "Turn on Low Power Mode",
                        captureHits: true,
                        onClick: { app.toggleLowPowerMode() },
                        radius: 12
                    )
                }
            }
        default:
            EmptyView()
        }
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
        ZStack(alignment: .top) {
            Group {
                switch app.panel {
                case .cpu:
                    VStack(spacing: 4) {
                        ForEach(app.prefs.sideOrder["cpu"] ?? ["cores", "procs", "gpu"], id: \.self) { sec in
                            if app.prefs.isSideVisible("cpu", sec) {
                                cpuSection(sec)
                            }
                        }
                    }
                case .ram:
                    VStack(spacing: 4) {
                        ForEach(app.prefs.sideOrder["ram"] ?? ["memory", "procs"], id: \.self) { sec in
                            if app.prefs.isSideVisible("ram", sec) {
                                ramSection(sec)
                            }
                        }
                    }
                case .gpu:
                    VStack(spacing: 4) {
                        ForEach(app.prefs.sideOrder["gpu"] ?? ["gpu"], id: \.self) { sec in
                            if app.prefs.isSideVisible("gpu", sec) {
                                gpuSection(sec)
                            }
                        }
                    }
                case .storage:
                    VStack(spacing: 4) {
                        ForEach(app.prefs.sideOrder["storage"] ?? ["activity", "volumes"], id: \.self) { sec in
                            if app.prefs.isSideVisible("storage", sec) {
                                storageSection(sec)
                            }
                        }
                    }
                case .net:
                    VStack(spacing: 4) {
                        ForEach(app.prefs.sideOrder["net"] ?? ["chart", "wifi", "addresses", "topProc"], id: \.self) { sec in
                            if app.prefs.isSideVisible("net", sec) {
                                netSection(sec)
                            }
                        }
                    }
                case .fans:
                    VStack(spacing: 4) {
                        ForEach(app.prefs.sideOrder["fans"] ?? ["fans", "sensors"], id: \.self) { sec in
                            if app.prefs.isSideVisible("fans", sec) {
                                fansSection(sec)
                            }
                        }
                    }
                case .battery:
                    VStack(spacing: 4) {
                        ForEach(app.prefs.sideOrder["battery"] ?? ["battery", "energy"], id: \.self) { sec in
                            if app.prefs.isSideVisible("battery", sec) {
                                batterySection(sec)
                            }
                        }
                    }
                case nil: EmptyView()
                }
            }
            .id(app.panel)
            .transition(.opacity)
        }
        .frame(width: 256)
        .animation(.easeOut(duration: 0.11), value: app.panel)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    func cpuSection(_ sec: String) -> some View {
        switch sec {
        case "cores":
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
        case "procs":
            Card("CPU USAGE", "square.grid.2x2", pal) {
                let count = app.prefs.cpuProcCount
                let procs = Array(snap.processes.prefix(count))
                VStack(spacing: 4) {
                    ForEach(procs) { p in
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
                            let cpuVal = app.prefs.cpuProcMode == "perCore" ? p.cpu : (p.cpu / Double(app.sampler.totalCores))
                            AnimatingPct1Text(
                                value: cpuVal,
                                font: Palette.body.monospacedDigit(),
                                color: .secondary
                            )
                            .animation(pal.anim, value: cpuVal)
                        }
                        .frame(height: 18)
                        .transition(.opacity)
                    }
                    if procs.count < count {
                        ForEach(0..<(count - procs.count), id: \.self) { _ in
                            HStack(spacing: 5) {
                                Color.clear.frame(width: 14, height: 14)
                                Text("—").font(Palette.body).foregroundStyle(.tertiary)
                                Spacer()
                                Text("—").font(Palette.body.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(height: 18)
                        }
                    }
                }
                .animation(pal.snappyAnim, value: procs.map(\.id))
            }
        case "gpu":
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
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func ramSection(_ sec: String) -> some View {
        switch sec {
        case "memory":
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
                    .overlay { HoverPad(tip: "Quick RAM Clean (evacuate purgeable caches)", radius: 12) }
                }
            }
        case "procs":
            Card("PROCESSES", "square.grid.2x2", pal, fillHeader: true) {
                let count = app.prefs.ramProcCount
                let q = app.procQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                let pool: [ProcSample] = {
                    var list = snap.memProcesses.filter { !app.killedIds.contains($0.id) }
                    let liveIds = Set(list.map(\.id))
                    for g in app.vanishGhosts.values where !liveIds.contains(g.id) {
                        list.append(g)
                    }
                    list.sort { $0.mem > $1.mem }
                    return list
                }()
                let filtered = q.isEmpty ? pool : pool.filter { $0.name.localizedCaseInsensitiveContains(q) }
                let procs = Array(filtered.prefix(count))
                VStack(spacing: 4) {
                    ForEach(procs) { p in
                        ZStack {
                            HStack(spacing: 5) {
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
                                    AnimatingGBText(
                                        bytes: Double(p.mem),
                                        font: Palette.body.monospacedDigit(),
                                        color: .secondary
                                    )
                                    .animation(pal.anim, value: p.mem)
                                }
                                .opacity(app.vanish[p.id] == nil ? 1 : 0)
                                ProcessKillButton(process: p, app: app, pal: pal)
                            }
                            if let start = app.vanish[p.id] {
                                ThanosDust(seed: Int(p.id), start: start)
                            }
                        }
                        .frame(height: 18)
                        .transition(.opacity)
                    }
                    if procs.count < count {
                        ForEach(0..<(count - procs.count), id: \.self) { _ in
                            HStack(spacing: 5) {
                                Color.clear.frame(width: 14, height: 14)
                                Text("—").font(Palette.body).foregroundStyle(.tertiary)
                                Spacer()
                                Text("—").font(Palette.body.monospacedDigit()).foregroundStyle(.tertiary)
                                Color.clear.frame(width: 18, height: 18)
                            }
                            .frame(height: 18)
                        }
                    }
                }
                .animation(pal.snappyAnim, value: procs.map(\.id))
            } headerTrailing: {
                ProcSearchField(pal: pal)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func gpuSection(_ sec: String) -> some View {
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

    @ViewBuilder
    func storageSection(_ sec: String) -> some View {
        switch sec {
        case "activity":
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
        case "volumes":
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
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func netSection(_ sec: String) -> some View {
        switch sec {
        case "chart":
            Card("NETWORK", "network", pal) {
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
            }
        case "wifi":
            if snap.wifi {
                Card("WI-FI DETAILS", "wifi", pal) {
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
                    GeoInfoRow(icon: "cable.connector", title: "Interface", value: snap.netInterface)
                }
            }
        case "addresses":
            Card("ADDRESSES", "globe", pal) {
                GeoInfoRow(icon: "info.circle", title: "Local IPv4", value: snap.netIPv4)
                GeoInfoRow(icon: "globe", title: "Public IPv4", value: snap.netGeo.publicIPv4 != "—" ? snap.netGeo.publicIPv4 : snap.publicIP)
                if snap.netGeo.location != "—" {
                    GeoInfoRow(icon: "map", title: "Location", value: snap.netGeo.location)
                }
                if snap.netGeo.geoCoordinates != "—" {
                    GeoInfoRow(icon: "mappin.and.ellipse", title: "GeoCoordinates", value: snap.netGeo.geoCoordinates)
                }
                if snap.netGeo.timezone != "—" {
                    GeoInfoRow(icon: "clock", title: "Timezone", value: snap.netGeo.timezone)
                }
                if snap.netGeo.asName != "—" {
                    GeoInfoRow(icon: "point.3.filled.connected.trianglepath.dotted", title: "AS", value: snap.netGeo.asName)
                }
                if snap.netGeo.isp != "—" {
                    GeoInfoRow(icon: "antenna.radiowaves.left.and.right", title: "ISP", value: snap.netGeo.isp)
                }
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
        case "topProc":
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
        default:
            EmptyView()
        }
    }

    var fanLo: Double {
        let v = snap.fans.map(\.minRPM).min() ?? 2317
        return v > 500 ? v : 2317
    }
    var fanHi: Double {
        let v = snap.fans.map(\.maxRPM).max() ?? 6800
        return v > fanLo ? v : 6800
    }

    func fanModeChip(_ title: String, _ mode: FanMode) -> some View {
        Text(title)
            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
            .foregroundStyle(app.fanMode == mode ? pal.accent : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(app.fanMode == mode ? pal.accent.opacity(0.18) : pal.track.opacity(0.8), in: Capsule())
            .overlay {
                HoverPad(captureHits: true, onClick: {
                    app.setFanMode(mode)
                })
            }
    }

    @ViewBuilder
    func fansSection(_ sec: String) -> some View {
        switch sec {
        case "fans":
            Card("FANS", "fan", pal) {
                if app.fanMode == .curve {
                    Text(String(format: "Hottest %.0f °C → %.0f RPM", app.hottestTemp(), app.curveTarget()))
                        .font(Palette.tiny)
                        .foregroundStyle(.secondary)
                    FanCurveEditor(
                        points: prefs.fanCurve,
                        rpmLo: fanLo,
                        rpmHi: fanHi,
                        nowTemp: app.hottestTemp(),
                        nowRPM: app.curveTarget(),
                        dark: app.currentScheme == .dark,
                        onChange: { i, t, r in prefs.setCurvePoint(i, temp: t, rpm: r) }
                    )
                    .frame(height: 132)
                } else {
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
                            if app.fanMode == .manual {
                                FanSlider(
                                    min: f.minRPM > 500 ? f.minRPM : fanLo,
                                    max: f.maxRPM > fanLo ? f.maxRPM : fanHi,
                                    value: app.fanTargets[f.id] ?? f.rpm
                                ) { app.setFanTarget(f.id, $0) }
                                    .frame(height: 18)
                            } else {
                                Bar(f.maxRPM > 0 ? min(1, f.rpm / f.maxRPM) : 0, pal.accent, pal.track)
                            }
                        }
                    }
                }
            } headerTrailing: {
                HStack(spacing: 3) {
                    fanModeChip("Auto", .auto)
                    fanModeChip("Manual", .manual)
                    fanModeChip("Curve", .curve)
                }
            }
        case "sensors":
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
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func batterySection(_ sec: String) -> some View {
        switch sec {
        case "battery":
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
                    .frame(height: 92)
                    .padding(.top, 2)
                }
            } headerTrailing: {
                let on = app.lowPowerMode
                HStack(spacing: 3) {
                    Image(systemName: on ? "leaf.fill" : "leaf")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text("Low Power")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(on ? pal.accent : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(on ? pal.accent.opacity(0.18) : pal.track.opacity(0.8), in: Capsule())
                .overlay {
                    HoverPad(
                        tip: on ? "Turn off Low Power Mode" : "Turn on Low Power Mode",
                        captureHits: true,
                        onClick: { app.toggleLowPowerMode() },
                        radius: 12
                    )
                }
            }
        case "energy":
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
        default:
            EmptyView()
        }
    }

    func updateBanner(_ ver: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pal.accent)
            Text("\(ver) available")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(updater.isUpdating ? (updater.updateProgress ?? "Updating…") : "Update")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(updater.isUpdating ? .secondary : pal.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(pal.accent.opacity(updater.isUpdating ? 0.08 : 0.16), in: Capsule())
                .overlay {
                    if !updater.isUpdating {
                        HoverPad(tip: "Download and install \(ver)", captureHits: true, onClick: {
                            updater.performUpdate()
                        }, radius: 10)
                    }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(pal.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(app.prefs.toolbarOrder, id: \.self) { id in
                if app.prefs.toolbar.contains(id) {
                    toolbarItem(for: id)
                }
            }
            // Settings button permanently pinned on the right
            tool("gearshape.fill", "Settings") { app.openSettings() }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(pal.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    func toolbarItem(for id: String) -> some View {
        switch id {
        case "activity":
            tool("waveform.path.ecg", "Activity Monitor") { App.shared.openUtil("Activity Monitor") }
        case "terminal":
            tool("terminal.fill", "Terminal") { App.shared.openUtil("Terminal") }
        case "interval":
            Text(intervalLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(pal.track, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay { HoverPad(tip: "Refresh: \(intervalLabel) — click to cycle") }
                .overlay { ClickPad(action: { App.shared.cycleInterval() }) }
                .accessibilityAddTraits(.isButton)
        case "theme":
            tool(themeIcon, "Theme") { App.shared.cycleTheme() }
        case "awake":
            awakeTool
        case "app1":
            customTool(1)
        case "app2":
            customTool(2)
        case "app3":
            customTool(3)
        default:
            EmptyView()
        }
    }

    func customTool(_ slot: Int) -> some View {
        let path = app.prefs.customAppPath(slot: slot)
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
        .overlay { HoverPad(tip: tip) }
        .overlay { ClickPad(action: { App.shared.openCustomApp(slot: slot) }) }
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
            let mode = app.prefs.preventLidSleep ? " (clamshell)" : ""
            if let rem = app.awakeRemainingSeconds {
                let h = rem / 3600
                let m = (rem % 3600) / 60
                let s = rem % 60
                let tStr = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
                tip = "Awake\(mode): \(tStr) remaining (right-click options)"
            } else {
                tip = "Awake\(mode): Indefinite (right-click options)"
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
            .overlay { HoverPad(tip: tip, selected: active) }
            .overlay { ClickPad(action: { app.toggleAwake() }) }
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
                Toggle("Prevent Lid-Close Sleep", isOn: Binding(
                    get: { app.prefs.preventLidSleep },
                    set: { app.setPreventLidSleep($0) }
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
            .overlay { HoverPad(tip: tip, selected: selected) }
            .overlay { ClickPad(action: action) }
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

final class TrackKillView: NSView {
    var onAttach: ((NSView) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?(self) }
    }
    override func layout() {
        super.layout()
        onAttach?(self)
    }
}

struct TrackKillRepresentable: NSViewRepresentable {
    let onAttach: (NSView) -> Void
    func makeNSView(context: Context) -> TrackKillView {
        let v = TrackKillView()
        v.onAttach = onAttach
        return v
    }
    func updateNSView(_ nsView: TrackKillView, context: Context) {
        nsView.onAttach = onAttach
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackKillView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 40, height: proposal.height ?? 18)
    }
}

struct ThanosDust: View {
    var seed: Int
    var start: Date
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
            let t = min(1.0, max(0.0, tl.date.timeIntervalSince(start) / 0.85))
            Canvas { ctx, size in
                var s = UInt64(UInt32(bitPattern: Int32(truncatingIfNeeded: seed))) &+ 0x9E3779B97F4A7C15
                for _ in 0..<420 {
                    s = s &* 6364136223846793005 &+ 1
                    let u1 = Double(s >> 33) / 2147483648.0
                    s = s &* 6364136223846793005 &+ 1
                    let u2 = Double(s >> 33) / 2147483648.0
                    s = s &* 6364136223846793005 &+ 1
                    let u3 = Double(s >> 33) / 2147483648.0
                    let x = CGFloat(u1) * size.width
                    let y = CGFloat(u2) * size.height
                    let dx = CGFloat(u3 - 0.2) * size.width * CGFloat(t)
                    let dy = CGFloat(u1 - 1.15) * 26 * CGFloat(t)
                    let fade = 1 - t
                    let w = 0.35 + CGFloat(u2) * 0.55
                    let rect = CGRect(x: x + dx, y: y + dy, width: w, height: w)
                    ctx.fill(Path(rect), with: .color(.primary.opacity(fade * (0.25 + u3 * 0.55))))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ProcessKillButton: View {
    let process: ProcSample
    @ObservedObject var app: App
    let pal: Palette

    var isConfirming: Bool {
        app.confirmingKillPid == process.id
    }

    var isVanishing: Bool { app.vanish[process.id] != nil }

    var body: some View {
        HStack(spacing: 3) {
            if isVanishing {
                TimelineView(.animation(minimumInterval: 0.016, paused: false)) { tl in
                    let angle = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(angle))
                        .frame(width: 14, height: 14)
                }
            } else if isConfirming {
                Text("Kill")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, isConfirming && !isVanishing ? 7 : 0)
        .padding(.vertical, isConfirming && !isVanishing ? 2.5 : 0)
        .background(isConfirming && !isVanishing ? Color.red : Color.clear, in: Capsule())
        .background(
            TrackKillRepresentable { v in
                if isConfirming { app.activeKillButton = v }
            }
        )
        .overlay {
            if !isVanishing {
                ClickPad(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        if isConfirming {
                            app.snapKill(process)
                        } else {
                            app.confirmingKillPid = process.id
                        }
                    }
                }, onAttach: { v in
                    if isConfirming {
                        app.activeKillButton = v
                    } else if app.activeKillButton === v {
                        app.activeKillButton = nil
                    }
                })
            }
        }
    }
}

struct Card<Content: View, HeaderTrailing: View>: View {
    let title: String
    let symbol: String
    let pal: Palette
    var panel: App.Panel?
    var active: Bool
    var fillHeader = false
    let headerTrailing: HeaderTrailing?
    let content: Content

    init(
        _ title: String,
        _ symbol: String,
        _ pal: Palette,
        panel: App.Panel? = nil,
        active: Bool = false,
        fillHeader: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder headerTrailing: () -> HeaderTrailing
    ) {
        self.title = title
        self.symbol = symbol
        self.pal = pal
        self.panel = panel
        self.active = active
        self.fillHeader = fillHeader
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
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .textCase(.uppercase)
                    .tracking(0.3)
                    .fixedSize()
                if let headerTrailing {
                    if fillHeader {
                        headerTrailing
                    } else {
                        Spacer()
                        headerTrailing
                    }
                }
            }
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? pal.cardHover : pal.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if let panel {
                ScreenFrame(id: panel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct AnimatingIntText: View, Animatable {
    var value: Double
    var font: Font
    var color: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(round(value)))")
            .font(font)
            .foregroundStyle(color)
    }
}

struct AnimatingPctText: View, Animatable {
    var value: Double
    var font: Font
    var color: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(String(format: "%.1f %%", value * 100))
            .font(font)
            .foregroundStyle(color)
    }
}

struct AnimatingBytesGBText: View, Animatable {
    var bytes: Double
    var font: Font
    var color: Color

    var animatableData: Double {
        get { bytes }
        set { bytes = newValue }
    }

    var body: some View {
        Text(bytesGB(UInt64(max(0, bytes))))
            .font(font)
            .foregroundStyle(color)
    }
}

struct AnimatingPct1Text: View, Animatable {
    var value: Double
    var font: Font
    var color: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(pct1(value))
            .font(font)
            .foregroundStyle(color)
    }
}

struct AnimatingGBText: View, Animatable {
    var bytes: Double
    var font: Font
    var color: Color

    var animatableData: Double {
        get { bytes }
        set { bytes = newValue }
    }

    var body: some View {
        Text(bytesGB(UInt64(max(0, bytes))))
            .font(font)
            .foregroundStyle(color)
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
                    .animation(Prefs.shared.animations ? .spring(response: 0.18, dampingFraction: 0.85) : nil, value: core.usage)

                AnimatingIntText(
                    value: core.usage * 100,
                    font: .system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit(),
                    color: .primary
                )
                .animation(Prefs.shared.animations ? .spring(response: 0.18, dampingFraction: 0.85) : nil, value: core.usage)
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
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !charging)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = charging ? CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2) : 0
            let stops: [Gradient.Stop] = (0...128).map { i in
                let u = CGFloat(i) / 128
                let s = 0.5 + 0.5 * sin((u * 0.6 - p) * 2 * CGFloat.pi)
                return .init(color: Color.white.opacity(0.08 + 0.22 * s), location: u)
            }
            GeometryReader { g in
                let filled = max(0, g.size.width * CGFloat(min(1, max(0, frac))))
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(fill).frame(width: filled)
                        .animation(Prefs.shared.animations ? .spring(response: 0.18, dampingFraction: 0.85) : nil, value: filled)
                    if charging && filled > 0 {
                        Capsule()
                            .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                            .frame(width: filled)
                            .blendMode(.plusLighter)
                            .animation(Prefs.shared.animations ? .spring(response: 0.18, dampingFraction: 0.85) : nil, value: filled)
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
    var user = 0.0 {
        didSet {
            targetUser = user
            startAnimationIfNeeded()
        }
    }
    var system = 0.0 {
        didSet {
            targetSystem = system
            startAnimationIfNeeded()
        }
    }
    var accent = NSColor.systemBlue
    var track = NSColor.white.withAlphaComponent(0.12)
    var frost = NSVisualEffectView.Material.hudWindow
    var stroke = NSColor.labelColor.withAlphaComponent(0.22)

    private var curUser = 0.0
    private var curSystem = 0.0
    private var targetUser = 0.0
    private var targetSystem = 0.0
    private var animTimer: Timer?

    private func startAnimationIfNeeded() {
        if !Prefs.shared.animations {
            curUser = targetUser
            curSystem = targetSystem
            needsDisplay = true
            return
        }
        if animTimer != nil { return }
        if curUser == 0 && curSystem == 0 {
            curUser = targetUser
            curSystem = targetSystem
            needsDisplay = true
            return
        }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let du = (self.targetUser - self.curUser) * 0.45
            let ds = (self.targetSystem - self.curSystem) * 0.45
            self.curUser += du
            self.curSystem += ds
            if abs(self.targetUser - self.curUser) < 0.001 && abs(self.targetSystem - self.curSystem) < 0.001 {
                self.curUser = self.targetUser
                self.curSystem = self.targetSystem
                self.animTimer?.invalidate()
                self.animTimer = nil
            }
            self.needsDisplay = true
        }
        if let animTimer {
            RunLoop.main.add(animTimer, forMode: .common)
        }
    }
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            trackingAreas.forEach(removeTrackingArea)
            hover = 0
            return
        }
        armTracking()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        armTracking()
    }
    private func armTracking() {
        if trackingAreas.contains(where: { $0.owner === self }) { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .assumeInside],
            owner: self,
            userInfo: nil
        ))
    }
    private func pointerInside() -> Bool {
        guard let w = window else { return false }
        let p = convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return bounds.contains(p)
    }
    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        hover = seg(at: x)
    }
    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        if pointerInside() { return }
        hover = 0
    }
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
        if let p = tip {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
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
            win.addChildWindow(p, ordered: .above)
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
        let u = CGFloat(min(1, max(0, curUser))) * r.width
        let s = CGFloat(min(1, max(0, curSystem))) * r.width
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

final class SparklineNSView: NSView {
    var values: [Double] = [] {
        didSet {
            targetValues = values
            if currentValues.count != values.count {
                currentValues = values
                needsDisplay = true
            } else {
                startAnimationIfNeeded()
            }
        }
    }
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }

    private var currentValues: [Double] = []
    private var targetValues: [Double] = []
    private var animTimer: Timer?

    override var isOpaque: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            animTimer?.invalidate()
            animTimer = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        animTimer?.invalidate()
    }

    private func startAnimationIfNeeded() {
        if !Prefs.shared.animations {
            currentValues = targetValues
            needsDisplay = true
            return
        }
        if animTimer != nil { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            var changed = false
            for i in 0..<self.currentValues.count {
                let diff = self.targetValues[i] - self.currentValues[i]
                if abs(diff) > 0.001 {
                    self.currentValues[i] += diff * 0.45
                    changed = true
                } else {
                    self.currentValues[i] = self.targetValues[i]
                }
            }
            if !changed {
                self.animTimer?.invalidate()
                self.animTimer = nil
            }
            self.needsDisplay = true
        }
        if let animTimer {
            RunLoop.main.add(animTimer, forMode: .common)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !currentValues.isEmpty else { return }
        let n = max(currentValues.count, 1)
        let w = bounds.width / CGFloat(n)
        let bw = max(1.2, w * 0.62)
        color.setFill()
        for (i, v) in currentValues.enumerated() {
            let h = max(1, CGFloat(min(1, max(0, v))) * bounds.height)
            let r = NSRect(x: CGFloat(i) * w, y: bounds.minY, width: bw, height: h)
            let path = NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1)
            path.fill()
        }
    }
}

struct Sparkline: NSViewRepresentable {
    let values: [Double]
    let color: Color

    func makeNSView(context: Context) -> SparklineNSView {
        let v = SparklineNSView()
        v.values = values
        v.color = NSColor(color)
        return v
    }

    func updateNSView(_ nsView: SparklineNSView, context: Context) {
        nsView.values = values
        nsView.color = NSColor(color)
    }
}

final class NetChartNSView: NSView {
    var up: [Double] = [] {
        didSet {
            targetUp = up
            if curUp.count != up.count { curUp = up; needsDisplay = true }
            else { startAnimationIfNeeded() }
        }
    }
    var down: [Double] = [] {
        didSet {
            targetDown = down
            if curDown.count != down.count { curDown = down; needsDisplay = true }
            else { startAnimationIfNeeded() }
        }
    }

    private var curUp: [Double] = []
    private var curDown: [Double] = []
    private var targetUp: [Double] = []
    private var targetDown: [Double] = []
    private var animTimer: Timer?

    private static let upNSCol = NSColor(srgbRed: 1.0, green: 0.38, blue: 0.38, alpha: 1.0)
    private static let downNSCol = NSColor(srgbRed: 0.35, green: 0.80, blue: 0.95, alpha: 1.0)

    override var isOpaque: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            animTimer?.invalidate()
            animTimer = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        animTimer?.invalidate()
    }

    private func startAnimationIfNeeded() {
        if !Prefs.shared.animations {
            curUp = targetUp
            curDown = targetDown
            needsDisplay = true
            return
        }
        if animTimer != nil { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            var changed = false
            for i in 0..<self.curUp.count {
                let diff = self.targetUp[i] - self.curUp[i]
                if abs(diff) > max(0.001, abs(self.targetUp[i]) * 0.001) {
                    self.curUp[i] += diff * 0.45
                    changed = true
                } else {
                    self.curUp[i] = self.targetUp[i]
                }
            }
            for i in 0..<self.curDown.count {
                let diff = self.targetDown[i] - self.curDown[i]
                if abs(diff) > max(0.001, abs(self.targetDown[i]) * 0.001) {
                    self.curDown[i] += diff * 0.45
                    changed = true
                } else {
                    self.curDown[i] = self.targetDown[i]
                }
            }
            if !changed {
                self.animTimer?.invalidate()
                self.animTimer = nil
            }
            self.needsDisplay = true
        }
        if let animTimer {
            RunLoop.main.add(animTimer, forMode: .common)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = max(curUp.count, max(curDown.count, 1))
        let w = bounds.width / CGFloat(n)
        let bw = max(1.2, w * 0.62)
        var peak = 1.0
        for i in 0..<n {
            if i < curUp.count { peak = max(peak, curUp[i]) }
            if i < curDown.count { peak = max(peak, curDown[i]) }
        }
        let mid = bounds.height / 2

        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        var x: CGFloat = bounds.minX
        while x < bounds.maxX {
            NSRect(x: x, y: mid - 0.4, width: 2.4, height: 0.8).fill()
            x += 5
        }

        for i in 0..<n {
            let u = i < curUp.count ? curUp[i] : 0
            let d = i < curDown.count ? curDown[i] : 0
            let px = bounds.minX + CGFloat(i) * w
            let uh = CGFloat(u / peak) * (mid - 1)
            let dh = CGFloat(d / peak) * (mid - 1)
            if uh > 0.4 {
                Self.upNSCol.setFill()
                NSBezierPath(roundedRect: NSRect(x: px, y: mid, width: bw, height: uh), xRadius: 0.8, yRadius: 0.8).fill()
            }
            if dh > 0.4 {
                Self.downNSCol.setFill()
                NSBezierPath(roundedRect: NSRect(x: px, y: mid - dh, width: bw, height: dh), xRadius: 0.8, yRadius: 0.8).fill()
            }
        }
    }
}

struct NetChart: NSViewRepresentable {
    let up: [Double]
    let down: [Double]
    static let upCol = Color(red: 1.0, green: 0.38, blue: 0.38)
    static let downCol = Color(red: 0.35, green: 0.80, blue: 0.95)

    func makeNSView(context: Context) -> NetChartNSView {
        let v = NetChartNSView()
        v.up = up
        v.down = down
        return v
    }

    func updateNSView(_ nsView: NetChartNSView, context: Context) {
        nsView.up = up
        nsView.down = down
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
    var anim: Animation? {
        prefs.animations ? .spring(response: 0.18, dampingFraction: 0.85) : nil
    }
    var snappyAnim: Animation? {
        prefs.animations ? .snappy(duration: 0.20, extraBounce: 0.05) : nil
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

private func pct(_ v: Double) -> String {
    "\(Int((min(1, max(0, v)) * 100).rounded()))%"
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

final class SankeyInterpolator {
    static let shared = SankeyInterpolator()
    var dispSourceW: Double = 0
    var dispSysW: Double = 0
    var dispChargeW: Double = 0
    private var lastTime: CFTimeInterval = 0

    func update(targetSource: Double, targetSys: Double, targetCharge: Double) -> (Double, Double, Double) {
        let now = CACurrentMediaTime()
        if lastTime == 0 || (now - lastTime) > 1.0 {
            lastTime = now
            dispSourceW = targetSource
            dispSysW = targetSys
            dispChargeW = targetCharge
            return (dispSourceW, dispSysW, dispChargeW)
        }
        let dt = min(0.1, max(0.001, now - lastTime))
        lastTime = now
        let f = 1.0 - exp(-dt * 12.0)
        dispSourceW += (targetSource - dispSourceW) * f
        dispSysW += (targetSys - dispSysW) * f
        dispChargeW += (targetCharge - dispChargeW) * f
        return (dispSourceW, dispSysW, dispChargeW)
    }
}

struct PowerSankeyView: View {
    let adapterW: Double
    let batteryW: Double  // positive = charging, negative = discharging
    let systemW: Double
    let charging: Bool
    let accent: Color

    // ponytail: D3 palettes → Sino roles (ac/batt/sys)
    private static let ac   = Color(red: 0.22, green: 0.78, blue: 0.40)
    private static let batt = Color(red: 1.00, green: 0.62, blue: 0.04)
    private static let sys  = Color(red: 0.27, green: 0.61, blue: 0.96)

    var body: some View {
        // ponytail: sine ping-pong of blend center, ends pinned → Metal if still mid
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let e = CGFloat(0.50 + 0.22 * sin(t * Double.pi * 2.0 / 3.2))
            Canvas { ctx, size in
            let W = size.width, H = size.height
            let padL: CGFloat = 54
            let padR: CGFloat = 58
            let nodeW: CGFloat = 8
            let srcX = padL
            let dstX = max(srcX + nodeW + 28, W - padR - nodeW)

            let targetSourceW = charging ? (adapterW > 0 ? adapterW : systemW) : (systemW > 0 ? systemW : abs(batteryW))
            let targetSysW = max(systemW, 0.5)
            let targetChargeW = (charging && batteryW > 0) ? batteryW : 0.0

            let (sourceW, sysW, chargeW) = SankeyInterpolator.shared.update(
                targetSource: targetSourceW,
                targetSys: targetSysW,
                targetCharge: targetChargeW
            )
            let totalSink = sysW + chargeW
            let total = max(sourceW, totalSink, 0.5)

            let maxH = H * 0.68
            let srcH = max(8, CGFloat(sourceW / total) * maxH)
            let sysH = max(7, CGFloat(sysW / total) * maxH)
            let chgH: CGFloat = chargeW > 0 ? max(7, CGFloat(chargeW / total) * maxH) : 0
            let gap: CGFloat = chgH > 0 ? 10 : 0
            let rightH = sysH + chgH + gap

            let srcTop = (H - srcH) / 2
            let srcBot = srcTop + srcH
            let sysTop = (H - rightH) / 2
            let sysBot = sysTop + sysH
            let chgTop = sysBot + gap
            let chgBot = chgTop + chgH

            let sysRatio = totalSink > 0 ? CGFloat(sysW / totalSink) : 1
            let sysSliceH = chgH > 0 ? max(4, srcH * sysRatio) : srcH

            // tuck ribbons under node centers (d3-sankey overlap)
            let x0 = srcX + nodeW * 0.5
            let x1 = dstX + nodeW * 0.5
            let dx = x1 - x0
            let k: CGFloat = 0.5

            func ribbon(sy0: CGFloat, sy1: CGFloat, dy0: CGFloat, dy1: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: x0, y: sy0))
                p.addCurve(to: CGPoint(x: x1, y: dy0),
                           control1: CGPoint(x: x0 + dx * k, y: sy0),
                           control2: CGPoint(x: x1 - dx * k, y: dy0))
                p.addLine(to: CGPoint(x: x1, y: dy1))
                p.addCurve(to: CGPoint(x: x0, y: sy1),
                           control1: CGPoint(x: x1 - dx * k, y: dy1),
                           control2: CGPoint(x: x0 + dx * k, y: sy1))
                p.closeSubpath()
                return p
            }

            func edge(sy: CGFloat, dy: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: x0, y: sy))
                p.addCurve(to: CGPoint(x: x1, y: dy),
                           control1: CGPoint(x: x0 + dx * k, y: sy),
                           control2: CGPoint(x: x1 - dx * k, y: dy))
                return p
            }

            func fillRibbon(_ path: Path, from a: Color, to b: Color) {
                let op: CGFloat = 0.42
                let band: CGFloat = 0.22
                ctx.fill(path, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: a.opacity(op), location: 0),
                        .init(color: a.opacity(op), location: e - band),
                        .init(color: b.opacity(op), location: e + band),
                        .init(color: b.opacity(op), location: 1),
                    ]),
                    startPoint: CGPoint(x: x0, y: 0),
                    endPoint: CGPoint(x: x1, y: 0)
                ))
            }

            func quietEdge(_ p: Path, from a: Color, to b: Color) {
                let grad = Gradient(colors: [a.opacity(0.18), b.opacity(0.18)])
                ctx.stroke(p, with: .linearGradient(grad, startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)), lineWidth: 0.5)
            }

            let srcCol = Self.batt
            let sysPath = ribbon(sy0: srcTop, sy1: srcTop + sysSliceH, dy0: sysTop, dy1: sysBot)
            fillRibbon(sysPath, from: srcCol, to: Self.sys)
            quietEdge(edge(sy: srcTop, dy: sysTop), from: srcCol, to: Self.sys)
            quietEdge(edge(sy: srcTop + sysSliceH, dy: sysBot), from: srcCol, to: Self.sys)

            if chgH > 0 {
                let chgPath = ribbon(sy0: srcTop + sysSliceH, sy1: srcBot, dy0: chgTop, dy1: chgBot)
                fillRibbon(chgPath, from: srcCol, to: Self.ac)
                quietEdge(edge(sy: srcTop + sysSliceH, dy: chgTop), from: srcCol, to: Self.ac)
                quietEdge(edge(sy: srcBot, dy: chgBot), from: srcCol, to: Self.ac)
            }

            func bar(_ r: CGRect, _ c: Color) {
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(c))
            }
            bar(CGRect(x: srcX, y: srcTop, width: nodeW, height: srcH), srcCol)
            bar(CGRect(x: dstX, y: sysTop, width: nodeW, height: sysH), Self.sys)
            if chgH > 0 {
                bar(CGRect(x: dstX, y: chgTop, width: nodeW, height: chgH), Self.ac)
            }

            let titleF = Font.system(size: 9, weight: .medium)
            let valF = Font.system(size: 9.5, weight: .semibold).monospacedDigit()
            let srcTitle = charging ? "Adapter" : "Battery"
            let srcMid = srcTop + srcH / 2
            ctx.draw(Text(srcTitle).font(titleF).foregroundColor(.secondary),
                     at: CGPoint(x: srcX - 6, y: srcMid - 7), anchor: .trailing)
            ctx.draw(Text(watts(sourceW)).font(valF).foregroundColor(.primary),
                     at: CGPoint(x: srcX - 6, y: srcMid + 6), anchor: .trailing)

            let sysMid = sysTop + sysH / 2
            ctx.draw(Text("System").font(titleF).foregroundColor(.secondary),
                     at: CGPoint(x: dstX + nodeW + 6, y: sysMid - 7), anchor: .leading)
            ctx.draw(Text(watts(sysW)).font(valF).foregroundColor(.primary),
                     at: CGPoint(x: dstX + nodeW + 6, y: sysMid + 6), anchor: .leading)

            if chgH > 0 {
                let chgMid = chgTop + chgH / 2
                ctx.draw(Text("Charging").font(titleF).foregroundColor(.secondary),
                         at: CGPoint(x: dstX + nodeW + 6, y: chgMid - 7), anchor: .leading)
                ctx.draw(Text(watts(chargeW)).font(valF).foregroundColor(.primary),
                         at: CGPoint(x: dstX + nodeW + 6, y: chgMid + 6), anchor: .leading)
            }
        }
    }
}
}

private func watts(_ w: Double) -> String {
    if w < 1 { return String(format: "%.0f mW", w * 1000) }
    return String(format: "%.2f W", w)
}

// MARK: - Clamshell / pmset sleep helper
enum FanCtl {
    static var ready: Bool {
        FileManager.default.fileExists(atPath: "/var/run/com.lov3u.sino.smcwrite.sock")
    }

    static func install() -> Bool {
        let src = Bundle.main.path(forResource: "sino-smcwrite", ofType: nil)
            ?? Bundle.main.bundlePath + "/Contents/Resources/sino-smcwrite"
        guard FileManager.default.isExecutableFile(atPath: src) || FileManager.default.fileExists(atPath: src) else {
            return false
        }
        let escaped = src.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\\\"\(escaped)\\\" --install\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}

enum PMSetHelper {
    static let sudoersFile = "/private/etc/sudoers.d/sino_awake"
    static let sudoersBody = "Cmnd_Alias SINO_PMSET = /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a lowpowermode 1, /usr/bin/pmset -a lowpowermode 0\n%admin ALL=(ALL) NOPASSWD: SINO_PMSET\n"

    static var isSudoersInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
    }

    @discardableResult
    static func installSudoers() -> Bool {
        if isSudoersInstalled { return true }
        let cmd = "printf '%s' '\(sudoersBody)' > \(sudoersFile) && chmod 0440 \(sudoersFile)"
        return runPrivileged(cmd)
    }

    static var isSleepDisabled: Bool { pmsetFlag("SleepDisabled") }
    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || pmsetFlag("lowpowermode")
    }

    private static func pmsetFlag(_ key: String) -> Bool {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let str = String(data: data, encoding: .utf8) else { return false }
            for line in str.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.lowercased().hasPrefix(key.lowercased()) else { continue }
                let parts = t.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2, parts[1] == "1" { return true }
            }
        } catch {}
        return false
    }

    @discardableResult
    static func setSleepDisabled(_ disable: Bool) -> Bool {
        setPmset("disablesleep", disable)
    }

    @discardableResult
    static func setLowPowerMode(_ on: Bool) -> Bool {
        setPmset("lowpowermode", on)
    }

    @discardableResult
    private static func setPmset(_ key: String, _ on: Bool) -> Bool {
        let val = on ? "1" : "0"
        let sudoProc = Process()
        sudoProc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sudoProc.arguments = ["-n", "/usr/bin/pmset", "-a", key, val]
        sudoProc.standardOutput = Pipe()
        sudoProc.standardError = Pipe()
        do {
            try sudoProc.run()
            sudoProc.waitUntilExit()
            if sudoProc.terminationStatus == 0 { return true }
        } catch {}
        let cmd = "printf '%s' '\(sudoersBody)' > \(sudoersFile) && chmod 0440 \(sudoersFile) && /usr/bin/pmset -a \(key) \(val)"
        return runPrivileged(cmd)
    }

    private static func runPrivileged(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
