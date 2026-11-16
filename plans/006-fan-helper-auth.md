# Plan 006: The fan helper upgrades itself and only trusts the signed Sino app

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- Sources/smcwrite.c Sources/SMC.c Sources/SMC.h Sources/SinoApp.swift build.sh`
> Expected: the WIP commit (smcwrite.c/SMC.c/SMC.h) and plan 001 (build.sh). Anything else in these
> paths: compare the excerpts below; on a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (a mistake disables fan control; it cannot brick fans — the helper resets to auto on exit)
- **Depends on**: plans/001-build-the-working-tree.md
- **Category**: security
- **Planned at**: commit `c497768` + uncommitted WIP, 2026-11-17

## Why this matters

Fan control goes through a root LaunchDaemon (`sino-smcwrite`) listening on a world-writable Unix
socket. Three gaps:
1. **Installed helpers never upgrade.** The app reinstalls only when it can't connect. Any old helper
   still answers `PING`, so the stricter peer check in the current tree never reaches existing machines.
   The helper installed on the owner's Mac (dated Sep 17) runs the old check, which accepts **any
   executable whose path ends in `Sino`**.
2. **The new check fails open.** `peer_signer_matches_self` starts at `ok = 1` and rejects only if the
   helper itself has certificates. `codesign --deep` does not sign executables in `Contents/Resources`, so
   the helper is ad-hoc (`codesign -dv …/sino-smcwrite` → `Signature=adhoc`) and the cert comparison
   never runs, even though the app is signed by the "Sino Dev" identity.
3. **The caller is identified by PID** (`LOCAL_PEERPID` + `kSecGuestAttributePid`), which can be raced
   by PID reuse. The audit token is the race-free identity.

Impact is bounded (writes are whitelisted to fan mode/target keys and clamped to the hardware min/max RPM),
but this is a root daemon. Fix all three.

## Current state

- `Sources/Bridging.h` includes `SMC.h`, so a `#define` integer in `SMC.h` is visible to Swift as a constant.
- `Sources/smcwrite.c:24-31` — `DEST`, `PLIST`, `SOCK`, `LABEL`, `ALLOWED_APP_DIR "/Applications/Sino.app"`,
  `ALLOWED_EXE_PATH "/Applications/Sino.app/Contents/MacOS/Sino"`, `ALLOWED_BUNDLE_ID "com.lov3u.sino"`.
- `Sources/smcwrite.c:197-217` — `peer_signer_matches_self(peer_info)`: `int ok = 1;` … sets `ok = 0`
  only inside `if (self_certs && CFArrayGetCount(self_certs) > 0)` when the peer's leaf cert differs.
- `Sources/smcwrite.c:219-278` — `peer_ok(fd)`:
  ```c
      pid_t pid = 0;
      socklen_t len = sizeof(pid);
      if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 || pid <= 0) return 0;
      ... proc_pidpath / realpath / strcmp(resolved, ALLOWED_EXE_PATH) / S_IWOTH checks ...
      CFNumberRef pid_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
      const void *keys[] = { kSecGuestAttributePid };
      const void *vals[] = { pid_num };
      ... SecCodeCopyGuestWithAttributes → SecCodeCheckValidity(guest, kSecCSDefaultFlags, NULL)
      → SecCodeCopyPath == ALLOWED_EXE_PATH → identifier == ALLOWED_BUNDLE_ID → peer_signer_matches_self
  ```
- `Sources/smcwrite.c:285-346` — `handle_client`: line protocol, `PING` → `OK\n`, `AUTO`, `AUTO n`,
  `SET n rpm`; anything else → `ERR\n`.
- `Sources/SMC.c:201-209` — client `fan_xfer(cmd)`: writes `cmd`, reads ≤7 bytes, success iff reply starts `OK`.
  `sino_fan_ctl_open()` (`:211-240`) connects and sends `PING`.
- `Sources/SinoApp.swift:409-428`:
  ```swift
    func setFanMode(_ mode: FanMode) {
        if fanCtlBusy { return }
        if mode == .auto {
            releaseFans()
            return
        }
        if sino_fan_ctl_open() == 0 {
            armFans(mode)
            return
        }
        fanCtlBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = FanCtl.install() && sino_fan_ctl_open() == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.fanCtlBusy = false
                if ok { self.armFans(mode) }
            }
        }
    }
  ```
  `FanCtl.install()` (`SinoApp.swift:4876-4893`) runs `sino-smcwrite --install` via an osascript admin
  prompt; `do_install` (`smcwrite.c:376-417`) already boots out the old daemon, copies, and bootstraps.
- `build.sh:6-9` picks `SIGN_ID="Sino Dev"` if that identity exists, else `"-"` (ad-hoc). Lines 15–18
  build the helper into `/tmp/sino-smcwrite` (plan 001 added `-framework Security`), then it is copied
  into `Contents/Resources/` of both bundles **without being signed**.
- SDK facts (verified 2026-11-17): `LOCAL_PEERTOKEN` is in `<sys/un.h>`; `audit_token_to_pid` is in
  `<bsm/libbsm.h>` (link `-lbsm`); `kSecGuestAttributeAudit` is in Security `SecCode.h`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| C check (writes /tmp only) | `cc -Wall -Wextra -O2 -o /tmp/sino-smcwrite-check Sources/smcwrite.c -isysroot "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -framework IOKit -framework CoreFoundation -framework Security -lbsm` | exit 0, no warnings |
| SMC.c syntax | `cc -Wall -Wextra -fsyntax-only -isysroot "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 Sources/SMC.c` | exit 0 |
| Swift typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 |
| Full build + install | `./build.sh` | `built and installed to /Applications/Sino.app` — **operator approval required** |

## Scope

**In scope**: `Sources/smcwrite.c`, `Sources/SMC.c`, `Sources/SMC.h`, `Sources/SinoApp.swift` (only `setFanMode`), `build.sh` (helper `cc` line + one signing line).

**Out of scope**: the key whitelist and RPM clamping (already correct); `FanCtl.install()`; moving fan
I/O off the main thread (separate finding — don't start it here); `Makefile`; uninstall (plan 007).

## Git workflow

- Branch `advisor/006-fan-helper-auth`; commits e.g. `feat(fans): helper version handshake`,
  `fix(fans): authenticate the helper's caller by audit token, fail closed`. Do not push.

## Steps

### Step 1: Add a protocol version
- `Sources/SMC.h`: add `#define SINO_HELPER_VERSION 2` and declare `int sino_fan_ctl_version(void);`.
- `Sources/smcwrite.c`: add `#include "SMC.h"` after the system includes. In `handle_client`, before the
  final `else`, add a `VER` branch that replies `"VER %d\n"` with `SINO_HELPER_VERSION` (format with `snprintf`
  into a small buffer, then `reply`).
- `Sources/SMC.c`: implement `sino_fan_ctl_version()`: if `g_fan_fd < 0` and `sino_fan_ctl_open() != 0`
  return 0; write `"VER\n"`; read up to 15 bytes; if `sscanf(buf, "VER %d", &v) == 1` return `v`, else
  return 0 (an old helper answers `ERR`, which means version 0).

**Verify**: C check and SMC.c syntax → exit 0; Swift typecheck → exit 0.

### Step 2: Reinstall when the running helper is outdated
In `setFanMode`, change the fast path to require the version, and make the reinstall drop the old connection first:
```swift
        if sino_fan_ctl_open() == 0, sino_fan_ctl_version() >= SINO_HELPER_VERSION {
            armFans(mode)
            return
        }
        sino_fan_ctl_close()
        fanCtlBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = FanCtl.install() && sino_fan_ctl_open() == 0
                && sino_fan_ctl_version() >= SINO_HELPER_VERSION
            …unchanged…
```
**Verify**: Swift typecheck → exit 0; `rg -n "SINO_HELPER_VERSION" Sources` → matches in SMC.h, smcwrite.c, SinoApp.swift.

### Step 3: Identify the caller by audit token
In `peer_ok`:
- Replace the `LOCAL_PEERPID` lookup with
  `audit_token_t tok; socklen_t len = sizeof(tok); if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &tok, &len) != 0) return 0; pid_t pid = audit_token_to_pid(tok); if (pid <= 0) return 0;`
  (add `#include <bsm/libbsm.h>`). Keep the `proc_pidpath` path pre-check as is.
- Replace the guest attributes: `CFDataRef tok_data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&tok, sizeof(tok));`
  with key `kSecGuestAttributeAudit` and value `tok_data` (release it like `pid_num` was). Remove the
  now-unused `pid_num`.
- In `build.sh`, append `-lbsm` to the helper `cc` line.

**Verify**: C check (with `-lbsm`) → exit 0, no warnings; `rg -n "LOCAL_PEERPID|kSecGuestAttributePid" Sources/smcwrite.c` → no matches.

### Step 4: Fail closed, and sign the helper so the cert check has something to compare
- `peer_signer_matches_self`: start with `int ok = 0;` and set `ok = 1` only when the helper's own
  certificate array is non-empty AND the peer's leaf certificate is `CFEqual` to it. An unsigned/ad-hoc
  helper therefore authorizes nobody.
- `build.sh`: right after the helper `cc` line, add
  `codesign -s "$SIGN_ID" --force --identifier com.lov3u.sino.smcwrite /tmp/sino-smcwrite >/dev/null`
  and, if `SIGN_ID` is `-`, print `warning: no "Sino Dev" identity — fan control will be refused by the helper`.

**Verify**: C check → exit 0; `rg -n "int ok = 0" Sources/smcwrite.c` → 1 match;
`bash -n build.sh` → exit 0.

### Step 5 (operator-approved): build, upgrade, prove it fails closed for strangers
1. `./build.sh` → success.
2. `codesign -dv /Applications/Sino.app/Contents/Resources/sino-smcwrite 2>&1 | rg Authority` → `Authority=Sino Dev`.
3. In Sino, switch fans to Manual → an admin prompt appears **once** (reinstall of the outdated helper);
   fans respond to the slider.
4. `printf 'PING\n' | nc -U /var/run/com.lov3u.sino.smcwrite.sock; echo "exit=$?"` → **no `OK`** printed
   (nc is not the signed Sino app, so the helper closes the connection).
5. `codesign -dv /Library/PrivilegedHelperTools/com.lov3u.sino.smcwrite 2>&1 | rg Authority` → `Authority=Sino Dev`.

## Test plan

- No unit harness exists for the C helper; gates are the compile checks plus Step 5's live checks.
  Step 5.4 is the key negative test (a foreign client is refused).

## Done criteria

- [ ] C check (with Security and `-lbsm`) exits 0 with no warnings; SMC.c syntax check exits 0
- [ ] Swift typecheck and `./tests.sh` exit 0
- [ ] `rg -n "LOCAL_PEERPID|kSecGuestAttributePid" Sources/smcwrite.c` → no matches
- [ ] `git diff --stat` touches only the in-scope files (+ `plans/README.md`)
- [ ] If the operator allowed Step 5: 5.2, 5.4, 5.5 give the stated results
- [ ] `plans/README.md` row updated

## STOP conditions

- The operator wants fan control to keep working on ad-hoc builds (Step 4 deliberately breaks that) — stop and ask.
- `SecCodeCopyGuestWithAttributes` with `kSecGuestAttributeAudit` returns an error for the real Sino app in Step 5.3 (report the OSStatus).
- Step 5.4 prints `OK` (the helper is still accepting strangers).

## Maintenance notes

- Bump `SINO_HELPER_VERSION` on every helper protocol or auth change; that is the only way installed helpers get replaced.
- The trust anchor is the "Sino Dev" leaf certificate. If that identity is regenerated, existing helpers
  refuse the new app until they are upgraded — and the upgrade itself needs the app to connect. The version
  check covers this: a refused connection makes `sino_fan_ctl_open()` fail, which triggers reinstall.
- Main-thread fan I/O and the shared `g_fan_fd` race are a known, separate finding.
