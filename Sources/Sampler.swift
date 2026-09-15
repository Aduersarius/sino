import AppKit
import Combine
import CoreWLAN
import Darwin
import Foundation
import IOKit
import SystemConfiguration

struct TempSample: Identifiable {
    let id: Int
    let name: String
    var c: Double
}

struct VolumeSample: Identifiable {
    let id: String
    let name: String
    var avail: UInt64
    var total: UInt64
    var usedPct: Double
}

struct CoreSample: Identifiable {
    let id: Int
    let name: String
    var usage: Double
}

struct FanSample: Identifiable {
    let id: Int
    let name: String
    var rpm: Double
    var maxRPM: Double
}

struct ProcSample: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    var cpu: Double = 0
    var mem: UInt64 = 0
    var energyW: Double = 0
}

struct Snapshot {
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var cpuHistory: [Double] = []
    var cores: [CoreSample] = []
    var ramPressure = 0.0
    var ramWired: UInt64 = 0
    var ramCompressed: UInt64 = 0
    var ramUsed: UInt64 = 0
    var ramTotal: UInt64 = 0
    var ramSwapUsed: UInt64 = 0
    var ramSwapTotal: UInt64 = 0
    var gpuName = "GPU"
    var gpuUsage = 0.0
    var gpuMemUsed: UInt64 = 0
    var gpuMemTotal: UInt64 = 0
    var gpuMemAlloc: UInt64 = 0
    var gpuRenderer = 0.0
    var gpuTiler = 0.0
    var gpuCores = 0
    var gpuVendor = ""
    var diskName = "Disk"
    var diskAvail: UInt64 = 0
    var diskTotal: UInt64 = 0
    var diskUsedPct = 0.0
    var volumes: [VolumeSample] = []
    var netName = "Wi-Fi"
    var mac = "—"
    var wifi = true
    var netIn = 0.0
    var netOut = 0.0
    var netIPv4 = "—"
    var netIPv6 = "—"
    var netRouter = "—"
    var netSSID = "—"
    var netInHistory: [Double] = []
    var netOutHistory: [Double] = []
    var netInPeak = 0.0
    var netOutPeak = 0.0
    var publicIP = "—"
    var netTopName = "—"
    var netTopIcon: NSImage?
    var netTopBps = 0.0
    var fans: [FanSample] = []
    var temps: [TempSample] = []
    var battCharge = 0.0
    var battHealth = 0.0
    var battCycles = 0
    var charging = false
    var processes: [ProcSample] = []
    var memProcesses: [ProcSample] = []
    var energyProcesses: [ProcSample] = []
}

final class Sampler: ObservableObject {
    @Published var snap = Snapshot()

    private var timer: Timer?
    private var prevTicks: [[UInt32]] = []
    private var prevProc: [pid_t: UInt64] = [:]
    private var prevProcAt = Date()
    private var history: [Double] = Array(repeating: 0, count: 48)
    private let eCores: Int
    private let pCores: Int
    private let pageSize: UInt64
    private let memSize: UInt64
    private var diskNameCached: String?
    private var prevNetIn: UInt64 = 0
    private var prevNetOut: UInt64 = 0
    private var prevNetAt = Date()
    private var prevNetName = ""
    private var macCache: [String: String] = [:]
    private var prevEnergy: [pid_t: UInt64] = [:]
    private var ticks = 0
    private let dumping = CommandLine.arguments.contains("--dump")
    var heavy = false
    private var netInHist = Array(repeating: 0.0, count: 48)
    private var netOutHist = Array(repeating: 0.0, count: 48)
    private var netInPeak = 0.0
    private var netOutPeak = 0.0
    private var publicIP = "—"
    private var publicIPAt = Date.distantPast
    private var publicIPBusy = false
    private var netTopName = "—"
    private var netTopIcon: NSImage?
    private var netTopBps = 0.0
    private var netTopBusy = false
    private var netTopAt = Date.distantPast
    private var prevNetProc: [pid_t: (UInt64, UInt64)] = [:]
    private var powerSrc: CFRunLoopSource?
    private var lastVolumesAt = Date.distantPast
    private var lastBattStaticAt = Date.distantPast
    private var lastRouterAt = Date.distantPast
    private var gpuNameCached: String?
    private var gpuVendorCached: String?
    private var gpuCoresCached: Int?

    init() {
        eCores = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        pCores = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        pageSize = UInt64(ps)
        memSize = sysctlU64("hw.memsize") ?? 1
        _ = sino_smc_init()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Prefs.shared.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<Sampler>.fromOpaque(ctx).takeUnretainedValue().powerChanged()
        }, ptr)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            powerSrc = src
        }
        // ponytail: no Location prompt — SSID from CoreWLAN/SCDynamicStore/profiles
    }

    func setInterval(_ t: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.25, t), repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        timer?.invalidate()
        if let powerSrc {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSrc, .commonModes)
        }
        sino_smc_shutdown()
    }

    private func powerChanged() {
        let apply = { [weak self] in
            guard let self else { return }
            var s = self.snap
            self.sampleBattery(&s)
            self.snap = s
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func tick() {
        var s = snap
        sampleCPU(&s)
        sampleRAM(&s)
        sampleGPU(&s)
        sampleDisk(&s)
        sampleNet(&s)
        sampleFans(&s)
        sampleBattery(&s)
        if heavy || dumping {
            sampleProcs(&s)
            kickNetTop()
        } else {
            s.processes = []
            s.memProcesses = []
            s.energyProcesses = []
            s.netTopName = "—"
            s.netTopIcon = nil
            s.netTopBps = 0
        }
        snap = s
        ticks += 1
        if dumping, ticks >= 3 {
            print("""
            CPU user \(Int(s.cpuUser*100))% sys \(Int(s.cpuSystem*100))% cores \(s.cores.map { Int($0.usage*100) })
            RAM \(s.ramUsed/1_048_576)MB / \(s.ramTotal/1_048_576)MB pressure \(Int(s.ramPressure*100))%
            GPU \(s.gpuName) vendor \(s.gpuVendor) cores \(s.gpuCores) device \(Int(s.gpuUsage*100))% renderer \(Int(s.gpuRenderer*100))% tiler \(Int(s.gpuTiler*100))% inuse \(s.gpuMemUsed/1_048_576)MB alloc \(s.gpuMemAlloc/1_048_576)MB
            Disk \(s.diskName) used \(Int(s.diskUsedPct*100))% avail \(s.diskAvail/1_000_000_000)GB
            Net \(s.netName) \(s.mac) ↓\(Int(s.netIn)) ↑\(Int(s.netOut)) B/s pub \(s.publicIP) local \(s.netIPv4) ssid \(s.netSSID) peak↓\(Int(s.netInPeak)) peak↑\(Int(s.netOutPeak)) top \(s.netTopName) \(Int(s.netTopBps)) B/s hist \(s.netInHistory.count)
            Fans \(s.fans.map { "\($0.name)=\(Int($0.rpm))" })
            Batt \(Int(s.battCharge*100))% health \(Int(s.battHealth*100))% cycles \(s.battCycles) charging \(s.charging)
            Procs:
            \(s.processes.map { "  \($0.name) \(Int($0.cpu*1000)/10)%" }.joined(separator: "\n"))
            """)
            Darwin.exit(0)
        }
    }

    private func sampleCPU(_ s: inout Snapshot) {
        var ncpu: natural_t = 0
        var info: processor_info_array_t?
        var infoCnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &infoCnt) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCnt) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let cores = Int(ncpu)
        let load = info.withMemoryRebound(to: UInt32.self, capacity: cores * Int(CPU_STATE_MAX)) { ptr in
            (0..<cores).map { c in
                let b = c * Int(CPU_STATE_MAX)
                return [ptr[b + Int(CPU_STATE_USER)], ptr[b + Int(CPU_STATE_SYSTEM)], ptr[b + Int(CPU_STATE_IDLE)], ptr[b + Int(CPU_STATE_NICE)]]
            }
        }
        if prevTicks.count == cores {
            var userSum = 0.0, sysSum = 0.0, totSum = 0.0
            var coreUsage: [Double] = []
            for i in 0..<cores {
                let du = Double(load[i][0] &- prevTicks[i][0])
                let ds = Double(load[i][1] &- prevTicks[i][1])
                let di = Double(load[i][2] &- prevTicks[i][2])
                let dn = Double(load[i][3] &- prevTicks[i][3])
                let tot = du + ds + di + dn
                let u = tot > 0 ? (du + dn) / tot : 0
                let sy = tot > 0 ? ds / tot : 0
                userSum += u; sysSum += sy; totSum += 1
                coreUsage.append(min(1, u + sy))
            }
            s.cpuUser = userSum / totSum
            s.cpuSystem = sysSum / totSum
            history.removeFirst()
            history.append(s.cpuUser + s.cpuSystem)
            s.cpuHistory = history
            // host_processor_info lists P-cores first on Apple Silicon
            let p = (pCores > 0 && eCores + pCores == cores) ? pCores : 0
            s.cores = coreUsage.enumerated().map { i, v in
                let name: String
                if p > 0, i < p {
                    name = "Performance Core #\(i + 1)"
                } else if p > 0 {
                    name = "Efficiency Core #\(i - p + 1)"
                } else {
                    name = "Core #\(i + 1)"
                }
                return CoreSample(id: i, name: name, usage: v)
            }
        }
        prevTicks = load
    }

    private func sampleRAM(_ s: inout Snapshot) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let used = (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * pageSize
        s.ramUsed = used
        s.ramTotal = memSize
        s.ramWired = UInt64(vm.wire_count) * pageSize
        s.ramCompressed = UInt64(vm.compressor_page_count) * pageSize
        s.ramPressure = min(1, Double(used) / Double(memSize))
        var xsw = xsw_usage()
        var xsz = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        if sysctl(&mib, 2, &xsw, &xsz, nil, 0) == 0 {
            s.ramSwapUsed = xsw.xsu_used
            s.ramSwapTotal = xsw.xsu_total
        }
    }

    private func sampleGPU(_ s: inout Snapshot) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var svc = IOIteratorNext(it)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }
            guard let dict = copyProps(svc) else { continue }
            if let cached = gpuNameCached { s.gpuName = cached }
            else if let model = dict["model"] as? String { s.gpuName = model; gpuNameCached = model }
            if let cached = gpuCoresCached { s.gpuCores = cached }
            else if let n = dict["gpu-core-count"] as? NSNumber { s.gpuCores = n.intValue; gpuCoresCached = n.intValue }
            if let cached = gpuVendorCached { s.gpuVendor = cached }
            else { let v = pciVendor(dict); s.gpuVendor = v; gpuVendorCached = v }
            guard let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            if let u = stats["Device Utilization %"] as? NSNumber { s.gpuUsage = u.doubleValue / 100 }
            if let u = stats["Renderer Utilization %"] as? NSNumber { s.gpuRenderer = u.doubleValue / 100 }
            if let u = stats["Tiler Utilization %"] as? NSNumber { s.gpuTiler = u.doubleValue / 100 }
            if let m = stats["In use system memory"] as? NSNumber { s.gpuMemUsed = m.uint64Value }
            if let m = stats["Alloc system memory"] as? NSNumber { s.gpuMemAlloc = m.uint64Value }
            s.gpuMemTotal = s.gpuMemAlloc > 0 ? s.gpuMemAlloc : memSize
            break
        }
    }

    private func sampleDisk(_ s: inout Snapshot) {
        if diskNameCached == nil { diskNameCached = nvmeModel() ?? "Apple SSD" }
        s.diskName = diskNameCached ?? "Disk"
        var stat = statfs()
        if statfs("/", &stat) == 0 {
            let bsize = UInt64(stat.f_bsize)
            let total = UInt64(stat.f_blocks) * bsize
            let avail = UInt64(stat.f_bavail) * bsize
            s.diskAvail = avail
            s.diskTotal = total
            s.diskUsedPct = total > 0 ? (1 - Double(avail) / Double(total)) : 0
        }
        if heavy || s.volumes.isEmpty || Date().timeIntervalSince(lastVolumesAt) >= 30 {
            lastVolumesAt = Date()
            var vols: [VolumeSample] = []
            if let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey],
                options: [.skipHiddenVolumes]
            ) {
                for url in urls {
                    guard let rv = try? url.resourceValues(forKeys: [
                        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
                    ]), let tot = rv.volumeTotalCapacity, tot > 1_000_000_000 else { continue }
                    let av = UInt64(rv.volumeAvailableCapacityForImportantUsage ?? 0)
                    let name = rv.volumeName ?? url.lastPathComponent
                    vols.append(VolumeSample(
                        id: url.path,
                        name: name,
                        avail: av,
                        total: UInt64(tot),
                        usedPct: 1 - Double(av) / Double(tot)
                    ))
                }
            }
            s.volumes = vols
        }
    }

    private func sampleNet(_ s: inout Snapshot) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }

        struct Iface {
            var name: String
            var mac = ""
            var inn: UInt64 = 0
            var out: UInt64 = 0
            var ipv4 = false
            var wifi = false
            var ip4 = ""
            var ip6 = ""
        }
        var byName: [String: Iface] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let nm = String(cString: cur.pointee.ifa_name)
            guard nm.hasPrefix("en") else { continue }
            var iface = byName[nm] ?? Iface(name: nm)
            guard let sa = cur.pointee.ifa_addr else { byName[nm] = iface; continue }
            let fam = sa.pointee.sa_family
            if fam == UInt8(AF_INET) {
                iface.ipv4 = true
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var a = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: buf)
                    if iface.ip4.isEmpty { iface.ip4 = ip }
                }
            }
            if fam == UInt8(AF_INET6) {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var a = sin6.pointee.sin6_addr
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &a, &buf, socklen_t(INET6_ADDRSTRLEN))
                    let ip = String(cString: buf)
                    if !ip.hasPrefix("fe80") && iface.ip6.isEmpty { iface.ip6 = ip }
                }
            }
            if fam == UInt8(AF_LINK) {
                if let mac = linkMAC(cur.pointee.ifa_addr) { iface.mac = mac }
                if let data = cur.pointee.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    iface.inn = UInt64(d.ifi_ibytes)
                    iface.out = UInt64(d.ifi_obytes)
                    iface.wifi = d.ifi_type == 71
                }
            }
            byName[nm] = iface
        }

        func placeholder(_ mac: String) -> Bool {
            mac.isEmpty || mac == "00:00:00:00:00:00" || mac == "02:00:00:00:00:00"
        }
        func score(_ i: Iface) -> Int {
            var n = 0
            if i.ipv4 { n += 100 }
            if i.wifi { n += 10 }
            return n
        }
        let cands = Array(byName.values)
        let pick = cands.max { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa < sb }
            return a.inn &+ a.out < b.inn &+ b.out
        }
        guard let iface = pick else { return }
        if let cached = macCache[iface.name] {
            s.mac = cached
        } else if let mac = ioMAC(for: iface.name), !placeholder(mac) {
            macCache[iface.name] = mac
            s.mac = mac
        } else if !placeholder(iface.mac) {
            s.mac = iface.mac
        } else {
            s.mac = iface.mac.isEmpty ? "—" : iface.mac
        }
        s.wifi = iface.wifi || iface.name == "en0"
        s.netSSID = s.wifi ? (currentSSID(bsd: iface.name) ?? "—") : "—"
        s.netName = s.wifi ? (s.netSSID == "—" ? "Wi-Fi" : s.netSSID) : "Ethernet"
        let dt = Date().timeIntervalSince(prevNetAt)
        if prevNetName == iface.name, prevNetIn > 0, dt > 0.2 {
            s.netIn = Double(iface.inn &- prevNetIn) / dt
            s.netOut = Double(iface.out &- prevNetOut) / dt
        } else {
            s.netIn = 0
            s.netOut = 0
        }
        prevNetName = iface.name
        prevNetIn = iface.inn
        prevNetOut = iface.out
        prevNetAt = Date()
        s.netIPv4 = iface.ip4.isEmpty ? "—" : iface.ip4
        s.netIPv6 = iface.ip6.isEmpty ? "—" : iface.ip6
        netInHist.removeFirst()
        netInHist.append(s.netIn)
        netOutHist.removeFirst()
        netOutHist.append(s.netOut)
        s.netInHistory = netInHist
        s.netOutHistory = netOutHist
        if s.netIn > netInPeak { netInPeak = s.netIn }
        if s.netOut > netOutPeak { netOutPeak = s.netOut }
        s.netInPeak = netInPeak
        s.netOutPeak = netOutPeak
        s.publicIP = publicIP
        s.netTopName = netTopName
        s.netTopIcon = netTopIcon
        s.netTopBps = netTopBps
        if heavy || s.netRouter == "—" || Date().timeIntervalSince(lastRouterAt) >= 30 {
            lastRouterAt = Date()
            if let store = SCDynamicStoreCreate(nil, "sino" as CFString, nil, nil),
               let info = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
               let r = info["Router"] as? String {
                s.netRouter = r
            } else {
                s.netRouter = "—"
            }
        }
        kickPublicIP()
    }

    func runHeavy() {
        heavy = true
        var s = snap
        sampleDisk(&s)
        sampleBattery(&s)
        sampleProcs(&s)
        snap = s
        kickNetTop()
    }

    func stopHeavy() {
        heavy = false
        netTopName = "—"
        netTopIcon = nil
        netTopBps = 0
        var s = snap
        s.processes = []
        s.memProcesses = []
        s.energyProcesses = []
        s.netTopName = "—"
        s.netTopIcon = nil
        s.netTopBps = 0
        snap = s
    }

    private func kickPublicIP() {
        if publicIPBusy || Date().timeIntervalSince(publicIPAt) < 120 { return }
        guard let url = URL(string: "https://api.ipify.org") else { return }
        publicIPBusy = true
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            defer { DispatchQueue.main.async { self?.publicIPBusy = false } }
            guard let data, let ip = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                ip.contains("."), ip.count < 48 else { return }
            DispatchQueue.main.async {
                self?.publicIP = ip
                self?.publicIPAt = Date()
            }
        }.resume()
    }

    private func kickNetTop() {
        if dumping || netTopBusy || Date().timeIntervalSince(netTopAt) < 2 { return }
        netTopBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { DispatchQueue.main.async { self?.netTopBusy = false } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            p.arguments = ["-P", "-L", "1", "-x"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            p.waitUntilExit()
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard let self else { return }
            var next: [pid_t: (UInt64, UInt64)] = [:]
            var best: (pid_t, String, Double) = (0, "—", 0)
            let dt = max(0.5, Date().timeIntervalSince(self.netTopAt == .distantPast ? Date() : self.netTopAt))
            for line in raw.split(separator: "\n").dropFirst() {
                let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                guard cols.count > 5 else { continue }
                let np = String(cols[1])
                guard let dot = np.lastIndex(of: ".") else { continue }
                let name = String(np[..<dot])
                guard name != "kernel_task", name != "launchd", name != "Pulse", name != "Sino" else { continue }
                let pid = pid_t(np[np.index(after: dot)...]) ?? 0
                let inn = UInt64(cols[4]) ?? 0
                let out = UInt64(cols[5]) ?? 0
                next[pid] = (inn, out)
                guard let prev = self.prevNetProc[pid] else { continue }
                let dIn = inn >= prev.0 ? Double(inn - prev.0) / dt : 0
                let dOut = out >= prev.1 ? Double(out - prev.1) / dt : 0
                let sum = dIn + dOut
                if sum > best.2 { best = (pid, name, sum) }
            }
            self.prevNetProc = next
            DispatchQueue.main.async {
                self.netTopAt = Date()
                guard self.heavy, best.2 > 0 else { return }
                let app = best.0 > 0 ? NSRunningApplication(processIdentifier: best.0) : nil
                self.netTopName = app?.localizedName ?? best.1
                self.netTopIcon = app?.icon
                self.netTopBps = best.2
            }
        }
    }

    private func sampleFans(_ s: inout Snapshot) {
        var rpm = [Float](repeating: 0, count: 8)
        var mx = [Float](repeating: 0, count: 8)
        let n = Int(sino_smc_fans(&rpm, &mx, 8))
        var fans: [FanSample] = (0..<n).map { i in
            FanSample(id: i, name: "Fan #\(i + 1)", rpm: Double(rpm[i]), maxRPM: Double(mx[i]))
        }
        fans.sort { $0.rpm > $1.rpm }
        s.fans = fans
        var nameBuf = [CChar](repeating: 0, count: 16 * 32)
        var cels = [Float](repeating: 0, count: 16)
        let tn = nameBuf.withUnsafeMutableBufferPointer { nb in
            cels.withUnsafeMutableBufferPointer { cb in
                sino_smc_temps(nb.baseAddress, cb.baseAddress, 16)
            }
        }
        var temps: [TempSample] = []
        for i in 0..<Int(tn) {
            let name = nameBuf.withUnsafeBufferPointer { p in
                String(cString: p.baseAddress! + i * 32)
            }
            temps.append(TempSample(id: i, name: name, c: Double(cels[i])))
        }
        s.temps = temps
    }

    private func sampleBattery(_ s: inout Snapshot) {
        // IOPS is instant on plug/unplug; AppleSmartBattery lags the 1.25s tick
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as NSArray
            for case let ps as CFTypeRef in list {
                guard let raw = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() else { continue }
                let d = raw as NSDictionary
                guard (d[kIOPSTypeKey] as? String) == (kIOPSInternalBatteryType as String) else { continue }
                if let cap = d[kIOPSCurrentCapacityKey] as? NSNumber {
                    s.battCharge = cap.doubleValue / 100
                }
                let ac = (d[kIOPSPowerSourceStateKey] as? String) == (kIOPSACPowerValue as String)
                let charging = (d[kIOPSIsChargingKey] as? NSNumber)?.boolValue
                    ?? (d[kIOPSIsChargingKey] as? Bool)
                    ?? false
                s.charging = ac || charging
                break
            }
        }
        let now = Date()
        if heavy || s.battHealth == 0 || now.timeIntervalSince(lastBattStaticAt) >= 60 {
            lastBattStaticAt = now
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            guard svc != 0 else { return }
            defer { IOObjectRelease(svc) }
            guard let dict = copyProps(svc) else { return }
            if let c = dict["CycleCount"] as? NSNumber { s.battCycles = c.intValue }
            if let bd = dict["BatteryData"] as? [String: Any],
               let fcc = (bd["FullChargeCapacity"] as? NSNumber)?.doubleValue,
               let dc = (bd["DesignCapacity"] as? NSNumber)?.doubleValue, dc > 0 {
                s.battHealth = fcc / dc
            }
        }
    }

    private func sampleProcs(_ s: inout Snapshot) {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard bytes > 0 else { return }
        let n = Int(bytes) / MemoryLayout<pid_t>.stride
        let now = Date()
        let dt = now.timeIntervalSince(prevProcAt)
        var next: [pid_t: UInt64] = [:]
        var nextEnergy: [pid_t: UInt64] = [:]
        var ranked: [(pid_t, String, NSImage?, Double)] = []
        var byMem: [(pid_t, String, NSImage?, UInt64)] = []
        var byEnergy: [(pid_t, String, NSImage?, Double)] = []
        for i in 0..<n {
            let pid = pids[i]
            if pid <= 0 { continue }
            var ti = proc_taskinfo()
            let sz = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.stride))
            guard sz == Int32(MemoryLayout<proc_taskinfo>.stride) else { continue }
            let total = ti.pti_total_user + ti.pti_total_system
            next[pid] = total
            let rss = ti.pti_resident_size
            var foot: UInt64 = 0
            if sino_pid_footprint(Int32(pid), &foot) != 0 || foot == 0 { foot = rss }
            var nj: UInt64 = 0
            let hasE = sino_pid_energy_nj(Int32(pid), &nj) == 0
            if hasE { nextEnergy[pid] = nj }
            let wantCPU = dt > 0.2 && prevProc[pid] != nil
            let wantMem = foot > 16 * 1024 * 1024
            let wantE = hasE && dt > 0.2 && prevEnergy[pid] != nil
            if !wantCPU && !wantMem && !wantE { continue }
            let (name, icon) = procIdentity(pid)
            if name == "kernel_task" || name == "Sino" { continue }
            if wantMem {
                byMem.append((pid, name, icon, foot))
            }
            if wantCPU, let prev = prevProc[pid] {
                let d = total >= prev ? total - prev : 0
                let pct = (Double(d) / 1_000_000_000) / dt
                if pct >= 0.005 {
                    ranked.append((pid, name, icon, min(1, pct)))
                }
            }
            if wantE, let prev = prevEnergy[pid], nj >= prev {
                let watts = Double(nj - prev) / 1_000_000_000 / max(dt, 0.2)
                if watts > 0.03 {
                    byEnergy.append((pid, name, icon, watts))
                }
            }
        }
        ranked.sort { $0.3 > $1.3 }
        s.processes = ranked.prefix(10).map { ProcSample(id: $0.0, name: $0.1, icon: $0.2, cpu: $0.3) }
        byMem.sort { $0.3 > $1.3 }
        s.memProcesses = byMem.prefix(10).map { ProcSample(id: $0.0, name: $0.1, icon: $0.2, mem: $0.3) }
        byEnergy.sort { $0.3 > $1.3 }
        s.energyProcesses = byEnergy.prefix(8).map { ProcSample(id: $0.0, name: $0.1, icon: $0.2, energyW: $0.3) }
        prevProc = next
        prevEnergy = nextEnergy
        prevProcAt = now
    }
}

private func procIdentity(_ pid: pid_t) -> (String, NSImage?) {
    if let app = NSRunningApplication(processIdentifier: pid) {
        return (app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)", app.icon)
    }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    if proc_pidpath(pid, &path, UInt32(MAXPATHLEN)) > 0 {
        let p = String(cString: path)
        let name = URL(fileURLWithPath: p).lastPathComponent
        return (name, NSWorkspace.shared.icon(forFile: p))
    }
    return ("pid \(pid)", nil)
}

private func pciVendor(_ dict: NSDictionary) -> String {
    var id: UInt32 = 0
    if let d = dict["vendor-id"] as? Data, !d.isEmpty {
        id = d.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    } else if let n = dict["vendor-id"] as? NSNumber {
        id = n.uint32Value
    } else {
        return ""
    }
    switch id {
    case 0x106B: return "Apple"
    case 0x10DE: return "NVIDIA"
    case 0x1002: return "AMD"
    case 0x8086: return "Intel"
    default: return id == 0 ? "" : String(format: "0x%04X", id)
    }
}

private func copyProps(_ svc: io_object_t) -> NSDictionary? {
    var ref: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return ref?.takeRetainedValue() as NSDictionary?
}

private func nvmeModel() -> String? {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &it) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(it) }
    var svc = IOIteratorNext(it)
    while svc != 0 {
        defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }
        guard let d = copyProps(svc) else { continue }
        for k in ["Model Number", "Product Name", "device-model", "Model"] {
            if let s = d[k] as? String { return s.trimmingCharacters(in: .whitespaces) }
            if let b = d[k] as? Data, let s = String(data: b, encoding: .utf8) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    return nil
}

private func ioMAC(for bsd: String) -> String? {
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
    var svc = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard svc != 0 else { return nil }
    for _ in 0..<8 {
        if let mac = ioMACOn(svc) {
            IOObjectRelease(svc)
            return mac
        }
        var parent: io_registry_entry_t = 0
        let kr = IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent)
        IOObjectRelease(svc)
        guard kr == KERN_SUCCESS else { return nil }
        svc = parent
    }
    IOObjectRelease(svc)
    return nil
}

private func ioMACOn(_ svc: io_registry_entry_t) -> String? {
    guard let cf = IORegistryEntryCreateCFProperty(svc, "IOMACAddress" as CFString, kCFAllocatorDefault, 0) else { return nil }
    let val = cf.takeRetainedValue()
    let data = (val as? Data) ?? (val as? NSData).map { $0 as Data }
    guard let data, data.count >= 6 else { return nil }
    return data.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
}

private func linkMAC(_ sa: UnsafePointer<sockaddr>) -> String? {
    sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl -> String? in
        let nlen = Int(sdl.pointee.sdl_nlen)
        let alen = Int(sdl.pointee.sdl_alen)
        guard alen == 6 else { return nil }
        return withUnsafePointer(to: sdl.pointee.sdl_data) { dataPtr in
            dataPtr.withMemoryRebound(to: UInt8.self, capacity: nlen + alen) { bytes in
                let mac = UnsafeBufferPointer(start: bytes + nlen, count: 6)
                return mac.map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
    }
}

private func currentSSID(bsd: String) -> String? {
    let wifi = CWWiFiClient.shared().interface()
    if let s = wifi?.ssid(), !s.isEmpty { return s }
    let name = wifi?.interfaceName ?? bsd
    if let store = SCDynamicStoreCreate(nil, "sino-ssid" as CFString, nil, nil),
       let d = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/AirPort" as CFString) as? [String: Any] {
        if let s = d["SSID_STR"] as? String, !s.isEmpty { return s }
        if let data = d["SSID"] as? Data,
           let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)),
           !s.isEmpty {
            return s
        }
    }
    if let s = ssidFromProfiles(wifi), !s.isEmpty { return s }
    return airportSSID(name)
}

// networksetup last; without Location it prints “not associated”. cache so we don’t spawn every tick
private var airportSSIDAt = Date.distantPast
private var airportSSIDCached: String?

private func airportSSID(_ bsd: String) -> String? {
    if Date().timeIntervalSince(airportSSIDAt) < 30 { return airportSSIDCached }
    airportSSIDAt = Date()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    p.arguments = ["-getairportnetwork", bsd]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { airportSSIDCached = nil; return nil }
    p.waitUntilExit()
    let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "Current Wi-Fi Network: "
    guard t.hasPrefix(prefix) else { airportSSIDCached = nil; return nil }
    let s = String(t.dropFirst(prefix.count))
    airportSSIDCached = s.isEmpty ? nil : s
    return airportSSIDCached
}

// CoreWLAN ssid() is nil without Location; remembered profiles still have AssociatedAt
private func ssidFromProfiles(_ wifi: CWInterface?) -> String? {
    guard let wifi, let profiles = wifi.configuration()?.networkProfiles else { return nil }
    var best: (Date, String)?
    let sel = NSSelectorFromString("bssidList")
    for i in 0..<profiles.count {
        guard let np = profiles.object(at: i) as? CWNetworkProfile,
              let ssid = np.ssid, !ssid.isEmpty,
              np.responds(to: sel),
              let list = np.value(forKey: "bssidList") as? [[String: Any]]
        else { continue }
        for e in list {
            guard let at = e["AssociatedAt"] as? Date else { continue }
            if best == nil || at > best!.0 { best = (at, ssid) }
        }
    }
    return best?.1
}

private func sysctlInt(_ name: String) -> Int? {
    var v: Int32 = 0
    var sz = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &v, &sz, nil, 0) == 0 else { return nil }
    return Int(v)
}

private func sysctlU64(_ name: String) -> UInt64? {
    var v: UInt64 = 0
    var sz = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &v, &sz, nil, 0) == 0 else { return nil }
    return v
}
