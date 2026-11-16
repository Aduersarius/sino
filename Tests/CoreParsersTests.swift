import Foundation

@main
struct CoreParsersTests {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok {
                failures += 1
                print("FAIL \(what)")
            }
        }

        let validHex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let upperHex = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"

        // UpdateValidator: parseSHA256Digest
        check(UpdateValidator.parseSHA256Digest("sha256:" + validHex) == validHex, "parse valid lowercase with prefix")
        check(UpdateValidator.parseSHA256Digest(upperHex) == validHex, "parse uppercase hex lowercased")
        check(UpdateValidator.parseSHA256Digest("sha256:" + upperHex) == validHex, "parse uppercase hex with prefix lowercased")
        check(UpdateValidator.parseSHA256Digest(String(validHex.dropLast())) == nil, "63 chars returns nil")
        check(UpdateValidator.parseSHA256Digest(String(validHex.dropLast()) + "g") == nil, "64 chars containing 'g' returns nil")
        check(UpdateValidator.parseSHA256Digest(nil) == nil, "nil returns nil")
        check(UpdateValidator.parseSHA256Digest("  sha256:\(validHex)\n") == validHex, "trimmed whitespace with prefix returns hex")

        // UpdateValidator: isTrustedGitHubURL
        guard let urlHttpsGitHub = URL(string: "https://github.com/a/b"),
              let urlHttpGitHub = URL(string: "http://github.com/a/b"),
              let urlEvil = URL(string: "https://evil.com"),
              let urlEvilSubdomain = URL(string: "https://github.com.evil.com/x"),
              let urlObjectsGitHub = URL(string: "https://objects.githubusercontent.com/x"),
              let urlEvilGitHubUserContent = URL(string: "https://evilgithubusercontent.com/x") else {
            fatalError("Failed to construct test URLs")
        }

        check(UpdateValidator.isTrustedGitHubURL(urlHttpsGitHub), "https://github.com/a/b is trusted")
        check(!UpdateValidator.isTrustedGitHubURL(urlHttpGitHub), "http://github.com/a/b is not trusted")
        check(!UpdateValidator.isTrustedGitHubURL(urlEvil), "https://evil.com is not trusted")
        check(!UpdateValidator.isTrustedGitHubURL(urlEvilSubdomain), "https://github.com.evil.com/x is not trusted")
        check(UpdateValidator.isTrustedGitHubURL(urlObjectsGitHub), "https://objects.githubusercontent.com/x is trusted")
        check(!UpdateValidator.isTrustedGitHubURL(urlEvilGitHubUserContent), "https://evilgithubusercontent.com/x is not trusted")

        // UpdateValidator: verifyFile
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("sino-test-update-\(UUID().uuidString).txt")
        do {
            try "abc".write(to: tempFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let abcDigest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            let badDigest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ae"

            check(UpdateValidator.verifyFile(tempFile, matchesDigest: abcDigest), "verifyFile matching sha256 digest")
            check(!UpdateValidator.verifyFile(tempFile, matchesDigest: badDigest), "verifyFile wrong digest returns false")
            check(!UpdateValidator.verifyFile(tempFile, matchesDigest: nil), "verifyFile nil digest returns false")
        } catch {
            check(false, "failed to write tempFile: \(error)")
        }

        if failures == 0 {
            print("core parsers: all checks passed")
        } else {
            print("core parsers: \(failures) failure(s)")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
