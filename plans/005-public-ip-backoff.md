# Plan 005: The public-IP lookup runs only while the dropdown is open and backs off after failures

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- Sources/Sampler.swift`
> Plan 002 is expected to have touched `sampleCPU` only. If `sampleNet` or `kickPublicIP` changed,
> compare the excerpts below; on a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf / privacy
- **Planned at**: commit `c497768`, 2026-11-17

## Why this matters

Every sampler tick (default every 1–2 s, dropdown open **or closed**) calls `kickPublicIP()`, which
asks `https://ipinfo.io/json` for the public IP. It is throttled to once per 120 s — but the throttle
timestamp `publicIPAt` is only set on **success**. Offline, on a captive portal, or when ipinfo
rate-limits (a 429 body fails to decode), every tick fires a new HTTPS request, forever. That costs
battery and radio, makes the rate-limit worse, and keeps sending the user's IP to a third party
although the value is only shown inside the dropdown's network card.

## Current state

- `Sources/Sampler.swift:177-180` — state: `publicIP`, `netGeo`, `publicIPAt = Date.distantPast`, `publicIPBusy = false`.
- `Sources/Sampler.swift:756` — last line of `sampleNet(_:)`, runs every tick: `kickPublicIP()`.
- `Sources/Sampler.swift:803-831`:
  ```swift
    func refreshPublicIP(completion: (() -> Void)? = nil) {
        publicIPAt = .distantPast
        publicIPBusy = false
        kickPublicIP(completion: completion)
    }

    private func kickPublicIP(completion: (() -> Void)? = nil) {
        if publicIPBusy || Date().timeIntervalSince(publicIPAt) < 120 {
            completion?()
            return
        }
        // Use secure HTTPS endpoint (ipinfo.io with fallback to https://ipwho.is)
        guard let url = URL(string: "https://ipinfo.io/json") else {
            completion?()
            return
        }
        publicIPBusy = true
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            defer {
                DispatchQueue.main.async {
                    self?.publicIPBusy = false
                    completion?()
                }
            }
            guard let data else { return }
  ```
- `Sources/Sampler.swift:872-875` — success path, the **only** place the throttle is armed:
  `DispatchQueue.main.async { self?.publicIP = ip; self?.netGeo = geo; self?.publicIPAt = Date() …`
- `Sources/Sampler.swift:172` — `var heavy = false`: true while the dropdown is open (`runHeavy()` / `stopHeavy()`).
- The public IP is displayed only in the dropdown network card (`SinoApp.swift` ~3243–3260, `snap.netGeo`).
- `refreshPublicIP` is the manual refresh (resets the throttle) — keep it working.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 |

## Scope

**In scope**: `Sources/Sampler.swift` — `sampleNet` (last line) and `kickPublicIP` only.

**Out of scope**: the ipinfo decoding block (duplicated in `CoreParsers.swift` — separate cleanup);
switching providers; `refreshPublicIP`'s behavior; any UI.

## Git workflow

- Branch `advisor/005-public-ip-backoff`; commit `fix(net): fetch the public IP only while open, and throttle failures too`. Do not push.

## Steps

### Step 1: Arm the throttle when the request starts
In `kickPublicIP`, directly after `publicIPBusy = true`, add:
```swift
        publicIPAt = Date()  // throttle failures as well as successes
```
Leave the success-path assignment at line ~875 in place (harmless; it re-arms on success).
Also fix the misleading comment `// Use secure HTTPS endpoint (ipinfo.io with fallback to https://ipwho.is)` —
there is no fallback; make it `// HTTPS, ipinfo.io only`.

**Verify**: typecheck exit 0; `rg -n "publicIPAt = Date\(\)" Sources/Sampler.swift` → 2 matches.

### Step 2: Only fetch while the dropdown is open
Change the last line of `sampleNet` from `kickPublicIP()` to:
```swift
        if heavy || dumping { kickPublicIP() }
```
(`dumping` is the `--dump` diagnostic mode, `Sampler.swift:171`; `tick()` uses the same `heavy || dumping` guard for processes.)

**Verify**: typecheck exit 0; `rg -n "kickPublicIP\(\)" Sources/Sampler.swift` → exactly one call site, guarded by `if heavy || dumping`.

## Test plan

- No unit seam exists (URLSession inside the sampler); the change is two lines. Gates: typecheck + tests.
- Manual (operator-approved, needs `./build.sh`): open the dropdown → network card shows the public IP
  within one interval; manual refresh still updates it. Then turn Wi-Fi off, open the dropdown, close it,
  and watch `nettop -P -L 0 -J bytes_in,bytes_out -p $(pgrep -x Sino)` for 60 s: no repeated connections.

## Done criteria

- [ ] Typecheck and `./tests.sh` exit 0
- [ ] Both `rg` checks give the stated results
- [ ] `git diff --stat` shows only `Sources/Sampler.swift` (+ `plans/README.md`)
- [ ] `plans/README.md` row updated

## STOP conditions

- `kickPublicIP` is called from anywhere besides `sampleNet` and `refreshPublicIP` (`rg -n kickPublicIP Sources`).
- Something outside the dropdown (menu-bar chip, notification) displays `publicIP`/`netGeo` — then the
  `if heavy` guard would blank it; report instead.

## Maintenance notes

- After a failure, the IP stays "—" for up to 120 s unless the user taps refresh — intended.
- Plan 009 (closed-state sampling) also edits `sampleNet`; do this plan first.
