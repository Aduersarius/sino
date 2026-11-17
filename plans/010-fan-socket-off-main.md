# Plan 010: Fan socket I/O runs on a serial queue off the main thread, with mutex and framing safety

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, leave `plans/README.md` to your reviewer.
>
> **Drift check (run first)**: `git diff --stat 540918b..HEAD -- Sources/SMC.c Sources/SinoApp.swift`
> If either file changed since `540918b`, compare the excerpts below against live code; on mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (touches fan override release on quit and slider responsiveness)
- **Depends on**: none (Plan 006 already merged in `540918b`)
- **Category**: bug
- **Planned at**: commit `540918b`, 2026-11-17

## Why this matters

Every 1 second while Manual or Curve mode is active, `fanHold` calls `reassertFans()` -> `sino_fan_ctl_set()`
on the **main thread**. Each socket exchange has 1 s send/receive timeouts and reconnects on failure (`PING` + retry),
so a wedged helper can freeze the entire UI for ~3 s every second. Meanwhile `g_fan_fd` in `Sources/SMC.c` has no
lock and can be closed/reopened concurrently by `setFanMode`'s background install and main-thread calls, and
late replies after a timeout stay unread in the stream and desynchronize subsequent commands.

## Current state

- `Sources/SMC.c:194-271`:
  - `static int g_fan_fd = -1;` (no mutex).
  - `fan_xfer(cmd)` writes `cmd` and reads up to 7 bytes (`read(g_fan_fd, r, 7)`), checking only `r[0] == 'O' && r[1] == 'K'`. It never checks for leftover bytes from a timed-out call or reads to `\n`.
  - `sino_fan_ctl_open()`, `sino_fan_ctl_close()`, `sino_fan_ctl_auto()`, `sino_fan_ctl_set()`, `sino_fan_ctl_version()` mutate `g_fan_fd` unlocked.
  - `sino_fan_ctl_version()` (`:264-271`) does raw `write`/`read` without closing `g_fan_fd` on error/timeout.
- `Sources/SinoApp.swift:53-56`: `@Published var fanMode`, `fanTargets`, `@Published var fanCtlBusy = false`, `private var fanHold: Timer?`.
- `Sources/SinoApp.swift:195-200` (`willTerminateNotification`): calls `self?.releaseFans()`.
- `Sources/SinoApp.swift:396-487`:
  - `releaseFans()`: invalidates `fanHold`, sets `.auto` and `fanTargets = [:]`, calls `sino_fan_ctl_auto()` + `sino_fan_ctl_close()` on main.
  - `setFanMode(_:)`: calls `sino_fan_ctl_open()` and `sino_fan_ctl_version()` on main; on failure dispatches `FanCtl.install()` + `open` + `version` to `DispatchQueue.global(qos: .userInitiated)`.
  - `armFans(_:)`: schedules 1 s `fanHold` timer on main calling `reassertFans()`.
  - `setFanTarget(_:_:)`: calls `sino_fan_ctl_set` synchronously on main.
  - `reassertFans()`: loops over `fanTargets` or `sampler.snap.fans` calling `sino_fan_ctl_set` synchronously on main.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| C compile check | `cc -Wall -Wextra -fsyntax-only -isysroot "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 Sources/SMC.c` | exit 0, zero warnings |
| Swift typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 |

## Scope

**In scope**:
- `Sources/SMC.c` (only lines 194–271, the `g_fan_fd` / `sino_fan_ctl_*` block plus `#include`s at top if needed)
- `Sources/SinoApp.swift` (only `fanQueue`/generation/in-flight state, `willTerminateNotification`'s `releaseFans(sync: true)`, `releaseFans`, `setFanMode`, `armFans`, `setFanTarget`, `reassertFans`)

**Out of scope**: `Sources/SMC.c` temperature/fan SMC key reads (Plan 013 owns lines 1–172); `Sources/Settings.swift` (`FanCtl.install()` Reinstall button).

## Git workflow

- Branch `advisor/010-fan-socket-off-main`; commits e.g. `fix(fans): guard g_fan_fd with a mutex and frame line replies`, `fix(fans): move fan socket I/O onto a serial background queue`. Do not push.

## Steps

### Step 1: Lock `g_fan_fd` and enforce newline framing in `Sources/SMC.c`
- Include `<errno.h>`, `<pthread.h>`, `<sys/socket.h>`, etc. Add `static pthread_mutex_t g_fan_lock = PTHREAD_MUTEX_INITIALIZER;`.
- Add internal `*_locked` helpers (only called with `g_fan_lock` held):
  - `fan_close_locked()`: if `g_fan_fd >= 0`, `close(g_fan_fd); g_fan_fd = -1;`.
  - `fan_xfer_locked(const char *cmd, char *reply, size_t rcap)`:
    1. If `g_fan_fd < 0`, return `-1`.
    2. Drain check before write: `char peek; ssize_t pk = recv(g_fan_fd, &peek, 1, MSG_PEEK | MSG_DONTWAIT);`
       If `pk == 0` or `pk > 0` (stale unread data!) or `(pk < 0 && errno != EAGAIN && errno != EWOULDBLOCK)`, call `fan_close_locked()` and return `-1`.
    3. Write all `strlen(cmd)` bytes; if write fails (`!= (ssize_t)n`), `fan_close_locked(); return -1;`.
    4. Loop reading into `reply` up to `rcap - 1` until `'\n'` appears or `read <= 0`. If `read <= 0` or no `'\n'`, call `fan_close_locked(); return -1;`. Null-terminate and return `0`.
  - `fan_open_locked()`: if `g_fan_fd >= 0`, verify with `fan_xfer_locked("PING\n", ...)` and `strncmp(..., "OK", 2) == 0`; else `fan_close_locked()`. Then open Unix socket with `SO_NOSIGPIPE`, 1 s `SO_RCVTIMEO`/`SO_SNDTIMEO`, `connect`, set `g_fan_fd`, run `PING\n` check, close on failure.
- Implement all 5 public functions (`sino_fan_ctl_open`, `sino_fan_ctl_close`, `sino_fan_ctl_auto`, `sino_fan_ctl_set`, `sino_fan_ctl_version`) by locking `g_fan_lock`, calling the `_locked` helpers, and unlocking before returning.
  - `sino_fan_ctl_version()`: open if needed, call `fan_xfer_locked("VER\n", buf, sizeof(buf))` (note: on error `fan_xfer_locked` closes `g_fan_fd` cleanly), parse `VER %d` with `sscanf` and return `v` (or `0`).

**Verify**: C compile check (`-Wall -Wextra`) → exit 0, zero warnings; `rg -n "g_fan_lock" Sources/SMC.c` → matches at mutex decl and every public `sino_fan_ctl_*` function.

### Step 2: Serialize Swift fan control on `fanQueue` off the main thread
In `Sources/SinoApp.swift`:
- Add stored properties next to `fanHold`:
  ```swift
  private let fanQueue = DispatchQueue(label: "com.lov3u.sino.fanctl", qos: .userInitiated)
  private var fanGen: UInt64 = 0
  private var fanReassertInFlight = false
  ```
- Update `releaseFans(sync: Bool = false)`:
  - Increment `fanGen &+= 1`, invalidate `fanHold`, set `fanMode = .auto`, `fanTargets = [:]`, `fanReassertInFlight = false`.
  - Run `{ _ = sino_fan_ctl_auto(); sino_fan_ctl_close() }` via `fanQueue.sync` when `sync == true`, else `fanQueue.async`.
- In `willTerminateNotification`: change `self?.releaseFans()` to `self?.releaseFans(sync: true)`.
- Update `setFanMode(_ mode: FanMode)`:
  - If `fanCtlBusy { return }`; if `mode == .auto { releaseFans(); return }`.
  - Increment `fanGen &+= 1`, capture `let gen = fanGen`, set `fanCtlBusy = true`, and dispatch on `fanQueue.async`:
    check `sino_fan_ctl_open() == 0 && sino_fan_ctl_version() >= SINO_HELPER_VERSION`; if false, call `sino_fan_ctl_close()` and try `FanCtl.install() && sino_fan_ctl_open() == 0 && sino_fan_ctl_version() >= SINO_HELPER_VERSION`.
    On `DispatchQueue.main.async`: clear `fanCtlBusy = false`; if `self.fanGen == gen && ok`, call `self.armFans(mode)`.
- Update `setFanTarget(_ id: Int, _ rpm: Double)`:
  - Keep `guard fanMode == .manual else { return }` and `fanTargets[id] = rpm` on main.
  - Capture `let gen = fanGen` and dispatch `fanQueue.async` calling `sino_fan_ctl_set(Int32(id), Float(rpm))` (check `sino_fan_ctl_set` result; note: inside `fanQueue` after `releaseFans`, don't re-apply if `sino_fan_ctl_auto()` already ran — even simpler, run `reassert` / `setFanTarget` through a single `sendTargets` closure or check `fanTargets`? Since `fanQueue` is FIFO and `releaseFans()` runs `sino_fan_ctl_auto()` AFTER any prior `setFanTarget`, `releaseFans()` always wins last! Just check in `setFanTarget` that `fanMode == .manual` on main before enqueuing).
- Update `reassertFans()`:
  - `guard !fanReassertInFlight else { return }`
  - Build `let pairs: [(Int, Double)]` on main (`switch fanMode { case .auto: return ... }`; for `.curve`, update `fanTargets[f.id] = rpm` on main).
  - Set `fanReassertInFlight = true`, capture `let gen = fanGen`, dispatch `fanQueue.async`: loop over `pairs` calling `sino_fan_ctl_set(Int32(id), Float(rpm))` (break on error), then `DispatchQueue.main.async` clearing `fanReassertInFlight = false` (always clear it, even if `fanGen != gen`!).

**Verify**: Swift typecheck → exit 0; `./tests.sh` → exit 0; `rg -n "sino_fan_ctl_" Sources/SinoApp.swift` → every call is inside `fanQueue.async` or `fanQueue.sync`.

## Test plan

- No unit seam for socket/daemon C code; gates are `-Wall -Wextra` C check, Swift typecheck, `./tests.sh`, and `rg` confirming zero main-thread `sino_fan_ctl_*` calls.
- Optional manual check (after operator `./build.sh`): toggle Manual/Curve, drag speed slider rapidly, quit Sino (`Cmd+Q` / menu Quit) and verify `fanHold` doesn't stutter UI and fans return to auto.

## Done criteria

- [ ] `cc -Wall -Wextra -fsyntax-only ... Sources/SMC.c` exits 0 with zero warnings
- [ ] Swift typecheck and `./tests.sh` exit 0
- [ ] Every `sino_fan_ctl_*` call in `Sources/SinoApp.swift` executes inside `fanQueue`
- [ ] `git diff --stat` touches only `Sources/SMC.c` and `Sources/SinoApp.swift` (+ `plans/README.md`)

## STOP conditions

- Either file has drifted in the quoted functions.
- Any `sino_fan_ctl_*` call outside `App` exists in `Sources/`.
