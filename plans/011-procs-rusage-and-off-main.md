# Plan 011: Process inspection uses single-syscall sino_pid_rusage and scans off the main thread

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, leave `plans/README.md` to your reviewer.
>
> **Drift check (run first)**: `git diff --stat 540918b..HEAD -- Sources/Sampler.swift Sources/SMC.c Sources/SMC.h`
> If `Sampler.swift` changed in `sampleProcs`, `tick`, `runHeavy`, or `stopHeavy`, compare excerpts; on mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (concurrency around `Sampler.snap` and `--dump` determinism)
- **Depends on**: none (Plan 008 already merged)
- **Category**: perf
- **Planned at**: commit `540918b`, 2026-11-17

## Why this matters

Plan 008 cached process names and icons by path, yet `--dump` on the live build still measured `procs ms 11`
(above Plan 008's `8 ms` threshold for staying on the main thread). `sampleProcs` still runs on the main thread,
and for every process (~500+) it makes two separate `proc_pid_rusage` calls (`sino_pid_footprint` +
`sino_pid_energy_nj`) even though `sino_pid_rusage` (`Sources/SMC.c:177`) fetches both in one syscall.
Moving the pure libproc syscall scan onto a dedicated serial background queue while keeping AppKit icon
resolution on main cuts main-thread UI stalls without introducing AppKit thread-safety bugs.

## Current state

- `Sources/SMC.h:10`: `int sino_pid_rusage(int pid, uint64_t *bytes, uint64_t *nanojoules);` (returns 0 on success; sets `*bytes` to `ri_phys_footprint ? ri_phys_footprint : ri_resident_size` and `*nanojoules` to `ri_energy_nj`).
- `Sources/Sampler.swift:144-145, 169-172`: `prevProc`, `prevProcAt`, `identityCache`, `prevEnergy`, `lastProcsMs`.
- `Sources/Sampler.swift:252-270` (`tick()`): calls `sampleProcs(&s)` synchronously inside `if heavy || dumping { ... }`.
- `Sources/Sampler.swift:767-776` (`runHeavy()`): sets `heavy = true`, calls `sampleProcs(&s)` synchronously.
- `Sources/Sampler.swift:785-806` (`stopHeavy()`): clears `prevProc`, `prevEnergy`, `identityCache`.
- `Sources/Sampler.swift:1045-1135` (`sampleProcs`):
  - Lines `1066-1070`: calls `sino_pid_footprint` AND `sino_pid_energy_nj` separately.
  - Line `1076`: calls `procPath(pid)` (`proc_pidpath`).
  - Lines `1078-1086`: looks up/populates `identityCache` using `procIdentity(pid, rawPath:)` (`NSWorkspace`/`Bundle`/`NSRunningApplication` — must remain on main).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Swift typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 |
| Check single rusage call | `rg -n "sino_pid_" Sources/Sampler.swift` | 1 match (`sino_pid_rusage`) |

## Scope

**In scope**: `Sources/Sampler.swift` (`procQueue`, `procBusy`, `collectRawProcs`, `applyRawProcs`, `tick`, `runHeavy`, `stopHeavy`, `sampleProcs`, `--dump` `procs ms`).

**Out of scope**: `Sources/SMC.c`, `Sources/SinoApp.swift`, `CoreParsers.swift`, `cleanRAM` (Plan 012), `sampleFans` (Plan 013).

## Git workflow

- Branch `advisor/011-procs-rusage-and-off-main`; commit `perf(procs): use single sino_pid_rusage syscall and scan off main thread`. Do not push.

## Steps

### Step 1: Define `RawProc` and switch the syscall scan to `sino_pid_rusage` on `procQueue`
- Add to `Sampler`:
  ```swift
  private let procQueue = DispatchQueue(label: "com.lov3u.sino.procs", qos: .utility)
  private var procBusy = false

  private struct RawProc {
      let pid: pid_t
      let rawPath: String?
      let cpu: Double?
      let mem: UInt64?
      let energyW: Double?
  }
  ```
- Note: `prevProc`, `prevEnergy`, and `prevProcAt` must ONLY be touched on `procQueue` (no cross-thread reads/writes!). `identityCache` and `snap` must ONLY be touched on the main thread!
- Implement `private func collectRawProcs(myPID: pid_t) -> [RawProc]` (called only on `procQueue`):
  - `proc_listpids(UInt32(PROC_ALL_PIDS), 0, ...)`
  - Per PID: `proc_pidinfo(..., PROC_PIDTASKINFO, ...)`
  - **One** call:
    ```swift
    var foot: UInt64 = 0
    var nj: UInt64 = 0
    let hasRusage = sino_pid_rusage(Int32(pid), &foot, &nj) == 0
    if !hasRusage || foot == 0 { foot = rss }
    let hasE = hasRusage
    ```
  - Compute `wantCPU`, `wantMem`, `wantE` with the exact same thresholds (`dt > 0.2 && dt < 10.0`, `foot > 16 * 1024 * 1024 || pid == myPID`, `pct >= 0.001`, `watts > 0.03`).
  - Only when `wantCPU || wantMem || wantE`: call `procPath(pid)` and append `RawProc(...)`.
  - Update `prevProc = next`, `prevEnergy = nextEnergy`, `prevProcAt = now`, and return the array.

### Step 2: Apply raw results on the main thread and run async in `tick()` / `runHeavy()`
- Implement `private func applyRawProcs(_ raw: [RawProc], to s: inout Snapshot)` (main thread only):
  - For each entry in `raw`: look up/populate `identityCache[rawPath]` or call `procIdentity(r.pid, rawPath: r.rawPath)`.
  - Skip `name == "kernel_task"`.
  - Populate `ranked`, `byMem`, `byEnergy`, sort, `aggregateProcs`, slice `.prefix(30)` / `.prefix(5)` into `s.processes`, `s.memProcesses`, `s.energyProcesses` — exact same logic as before.
- Replace `sampleProcs(_ s: inout Snapshot)` / add `kickProcs()`:
  - In `tick()` and `runHeavy()`:
    - When `dumping`: run synchronously (`let raw = procQueue.sync { collectRawProcs(myPID: ProcessInfo.processInfo.processIdentifier) }`, then time `let t0 = Date(); applyRawProcs(raw, to: &s); lastProcsMs = Date().timeIntervalSince(t0) * 1000.0`) so `--dump` output still populates `Procs:` and `procs ms` cleanly.
    - When `heavy && !dumping`: call `kickProcs()`:
      - `guard !procBusy else { return }`
      - `procBusy = true`
      - `let myPID = ProcessInfo.processInfo.processIdentifier`
      - `procQueue.async { [weak self] in`
        `guard let self else { return }`
        `let raw = self.collectRawProcs(myPID: myPID)`
        `DispatchQueue.main.async {`
        `  self.procBusy = false`
        `  guard self.heavy else { return }`
        `  let t0 = Date()`
        `  var s = self.snap`
        `  self.applyRawProcs(raw, to: &s)`
        `  self.lastProcsMs = Date().timeIntervalSince(t0) * 1000.0`
        `  self.snap = s`
        `}`
        `}`
- Update `stopHeavy()`:
  - Clear `identityCache = [:]` on main.
  - Dispatch `procQueue.async { [weak self] in self?.prevProc = [:]; self?.prevEnergy = [:] }` so `prevProc`/`prevEnergy` remain strictly `procQueue`-confined!
- Notice what happens if `tick()` runs while `heavy` is true: `tick()` must NOT overwrite `s.processes` / `s.memProcesses` / `s.energyProcesses` (they already copy from `snap` at `var s = snap`, and when `!heavy && !dumping` the `else` branch clears them as before!).

**Verify**:
- `rg -n "sino_pid_" Sources/Sampler.swift` → exactly 1 match (`sino_pid_rusage`)
- `swiftc -typecheck ...` → exit 0
- `./tests.sh` → exit 0

## Test plan

- Static gates: typecheck + `./tests.sh` + `rg -n "sino_pid_" Sources/Sampler.swift` == 1.
- Optional live check (after operator `./build.sh`): `--dump` shows populated `Procs:` list and `procs ms <= 3` (main-thread apply time).

## Done criteria

- [ ] `sino_pid_footprint` and `sino_pid_energy_nj` are no longer called in `Sources/Sampler.swift`; `sino_pid_rusage` is used once per PID
- [ ] `prevProc`, `prevEnergy`, `prevProcAt` are accessed only on `procQueue`; `identityCache` and `snap` only on main
- [ ] Swift typecheck and `./tests.sh` exit 0
- [ ] `git diff --stat` touches only `Sources/Sampler.swift` (+ `plans/README.md`)

## STOP conditions

- Any property besides `prevProc`/`prevEnergy`/`prevProcAt` is mutated on `procQueue` (or those three are read on main outside `procQueue`).
- `sampleProcs` has callers other than `tick()` and `runHeavy()`.
