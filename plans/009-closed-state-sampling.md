# Plan 009: With the dropdown closed, Sino samples only what the menu bar shows

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- Sources/Sampler.swift Sources/SinoApp.swift`
> Plans 002, 005, 006, 007, 008 are expected to have touched these files in other functions. If
> `tick`, `runHeavy`, `sampleNet` (Wi-Fi block), `sampleGPU`, `sampleBattery` or `menuChips` changed
> beyond those plans, compare the excerpts below; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (a missed consumer shows stale data in the dropdown)
- **Depends on**: plans/005-public-ip-backoff.md, plans/008-proc-identity-cache.md (same file, and 005 already removes the closed-state network fetch)
- **Category**: perf
- **Planned at**: commit `c497768`, 2026-11-17

## Why this matters

The README promises "<1% idle CPU", and "Process tables and heavy metrics run only while the dropdown is
open". Measured on the owner's M3 Pro (interval 2 s, cat chip on), with the dropdown closed: **3.1% CPU**,
and 3.9% averaged over a 1h36m session. With the dropdown closed, every tick still does the full Wi-Fi
detail work (SSID resolution, RSSI, noise, tx rate, channel, PHY mode, BSSID via CoreWLAN), copies the
entire IOAccelerator registry dictionary for the GPU, and copies the whole AppleSmartBattery registry
dictionary. The menu-bar chips need none of the Wi-Fi details and only a few numbers. Cutting the
closed-state work to what the chips display is the main lever on idle CPU and battery.

## Current state

- What the menu bar actually needs — `Sources/SinoApp.swift:475-504`, `menuChips()`:
  `ram` → `s.ramPressure`; `cpu` → `s.cpuUser + s.cpuSystem`; `gpu` → `s.gpuUsage`; `storage` → `s.diskUsedPct`;
  `net` → `s.netIn`, `s.netOut`; `fans` → `s.fans.first?.rpm`; `battery` → `s.battCharge`, `s.charging`; `cat` → nothing.
  Fan curve mode also reads `sampler.snap.temps` every second (`SinoApp.swift:451-457`, `466-471`) — temps must keep updating while closed.
- `Sources/Sampler.swift:249-268` — `tick()` calls `sampleCPU, sampleRAM, sampleGPU, sampleDisk, sampleNet, sampleFans, sampleBattery` every tick; only processes and nettop are gated by `heavy || dumping`.
- `Sources/Sampler.swift:759-768` — `runHeavy()` (called when the dropdown opens): sets `heavy = true`, then
  re-samples **disk, battery, processes** immediately — but not network, so anything gated off while closed
  must be refreshed here too.
- `Sources/Sampler.swift:650-713` — the Wi-Fi block inside `sampleNet`:
  ```swift
        s.netInterface = iface.name
        s.wifi = iface.wifi || iface.name == "en0"
        s.netSSID = s.wifi ? (currentSSID(bsd: iface.name) ?? "—") : "—"
        s.netName = s.wifi ? (s.netSSID == "—" ? "Wi-Fi" : s.netSSID) : "Ethernet"
        if s.wifi {
            let client = CWWiFiClient.shared()
            let wifi = client.interface(withName: iface.name) ?? client.interface()
            s.netRSSI = wifi?.rssiValue() ?? 0
            … channel / band / width, activePHYMode …
            s.netBSSID = currentBSSID(wifi: wifi, ssid: s.netSSID, channel: channelNum) ?? "—"
        } else { … zeros / "—" … }
  ```
  The byte counters and rates (`:714-740`) are what the `net` chip needs — they must stay every tick.
- `Sources/Sampler.swift:431-445` — `sampleGPU` copies the whole registry dict with `copyProps(svc)` each tick,
  although name/cores/vendor are cached after the first read; only `dict["PerformanceStatistics"]` is needed after that.
- `Sources/Sampler.swift:965-1000+` — `sampleBattery`: the IOPS part (instant, gives `battCharge`, `charging`,
  minutes remaining) then `copyProps` of `AppleSmartBattery` for telemetry/health/cycles used only by the dropdown battery card.
- `Sources/Sampler.swift:1226-1230` — `copyProps(_:)` = `IORegistryEntryCreateCFProperties` (all keys).
- `IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)` reads one key.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 |
| Build | `./build.sh` | **operator approval required** (needed for the CPU measurement) |
| Idle CPU over 5 min (dropdown closed, don't touch the Mac) | `P=$(pgrep -x Sino); a=$(ps -o time= -p $P); sleep 300; b=$(ps -o time= -p $P); echo "$a -> $b"` | CPU time used in 300 s; % = seconds used / 3 |
| Consumers of gated fields | `rg -n "snap\.(netSSID\|netRSSI\|netNoise\|netTxRate\|netChannel\|netStandard\|netBSSID\|systemLoadW\|adapterPowerW\|batteryPowerW\|battHealth\|battCycles)" Sources` | every hit is inside dropdown/settings SwiftUI views |

## Scope

**In scope**: `Sources/Sampler.swift` — `tick`, `runHeavy`, `sampleNet` (Wi-Fi block only), `sampleGPU`, `sampleBattery`.

**Out of scope**: SMC key caching in `Sources/SMC.c` (worthwhile, but separate and riskier); temps/fans
sampling (fan curve mode needs them while closed); the cat-chip animation timer in `SinoApp.swift`;
`sampleCPU`, `sampleRAM`, `sampleDisk`; any UI.

## Git workflow

- Branch `advisor/009-closed-state-sampling`; one commit per step, e.g. `perf(net): skip Wi-Fi details while closed`. Do not push.

## Steps

### Step 1: Baseline
Before any edit: operator-approved `./build.sh`, note the enabled chips and interval
(`defaults read com.lov3u.sino sino.interval`), close the dropdown, run the idle-CPU command. Record the result.
**Verify**: a number is recorded. If no build is allowed, skip all measurement steps and say so in the report.

### Step 2: Skip Wi-Fi details while closed
Wrap the SSID/name lines and the whole `if s.wifi { … } else { … }` Wi-Fi detail block so it only runs when
`heavy || dumping`. While closed, leave the previous values in `s` untouched (the snapshot is copied from
`snap`, so the last-known values persist). Keep `s.netInterface` and `s.wifi` every tick. Then add
`sampleNet(&s)` to `runHeavy()` (before `snap = s`) so the details are fresh the moment the dropdown opens.
**Verify**: typecheck → exit 0; the consumers command shows no hit outside dropdown/settings views.

### Step 3: Read one registry key for the GPU after the first sample
In `sampleGPU`, once `gpuNameCached`, `gpuCoresCached` and `gpuVendorCached` are all set, read only
`PerformanceStatistics` with `IORegistryEntryCreateCFProperty(...)?.takeRetainedValue() as? [String: Any]`
instead of `copyProps(svc)`. The first sample keeps using `copyProps` to fill the caches.
**Verify**: typecheck → exit 0; with the GPU chip on, its percentage still moves under load (manual).

### Step 4: Skip the AppleSmartBattery registry copy while closed
In `sampleBattery`, keep the IOPS part every call; run the `AppleSmartBattery` part only when `heavy || dumping`.
`runHeavy()` already calls `sampleBattery`, and `pollFastBattery()` refreshes it every 0.5 s while open.
**Verify**: typecheck → exit 0; the consumers command still shows battery telemetry fields only in the dropdown battery card.

### Step 5: Re-measure
Same build conditions as Step 1 → run the idle-CPU command again.
**Verify**: CPU time over 300 s is at least 30% lower than the baseline. Record both numbers in the final commit message.

## Test plan

- No unit seam (IOKit/CoreWLAN). Gates: typecheck, tests, and the before/after measurement.
- Manual regression pass after Step 5: open the dropdown → Network card shows SSID, RSSI, channel and BSSID
  within one tick; Battery card shows watts/health/cycles; GPU chip and net chip update while closed;
  fan curve mode (if used) still reacts to temperature.

## Done criteria

- [ ] Typecheck and `./tests.sh` exit 0
- [ ] `rg -n "sampleNet\(&s\)" Sources/Sampler.swift` → 2 matches (tick and runHeavy)
- [ ] Before/after idle-CPU numbers recorded, reduction ≥ 30% (if a build was allowed)
- [ ] `git diff --stat` shows only `Sources/Sampler.swift` (+ `plans/README.md`)
- [ ] `plans/README.md` row updated

## STOP conditions

- The consumers command finds a gated field used outside the dropdown/settings views (e.g. a notification
  or a menu-bar chip) — gating it would show stale data; report the hit.
- Step 5's reduction is < 30%: stop and report both numbers instead of cutting more. The next suspects are
  per-tick SMC lookups in `Sources/SMC.c` (`sino_smc_temps` / `sino_smc_fans` call key-info + read for every
  key, every tick) and the cat chip's ~8 Hz redraw timer — both need their own plan.

## Maintenance notes

- New dropdown-only metrics belong behind `heavy || dumping`; anything a chip shows must stay ungated.
- If a Wi-Fi chip (SSID/RSSI) is ever added to the menu bar, Step 2's gate must include it.
- Update the README's idle CPU claim to the measured number once this lands.
