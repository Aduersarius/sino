import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

final class Prefs: ObservableObject {
    static let shared = Prefs()
    static let modules: [(id: String, title: String, icon: String)] = [
        ("cpu", "CPU", "cpu"),
        ("ram", "RAM", "memorychip"),
        ("gpu", "GPU", "display"),
        ("storage", "Storage", "internaldrive"),
        ("net", "Network", "wifi"),
        ("fans", "Fans", "fan"),
        ("battery", "Battery", "battery.100percent")
    ]
    static let frosts: [(id: String, title: String)] = [
        ("hud", "HUD"),
        ("menu", "Menu"),
        ("popover", "Popover"),
        ("sidebar", "Sidebar"),
        ("header", "Header"),
        ("window", "Window")
    ]

    @Published var interval: Double
    @Published var bar: Set<String>
    @Published var barOrder: [String]
    @Published var drop: Set<String>
    @Published var login: Bool
    @Published var colors: [String: [Double]]
    @Published var frost: String
    @Published var frostTint: Double
    @Published var frostBehind: Bool
    @Published var customApp: String
    @Published var customApp2: String

    private init() {
        let d = UserDefaults.standard
        interval = (d.object(forKey: "sino.interval") ?? d.object(forKey: "pulse.interval")) as? Double ?? 1
        bar = Set(d.stringArray(forKey: "sino.bar") ?? d.stringArray(forKey: "pulse.bar") ?? ["ram", "cpu"])
        let ids = Prefs.modules.map(\.id)
        var order = d.stringArray(forKey: "sino.barOrder") ?? d.stringArray(forKey: "pulse.barOrder") ?? []
        order = order.filter { ids.contains($0) }
        for id in ids where !order.contains(id) { order.append(id) }
        barOrder = order
        drop = Set(d.stringArray(forKey: "sino.drop") ?? d.stringArray(forKey: "pulse.drop") ?? Prefs.modules.map(\.id))
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
        d.set(login, forKey: "sino.login")
        d.set(colors, forKey: "sino.colors")
        d.set(frost, forKey: "sino.frost")
        d.set(frostTint, forKey: "sino.frostTint")
        d.set(frostBehind, forKey: "sino.frostBehind")
        d.set(customApp, forKey: "sino.customApp")
        d.set(customApp2, forKey: "sino.customApp2")
        writeSlot()
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

    func customAppName(slot: Int = 1) -> String {
        let path = slot == 2 ? customApp2 : customApp
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    func customAppIcon(slot: Int = 1) -> NSImage? {
        let path = slot == 2 ? customApp2 : customApp
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
        if slot == 2 {
            customApp2 = url.path
        } else {
            customApp = url.path
        }
        save()
    }

    func clearCustomApp(slot: Int = 1) {
        if slot == 2 {
            customApp2 = ""
        } else {
            customApp = ""
        }
        save()
    }
}

enum Chrome {
    static func window(_ dark: Bool) -> Color {
        dark ? Color(red: 0.110, green: 0.110, blue: 0.118) : Color(red: 0.95, green: 0.95, blue: 0.97)
    }
    static func sidebar(_ dark: Bool) -> Color {
        dark ? Color(red: 0.145, green: 0.145, blue: 0.153) : Color(red: 0.93, green: 0.93, blue: 0.95)
    }
    static func group(_ dark: Bool) -> Color {
        dark ? Color(red: 0.173, green: 0.173, blue: 0.180) : Color.white.opacity(0.78)
    }
    static func selected(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
    }
    static func badge(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
    static let text: Font = .system(size: 13)
    static let title: Font = .system(size: 16, weight: .semibold)
    static let section: Font = .system(size: 13, weight: .semibold)
    static let caption: Font = .system(size: 11)
    static let rail: CGFloat = 176
} 

final class Updater: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Updater()
    static let repo = "Aduersarius/sino"
    @Published var status = "—"
    @Published var updateURL: URL?

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
        status = "Checking…"
        if !notify { updateURL = nil }
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
                if latest.compare(self.current, options: .numeric) == .orderedDescending {
                    self.status = "\(latest) available"
                    if notify { self.ping(latest) }
                } else {
                    self.status = "Up to date"
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
        c.body = "Version \(latest) is ready on GitHub"
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

struct SettingsRoot: View {
    @ObservedObject var app: App
    @ObservedObject var prefs: Prefs
    @ObservedObject var updater = Updater.shared

    var page: String { app.settingsPage }
    var dark: Bool { app.currentScheme == .dark }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .padding(.top, 38)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .frame(width: Chrome.rail, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Chrome.sidebar(dark))
            ScrollView {
                pageBody
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 38)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.all, 0, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: 600, height: 360)
        .background(Chrome.window(dark))
        .preferredColorScheme(app.currentScheme)
    }

    @ViewBuilder
    var pageBody: some View {
        switch page {
        case "appear": appearancePage
        case "bar": barPage
        case "drop": modulesPage(bind: prefs.dropBind)
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
            section("System") {
                row("Launch at Login") {
                    Toggle("", isOn: Binding(get: { prefs.login }, set: { prefs.setLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                row("Quit Sino") {
                    Button("Quit") { NSApp.terminate(nil) }
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
            }
        }
    }

    func appRow(_ slot: Int) -> some View {
        let path = slot == 2 ? prefs.customApp2 : prefs.customApp
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

    func modulesPage(bind: @escaping (String) -> Binding<Bool>) -> some View {
        SettingsGroup {
            ForEach(Array(Prefs.modules.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Divider().padding(.leading, 14) }
                SettingsRow(title: m.title) {
                    Toggle("", isOn: bind(m.id)).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    var barPage: some View {
        SettingsGroup {
            BarOrderTable(prefs: prefs)
                .frame(height: CGFloat(max(prefs.barOrder.count, 1)) * 36)
        }
    }

    var aboutPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Sino") {
                row("Version") {
                    Text(updater.current).font(Chrome.caption).foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 14)
                row("Updates") {
                    Button("Check") { updater.check() }
                }
                if updater.status != "—" {
                    Text(updater.status)
                        .font(Chrome.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                if updater.updateURL != nil {
                    Divider().padding(.leading, 14)
                    row("Release") {
                        Button("Open") { updater.openUpdate() }
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
        VStack(alignment: .leading, spacing: 2) {
            nav("general", "General", "gearshape.fill", Color(red: 0.55, green: 0.55, blue: 0.58))
            nav("appear", "Appearance", "paintpalette.fill", Color(red: 1.0, green: 0.35, blue: 0.55))
            nav("bar", "Menu Bar", "menubar.rectangle", Color(red: 0.20, green: 0.48, blue: 1.0))
            nav("drop", "Dropdown", "rectangle.split.2x1", Color(red: 0.62, green: 0.35, blue: 0.95))
            nav("about", "About", "info.circle.fill", Color(red: 0.20, green: 0.52, blue: 0.96))
            Spacer(minLength: 0)
        }
    }

    func nav(_ id: String, _ title: String, _ icon: String, _ color: Color) -> some View {
        Button { app.settingsPage = id } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).font(.system(size: 13, weight: .regular)).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(page == id ? Chrome.selected(dark) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .settingsHover(radius: 10)
    }

    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Chrome.section)
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

final class QuietRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}

struct SettingsGroup<Content: View>: View {
    @Environment(\.colorScheme) var scheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Chrome.group(scheme == .dark), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                Text(title).font(Chrome.text)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        v.updateTrackingAreas()
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
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking = false
    private var pressed = false { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        (captureHits || onClick != nil) && bounds.contains(point) ? self : nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { self.updateTrackingAreas() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            TooltipManager.shared.hide(for: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit {
        TooltipManager.shared.hideImmediately()
    }
    override func layout() {
        super.layout()
        updateTrackingAreas()
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: targetRect(),
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if let tip, !tip.isEmpty {
            TooltipManager.shared.show(tip, for: self)
        }
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        TooltipManager.shared.hide(for: self)
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
