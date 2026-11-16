import CryptoKit
import Foundation

/// Fixed-capacity sliding window of `Double` samples.
struct RingBuffer {
    private(set) var values: [Double]

    init(count: Int, repeating value: Double = 0) {
        self.values = Array(repeating: value, count: max(1, count))
    }

    mutating func append(_ value: Double) {
        if !values.isEmpty { values.removeFirst() }
        values.append(value)
    }
}

/// Pure Apple Silicon / multi-core labeling helpers.
/// On Apple Silicon, `host_processor_info` returns Efficiency cores first (`0 ..< eCores`),
/// followed by Performance cores (`eCores ..< total`).
enum CPUCoreLayout {
    static func label(index: Int, eCores: Int, pCores: Int, totalCores: Int) -> String {
        if eCores > 0, pCores > 0, eCores + pCores == totalCores {
            if index < eCores {
                return "Efficiency Core #\(index + 1)"
            }
            return "Performance Core #\(index - eCores + 1)"
        }
        return "Core #\(index + 1)"
    }
}

/// Pure telemetry & system-output parsers, decoupled from AppKit/IOKit/Process for unit testing.
enum NetParser {
    /// Reads a 6-byte link-layer MAC address directly from a raw `sockaddr_dl` buffer,
    /// bounded by `sa_len` rather than copying the fixed 12-byte C `sdl_data` tuple.
    static func extractLinkMAC(
        rawBytes: UnsafeRawPointer,
        saLen: Int,
        dataOffset: Int,
        nameLen: Int,
        addrLen: Int
    ) -> String? {
        guard addrLen == 6, nameLen >= 0, dataOffset >= 0 else { return nil }
        guard saLen >= dataOffset + nameLen + addrLen else { return nil }
        let base = rawBytes.advanced(by: dataOffset + nameLen).assumingMemoryBound(to: UInt8.self)
        return (0..<6).map { String(format: "%02X", base[$0]) }.joined(separator: ":")
    }

    struct NettopSample: Equatable {
        var pid: Int32
        var name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    struct NetCounters: Equatable {
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    struct NettopDiffResult: Equatable {
        var nextCounters: [Int32: NetCounters]
        var topPID: Int32
        var topName: String
        var topBytesPerSec: Double
    }

    static func parseNettopCSV(
        _ raw: String,
        previous: [Int32: NetCounters],
        dt: TimeInterval,
        ignoredNames: Set<String> = ["kernel_task", "launchd", "Pulse", "Sino"]
    ) -> NettopDiffResult {
        let elapsed = max(0.5, dt)
        var next: [Int32: NetCounters] = [:]
        var bestPID: Int32 = 0
        var bestName = "—"
        var bestRate = 0.0

        for line in raw.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count > 5 else { continue }
            let nameAndPID = String(cols[1])
            guard let dot = nameAndPID.lastIndex(of: ".") else { continue }
            let name = String(nameAndPID[..<dot])
            guard !name.isEmpty, !ignoredNames.contains(name) else { continue }
            guard let pid = Int32(nameAndPID[nameAndPID.index(after: dot)...]), pid > 0 else { continue }
            let inn = UInt64(cols[4]) ?? 0
            let out = UInt64(cols[5]) ?? 0
            next[pid] = NetCounters(bytesIn: inn, bytesOut: out)
            guard let prev = previous[pid] else { continue }
            let dIn = inn >= prev.bytesIn ? Double(inn - prev.bytesIn) / elapsed : 0
            let dOut = out >= prev.bytesOut ? Double(out - prev.bytesOut) / elapsed : 0
            let sum = dIn + dOut
            if sum > bestRate {
                bestPID = pid
                bestName = name
                bestRate = sum
            }
        }
        return NettopDiffResult(nextCounters: next, topPID: bestPID, topName: bestName, topBytesPerSec: bestRate)
    }

    struct IPInfoParsed: Equatable {
        var publicIPv4: String
        var location: String
        var geoCoordinates: String
        var timezone: String
        var asName: String
        var isp: String
        var organization: String
    }

    static func parseIPInfoJSON(_ data: Data) -> IPInfoParsed? {
        struct IPInfoResponse: Codable {
            var ip: String?
            var city: String?
            var region: String?
            var country: String?
            var loc: String?
            var org: String?
            var postal: String?
            var timezone: String?
        }
        guard let resp = try? JSONDecoder().decode(IPInfoResponse.self, from: data),
              let ip = resp.ip, !ip.isEmpty else { return nil }
        var locParts: [String] = []
        if let c = resp.country, !c.isEmpty { locParts.append(c) }
        if let r = resp.region, !r.isEmpty { locParts.append(r) }
        if let ci = resp.city, !ci.isEmpty { locParts.append(ci) }
        if let z = resp.postal, !z.isEmpty { locParts.append("ZIP: \(z)") }

        var asName = "—"
        var isp = "—"
        var organization = "—"
        if let rawOrg = resp.org, !rawOrg.isEmpty {
            let parts = rawOrg.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = parts.first, first.uppercased().hasPrefix("AS") {
                asName = String(first)
                let remaining = parts.count > 1 ? String(parts[1]) : "—"
                isp = remaining
                organization = remaining
            } else {
                isp = rawOrg
                organization = rawOrg
            }
        }

        let coords: String
        if let loc = resp.loc, !loc.isEmpty {
            coords = loc.replacingOccurrences(of: ",", with: " , ")
        } else {
            coords = "—"
        }

        return IPInfoParsed(
            publicIPv4: ip,
            location: locParts.isEmpty ? "—" : locParts.joined(separator: ", "),
            geoCoordinates: coords,
            timezone: (resp.timezone?.isEmpty == false ? resp.timezone : nil) ?? "—",
            asName: asName,
            isp: isp,
            organization: organization
        )
    }

    static func parseAirportSSID(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Current Wi-Fi Network: "
        guard t.hasPrefix(prefix) else { return nil }
        let s = String(t.dropFirst(prefix.count))
        return s.isEmpty ? nil : s
    }
}

enum PMSetParser {
    static func parseFlag(_ key: String, from output: String) -> Bool {
        let needle = key.lowercased()
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2, parts[0].lowercased() == needle else { continue }
            if parts[1] == "1" { return true }
        }
        return false
    }

    static func isValidPosixUsername(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") ||
            (scalar >= "A" && scalar <= "Z") ||
            (scalar >= "0" && scalar <= "9") ||
            scalar == "_" || scalar == "-" || scalar == "."
        }
    }
}

enum ProcParser {
    static func canonicalAppName(from rawName: String) -> String {
        var clean = rawName
        for pattern in [
            " Helper (Renderer)",
            " Helper (GPU)",
            " Helper (Plugin)",
            " Helper (Alerts)",
            " Helper",
            " (Renderer)",
            " (GPU)",
            " (Prewarmed)"
        ] {
            if clean.hasSuffix(pattern) {
                clean = String(clean.dropLast(pattern.count))
                break
            }
        }
        if clean.hasPrefix("com.apple.WebKit.") || clean == "Safari Web Content" {
            return "Safari"
        }
        return clean
    }

    static func isSafariProcessPath(_ path: String) -> Bool {
        path.hasPrefix("/Applications/Safari.app/") ||
        path.contains("/Safari.app/") ||
        path.contains("/com.apple.Safari.") ||
        path.contains("/com.apple.WebKit.")
    }
}

enum PrefsValidation {
    static func clampInterval(_ v: Double) -> Double {
        v.isFinite ? min(5, max(0.25, v)) : 1
    }

    static func clampFoldAngle(_ v: Double) -> Double {
        v.isFinite ? min(135, max(75, v)) : 105
    }

    static func clampUnit(_ v: Double, fallback: Double) -> Double {
        v.isFinite ? min(1, max(0, v)) : fallback
    }

    static func clampFoldJitter(_ v: Double) -> Double {
        v.isFinite ? min(5, max(0, v)) : 0
    }

    static func clampProcCount(_ v: Int, fallback: Int) -> Int {
        v > 0 ? max(3, min(30, v)) : fallback
    }

    static func validFoldMode(_ v: String?, legacyBlurOnly: Bool = false) -> String {
        if let v, ["fold", "blur", "off"].contains(v) { return v }
        return legacyBlurOnly ? "blur" : "fold"
    }

    static func validCpuProcMode(_ v: String?) -> String {
        v == "perCore" ? "perCore" : "total"
    }

    static func parseFanCurvePairs(_ raw: [[Double]]) -> [(temp: Double, rpm: Double)]? {
        guard raw.count >= 3 else { return nil }
        var out: [(Double, Double)] = []
        for pair in raw.prefix(3) {
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return nil }
            let temp = min(105, max(30, pair[0]))
            let rpm = min(20000, max(0, pair[1]))
            out.append((temp, rpm))
        }
        return out
    }

    static func isValidMove(from: Int, to: Int, count: Int) -> Bool {
        from >= 0 && from < count && to >= 0 && to <= count
    }
}

enum UpdateValidator {
    static let allowedHosts: Set<String> = [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "github-releases.githubusercontent.com",
        "release-assets.githubusercontent.com"
    ]

    static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        if allowedHosts.contains(host) { return true }
        return host.hasSuffix(".githubusercontent.com")
    }

    static func parseSHA256Digest(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = trimmed.hasPrefix("sha256:") ? String(trimmed.dropFirst(7)) : trimmed
        guard hex.count == 64, hex.unicodeScalars.allSatisfy({
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }) else { return nil }
        return hex
    }

    static func sha256Hex(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyFile(_ url: URL, matchesDigest rawDigest: String?) -> Bool {
        guard let expected = parseSHA256Digest(rawDigest),
              let actual = sha256Hex(fileAt: url) else { return false }
        return actual == expected
    }
}
