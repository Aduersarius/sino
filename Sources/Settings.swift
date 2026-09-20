import AppKit
import Carbon
import Combine
import CoreLocation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct FanCurvePoint: Equatable {
    var temp: Double
    var rpm: Double
}

enum FanMode: String, Hashable {
    case auto, manual, curve
}

enum FanCurves {
    static func silent(min: Double, max: Double) -> [FanCurvePoint] {
        [FanCurvePoint(temp: 40, rpm: min), FanCurvePoint(temp: 82, rpm: min), FanCurvePoint(temp: 98, rpm: min + (max - min) * 0.4)]
    }
    static func balanced(min: Double, max: Double) -> [FanCurvePoint] {
        [FanCurvePoint(temp: 55, rpm: min), FanCurvePoint(temp: 78, rpm: min + (max - min) * 0.45), FanCurvePoint(temp: 96, rpm: max)]
    }
    static func full(min: Double, max: Double) -> [FanCurvePoint] {
        [FanCurvePoint(temp: 30, rpm: max), FanCurvePoint(temp: 60, rpm: max), FanCurvePoint(temp: 100, rpm: max)]
    }
    static func rpm(_ temp: Double, _ points: [FanCurvePoint]) -> Double {
        let p = points.sorted { $0.temp < $1.temp }
        guard let first = p.first, let last = p.last else { return 2317 }
        if temp <= first.temp { return first.rpm }
        if temp >= last.temp { return last.rpm }
        if p.count == 1 { return first.rpm }
        var m = [Double](repeating: 0, count: p.count)
        for i in 0..<p.count {
            if i == 0 {
                let dt = p[1].temp - p[0].temp
                m[i] = dt > 0.01 ? (p[1].rpm - p[0].rpm) / dt : 0
            } else if i == p.count - 1 {
                let dt = p[i].temp - p[i - 1].temp
                m[i] = dt > 0.01 ? (p[i].rpm - p[i - 1].rpm) / dt : 0
            } else {
                let dt = p[i + 1].temp - p[i - 1].temp
                m[i] = dt > 0.01 ? (p[i + 1].rpm - p[i - 1].rpm) / dt : 0
            }
        }
        for i in 0..<(p.count - 1) {
            let a = p[i], b = p[i + 1]
            if temp <= b.temp {
                let dt = max(0.01, b.temp - a.temp)
                let u = (temp - a.temp) / dt
                let u2 = u * u
                let u3 = u2 * u
                let v = (2 * u3 - 3 * u2 + 1) * a.rpm
                    + (u3 - 2 * u2 + u) * dt * m[i]
                    + (-2 * u3 + 3 * u2) * b.rpm
                    + (u3 - u2) * dt * m[i + 1]
                let lo = min(a.rpm, b.rpm), hi = max(a.rpm, b.rpm)
                return max(lo, min(hi, v))
            }
        }
        return last.rpm
    }
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    static let modules: [(id: String, title: String, icon: String)] = [
        ("cat", "Cat", "cat"),
        ("cpu", "CPU", "cpu"),
        ("ram", "RAM", "memorychip"),
        ("gpu", "GPU", "display"),
        ("storage", "Storage", "internaldrive"),
        ("net", "Network", "network"),
        ("fans", "Fans", "fan"),
        ("battery", "Battery", "battery.100percent")
    ]
    static let dropElements: [(id: String, title: String, icon: String)] = [
        ("cpu", "CPU", "cpu"),
        ("ram", "RAM", "memorychip"),
        ("gpu", "GPU", "display"),
        ("storage", "Storage", "internaldrive"),
        ("net", "Network", "network"),
        ("fans", "Fans", "fan"),
        ("battery", "Battery", "battery.100percent"),
        ("toolbar", "Toolbar", "menubar.dock.rectangle")
    ]
    static let sidePanels: [(id: String, title: String, icon: String)] = [
        ("cpu", "CPU", "cpu"),
        ("ram", "RAM", "memorychip"),
        ("gpu", "GPU", "display"),
        ("storage", "Storage", "internaldrive"),
        ("net", "Network", "network"),
        ("fans", "Fans", "fan"),
        ("battery", "Battery", "battery.100percent")
    ]
    static let sideSections: [String: [(id: String, title: String, icon: String)]] = [
        "cpu": [
            ("cores", "CPU Cores", "cpu"),
            ("procs", "CPU Usage", "square.grid.2x2"),
            ("gpu", "GPU Summary", "display")
        ],
        "ram": [
            ("memory", "Memory & Clean", "memorychip"),
            ("procs", "Processes", "square.grid.2x2")
        ],
        "gpu": [
            ("gpu", "GPU Details", "display")
        ],
        "storage": [
            ("activity", "Storage Activity", "externaldrive.connected.to.line.below"),
            ("volumes", "Volumes", "internaldrive")
        ],
        "net": [
            ("chart", "Bandwidth & Chart", "network"),
            ("wifi", "Wi-Fi Details", "wifi"),
            ("addresses", "Addresses & Geo", "globe"),
            ("topProc", "Top Process", "square.grid.2x2")
        ],
        "fans": [
            ("fans", "Fan Speeds", "fan"),
            ("sensors", "Sensors", "thermometer")
        ],
        "battery": [
            ("battery", "Battery & Power", "battery.100percent"),
            ("energy", "Energy Usage", "bolt.fill")
        ]
    ]
    static let frosts: [(id: String, title: String)] = [
        ("hud", "HUD"),
        ("menu", "Menu"),
        ("popover", "Popover"),
        ("sidebar", "Sidebar"),
        ("header", "Header"),
        ("window", "Window")
    ]
    static let toolbarButtons: [(id: String, title: String, icon: String)] = [
        ("activity", "Activity Monitor", "waveform.path.ecg"),
        ("terminal", "Terminal", "terminal.fill"),
        ("interval", "Refresh Interval", "timer"),
        ("theme", "Theme", "sun.max.fill"),
        ("awake", "Awake", "cup.and.saucer.fill"),
        ("app1", "Shortcut App 1", "plus.app"),
        ("app2", "Shortcut App 2", "plus.app"),
        ("app3", "Shortcut App 3", "plus.app")
    ]

    @Published var interval: Double
    @Published var bar: Set<String>
    @Published var barOrder: [String]
    @Published var drop: Set<String>
    @Published var dropOrder: [String]
    @Published var sideOrder: [String: [String]]
    @Published var sideHidden: Set<String>
    @Published var expandedAccordionPanel: String? = "cpu"
    @Published var toolbar: Set<String>
    @Published var toolbarOrder: [String]
    @Published var login: Bool
    @Published var colors: [String: [Double]]
    @Published var frost: String
    @Published var frostTint: Double
    @Published var frostBehind: Bool
    @Published var customApp: String
    @Published var customApp2: String
    @Published var customApp3: String
    @Published var cpuProcMode: String // "total" (0-100%) or "perCore" (100% per core)
    @Published var cpuProcCount: Int
    @Published var ramProcCount: Int
    @Published var awakeShortcutKeyCode: Int
    @Published var awakeShortcutModifiers: UInt
    @Published var rightClickAwake: Bool
    @Published var preventDisplaySleep: Bool
    @Published var preventLidSleep: Bool
    @Published var animations: Bool
    @Published var updateNotify: Bool
    @Published var updateBanner: Bool
    @Published var hasCompletedOnboarding: Bool
    @Published var fanCurve: [FanCurvePoint]

    private init() {
        let d = UserDefaults.standard
        interval = (d.object(forKey: "sino.interval") ?? d.object(forKey: "pulse.interval")) as? Double ?? 1
        cpuProcMode = d.string(forKey: "sino.cpuProcMode") ?? d.string(forKey: "pulse.cpuProcMode") ?? "total"
        cpuProcCount = (d.object(forKey: "sino.cpuProcCount") ?? d.object(forKey: "pulse.cpuProcCount")) as? Int ?? 5
        ramProcCount = (d.object(forKey: "sino.ramProcCount") ?? d.object(forKey: "pulse.ramProcCount")) as? Int ?? 10
        awakeShortcutKeyCode = (d.object(forKey: "sino.awakeShortcutKeyCode") ?? d.object(forKey: "pulse.awakeShortcutKeyCode")) as? Int ?? kVK_ANSI_A
        awakeShortcutModifiers = (d.object(forKey: "sino.awakeShortcutModifiers") ?? d.object(forKey: "pulse.awakeShortcutModifiers")) as? UInt ?? UInt(controlKey | optionKey)
        var barSet = Set(d.stringArray(forKey: "sino.bar") ?? d.stringArray(forKey: "pulse.bar") ?? ["cat", "ram", "cpu"])
        let ids = Prefs.modules.map(\.id)
        var order = d.stringArray(forKey: "sino.barOrder") ?? d.stringArray(forKey: "pulse.barOrder") ?? []
        order = order.filter { ids.contains($0) }
        for id in ids where !order.contains(id) { order.append(id) }
        // ponytail: one-shot — sit the cat on the left; toggle stays in Menu Bar
        if d.object(forKey: "sino.catChip") == nil {
            barSet.insert("cat")
            if let i = order.firstIndex(of: "cat") { order.remove(at: i) }
            order.insert("cat", at: 0)
            d.set(true, forKey: "sino.catChip")
            d.set(Array(barSet), forKey: "sino.bar")
            d.set(order, forKey: "sino.barOrder")
        }
        bar = barSet
        barOrder = order
        let dropIds = Prefs.dropElements.map(\.id)
        var dOrder = d.stringArray(forKey: "sino.dropOrder") ?? []
        dOrder = dOrder.filter { dropIds.contains($0) }
        for id in dropIds where !dOrder.contains(id) { dOrder.append(id) }
        dropOrder = dOrder
        var dSet = Set(d.stringArray(forKey: "sino.drop") ?? d.stringArray(forKey: "pulse.drop") ?? dropIds)
        if d.object(forKey: "sino.dropOrder") == nil {
            dSet.insert("toolbar")
        }
        drop = dSet.isEmpty ? ["cpu"] : dSet

        var sOrder = (d.object(forKey: "sino.sideOrder") as? [String: [String]]) ?? [:]
        for (k, items) in Prefs.sideSections {
            let validIds = items.map(\.id)
            if sOrder[k] == nil {
                sOrder[k] = validIds
            } else {
                var cur = sOrder[k]!.filter { validIds.contains($0) }
                for id in validIds where !cur.contains(id) { cur.append(id) }
                sOrder[k] = cur
            }
        }
        sideOrder = sOrder
        sideHidden = Set(d.stringArray(forKey: "sino.sideHidden") ?? [])
        let toolIds = Prefs.toolbarButtons.map(\.id)
        toolbar = Set(d.stringArray(forKey: "sino.toolbar") ?? toolIds)
        var tOrder = d.stringArray(forKey: "sino.toolbarOrder") ?? []
        tOrder = tOrder.filter { toolIds.contains($0) }
        for id in toolIds where !tOrder.contains(id) { tOrder.append(id) }
        toolbarOrder = tOrder
        login = (d.object(forKey: "sino.login") ?? d.object(forKey: "pulse.login")) as? Bool ?? false
        var cols = (d.object(forKey: "sino.colors") ?? d.object(forKey: "pulse.colors")) as? [String: [Double]] ?? [:]
        if cols["outline"] == nil, (d.object(forKey: "sino.strokeA") ?? d.object(forKey: "pulse.strokeA")) != nil {
            cols["outline"] = [
                d.double(forKey: "sino.strokeR"),
                d.double(forKey: "sino.strokeG"),
                d.double(forKey: "sino.strokeB"),
                d.double(forKey: "sino.strokeA")
            ]
        }
        colors = cols
        frost = d.string(forKey: "sino.frost") ?? d.string(forKey: "pulse.frost") ?? "hud"
        frostTint = (d.object(forKey: "sino.frostTint") ?? d.object(forKey: "pulse.frostTint")) as? Double ?? 0
        frostBehind = (d.object(forKey: "sino.frostBehind") ?? d.object(forKey: "pulse.frostBehind")) as? Bool ?? true
        customApp = d.string(forKey: "sino.customApp") ?? d.string(forKey: "pulse.customApp") ?? ""
        customApp2 = d.string(forKey: "sino.customApp2") ?? d.string(forKey: "pulse.customApp2") ?? ""
        customApp3 = d.string(forKey: "sino.customApp3") ?? d.string(forKey: "pulse.customApp3") ?? ""
        rightClickAwake = (d.object(forKey: "sino.rightClickAwake") ?? d.object(forKey: "pulse.rightClickAwake")) as? Bool ?? false
        preventDisplaySleep = (d.object(forKey: "sino.preventDisplaySleep") ?? d.object(forKey: "pulse.preventDisplaySleep")) as? Bool ?? true
        preventLidSleep = (d.object(forKey: "sino.preventLidSleep") ?? d.object(forKey: "pulse.preventLidSleep")) as? Bool ?? true
        animations = (d.object(forKey: "sino.animations") ?? d.object(forKey: "pulse.animations")) as? Bool ?? true
        updateNotify = (d.object(forKey: "sino.updateNotify") ?? d.object(forKey: "pulse.updateNotify")) as? Bool ?? true
        updateBanner = (d.object(forKey: "sino.updateBanner") ?? d.object(forKey: "pulse.updateBanner")) as? Bool ?? true
        hasCompletedOnboarding = (d.object(forKey: "sino.hasCompletedOnboarding") ?? d.object(forKey: "pulse.hasCompletedOnboarding")) as? Bool ?? false
        if let raw = d.array(forKey: "sino.fanCurve") as? [[Double]], raw.count >= 3 {
            fanCurve = raw.prefix(3).map { FanCurvePoint(temp: $0[0], rpm: $0[1]) }
        } else {
            fanCurve = FanCurves.balanced(min: 2317, max: 6800)
        }
        if bar.isEmpty { bar = ["ram", "cpu"] }
        if drop.isEmpty { drop = ["cpu"] }
        if d.object(forKey: "sino.frost.light") == nil && d.object(forKey: "pulse.frost.light") == nil { writeSlot(false) }
        if d.object(forKey: "sino.frost.dark") == nil && d.object(forKey: "pulse.frost.dark") == nil { writeSlot(true) }
        loadSlot()
    }

    func isDark() -> Bool {
        let t = UserDefaults.standard.string(forKey: "theme") ?? "system"
        if t == "light" { return false }
        if t == "dark" { return true }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func writeSlot(_ dark: Bool? = nil) {
        let s = (dark ?? isDark()) ? "dark" : "light"
        let d = UserDefaults.standard
        d.set(frost, forKey: "sino.frost.\(s)")
        d.set(frostTint, forKey: "sino.frostTint.\(s)")
        d.set(frostBehind, forKey: "sino.frostBehind.\(s)")
        d.set(colors, forKey: "sino.colors.\(s)")
    }

    func loadSlot(_ dark: Bool? = nil) {
        let s = (dark ?? isDark()) ? "dark" : "light"
        let d = UserDefaults.standard
        frost = d.string(forKey: "sino.frost.\(s)") ?? d.string(forKey: "pulse.frost.\(s)") ?? frost
        frostTint = (d.object(forKey: "sino.frostTint.\(s)") ?? d.object(forKey: "pulse.frostTint.\(s)")) as? Double ?? frostTint
        frostBehind = (d.object(forKey: "sino.frostBehind.\(s)") ?? d.object(forKey: "pulse.frostBehind.\(s)")) as? Bool ?? frostBehind
        if let c = (d.object(forKey: "sino.colors.\(s)") ?? d.object(forKey: "pulse.colors.\(s)")) as? [String: [Double]] { colors = c }
    }

    func save() {
        let d = UserDefaults.standard
        d.set(interval, forKey: "sino.interval")
        d.set(Array(bar), forKey: "sino.bar")
        d.set(barOrder, forKey: "sino.barOrder")
        d.set(Array(drop), forKey: "sino.drop")
        d.set(dropOrder, forKey: "sino.dropOrder")
        d.set(sideOrder, forKey: "sino.sideOrder")
        d.set(Array(sideHidden), forKey: "sino.sideHidden")
        d.set(Array(toolbar), forKey: "sino.toolbar")
        d.set(toolbarOrder, forKey: "sino.toolbarOrder")
        d.set(login, forKey: "sino.login")
        d.set(colors, forKey: "sino.colors")
        d.set(frost, forKey: "sino.frost")
        d.set(frostTint, forKey: "sino.frostTint")
        d.set(frostBehind, forKey: "sino.frostBehind")
        d.set(customApp, forKey: "sino.customApp")
        d.set(customApp2, forKey: "sino.customApp2")
        d.set(customApp3, forKey: "sino.customApp3")
        d.set(cpuProcMode, forKey: "sino.cpuProcMode")
        d.set(cpuProcCount, forKey: "sino.cpuProcCount")
        d.set(ramProcCount, forKey: "sino.ramProcCount")
        d.set(rightClickAwake, forKey: "sino.rightClickAwake")
        d.set(preventDisplaySleep, forKey: "sino.preventDisplaySleep")
        d.set(preventLidSleep, forKey: "sino.preventLidSleep")
        d.set(animations, forKey: "sino.animations")
        d.set(updateNotify, forKey: "sino.updateNotify")
        d.set(updateBanner, forKey: "sino.updateBanner")
        d.set(fanCurve.map { [$0.temp, $0.rpm] }, forKey: "sino.fanCurve")
        writeSlot()
    }

    func setCurvePoint(_ i: Int, temp: Double? = nil, rpm: Double? = nil) {
        guard fanCurve.indices.contains(i) else { return }
        var pts = fanCurve
        if let temp { pts[i].temp = min(105, max(30, temp)) }
        if let rpm { pts[i].rpm = rpm }
        fanCurve = pts
        save()
        App.shared.reassertFans()
    }

    func applyFanPreset(_ id: String, minRPM: Double, maxRPM: Double) {
        switch id {
        case "silent": fanCurve = FanCurves.silent(min: minRPM, max: maxRPM)
        case "full": fanCurve = FanCurves.full(min: minRPM, max: maxRPM)
        default: fanCurve = FanCurves.balanced(min: minRPM, max: maxRPM)
        }
        save()
        App.shared.setFanMode(.curve)
    }

    func barBind(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.bar.contains(id) },
            set: { on in
                if on { self.bar.insert(id) }
                else {
                    self.bar.remove(id)
                    if self.bar.isEmpty { self.bar.insert("cpu") }
                }
                self.save()
            }
        )
    }

    func toolbarBind(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.toolbar.contains(id) },
            set: { on in
                if on { self.toolbar.insert(id) }
                else { self.toolbar.remove(id) }
                self.save()
            }
        )
    }

    func moveBarIndex(from i: Int, to j: Int) {
        guard i != j, barOrder.indices.contains(i), barOrder.indices.contains(j) else { return }
        barOrder.move(fromOffsets: IndexSet(integer: i), toOffset: j > i ? j + 1 : j)
    }

    func dropBind(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.drop.contains(id) },
            set: { on in
                if on { self.drop.insert(id) }
                else {
                    self.drop.remove(id)
                    if self.drop.isEmpty { self.drop.insert("cpu") }
                }
                self.save()
            }
        )
    }

    func sideBind(_ panel: String, _ sectionId: String) -> Binding<Bool> {
        let key = "\(panel):\(sectionId)"
        return Binding(
            get: { !self.sideHidden.contains(key) },
            set: { on in
                if on { self.sideHidden.remove(key) }
                else { self.sideHidden.insert(key) }
                self.save()
            }
        )
    }

    func isSideVisible(_ panel: String, _ sectionId: String) -> Bool {
        !sideHidden.contains("\(panel):\(sectionId)")
    }

    var frostMaterial: NSVisualEffectView.Material {
        switch frost {
        case "menu": return .menu
        case "popover": return .popover
        case "sidebar": return .sidebar
        case "header": return .headerView
        case "window": return .windowBackground
        default: return .hudWindow
        }
    }

    func nsColor(_ key: String, fallback: NSColor) -> NSColor {
        guard let v = colors[key], v.count == 4, v[3] >= 0 else { return fallback }
        return NSColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: v[3])
    }

    func swiftColor(_ key: String, fallback: NSColor) -> Color {
        Color(nsColor: nsColor(key, fallback: fallback))
    }

    func colorBind(_ key: String, fallback: NSColor) -> Binding<Color> {
        Binding(
            get: { self.swiftColor(key, fallback: fallback) },
            set: { c in
                let ns = NSColor(c).usingColorSpace(.sRGB) ?? fallback
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                ns.getRed(&r, green: &g, blue: &b, alpha: &a)
                self.colors[key] = [Double(r), Double(g), Double(b), Double(a)]
                self.save()
                App.shared.applyStroke()
            }
        )
    }

    var strokeNS: NSColor {
        nsColor("outline", fallback: NSColor.labelColor.withAlphaComponent(0.22))
    }

    func setInterval(_ v: Double) {
        interval = min(5, max(0.25, v))
        save()
        App.shared.sampler.setInterval(interval)
    }

    func setCpuProcMode(_ m: String) {
        cpuProcMode = m
        save()
    }

    func setCpuProcCount(_ v: Int) {
        cpuProcCount = max(3, min(30, v))
        save()
    }

    func setRamProcCount(_ v: Int) {
        ramProcCount = max(3, min(30, v))
        save()
    }

    func setAwakeShortcut(keyCode: Int, modifiers: UInt) {
        awakeShortcutKeyCode = keyCode
        awakeShortcutModifiers = modifiers
        let d = UserDefaults.standard
        d.set(keyCode, forKey: "sino.awakeShortcutKeyCode")
        d.set(modifiers, forKey: "sino.awakeShortcutModifiers")
        HotKeyManager.shared.update(keyCode: keyCode, modifiers: modifiers)
    }

    func setRightClickAwake(_ on: Bool) {
        rightClickAwake = on
        save()
    }

    func setPreventDisplaySleep(_ on: Bool) {
        preventDisplaySleep = on
        save()
    }

    func setPreventLidSleep(_ on: Bool) {
        preventLidSleep = on
        save()
    }

    func setAnimations(_ on: Bool) {
        animations = on
        save()
    }

    func setUpdateNotify(_ on: Bool) {
        updateNotify = on
        updateBanner = on
        save()
    }

    func setUpdateBanner(_ on: Bool) {
        updateBanner = on
        save()
    }

    func setHasCompletedOnboarding(_ on: Bool) {
        hasCompletedOnboarding = on
        UserDefaults.standard.set(on, forKey: "sino.hasCompletedOnboarding")
    }

    func setLogin(_ on: Bool) {
        login = on
        save()
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {}
        }
    }

    func resetAppearance() {
        colors = [:]
        frost = "hud"
        frostTint = 0
        frostBehind = true
        save()
        App.shared.applyStroke()
    }

    func customAppPath(slot: Int = 1) -> String {
        slot == 3 ? customApp3 : (slot == 2 ? customApp2 : customApp)
    }

    func customAppName(slot: Int = 1) -> String {
        let path = customAppPath(slot: slot)
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    func customAppIcon(slot: Int = 1) -> NSImage? {
        let path = customAppPath(slot: slot)
        guard !path.isEmpty else { return nil }
        let raw = NSWorkspace.shared.icon(forFile: path)
        if let best = raw.representations.max(by: { $0.pixelsWide < $1.pixelsWide }), best.pixelsWide >= 64 {
            let img = NSImage(size: NSSize(width: 32, height: 32))
            img.addRepresentation(best)
            return img
        }
        return raw
    }

    var customAppName: String { customAppName(slot: 1) }
    var customAppIcon: NSImage? { customAppIcon(slot: 1) }

    func pickCustomApp(slot: Int = 1) {
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = "Choose"
        p.message = "App for the dropdown toolbar"
        let res = p.runModal()

        if wasAccessory && App.shared.settingsWC == nil {
            NSApp.setActivationPolicy(.accessory)
        }

        guard res == .OK, let url = p.url else { return }
        if slot == 3 {
            customApp3 = url.path
        } else if slot == 2 {
            customApp2 = url.path
        } else {
            customApp = url.path
        }
        save()
    }

    func clearCustomApp(slot: Int = 1) {
        if slot == 3 {
            customApp3 = ""
        } else if slot == 2 {
            customApp2 = ""
        } else {
            customApp = ""
        }
        save()
    }
}

enum Chrome {
    static func window(_ dark: Bool) -> Color {
        dark ? Color(red: 0.118, green: 0.118, blue: 0.118) : Color(red: 0.95, green: 0.95, blue: 0.97)
    }
    static func sidebar(_ dark: Bool) -> Color {
        dark ? Color(red: 0.133, green: 0.133, blue: 0.133) : Color(red: 0.98, green: 0.98, blue: 0.99)
    }
    static func sidebarBorder(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
    }
    static func group(_ dark: Bool) -> Color {
        dark ? Color(red: 0.145, green: 0.145, blue: 0.145) : Color.white
    }
    static func cardBorder(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
    static func selected(_ dark: Bool) -> Color {
        dark ? Color(red: 0.23, green: 0.23, blue: 0.23) : Color.black.opacity(0.07)
    }
    static func badge(_ dark: Bool) -> Color {
        dark ? Color(red: 0.18, green: 0.18, blue: 0.19) : Color.black.opacity(0.06)
    }
    static func badgeBorder(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
    static let text: Font = .system(size: 13)
    static let title: Font = .system(size: 18, weight: .bold)
    static let section: Font = .system(size: 13, weight: .semibold)
    static let caption: Font = .system(size: 11)
    static let rail: CGFloat = 180
} 

final class Updater: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Updater()
    static let repo = "Aduersarius/sino"
    @Published var status = "—"
    @Published var updateURL: URL?
    @Published var downloadURL: URL?
    @Published var isUpdating = false
    @Published var updateProgress: String? = nil
    @Published var availableVersion: String?

    var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private override init() { super.init() }

    func start() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        check(notify: true)
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.check(notify: true)
        }
    }

    func check(notify: Bool = false) {
        guard !isUpdating else { return }
        status = "Checking…"
        if !notify {
            updateURL = nil
            downloadURL = nil
        }
        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err {
                    self.status = err.localizedDescription
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 {
                    self.status = "No GitHub releases yet"
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.status = "Couldn't read GitHub"
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if let html = json["html_url"] as? String { self.updateURL = URL(string: html) }
                if let assets = json["assets"] as? [[String: Any]],
                   let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                   let dl = zipAsset["browser_download_url"] as? String {
                    self.downloadURL = URL(string: dl)
                }
                if latest.compare(self.current, options: .numeric) == .orderedDescending {
                    self.availableVersion = latest
                    self.status = "\(latest) available"
                    if notify, Prefs.shared.updateNotify { self.ping(latest) }
                } else {
                    self.availableVersion = nil
                    self.status = "Up to date"
                }
            }
        }.resume()
    }

    func performUpdate() {
        guard !isUpdating else { return }
        guard let dl = downloadURL ?? URL(string: "https://github.com/\(Updater.repo)/releases/latest/download/Sino.app.zip") else {
            openUpdate()
            return
        }

        isUpdating = true
        updateProgress = "Downloading update…"

        let session = URLSession(configuration: .default)
        session.downloadTask(with: dl) { tempURL, resp, err in
            if let err {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.updateProgress = nil
                    self.status = "Download failed: \(err.localizedDescription)"
                }
                return
            }
            guard let tempURL else {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.updateProgress = nil
                    self.status = "Download failed"
                }
                return
            }

            DispatchQueue.main.async {
                self.updateProgress = "Installing update…"
            }

            let script = """
            DEST="/Applications/Sino.app"
            WORK=$(mktemp -d /tmp/sino_update_XXXXXX)
            trap 'rm -rf "$WORK"' EXIT
            cp "\(tempURL.path)" "$WORK/Sino.app.zip"
            ditto -x -k "$WORK/Sino.app.zip" "$WORK"
            APP=$(find "$WORK" -maxdepth 2 -name 'Sino.app' | head -1)
            if [ -n "$APP" ]; then
                rm -rf "$DEST"
                cp -R "$APP" "$DEST"
                xattr -cr "$DEST" 2>/dev/null || true
                codesign -s - --force --deep "$DEST" >/dev/null 2>&1 || true
                sleep 0.5
                open -n "$DEST"
            fi
            """

            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = ["-c", script]
                try? proc.run()
                proc.waitUntilExit()

                DispatchQueue.main.async {
                    if proc.terminationStatus == 0 {
                        NSApp.terminate(nil)
                    } else {
                        self.isUpdating = false
                        self.updateProgress = nil
                        self.status = "Installation failed"
                    }
                }
            }
        }.resume()
    }

    private func ping(_ latest: String) {
        let key = "sino.update.notifiedTag"
        if (UserDefaults.standard.string(forKey: key) ?? UserDefaults.standard.string(forKey: "pulse.update.notifiedTag")) == latest { return }
        UserDefaults.standard.set(latest, forKey: key)
        let c = UNMutableNotificationContent()
        c.title = "Sino"
        c.body = "Version \(latest) is ready — update available"
        c.sound = .default
        let req = UNNotificationRequest(identifier: "sino.update.\(latest)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func openUpdate() {
        if let u = updateURL { NSWorkspace.shared.open(u) }
        else if let u = URL(string: "https://github.com/\(Updater.repo)/releases") {
            NSWorkspace.shared.open(u)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        openUpdate()
        completionHandler()
    }
}

final class FanCurveView: NSView {
    var points: [FanCurvePoint] = []
    var rpmLo = 2317.0
    var rpmHi = 6800.0
    var nowTemp = 0.0
    var nowRPM = 0.0
    var dark = true
    var onChange: ((Int, Double, Double) -> Void)?
    private var drag: Int?
    private var dragTemp = 0.0
    private var dragRPM = 0.0
    private let tLo = 30.0, tHi = 105.0
    private let padL: CGFloat = 46, padR: CGFloat = 10, padT: CGFloat = 16, padB: CGFloat = 26

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    private var plot: NSRect {
        NSRect(x: padL, y: padT, width: max(8, bounds.width - padL - padR), height: max(8, bounds.height - padT - padB))
    }

    private func pos(_ p: FanCurvePoint) -> NSPoint {
        let r = plot
        let x = r.minX + CGFloat((p.temp - tLo) / (tHi - tLo)) * r.width
        let u = (p.rpm - rpmLo) / max(1, rpmHi - rpmLo)
        return NSPoint(x: x, y: r.maxY - CGFloat(min(1, max(0, u))) * r.height)
    }

    private func values(_ loc: NSPoint) -> (Double, Double) {
        let r = plot
        let tx = min(1, max(0, Double((loc.x - r.minX) / max(1, r.width))))
        let ty = min(1, max(0, Double((r.maxY - loc.y) / max(1, r.height))))
        return (tLo + tx * (tHi - tLo), rpmLo + ty * (rpmHi - rpmLo))
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = plot
        let grid = dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)
        let ink = dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.55)
        let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)
        let box = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (dark ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.03)).setFill()
        box.fill()
        grid.setStroke()
        box.lineWidth = 1
        box.stroke()

        let font = NSFont.systemFont(ofSize: 9)
        func label(_ s: String, _ at: NSPoint, _ align: NSTextAlignment) {
            let para = NSMutableParagraphStyle()
            para.alignment = align
            let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: para]
            let w: CGFloat = 52
            let x = align == .right ? at.x - w : (align == .center ? at.x - w / 2 : at.x)
            (s as NSString).draw(in: NSRect(x: x, y: at.y, width: w, height: 14), withAttributes: attr)
        }

        for i in 0...3 {
            let u = CGFloat(i) / 3
            let y = r.maxY - u * r.height
            let line = NSBezierPath()
            line.move(to: NSPoint(x: r.minX, y: y))
            line.line(to: NSPoint(x: r.maxX, y: y))
            line.lineWidth = 1
            grid.setStroke()
            line.stroke()
            let rpm = rpmLo + Double(u) * (rpmHi - rpmLo)
            label(String(format: "%.0f", rpm), NSPoint(x: r.minX - 4, y: y - 7), .right)
        }
        for t in [30.0, 55.0, 80.0, 105.0] {
            let x = r.minX + CGFloat((t - tLo) / (tHi - tLo)) * r.width
            label(String(format: "%.0f°", t), NSPoint(x: x, y: r.maxY + 4), .center)
        }

        if nowTemp >= tLo && nowTemp <= tHi {
            let x = r.minX + CGFloat((nowTemp - tLo) / (tHi - tLo)) * r.width
            let dash = NSBezierPath()
            dash.move(to: NSPoint(x: x, y: r.minY))
            dash.line(to: NSPoint(x: x, y: r.maxY))
            dash.lineWidth = 1
            NSColor.systemOrange.withAlphaComponent(0.7).setStroke()
            dash.setLineDash([3, 3], count: 2, phase: 0)
            dash.stroke()
            let nowP = FanCurvePoint(temp: nowTemp, rpm: nowRPM)
            let np = pos(nowP)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: np.x - 3.5, y: np.y - 3.5, width: 7, height: 7)).fill()
        }

        var live = points
        if let i = drag, live.indices.contains(i) {
            live[i] = FanCurvePoint(temp: dragTemp, rpm: dragRPM)
        }
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        let steps = 48
        for i in 0...steps {
            let t = tLo + (tHi - tLo) * Double(i) / Double(steps)
            let q = pos(FanCurvePoint(temp: t, rpm: FanCurves.rpm(t, live)))
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        accent.setStroke()
        path.stroke()
        if drag != nil {
            let q = pos(FanCurvePoint(temp: dragTemp, rpm: dragRPM))
            let hair = NSBezierPath()
            hair.lineWidth = 1
            hair.move(to: NSPoint(x: q.x, y: r.minY))
            hair.line(to: NSPoint(x: q.x, y: r.maxY))
            hair.move(to: NSPoint(x: r.minX, y: q.y))
            hair.line(to: NSPoint(x: r.maxX, y: q.y))
            hair.setLineDash([3, 2], count: 2, phase: 0)
            accent.withAlphaComponent(0.7).setStroke()
            hair.stroke()
            let pillFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
            let pillFg: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: NSColor.white]
            func pill(_ s: String, atX cx: CGFloat, atY cy: CGFloat) {
                let size = (s as NSString).size(withAttributes: pillFg)
                let w = size.width + 8
                let h: CGFloat = 14
                let x = min(bounds.width - w - 2, max(2, cx - w / 2))
                let y = min(bounds.height - h - 2, max(2, cy - h / 2))
                let rect = NSRect(x: x, y: y, width: w, height: h)
                accent.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
                (s as NSString).draw(at: NSPoint(x: rect.minX + 4, y: rect.minY + 1.5), withAttributes: pillFg)
            }
            pill(String(format: "%.0f RPM", dragRPM), atX: r.minX - 22, atY: q.y)
            pill(String(format: "%.0f°C", dragTemp), atX: q.x, atY: r.maxY + 12)
        }
        for p in live {
            let q = pos(p)
            let knob = NSRect(x: q.x - 7, y: q.y - 7, width: 14, height: 14)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knob).fill()
            accent.setStroke()
            let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        var best = -1
        var bestD = CGFloat(18)
        for (i, p) in points.enumerated() {
            let q = pos(p)
            let d = hypot(q.x - loc.x, q.y - loc.y)
            if d < bestD { bestD = d; best = i }
        }
        drag = best >= 0 ? best : nil
        if drag != nil { apply(loc) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        apply(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        needsDisplay = true
    }

    private func apply(_ loc: NSPoint) {
        guard let i = drag else { return }
        let v = values(loc)
        dragTemp = v.0
        dragRPM = v.1
        onChange?(i, v.0, v.1)
        needsDisplay = true
    }
}

struct FanCurveEditor: NSViewRepresentable {
    var points: [FanCurvePoint]
    var rpmLo: Double
    var rpmHi: Double
    var nowTemp: Double
    var nowRPM: Double
    var dark: Bool
    var onChange: (Int, Double, Double) -> Void

    func makeNSView(context: Context) -> FanCurveView {
        let v = FanCurveView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: FanCurveView, context: Context) {
        v.points = points
        v.rpmLo = rpmLo
        v.rpmHi = rpmHi
        v.nowTemp = nowTemp
        v.nowRPM = nowRPM
        v.dark = dark
        v.onChange = onChange
        v.needsDisplay = true
    }
}

struct SettingsRoot: View {
    @ObservedObject var app: App
    @ObservedObject var prefs: Prefs
    @ObservedObject var sampler: Sampler
    @ObservedObject var updater = Updater.shared

    var page: String { app.settingsPage }
    var dark: Bool { app.currentScheme == .dark }

    var pageInfo: (title: String, icon: String, color: Color) {
        switch page {
        case "appear": return ("Appearance", "paintpalette.fill", Color(red: 1.0, green: 0.35, blue: 0.55))
        case "bar": return ("Menu Bar", "menubar.rectangle", Color(red: 0.20, green: 0.48, blue: 1.0))
        case "drop": return ("Dropdown", "rectangle.split.2x1", Color(red: 0.62, green: 0.35, blue: 0.95))
        case "toolbar": return ("Toolbar", "menubar.dock.rectangle", Color(red: 0.95, green: 0.55, blue: 0.15))
        case "fans": return ("Fans", "fan", Color(red: 0.20, green: 0.72, blue: 0.78))
        case "about": return ("About", "info.circle.fill", Color(red: 0.20, green: 0.52, blue: 0.96))
        default: return ("General", "gearshape.fill", Color(red: 0.55, green: 0.55, blue: 0.58))
        }
    }

    var contentHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: pageInfo.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(pageInfo.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(pageInfo.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack(alignment: .topLeading) {
                ScrollView {
                    pageBody
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 56)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 36)
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.all, 0, for: .scrollContent)
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black.opacity(0.15), location: 0.35),
                                .init(color: .black.opacity(0.65), location: 0.65),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 70)
                        Rectangle().fill(Color.black)
                    }
                )

                contentHeader
                    .padding(.top, 14)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 640, maxWidth: 640, minHeight: 480, maxHeight: .infinity)
        .background(Chrome.window(dark))
        .preferredColorScheme(app.currentScheme)
        .tint(Color(red: 0.04, green: 0.52, blue: 1.0))
    }

    @ViewBuilder
    var pageBody: some View {
        switch page {
        case "appear": appearancePage
        case "bar": barPage
        case "drop": dropdownPage
        case "toolbar": toolbarPage
        case "fans": fansPage
        case "about": aboutPage
        default: generalPage
        }
    }

    var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Update") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Refresh interval").font(Chrome.text)
                        Spacer()
                        Text(String(format: "%.2fs", prefs.interval))
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Chrome.badge(dark), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Slider(
                        value: Binding(get: { prefs.interval }, set: { prefs.setInterval($0) }),
                        in: 0.25...5,
                        step: 0.25
                    )
                    Text("How often sensors are sampled.")
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            section("CPU") {
                row("Percentage scale") {
                    Picker("", selection: Binding(
                        get: { prefs.cpuProcMode },
                        set: { prefs.setCpuProcMode($0) }
                    )) {
                        Text("Total System (0-100%)").tag("total")
                        Text("Per-Core (Activity Monitor)").tag("perCore")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .clickHover()
                }
                Divider().padding(.leading, 14)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Processes count").font(Chrome.text)
                        Spacer()
                        Text("\(prefs.cpuProcCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Chrome.badge(dark), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Slider(
                        value: Binding(get: { Double(prefs.cpuProcCount) }, set: { prefs.setCpuProcCount(Int($0)) }),
                        in: 3...20,
                        step: 1
                    )
                    Text("Number of CPU-heavy processes to list in the CPU panel.")
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            section("Memory") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Processes count").font(Chrome.text)
                        Spacer()
                        Text("\(prefs.ramProcCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Chrome.badge(dark), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Slider(
                        value: Binding(get: { Double(prefs.ramProcCount) }, set: { prefs.setRamProcCount(Int($0)) }),
                        in: 3...20,
                        step: 1
                    )
                    Text("Number of memory-heavy processes to list in the RAM panel.")
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            section("System") {
                row("Smooth Animations") {
                    Toggle("", isOn: Binding(get: { prefs.animations }, set: { prefs.setAnimations($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                row("Launch at Login") {
                    Toggle("", isOn: Binding(get: { prefs.login }, set: { prefs.setLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                row("Setup Guide") {
                    Button("Show Onboarding…") {
                        app.openOnboarding()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Divider().padding(.leading, 14)
                row("Quit Sino") {
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
            section("Sleep Prevention (Awake)") {
                row("Global shortcut") {
                    AwakeShortcutRow(prefs: prefs)
                }
                Divider().padding(.leading, 14)
                row("Prevent display sleep") {
                    Toggle("", isOn: Binding(
                        get: { app.preventDisplaySleep },
                        set: { app.setPreventDisplaySleep($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                row("Prevent lid-close sleep (clamshell)") {
                    Toggle("", isOn: Binding(
                        get: { prefs.preventLidSleep },
                        set: { app.setPreventLidSleep($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                row("Right-click status bar to toggle") {
                    Toggle("", isOn: Binding(
                        get: { prefs.rightClickAwake },
                        set: { prefs.setRightClickAwake($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            section("Toolbar") {
                row("Shortcut app 1") {
                    appRow(1)
                }
                Divider().padding(.leading, 14)
                row("Shortcut app 2") {
                    appRow(2)
                }
                Divider().padding(.leading, 14)
                row("Shortcut app 3") {
                    appRow(3)
                }
            }
        }
    }

    func appRow(_ slot: Int) -> some View {
        let path = prefs.customAppPath(slot: slot)
        return HStack(spacing: 8) {
            if let img = prefs.customAppIcon(slot: slot) {
                Image(nsImage: img).resizable().frame(width: 16, height: 16)
            }
            Text(path.isEmpty ? "None" : prefs.customAppName(slot: slot))
                .font(Chrome.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button(path.isEmpty ? "Choose" : "Change") { prefs.pickCustomApp(slot: slot) }
            if !path.isEmpty {
                Button("Clear") { prefs.clearCustomApp(slot: slot) }
            }
        }
    }

    var appearancePage: some View {
        let dark = app.currentScheme == .dark
        return VStack(alignment: .leading, spacing: 16) {
            section("Theme") {
                row("Appearance") {
                    Picker("", selection: Binding(get: { app.theme }, set: { app.setTheme($0) })) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .clickHover()
                }
            }
            section("Glass") {
                row("Material") {
                    Picker("", selection: Binding(
                        get: { prefs.frost },
                        set: { prefs.frost = $0; prefs.save() }
                    )) {
                        ForEach(Prefs.frosts, id: \.id) { f in
                            Text(f.title).tag(f.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .clickHover()
                }
                Divider().padding(.leading, 14)
                row("Behind window") {
                    Toggle("", isOn: Binding(
                        get: { prefs.frostBehind },
                        set: { prefs.frostBehind = $0; prefs.save() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tint intensity").font(Chrome.text)
                        Spacer()
                        Text(String(format: "%.0f%%", prefs.frostTint * 100))
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Chrome.badge(dark), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Slider(
                        value: Binding(get: { prefs.frostTint }, set: { prefs.frostTint = $0; prefs.save() }),
                        in: 0...0.5
                    )
                    Text("Darkens or tints the frosted plate.")
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            section("Colors") {
                colorRow("Outline", "outline", NSColor.labelColor.withAlphaComponent(0.22))
                Divider().padding(.leading, 14)
                colorRow("Glass tint", "tint", NSColor.black)
                Divider().padding(.leading, 14)
                colorRow("Card", "card", NSColor.white.withAlphaComponent(dark ? 0.10 : 0.62))
                Divider().padding(.leading, 14)
                colorRow("Card hover", "hover", dark
                    ? NSColor.white.withAlphaComponent(0.20)
                    : NSColor(srgbRed: 0.88, green: 0.93, blue: 1, alpha: 1))
                Divider().padding(.leading, 14)
                colorRow("Accent", "accent", NSColor(srgbRed: 0.04, green: 0.48, blue: 1, alpha: 1))
                Divider().padding(.leading, 14)
                colorRow("Bar track", "track", dark
                    ? NSColor.white.withAlphaComponent(0.12)
                    : NSColor.black.withAlphaComponent(0.08))
                Divider().padding(.leading, 14)
                colorRow("Battery", "green", NSColor(srgbRed: 0.40, green: 0.78, blue: 0.35, alpha: 1))
            }
            Button("Reset appearance") { prefs.resetAppearance() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    func colorRow(_ title: String, _ key: String, _ fallback: NSColor) -> some View {
        row(title) {
            ColorPicker("", selection: prefs.colorBind(key, fallback: fallback), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 48)
        }
    }

    var dropdownPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Main Dropdown").font(Chrome.section)
            SettingsGroup {
                DropOrderTable(prefs: prefs)
                    .frame(height: CGFloat(max(prefs.dropOrder.count, 1)) * 36)
            }
            Text("Drag to reorder cards in the main column. Toggle switches control card visibility.")
                .font(Chrome.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Text("Secondary Dropdown (Hover Panels)").font(Chrome.section).padding(.top, 4)
            SideSectionsConfigView(prefs: prefs)
        }
    }

    var barPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup {
                BarOrderTable(prefs: prefs)
                    .frame(height: CGFloat(max(prefs.barOrder.count, 1)) * 36)
            }
            Text("Drag to reorder chips. Toggle switches control chip visibility.")
                .font(Chrome.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            section("Actions") {
                row("Right-click to toggle Awake") {
                    Toggle("", isOn: Binding(
                        get: { prefs.rightClickAwake },
                        set: { prefs.setRightClickAwake($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
    }

    var toolbarPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup {
                ToolbarOrderTable(prefs: prefs)
                    .frame(height: CGFloat(max(prefs.toolbarOrder.count, 1)) * 36)
            }
            Text("Drag to reorder buttons. Settings button remains pinned on the right.")
                .font(Chrome.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    var fansPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Control") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: Binding(
                        get: { app.fanMode },
                        set: { app.setFanMode($0) }
                    )) {
                        Text("Auto").tag(FanMode.auto)
                        Text("Manual").tag(FanMode.manual)
                        Text("Curve").tag(FanMode.curve)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(app.fanCtlBusy)
                    Text(fanModeCaption)
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            section("Presets") {
                HStack(spacing: 8) {
                    Button("Silent") { prefs.applyFanPreset("silent", minRPM: fanLo, maxRPM: fanHi) }
                    Button("Balanced") { prefs.applyFanPreset("balanced", minRPM: fanLo, maxRPM: fanHi) }
                    Button("Full") { prefs.applyFanPreset("full", minRPM: fanLo, maxRPM: fanHi) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(app.fanCtlBusy)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            if app.fanMode == .curve {
                section("Curve") {
                    row("Sensor") {
                        Text(String(format: "Hottest %.0f °C → %.0f RPM", app.hottestTemp(), app.curveTarget()))
                            .font(Chrome.caption)
                            .foregroundStyle(.secondary)
                    }
                    FanCurveEditor(
                        points: prefs.fanCurve,
                        rpmLo: fanLo,
                        rpmHi: fanHi,
                        nowTemp: app.hottestTemp(),
                        nowRPM: app.curveTarget(),
                        dark: dark,
                        onChange: { i, t, r in prefs.setCurvePoint(i, temp: t, rpm: r) }
                    )
                    .frame(height: 176)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    Text("Drag the dots. X = °C, Y = RPM. Orange = now.")
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
            if app.fanMode == .manual {
                section("Speeds") {
                    if sampler.snap.fans.isEmpty {
                        Text("No fans reported.")
                            .font(Chrome.caption)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    } else {
                        ForEach(sampler.snap.fans) { f in
                            fanSpeedRow(f)
                        }
                    }
                }
            }
            section("Helper") {
                row("SMC writer") {
                    Text(FanCtl.ready ? "Ready" : "Not installed")
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 14)
                row("Install") {
                    Button(FanCtl.ready ? "Reinstall…" : "Install…") {
                        _ = FanCtl.install()
                        app.objectWillChange.send()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(app.fanCtlBusy)
                }
            }
        }
    }

    var fanModeCaption: String {
        switch app.fanMode {
        case .auto: return "macOS/SMC picks RPM. Sino does not write."
        case .manual: return "Fixed RPM until you change it. Auto when Sino quits."
        case .curve: return "Hottest sensor → RPM. Auto when Sino quits."
        }
    }

    var fanLo: Double {
        let v = sampler.snap.fans.map(\.minRPM).min() ?? 2317
        return v > 500 ? v : 2317
    }

    var fanHi: Double {
        let v = sampler.snap.fans.map(\.maxRPM).max() ?? 6800
        return v > fanLo ? v : 6800
    }

    @ViewBuilder
    func fanSpeedRow(_ f: FanSample) -> some View {
        if f.id > 0 { Divider().padding(.leading, 14) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(f.name).font(Chrome.text)
                Spacer()
                Text("\(Int((app.fanTargets[f.id] ?? f.rpm).rounded())) RPM")
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Chrome.badge(dark), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Slider(
                value: Binding(
                    get: { app.fanTargets[f.id] ?? f.rpm },
                    set: { app.setFanTarget(f.id, $0) }
                ),
                in: fanRange(f)
            )
            Text("Range \(Int(fanRange(f).lowerBound))–\(Int(fanRange(f).upperBound)) RPM")
                .font(Chrome.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func fanRange(_ f: FanSample) -> ClosedRange<Double> {
        let lo = f.minRPM > 500 ? f.minRPM : 2000
        let hi = f.maxRPM > lo ? f.maxRPM : 6800
        return lo...hi
    }

    var aboutPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                if let img = NSApp.applicationIconImage ?? NSImage(named: "AppIcon") {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                Text("Sino")
                    .font(.system(size: 20, weight: .bold))
                Text("Made with ❤️ by Nikolay Golovin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            section("Sino") {
                row("Version") {
                    Text(updater.current).font(Chrome.caption).foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 14)
                row("Updates") {
                    HStack(spacing: 8) {
                        if updater.isUpdating {
                            Text(updater.updateProgress ?? "Updating…")
                                .font(Chrome.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            if updater.downloadURL != nil {
                                Button("Update Now") { updater.performUpdate() }
                            }
                            Button("Check") { updater.check() }
                        }
                    }
                }
                Divider().padding(.leading, 14)
                row("Update notifications") {
                    Toggle("", isOn: Binding(get: { prefs.updateNotify }, set: { prefs.setUpdateNotify($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if updater.status != "—" && !updater.isUpdating {
                    Text(updater.status)
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                if updater.updateURL != nil {
                    Divider().padding(.leading, 14)
                    row("Release") {
                        Button("View on GitHub") { updater.openUpdate() }
                    }
                }
            }
            section("Source") {
                row("GitHub") {
                    Button("Aduersarius/sino") { openURL("https://github.com/Aduersarius/sino") }
                }
            }
            section("Contact") {
                row("Author") {
                    Text("Nikolay Golovin").font(Chrome.text).foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 14)
                row("GitHub") {
                    Button("@Aduersarius") { openURL("https://github.com/Aduersarius") }
                }
            }
        }
    }

    func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            nav("general", "General", "gearshape.fill", Color(red: 0.55, green: 0.55, blue: 0.58))
            nav("appear", "Appearance", "paintpalette.fill", Color(red: 1.0, green: 0.35, blue: 0.55))
            nav("bar", "Menu Bar", "menubar.rectangle", Color(red: 0.20, green: 0.48, blue: 1.0))
            nav("drop", "Dropdown", "rectangle.split.2x1", Color(red: 0.62, green: 0.35, blue: 0.95))
            nav("toolbar", "Toolbar", "menubar.dock.rectangle", Color(red: 0.95, green: 0.55, blue: 0.15))
            nav("fans", "Fans", "fan", Color(red: 0.20, green: 0.72, blue: 0.78))
            nav("about", "About", "info.circle.fill", Color(red: 0.20, green: 0.52, blue: 0.96))
            Spacer(minLength: 0)
        }
        .padding(.top, 46)
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(width: Chrome.rail, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Chrome.sidebar(dark))
        )
        .padding(.leading, 9)
        .padding(.vertical, 8)
    }

    func nav(_ id: String, _ title: String, _ icon: String, _ color: Color) -> some View {
        Button { app.selectSettingsPage(id) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(page == id ? Chrome.selected(dark) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .settingsHover(radius: 8)
    }

    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            SettingsGroup { content() }
        }
    }

    func row<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        SettingsRow(title: title, trailing: trailing)
    }
}

struct BarOrderTable: NSViewRepresentable {
    @ObservedObject var prefs: Prefs

    func makeCoordinator() -> Coord { Coord(prefs: prefs) }

    func makeNSView(context: Context) -> NSTableView {
        let tv = NSTableView()
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.allowsEmptySelection = true
        tv.allowsMultipleSelection = false
        tv.usesAlternatingRowBackgroundColors = false
        tv.rowHeight = 36
        tv.intercellSpacing = .zero
        tv.style = .plain
        tv.delegate = context.coordinator
        tv.dataSource = context.coordinator
        tv.registerForDraggedTypes([.string])
        tv.draggingDestinationFeedbackStyle = .gap
        tv.setDraggingSourceOperationMask(.move, forLocal: true)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("m"))
        col.resizingMask = .autoresizingMask
        tv.addTableColumn(col)
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        context.coordinator.table = tv
        return tv
    }

    func updateNSView(_ tv: NSTableView, context: Context) {
        context.coordinator.prefs = prefs
        guard !context.coordinator.dragging else { return }
        tv.reloadData()
        tv.sizeLastColumnToFit()
    }

    final class Coord: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var prefs: Prefs
        weak var table: NSTableView?
        var dragging = false
        init(prefs: Prefs) { self.prefs = prefs }

        func numberOfRows(in tableView: NSTableView) -> Int { prefs.barOrder.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            QuietRow()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = prefs.barOrder[row]
            let title = Prefs.modules.first(where: { $0.id == id })?.title ?? id
            let cell = NSTableCellView()
            let grip = NSImageView()
            grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder")
            grip.contentTintColor = .tertiaryLabelColor
            grip.translatesAutoresizingMaskIntoConstraints = false
            let lab = NSTextField(labelWithString: title)
            lab.font = .systemFont(ofSize: 13)
            lab.translatesAutoresizingMaskIntoConstraints = false
            let sw = NSSwitch()
            sw.state = prefs.bar.contains(id) ? .on : .off
            sw.identifier = NSUserInterfaceItemIdentifier(id)
            sw.target = self
            sw.action = #selector(tog(_:))
            sw.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(grip)
            cell.addSubview(lab)
            cell.addSubview(sw)
            NSLayoutConstraint.activate([
                grip.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                grip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                grip.widthAnchor.constraint(equalToConstant: 16),
                grip.heightAnchor.constraint(equalToConstant: 16),
                lab.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 10),
                lab.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                sw.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                sw.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                lab.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -8)
            ])
            return cell
        }

        @objc func tog(_ sender: NSSwitch) {
            let id = sender.identifier?.rawValue ?? ""
            prefs.barBind(id).wrappedValue = sender.state == .on
            table?.reloadData()
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let item = NSPasteboardItem()
            item.setString("\(row)", forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let s = info.draggingPasteboard.string(forType: .string), let from = Int(s) else { return false }
            guard from != row, from + 1 != row else { return true }
            prefs.barOrder.move(fromOffsets: IndexSet(integer: from), toOffset: row)
            prefs.save()
            tableView.reloadData()
            return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            dragging = true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            tableView.reloadData()
        }
    }
}

struct DropOrderTable: NSViewRepresentable {
    @ObservedObject var prefs: Prefs

    func makeCoordinator() -> Coord { Coord(prefs: prefs) }

    func makeNSView(context: Context) -> NSTableView {
        let tv = NSTableView()
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.allowsEmptySelection = true
        tv.allowsMultipleSelection = false
        tv.usesAlternatingRowBackgroundColors = false
        tv.rowHeight = 36
        tv.intercellSpacing = .zero
        tv.style = .plain
        tv.delegate = context.coordinator
        tv.dataSource = context.coordinator
        tv.registerForDraggedTypes([.string])
        tv.draggingDestinationFeedbackStyle = .gap
        tv.setDraggingSourceOperationMask(.move, forLocal: true)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("d"))
        col.resizingMask = .autoresizingMask
        tv.addTableColumn(col)
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        context.coordinator.table = tv
        return tv
    }

    func updateNSView(_ tv: NSTableView, context: Context) {
        context.coordinator.prefs = prefs
        guard !context.coordinator.dragging else { return }
        tv.reloadData()
        tv.sizeLastColumnToFit()
    }

    final class Coord: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var prefs: Prefs
        weak var table: NSTableView?
        var dragging = false
        init(prefs: Prefs) { self.prefs = prefs }

        func numberOfRows(in tableView: NSTableView) -> Int { prefs.dropOrder.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            QuietRow()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = prefs.dropOrder[row]
            let item = Prefs.dropElements.first(where: { $0.id == id })
            let title = item?.title ?? id
            let cell = NSTableCellView()

            let grip = NSImageView()
            grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder")
            grip.contentTintColor = .tertiaryLabelColor
            grip.translatesAutoresizingMaskIntoConstraints = false

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: item?.icon ?? "square", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false

            let lab = NSTextField(labelWithString: title)
            lab.font = .systemFont(ofSize: 13)
            lab.translatesAutoresizingMaskIntoConstraints = false

            let sw = NSSwitch()
            sw.state = prefs.drop.contains(id) ? .on : .off
            sw.identifier = NSUserInterfaceItemIdentifier(id)
            sw.target = self
            sw.action = #selector(tog(_:))
            sw.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(grip)
            cell.addSubview(icon)
            cell.addSubview(lab)
            cell.addSubview(sw)

            NSLayoutConstraint.activate([
                grip.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                grip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                grip.widthAnchor.constraint(equalToConstant: 16),
                grip.heightAnchor.constraint(equalToConstant: 16),

                icon.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),

                lab.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                lab.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                sw.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                sw.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                lab.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -8)
            ])
            return cell
        }

        @objc func tog(_ sender: NSSwitch) {
            let id = sender.identifier?.rawValue ?? ""
            prefs.dropBind(id).wrappedValue = sender.state == .on
            table?.reloadData()
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let item = NSPasteboardItem()
            item.setString("\(row)", forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let s = info.draggingPasteboard.string(forType: .string), let from = Int(s) else { return false }
            guard from != row, from + 1 != row else { return true }
            prefs.dropOrder.move(fromOffsets: IndexSet(integer: from), toOffset: row)
            prefs.save()
            tableView.reloadData()
            return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            dragging = true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            tableView.reloadData()
        }
    }
}

struct SideOrderTable: NSViewRepresentable {
    @ObservedObject var prefs: Prefs
    var panel: String

    func makeCoordinator() -> Coord { Coord(prefs: prefs, panel: panel) }

    func makeNSView(context: Context) -> NSTableView {
        let tv = NSTableView()
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.allowsEmptySelection = true
        tv.allowsMultipleSelection = false
        tv.usesAlternatingRowBackgroundColors = false
        tv.rowHeight = 36
        tv.intercellSpacing = .zero
        tv.style = .plain
        tv.delegate = context.coordinator
        tv.dataSource = context.coordinator
        tv.registerForDraggedTypes([.string])
        tv.draggingDestinationFeedbackStyle = .gap
        tv.setDraggingSourceOperationMask(.move, forLocal: true)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("s"))
        col.resizingMask = .autoresizingMask
        tv.addTableColumn(col)
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        context.coordinator.table = tv
        return tv
    }

    func updateNSView(_ tv: NSTableView, context: Context) {
        context.coordinator.prefs = prefs
        context.coordinator.panel = panel
        guard !context.coordinator.dragging else { return }
        tv.reloadData()
        tv.sizeLastColumnToFit()
    }

    final class Coord: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var prefs: Prefs
        var panel: String
        weak var table: NSTableView?
        var dragging = false
        init(prefs: Prefs, panel: String) {
            self.prefs = prefs
            self.panel = panel
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            prefs.sideOrder[panel]?.count ?? 0
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            QuietRow()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let items = prefs.sideOrder[panel], row < items.count else { return nil }
            let id = items[row]
            let item = Prefs.sideSections[panel]?.first(where: { $0.id == id })
            let title = item?.title ?? id
            let iconName = item?.icon ?? "square"
            let cell = NSTableCellView()

            let grip = NSImageView()
            grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder")
            grip.contentTintColor = .tertiaryLabelColor
            grip.translatesAutoresizingMaskIntoConstraints = false

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false

            let lab = NSTextField(labelWithString: title)
            lab.font = .systemFont(ofSize: 13)
            lab.translatesAutoresizingMaskIntoConstraints = false

            let sw = NSSwitch()
            sw.state = prefs.isSideVisible(panel, id) ? .on : .off
            sw.identifier = NSUserInterfaceItemIdentifier(id)
            sw.target = self
            sw.action = #selector(tog(_:))
            sw.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(grip)
            cell.addSubview(icon)
            cell.addSubview(lab)
            cell.addSubview(sw)

            NSLayoutConstraint.activate([
                grip.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                grip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                grip.widthAnchor.constraint(equalToConstant: 16),
                grip.heightAnchor.constraint(equalToConstant: 16),

                icon.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),

                lab.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                lab.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                sw.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                sw.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                lab.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -8)
            ])
            return cell
        }

        @objc func tog(_ sender: NSSwitch) {
            let id = sender.identifier?.rawValue ?? ""
            prefs.sideBind(panel, id).wrappedValue = sender.state == .on
            table?.reloadData()
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let item = NSPasteboardItem()
            item.setString("\(row)", forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let s = info.draggingPasteboard.string(forType: .string), let from = Int(s) else { return false }
            guard from != row, from + 1 != row else { return true }
            guard var order = prefs.sideOrder[panel] else { return false }
            order.move(fromOffsets: IndexSet(integer: from), toOffset: row)
            prefs.sideOrder[panel] = order
            prefs.save()
            tableView.reloadData()
            return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            dragging = true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            tableView.reloadData()
        }
    }
}

struct SideSectionsConfigView: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Prefs.sidePanels, id: \.id) { panel in
                accordionItem(for: panel)
            }
        }
    }

    func accordionItem(for panel: (id: String, title: String, icon: String)) -> some View {
        let isExpanded = prefs.expandedAccordionPanel == panel.id
        let count = (prefs.sideOrder[panel.id] ?? []).count
        let activeCount = (prefs.sideOrder[panel.id] ?? []).filter { prefs.isSideVisible(panel.id, $0) }.count

        return SettingsGroup {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        prefs.expandedAccordionPanel = nil
                    } else {
                        prefs.expandedAccordionPanel = panel.id
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14)

                    Image(systemName: panel.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)

                    Text(panel.title)
                        .font(Chrome.text)
                        .foregroundStyle(Color.primary)

                    Spacer()

                    Text("\(activeCount)/\(count) active")
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settingsHover(radius: isExpanded ? 0 : 10)

            if isExpanded {
                Divider().padding(.leading, 14)
                SideOrderTable(prefs: prefs, panel: panel.id)
                    .frame(height: CGFloat(max(prefs.sideOrder[panel.id]?.count ?? 1, 1)) * 36)
                    .id(panel.id)
            }
        }
    }
}

struct ToolbarOrderTable: NSViewRepresentable {
    @ObservedObject var prefs: Prefs

    func makeCoordinator() -> Coord { Coord(prefs: prefs) }

    func makeNSView(context: Context) -> NSTableView {
        let tv = NSTableView()
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.allowsEmptySelection = true
        tv.allowsMultipleSelection = false
        tv.usesAlternatingRowBackgroundColors = false
        tv.rowHeight = 36
        tv.intercellSpacing = .zero
        tv.style = .plain
        tv.delegate = context.coordinator
        tv.dataSource = context.coordinator
        tv.registerForDraggedTypes([.string])
        tv.draggingDestinationFeedbackStyle = .gap
        tv.setDraggingSourceOperationMask(.move, forLocal: true)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("t"))
        col.resizingMask = .autoresizingMask
        tv.addTableColumn(col)
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        context.coordinator.table = tv
        return tv
    }

    func updateNSView(_ tv: NSTableView, context: Context) {
        context.coordinator.prefs = prefs
        guard !context.coordinator.dragging else { return }
        tv.reloadData()
        tv.sizeLastColumnToFit()
    }

    final class Coord: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var prefs: Prefs
        weak var table: NSTableView?
        var dragging = false
        init(prefs: Prefs) { self.prefs = prefs }

        func numberOfRows(in tableView: NSTableView) -> Int { prefs.toolbarOrder.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            QuietRow()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = prefs.toolbarOrder[row]
            let item = Prefs.toolbarButtons.first(where: { $0.id == id })
            let title: String
            if id == "app1" {
                title = prefs.customApp.isEmpty ? "Shortcut App 1" : "App 1 (\(prefs.customAppName(slot: 1)))"
            } else if id == "app2" {
                title = prefs.customApp2.isEmpty ? "Shortcut App 2" : "App 2 (\(prefs.customAppName(slot: 2)))"
            } else if id == "app3" {
                title = prefs.customApp3.isEmpty ? "Shortcut App 3" : "App 3 (\(prefs.customAppName(slot: 3)))"
            } else {
                title = item?.title ?? id
            }

            let cell = NSTableCellView()
            let grip = NSImageView()
            grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder")
            grip.contentTintColor = .tertiaryLabelColor
            grip.translatesAutoresizingMaskIntoConstraints = false

            let icon = NSImageView()
            if let customIcon = customAppIcon(for: id) {
                icon.image = customIcon
            } else {
                icon.image = NSImage(systemSymbolName: item?.icon ?? "square", accessibilityDescription: nil)
                icon.contentTintColor = .secondaryLabelColor
            }
            icon.translatesAutoresizingMaskIntoConstraints = false

            let lab = NSTextField(labelWithString: title)
            lab.font = .systemFont(ofSize: 13)
            lab.translatesAutoresizingMaskIntoConstraints = false

            let sw = NSSwitch()
            sw.state = prefs.toolbar.contains(id) ? .on : .off
            sw.identifier = NSUserInterfaceItemIdentifier(id)
            sw.target = self
            sw.action = #selector(tog(_:))
            sw.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(grip)
            cell.addSubview(icon)
            cell.addSubview(lab)
            cell.addSubview(sw)

            NSLayoutConstraint.activate([
                grip.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                grip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                grip.widthAnchor.constraint(equalToConstant: 16),
                grip.heightAnchor.constraint(equalToConstant: 16),

                icon.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),

                lab.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                lab.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                sw.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                sw.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                lab.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -8)
            ])
            return cell
        }

        private func customAppIcon(for id: String) -> NSImage? {
            switch id {
            case "app1": return prefs.customAppIcon(slot: 1)
            case "app2": return prefs.customAppIcon(slot: 2)
            case "app3": return prefs.customAppIcon(slot: 3)
            default: return nil
            }
        }

        @objc func tog(_ sender: NSSwitch) {
            let id = sender.identifier?.rawValue ?? ""
            prefs.toolbarBind(id).wrappedValue = sender.state == .on
            table?.reloadData()
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let item = NSPasteboardItem()
            item.setString("\(row)", forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let s = info.draggingPasteboard.string(forType: .string), let from = Int(s) else { return false }
            guard from != row, from + 1 != row else { return true }
            prefs.toolbarOrder.move(fromOffsets: IndexSet(integer: from), toOffset: row)
            prefs.save()
            tableView.reloadData()
            return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            dragging = true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            tableView.reloadData()
        }
    }
}

final class QuietRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}

struct SettingsGroup<Content: View>: View {
    @Environment(\.colorScheme) var scheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 0) { content }
            .background(Chrome.group(dark), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Chrome.text).foregroundStyle(.primary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct HoverFill: ViewModifier {
    var radius: CGFloat = 8
    var selected: Bool = false
    var hugPopup: Bool = false
    func body(content: Content) -> some View {
        // ponytail: NSTrackingArea — swiftc has no @State macro plugin
        content.overlay(HoverBGView(radius: radius, selected: selected, hugPopup: hugPopup))
    }
}

private struct HoverBGView: NSViewRepresentable {
    var radius: CGFloat
    var selected: Bool
    var hugPopup: Bool = false
    func makeNSView(context: Context) -> HoverBG {
        let v = HoverBG()
        v.radius = radius
        v.selected = selected
        v.hugPopup = hugPopup
        return v
    }
    func updateNSView(_ v: HoverBG, context: Context) {
        v.radius = radius
        v.selected = selected
        v.hugPopup = hugPopup
        v.needsDisplay = true
        v.syncHover()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HoverBG, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 20, height: proposal.height ?? 20)
    }
}

final class HoverBG: NSView {
    var radius: CGFloat = 8
    var hugPopup = false
    var captureHits = false
    var onClick: (() -> Void)?
    var tip: String? {
        didSet {
            if hovering, let tip, !tip.isEmpty {
                TooltipManager.shared.show(tip, for: self)
            }
        }
    }
    var selected = false { didSet { needsDisplay = true } }
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
            if hovering {
                startMonitoringMouse()
                if let tip, !tip.isEmpty {
                    TooltipManager.shared.show(tip, for: self)
                }
            } else {
                stopMonitoringMouse()
                TooltipManager.shared.hide(for: self)
            }
        }
    }
    private var tracking = false
    private var pressed = false { didSet { needsDisplay = true } }
    private var mouseMonitor: Any?
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard captureHits || onClick != nil else { return nil }
        var r = bounds
        if r.width < 2 || r.height < 2, let s = superview {
            r = convert(s.bounds, from: s)
        }
        return r.contains(point) ? self : nil
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.width, .height]
        if let s = superview { frame = s.bounds }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { self.updateTrackingAreas() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hovering = false
        }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit {
        stopMonitoringMouse()
        TooltipManager.shared.hideImmediately()
    }
    override func layout() {
        super.layout()
        if let s = superview { frame = s.bounds }
        updateTrackingAreas()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        syncHover()
    }
    override func mouseEntered(with event: NSEvent) {
        syncHover(event)
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
    }
    override func mouseMoved(with event: NSEvent) {
        syncHover(event)
    }
    func syncHover(_ event: NSEvent? = nil) {
        guard let w = window, w.isVisible else {
            if hovering { hovering = false }
            return
        }
        let p: NSPoint
        if let event, event.window == w {
            p = convert(event.locationInWindow, from: nil)
        } else {
            let screenPt = NSEvent.mouseLocation
            let winPt = w.convertPoint(fromScreen: screenPt)
            p = convert(winPt, from: nil)
        }
        let inside = targetRect().contains(p)
        if hovering != inside {
            hovering = inside
        }
    }
    private func startMonitoringMouse() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self else { return event }
            self.syncHover(event)
            return event
        }
    }
    private func stopMonitoringMouse() {
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }
    override func mouseDown(with event: NSEvent) {
        TooltipManager.shared.hideImmediately()
        if onClick != nil {
            tracking = true
            pressed = true
            return
        }
        guard captureHits else { return }
        forward(event) { $0.mouseDown(with: $1) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        pressed = targetRect().contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        if let onClick {
            let go = tracking && targetRect().contains(convert(event.locationInWindow, from: nil))
            tracking = false
            pressed = false
            if go { onClick() }
            syncHover()
            return
        }
        guard captureHits else { return }
        forward(event) { $0.mouseUp(with: $1) }
    }
    override func rightMouseDown(with event: NSEvent) {
        TooltipManager.shared.hideImmediately()
        guard onClick != nil || captureHits else { return }
        forward(event) { $0.rightMouseDown(with: $1) }
    }
    private func forward(_ event: NSEvent, _ send: (NSView, NSEvent) -> Void) {
        guard let content = window?.contentView else { return }
        isHidden = true
        defer { isHidden = false }
        let p = content.convert(event.locationInWindow, from: nil)
        if let v = content.hitTest(p), v !== self { send(v, event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let a: CGFloat
        if pressed { a = 0.22 }
        else if selected && hovering { a = 0.12 }
        else if selected { a = 0.08 }
        else if hovering { a = 0.10 }
        else { return }
        let r = targetRect()
        let rad = hugPopup ? min(r.height, r.width) / 2 : radius
        NSColor.labelColor.withAlphaComponent(a).setFill()
        NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
    }
    private func targetRect() -> NSRect {
        if hugPopup {
            if let p = nearestPopup() {
                return convert(p.bounds, from: p).integral
            }
            let h = min(bounds.height, 22)
            return NSRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h).integral
        }
        return bounds
    }
    private func nearestPopup() -> NSPopUpButton? {
        var n: NSView? = superview
        while let cur = n {
            let hits = popups(in: cur).filter {
                convert($0.bounds, from: $0).intersects(bounds)
            }
            if let p = hits.min(by: {
                convert($0.bounds, from: $0).width < convert($1.bounds, from: $1).width
            }) { return p }
            n = cur.superview
        }
        return nil
    }
    private func popups(in root: NSView) -> [NSPopUpButton] {
        var out: [NSPopUpButton] = []
        if let p = root as? NSPopUpButton { out.append(p) }
        for c in root.subviews { out.append(contentsOf: popups(in: c)) }
        return out
    }
}

private extension View {
    func settingsHover(radius: CGFloat = 8, selected: Bool = false) -> some View {
        modifier(HoverFill(radius: radius, selected: selected))
    }
    func clickHover() -> some View {
        modifier(HoverFill(radius: 6, hugPopup: true))
    }
}

func shortcutString(keyCode: Int, modifiers: UInt) -> String {
    guard keyCode >= 0 else { return "None" }
    var s = ""
    if modifiers & UInt(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt(optionKey) != 0 { s += "⌥" }
    if modifiers & UInt(shiftKey) != 0 { s += "⇧" }
    if modifiers & UInt(cmdKey) != 0 { s += "⌘" }

    switch keyCode {
    case kVK_ANSI_A: s += "A"
    case kVK_ANSI_B: s += "B"
    case kVK_ANSI_C: s += "C"
    case kVK_ANSI_D: s += "D"
    case kVK_ANSI_E: s += "E"
    case kVK_ANSI_F: s += "F"
    case kVK_ANSI_G: s += "G"
    case kVK_ANSI_H: s += "H"
    case kVK_ANSI_I: s += "I"
    case kVK_ANSI_J: s += "J"
    case kVK_ANSI_K: s += "K"
    case kVK_ANSI_L: s += "L"
    case kVK_ANSI_M: s += "M"
    case kVK_ANSI_N: s += "N"
    case kVK_ANSI_O: s += "O"
    case kVK_ANSI_P: s += "P"
    case kVK_ANSI_Q: s += "Q"
    case kVK_ANSI_R: s += "R"
    case kVK_ANSI_S: s += "S"
    case kVK_ANSI_T: s += "T"
    case kVK_ANSI_U: s += "U"
    case kVK_ANSI_V: s += "V"
    case kVK_ANSI_W: s += "W"
    case kVK_ANSI_X: s += "X"
    case kVK_ANSI_Y: s += "Y"
    case kVK_ANSI_Z: s += "Z"
    case kVK_ANSI_0: s += "0"
    case kVK_ANSI_1: s += "1"
    case kVK_ANSI_2: s += "2"
    case kVK_ANSI_3: s += "3"
    case kVK_ANSI_4: s += "4"
    case kVK_ANSI_5: s += "5"
    case kVK_ANSI_6: s += "6"
    case kVK_ANSI_7: s += "7"
    case kVK_ANSI_8: s += "8"
    case kVK_ANSI_9: s += "9"
    case kVK_Space: s += "Space"
    case kVK_Return: s += "↩"
    case kVK_Tab: s += "⇥"
    case kVK_F1: s += "F1"
    case kVK_F2: s += "F2"
    case kVK_F3: s += "F3"
    case kVK_F4: s += "F4"
    case kVK_F5: s += "F5"
    case kVK_F6: s += "F6"
    case kVK_F7: s += "F7"
    case kVK_F8: s += "F8"
    case kVK_F9: s += "F9"
    case kVK_F10: s += "F10"
    case kVK_F11: s += "F11"
    case kVK_F12: s += "F12"
    default: s += "Key(\(keyCode))"
    }
    return s
}

struct AwakeShortcutRow: NSViewRepresentable {
    @ObservedObject var prefs: Prefs

    func makeNSView(context: Context) -> AwakeShortcutView {
        let v = AwakeShortcutView()
        v.prefs = prefs
        return v
    }

    func updateNSView(_ nsView: AwakeShortcutView, context: Context) {
        nsView.prefs = prefs
        nsView.updateUI()
    }
}

final class AwakeShortcutView: NSView {
    var prefs: Prefs?
    private let button = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private var recording = false
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        stopRecording()
    }

    private func setup() {
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        button.target = self
        button.action = #selector(buttonClicked)

        clearButton.bezelStyle = .inline
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearClicked)

        addSubview(button)
        addSubview(clearButton)
    }

    override func layout() {
        super.layout()
        button.sizeToFit()
        clearButton.sizeToFit()

        let btnW = max(70, button.frame.width + 12)
        let btnH: CGFloat = 22
        button.frame = NSRect(x: 0, y: (bounds.height - btnH) / 2, width: btnW, height: btnH)

        let clrW = clearButton.frame.width + 6
        let clrH: CGFloat = 18
        clearButton.frame = NSRect(x: btnW + 6, y: (bounds.height - clrH) / 2, width: clrW, height: clrH)
    }

    override var intrinsicContentSize: NSSize {
        button.sizeToFit()
        clearButton.sizeToFit()
        let btnW = max(70, button.frame.width + 12)
        let clrW = (prefs?.awakeShortcutKeyCode ?? -1) >= 0 && !recording ? clearButton.frame.width + 12 : 0
        return NSSize(width: btnW + clrW, height: 24)
    }

    func updateUI() {
        guard !recording else {
            button.title = "Type shortcut…"
            clearButton.isHidden = true
            invalidateIntrinsicContentSize()
            needsLayout = true
            return
        }
        let code = prefs?.awakeShortcutKeyCode ?? -1
        let mods = prefs?.awakeShortcutModifiers ?? 0
        button.title = shortcutString(keyCode: code, modifiers: mods)
        clearButton.isHidden = (code < 0)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func buttonClicked() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @objc private func clearClicked() {
        stopRecording()
        prefs?.setAwakeShortcut(keyCode: -1, modifiers: 0)
        updateUI()
    }

    private func startRecording() {
        stopRecording()
        recording = true
        updateUI()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.stopRecording()
                return nil
            }
            if event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { // Backspace
                self.prefs?.setAwakeShortcut(keyCode: -1, modifiers: 0)
                self.stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFKey = (event.keyCode >= 96 && event.keyCode <= 101) || event.keyCode == 103 || event.keyCode == 109 || event.keyCode == 111 || event.keyCode == 118 || event.keyCode == 120 || event.keyCode == 122
            if !flags.isEmpty || isFKey {
                var carbonMods: UInt = 0
                if flags.contains(.command) { carbonMods |= UInt(cmdKey) }
                if flags.contains(.option) { carbonMods |= UInt(optionKey) }
                if flags.contains(.control) { carbonMods |= UInt(controlKey) }
                if flags.contains(.shift) { carbonMods |= UInt(shiftKey) }
                self.prefs?.setAwakeShortcut(keyCode: Int(event.keyCode), modifiers: carbonMods)
                self.stopRecording()
                return nil
            }
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        updateUI()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopRecording()
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

// MARK: - Location Permission Manager
final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()
    @Published var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        status == .authorizedAlways
    }

    var isDenied: Bool {
        status == .denied || status == .restricted
    }

    func request() {
        manager.requestAlwaysAuthorization()
    }

    func refresh() {
        status = manager.authorizationStatus
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.status = manager.authorizationStatus
        }
    }
}

// MARK: - First-Launch Onboarding View
final class OnboardingState: ObservableObject {
    @Published var sudoersInstalled: Bool = PMSetHelper.isSudoersInstalled
    @Published var isConfiguringClamshell: Bool = false

    func refresh() {
        sudoersInstalled = PMSetHelper.isSudoersInstalled
    }

    func configureClamshell(app: App) {
        isConfiguringClamshell = true
        Thread.detachNewThread { [weak self] in
            let ok: Bool = PMSetHelper.installSudoers()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConfiguringClamshell = false
                self.sudoersInstalled = PMSetHelper.isSudoersInstalled
                if ok {
                    app.prefs.setPreventLidSleep(true)
                }
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var app: App
    @ObservedObject var prefs: Prefs
    @ObservedObject var location = LocationPermission.shared
    @ObservedObject var state = OnboardingState()

    var dark: Bool { app.currentScheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage ?? NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: Color.black.opacity(dark ? 0.40 : 0.12), radius: 6, y: 3)
                }
                Text("Welcome to Sino")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                Text("Configure optional permissions for enhanced monitoring and clamshell sleep control.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 16)
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)

            // Permissions list
            VStack(spacing: 12) {
                SettingsGroup {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "wifi")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Wi-Fi Network Name").font(Chrome.section)
                                Spacer()
                                if location.isAuthorized {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Text("Granted")
                                            .font(Chrome.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else if location.isDenied {
                                    Button("Open Settings") {
                                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                } else {
                                    Button("Enable") {
                                        location.request()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                            Text("macOS requires Location permission to display the active Wi-Fi SSID in the menu bar and network card. Without it, Sino displays \"Wi-Fi\".")
                                .font(Chrome.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                }

                SettingsGroup {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Clamshell Sleep (Optional)").font(Chrome.section)
                                Spacer()
                                if state.sudoersInstalled {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Text("Configured")
                                            .font(Chrome.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Button(state.isConfiguringClamshell ? "Configuring…" : "Configure…") {
                                        state.configureClamshell(app: app)
                                    }
                                    .disabled(state.isConfiguringClamshell)
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            Text("Allows Awake to keep your MacBook awake when the lid is closed. Installs a passwordless pmset rule (/etc/sudoers.d/sino_awake) via an admin prompt.")
                                .font(Chrome.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            // Footer
            HStack {
                Button("Skip for Now") {
                    app.closeOnboarding()
                }
                .buttonStyle(.plain)
                .font(Chrome.text)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Get Started") {
                    app.closeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .frame(width: 480, height: 430)
        .background(Chrome.window(dark))
        .preferredColorScheme(app.currentScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            location.refresh()
            state.refresh()
        }
    }
}
