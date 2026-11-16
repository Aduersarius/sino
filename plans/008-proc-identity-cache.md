# Plan 008: The process list resolves names and icons once per binary, not once per process per tick

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- Sources/Sampler.swift`
> Plans 002 and 005 touch `sampleCPU`, `sampleNet`, `kickPublicIP` — fine. If `sampleProcs`,
> `procIdentity` or `topLevelAppBundle` changed, compare the excerpts below; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: none (do after 005 to avoid edit conflicts in Sampler.swift)
- **Category**: perf
- **Planned at**: commit `c497768`, 2026-11-17

## Why this matters

While the dropdown is open, every tick (`Prefs.interval`, 0.25–5 s) runs `sampleProcs` on the **main
thread** (the sampler's `Timer` is on the main run loop). For each of ~500+ processes seen on the previous
tick it calls `procIdentity(pid)`, which walks the executable path, builds a `Bundle`, and asks
`NSWorkspace.shared.icon(forFile:)` for a brand-new `NSImage` — no caching. That's hundreds of icon
lookups and image allocations per tick on the UI thread: jank while scrolling the dropdown and avoidable
CPU and memory churn. Identity depends only on the executable path, so it can be cached by path.

## Current state

- `Sources/Sampler.swift:249-268` — `tick()` runs on the main-run-loop timer; `if heavy || dumping { sampleProcs(&s); kickNetTop() }`.
- `Sources/Sampler.swift:1034-1106` — `sampleProcs`. The hot lines:
  ```swift
            let wantCPU = dt > 0.2 && dt < 10.0 && prevProc[pid] != nil
            let wantMem = foot > 16 * 1024 * 1024 || pid == myPID
            let wantE = hasE && dt > 0.2 && dt < 10.0 && prevEnergy[pid] != nil
            if !wantCPU && !wantMem && !wantE { continue }
            let (name, icon) = procIdentity(pid)
  ```
  `wantCPU` is true for nearly every pid after the first tick, so `procIdentity` runs for almost all processes.
- `Sources/Sampler.swift:1156-1185` — `procIdentity(_ pid:)` (file-private free function):
  ```swift
  private func procIdentity(_ pid: pid_t) -> (String, NSImage?) {
      var rawPath: String? = nil
      var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      if proc_pidpath(pid, &path, UInt32(MAXPATHLEN)) > 0 {
          rawPath = String(cString: path)
      }
      if let p = rawPath {
          if p.contains("WebKit.framework") || p.contains("Safari") {
              return ("Safari", NSWorkspace.shared.icon(forFile: "/Applications/Safari.app"))
          }
          if let topApp = topLevelAppBundle(forPath: p) { return topApp }
      }
      if let app = NSRunningApplication(processIdentifier: pid) {
          let name = canonicalAppName(from: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)")
          return (name, app.icon)
      }
      if let p = rawPath {
          let leaf = URL(fileURLWithPath: p).lastPathComponent
          let name = canonicalAppName(from: leaf)
          let icon = NSWorkspace.shared.icon(forFile: p)
          return (name, icon)
      }
      return ("pid \(pid)", nil)
  }
  ```
- `Sources/Sampler.swift:1109-1128` — `topLevelAppBundle(forPath:)` (Bundle + `NSWorkspace.icon`).
- `Sources/Sampler.swift:785-806` — `stopHeavy()` clears per-open state (`prevProc = [:]`, `prevEnergy = [:]`).
- Existing cache style in the same class: `private var macCache: [String: String] = [:]` (`:168`) used as
  `if let cached = macCache[iface.name] { … } else { …; macCache[iface.name] = mac }` (`:640-644`). Match it.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 |
| Timing (operator-approved build) | `/Applications/Sino.app/Contents/MacOS/Sino --dump` | prints the snapshot plus the `procs ms` line from Step 1, then exits |

## Scope

**In scope**: `Sources/Sampler.swift` — `procIdentity`, `sampleProcs`, `stopHeavy`, one new stored property, and the `--dump` print.

**Out of scope**: `aggregateProcs`, the ranking logic, the UI, `kickNetTop`. Do **not** move sampling to a
background queue in this plan (see Step 4's gate).

## Git workflow

- Branch `advisor/008-proc-identity-cache`; commit `perf(procs): cache process names and icons by executable path`. Do not push.

## Steps

### Step 1: Measure the baseline
In `tick()`, wrap the `sampleProcs(&s)` call to time it, and add a line to the `--dump` print (it already
runs `sampleProcs` because `dumping` is true): keep the duration of the last call in a stored property
(`private var lastProcsMs = 0.0`) and print `procs ms \(Int(lastProcsMs))`.
**Verify**: typecheck → exit 0. If the operator allows a build: run `--dump` three times and record the
`procs ms` values in the commit message.

### Step 2: Cache identity by path
- Add `private var identityCache: [String: (String, NSImage?)] = [:]` to the sampler.
- Change `procIdentity` to take the cache into account. Simplest correct shape: split out the path lookup
  (`proc_pidpath`) so `sampleProcs` gets `rawPath` first; if `rawPath` is non-nil and `identityCache[rawPath]`
  exists, use it; otherwise compute exactly as today and store it under `rawPath`. Do **not** cache when the
  path is nil (those fall back to `"pid N"`, and the pid-based `NSRunningApplication` result is pid-specific).
- Bound the cache: in `stopHeavy()`, set `identityCache = [:]` (it rebuilds on the next open; bounded by the
  number of distinct binaries seen while open).
**Verify**: typecheck → exit 0; `rg -n "identityCache" Sources/Sampler.swift` → ≥ 4 matches (decl, read, write, clear).

### Step 3: Re-measure
**Verify** (operator-approved build): `--dump` × 3 → `procs ms` lower than Step 1's median.
Note: `--dump` exits after 3 ticks, so the first tick fills the cache; the gain shows from tick 2 on and is
larger with the dropdown open for a long time.

### Step 4: Gate for moving off the main thread
If the post-cache `procs ms` median is **≤ 8 ms**, stop here — moving sampling off the main thread is not
worth the threading risk (the sampler mutates `snap` and many stored properties from the main thread).
If it is **> 8 ms**, do NOT improvise a threading change: STOP and report the numbers.

## Test plan

- No unit seam (proc APIs + AppKit). Gates: typecheck, `./tests.sh`, and the before/after `procs ms` numbers.
- Manual: open the dropdown's CPU and memory lists — names and icons look exactly as before (Safari helpers
  grouped as "Safari", Chrome helpers grouped under the app name).

## Done criteria

- [ ] Typecheck and `./tests.sh` exit 0
- [ ] `rg -n "identityCache" Sources/Sampler.swift` → ≥ 4 matches
- [ ] Before/after `procs ms` recorded (if a build was allowed)
- [ ] `git diff --stat` shows only `Sources/Sampler.swift` (+ `plans/README.md`)
- [ ] `plans/README.md` row updated

## STOP conditions

- Post-cache `procs ms` median > 8 ms (Step 4).
- Names in the process list change after the cache (e.g. two different apps share a path) — report the example.

## Maintenance notes

- Icons are cached per open of the dropdown; an app that changes its icon while the dropdown is open shows
  the old one until the next open. Acceptable.
- The duplicate `canonicalAppName` in `Sources/CoreParsers.swift` lacks the "Semgrep" branch this file has;
  if someone later switches to CoreParsers, merge that branch first.
