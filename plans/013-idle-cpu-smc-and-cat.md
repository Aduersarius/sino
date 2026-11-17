# Plan 013: Cut idle CPU by caching SMC key info, skipping unused closed reads, and eliminating wasted cat wakeups

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, leave `plans/README.md` to your reviewer.
>
> **Drift check (run first)**: `git diff --stat 540918b..HEAD -- Sources/SMC.c Sources/CoreParsers.swift Sources/Sampler.swift Sources/SinoApp.swift Tests/CoreParsersTests.swift`
> Plans 010–012 touch other regions of these files. Compare the excerpts below against live code; on mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW–MED (must preserve cat animation poses and Curve-mode temperature tracking while closed)
- **Depends on**: plans/010-fan-socket-off-main.md, plans/011-procs-rusage-and-off-main.md, plans/012-remove-clean-ram.md
- **Category**: perf
- **Planned at**: commit `540918b`, 2026-11-17

## Why this matters

Even after Plan 009, idle CPU on PID 38402 was measured at `2.2%` (still above the README's `<1%` claim).
Two main remaining idle costs:
1. `Sources/SMC.c` issues `kSMCReadKeyInfo` + `kSMCReadBytes` on every single key read (~36 IOKit calls per tick),
   re-probing missing M1 temp keys and unchanging fan min/max/count forever — and `sampleFans` reads all
   temperatures every closed tick even when fan mode is `.auto`.
2. `catTimer` in `Sources/SinoApp.swift:361` wakes the main run loop unconditionally every `0.12 s` (8.33 Hz)
   with no tolerance, even during 4–6 second sleeping/idle plateaus, and `drawCat` executes up to 462
   `NSRect.fill()` calls + dictionary allocations per frame transition.

## Current state

- `Sources/SMC.c:79-172`:
  - `smc_read` calls `kSMCReadKeyInfo` then `kSMCReadBytes` every single time.
  - `sino_smc_fans` reads `FNum`, then `FiAc`, `FiMn`, `FiMx` for every fan on every tick.
  - `sino_smc_temps` probes 11 hardcoded temp keys every call.
  - `sino_smc_shutdown()` (`:118-123`) closes `g_conn = 0`.
  - All `sino_smc_*` calls come from the main thread (`Sampler.tick()` / `Sampler.runHeavy()`).
- `Sources/Sampler.swift:942-970` (`sampleFans`): calls `sino_smc_fans` and `sino_smc_temps` every tick regardless of `heavy` or `fanMode`.
  - Only `menuChips()` (`SinoApp.swift:499`) reads `s.fans.first` when `"fans"` is in `prefs.bar`; only `reassertFans()` (`SinoApp.swift:466,481`) reads `s.temps` when `fanMode == .curve`.
- `Sources/SinoApp.swift:357-383`:
  - `armCatAnim()` creates a repeating `0.12 s` timer with no tolerance.
  - `tickCat()` increments `extra.catTick += 1`, redraws on `catFrame != lastCatFrame`, and calls `holdHighlight()` on every 0.12 s tick while `dropOpen`.
- `Sources/SinoApp.swift:1532-1568` (`ExtraView.catFrame`): pure mapping from `catTick % 1000` to 14 distinct frames (`0, 1, 2, 5, 6, 7, 8, 9, 10, 11, 16, 17, 18, 19`).
- `Sources/SinoApp.swift:2023-2046` (`ExtraView.drawCat`): builds `[Character: NSColor]` and fills per-pixel `NSRect`s on every redraw.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| C compile check | `cc -Wall -Wextra -fsyntax-only -isysroot "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 Sources/SMC.c` | exit 0, zero warnings |
| Swift typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 (`fold core` and `core parsers` pass) |

## Scope

**In scope**: `Sources/SMC.c` (lines 74–172), `Sources/CoreParsers.swift`, `Tests/CoreParsersTests.swift`, `Sources/Sampler.swift` (`trackTemps`, `sampleFans`, `runHeavy`), `Sources/SinoApp.swift` (`armCatAnim`, `tickCat`, `ExtraView.catFrame`/`drawCat`, `armFans`/`releaseFans`).

**Out of scope**: M2/M3 SMC key discovery (`sino_smc_temps` key table itself); `Sources/smcwrite.c`.

## Git workflow

- Branch `advisor/013-idle-cpu-smc-and-cat`; commits e.g. `perf(smc): cache key metadata and static fan bounds`, `perf(cat): sleep between pose transitions and cache sprite images`, `perf(fans): skip closed temp/fan reads when unused`. Do not push.

## Steps

### Step 1: Cache SMC `SMCKeyInfo` and static fan bounds in `Sources/SMC.c`
- Add a fixed-size cache (max 64 keys) in `Sources/SMC.c`:
  ```c
  enum { SMC_CACHE_CAP = 64 };
  typedef struct {
      UInt32 key;
      UInt32 dataSize;
      UInt32 dataType;
      int8_t state; /* 0 = unprobed, 1 = valid, -1 = missing */
  } SMCCacheEntry;
  static SMCCacheEntry g_smc_cache[SMC_CACHE_CAP];
  static int g_smc_cache_count = 0;
  static int g_fan_count = -1;
  static float g_fan_min[9];
  static float g_fan_max[9];
  ```
- In `smc_read`: look up `UInt32 k = fourcc(key)` in `g_smc_cache`.
  - If `state == -1`: return `-1` immediately (no IOKit call).
  - If not cached (`state == 0`): send `kSMCReadKeyInfo`. If `smc_call(&in, &out) != KERN_SUCCESS || out.result != 0 || out.keyInfo.dataSize == 0`, store `state = -1` (if `g_smc_cache_count < SMC_CACHE_CAP`) and return `-1`. Otherwise store `dataSize`, `dataType`, `state = 1`.
  - Use cached `sz` (clamped `<= sizeof(out.bytes)`) and `type` to call ONLY `kSMCReadBytes`.
- In `sino_smc_fans`: cache `g_fan_count` and `g_fan_min[i]` / `g_fan_max[i]` on first probe (`g_fan_count < 0`); subsequent ticks read ONLY `FiAc` (`rpm`). Note: if `rpm == NULL`, skip `FiAc` too.
- In `sino_smc_shutdown()`: reset `g_smc_cache_count = 0` and `g_fan_count = -1` (and `memset(g_smc_cache, 0, sizeof(g_smc_cache))`).

**Verify**: C check (`-Wall -Wextra`) → exit 0, zero warnings.

### Step 2: Extract `CatAnim` into `Sources/CoreParsers.swift` + unit test it
- Add `enum CatAnim` in `Sources/CoreParsers.swift`:
  - `static let cycleLength = 1000`
  - `static let tickInterval: TimeInterval = 0.12`
  - `static func frame(at tick: Int) -> Int` — exact logic of `ExtraView.catFrame` (`SinoApp.swift:1534-1567`), using normalized `(tick % cycleLength + cycleLength) % cycleLength`.
  - `static func ticksUntilChange(from tick: Int) -> Int` — returns smallest `d` in `1...cycleLength` where `frame(at: tick + d) != frame(at: tick)` (or `cycleLength` if constant).
- Add checks to `Tests/CoreParsersTests.swift`:
  - Specific poses: ticks `0->0`, `10->1`, `23->8`, `38->2`, `42->10`, `66->9`, `495->16`, `500->17`, `536->18`, `544->19`, `995->16`.
  - Exhaustive check over `0..<1000`: `d = CatAnim.ticksUntilChange(from: t)` satisfies `d >= 1 && d <= 1000`, `CatAnim.frame(at: t + d) != CatAnim.frame(at: t)`, and every `1 <= k < d` has `CatAnim.frame(at: t + k) == CatAnim.frame(at: t)`.

**Verify**: `./tests.sh` → exit 0 (`core parsers: all checks passed`).

### Step 3: Event-driven cat scheduling + sprite caching in `Sources/SinoApp.swift`
- Replace `ExtraView.catFrame`'s body with `guard catAnimated else { return 0 }; return CatAnim.frame(at: catTick)`.
- Replace `armCatAnim()` / `tickCat()` with one-shot transition scheduling (`scheduleCatTick()`):
  - `armCatAnim()`: when `!prefs.bar.contains("cat")`, invalidate `catTimer`, set `nil`, `extra.catTick = 0`. When on, `if catTimer == nil { scheduleCatTick() }`.
  - `scheduleCatTick()`: compute `let step = CatAnim.ticksUntilChange(from: extra.catTick)`, `let delay = CatAnim.tickInterval * Double(step)`, create non-repeating `Timer(timeInterval: delay, repeats: false)` updating `catTick = (catTick + step) % CatAnim.cycleLength`, set `t.tolerance = min(0.05, delay * 0.15)`, add to `RunLoop.main` `.common`, store in `catTimer`.
  - Inside timer callback (`tickCat(step:)`): redraw `button.image = extra.makeImage()`, call `if dropOpen { holdHighlight() }` only after redraw, then call `scheduleCatTick()` if `prefs.bar.contains("cat")`.
- Cache cat sprites in `ExtraView`:
  - Add `private static let catPalette: [Character: NSColor]` and `private static var catSpriteCache: [Int: NSImage] = [:]`.
  - Add `private static func catSpriteImage(for frame: Int, rows: [String]) -> NSImage`: if cached return it; else create `NSImage(size: NSSize(width: cols, height: rows.count))`, `lockFocusFlipped(true)`, fill `1x1` pixel rects, `unlockFocus()`, store and return.
  - In `drawCat(_ r:)`: look up `Self.catSpriteImage(for: catFrame, rows: sprite)` and call `img.draw(in: NSRect(x: ox, y: oy, width: cols * s, height: rows * s))` (`makeImage()` already sets `imageInterpolation = .none`).

**Verify**: Swift typecheck → exit 0; `./tests.sh` → exit 0.

### Step 4: Skip unused closed fan/temp reads in `Sources/Sampler.swift`
- Add `var trackTemps = false` to `Sampler`.
- In `SinoApp.swift`: in `armFans(_:)` set `sampler.trackTemps = (mode == .curve)`, and in `releaseFans(...)` set `sampler.trackTemps = false`.
- In `Sampler.swift` `sampleFans(_ s:)`:
  - Wrap the `sino_smc_fans` + `fanHistory` block in `if heavy || dumping || s.fans.isEmpty || trackTemps || Prefs.shared.bar.contains("fans")` (keeping `s.fans.isEmpty` ensures startup discovers fan count/bounds once for Settings even before the dropdown opens).
  - Wrap the `sino_smc_temps` block in `if heavy || dumping || trackTemps`.
- In `Sampler.swift` `runHeavy()`: add `sampleFans(&s)` before `snap = s` so fans and temperatures are immediately fresh when the dropdown opens.

**Verify**: Swift typecheck → exit 0; `./tests.sh` → exit 0; `rg -n "sampleFans\(&s\)" Sources/Sampler.swift` → 2 matches (`tick` and `runHeavy`).

## Test plan

- `Tests/CoreParsersTests.swift` validates `CatAnim.frame` and `CatAnim.ticksUntilChange` exhaustively over all 1000 cycle ticks.
- C check (`-Wall -Wextra`), Swift typecheck, `./tests.sh`.
- Optional live check (after operator `./build.sh`): enable Cat chip + close dropdown, verify cat still blinks/sleeps smoothly and `ps -o time -p $(pgrep -x Sino)` idle CPU drops closer to `<1%`.

## Done criteria

- [ ] `cc -Wall -Wextra -fsyntax-only ... Sources/SMC.c` exits 0 with zero warnings
- [ ] Swift typecheck and `./tests.sh` exit 0 (including exhaustive 1000-tick `CatAnim` assertions)
- [ ] `rg -n "sampleFans\(&s\)" Sources/Sampler.swift` → 2 matches
- [ ] `git diff --stat` touches only the 5 in-scope files (+ `plans/README.md`)

## STOP conditions

- Any `SMC.c` read function (`sino_smc_fans` / `sino_smc_temps`) is called from a background thread (would require locking `g_smc_cache`).
- `ExtraView.drawCat` or `CatAnim` differs from the current `catFrame` cycle.
