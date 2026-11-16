# Plan 004: install.sh's build-from-source fallback leaves an installed app

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- install.sh build.sh`
> Plan 001 is expected to have changed `build.sh` (link flag, source list) — that's fine. Any change
> to `install.sh`, or to build.sh's install/cleanup tail, means: compare excerpts; on mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (pairs naturally with 001, but independent)
- **Category**: bug
- **Planned at**: commit `c497768`, 2026-11-17

## Why this matters

The README's one-liner (`curl … install.sh | bash`) prefers the release zip and falls back to building
`main` from source. In the fallback, `build.sh` already installs into `/Applications/Sino.app` and then
deletes its own intermediate bundle. `install.sh` then does `rm -rf /Applications/Sino.app` and tries to
`cp -R "$TMP/sino-main/Sino.app"` — a path that never exists. Net effect: the freshly installed app is
deleted and the script exits with an error. Anyone whose release download fails ends up with **no app**.

## Current state

- `install.sh:8-26`:
  ```bash
  if curl -fsSL -o "$ZIP" "https://github.com/Aduersarius/sino/releases/latest/download/Sino.app.zip"; then
    ditto -x -k "$ZIP" "$TMP"
    APP=$(find "$TMP" -maxdepth 2 -name 'Sino.app' | head -1)
  else
    if ! xcode-select -p >/dev/null 2>&1; then
      echo "install CLT first: xcode-select --install"
      exit 1
    fi
    curl -fsSL https://github.com/Aduersarius/sino/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP"
    cd "$TMP"/sino-main
    chmod +x build.sh
    ./build.sh
    APP="$TMP/sino-main/Sino.app"
  fi
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  find "$DEST" -exec xattr -c {} + 2>/dev/null || true
  open "$DEST"
  echo "installed $DEST"
  ```
- `build.sh` tail: sets `APP="$ROOT/dist/Sino.app"`, installs a full copy into `ROOTAPP="/Applications/Sino.app"`
  (binary, helper, plist, icon, metal, xattr clear, codesign, lsregister), then
  `rm -rf "$ROOT/Pulse.app" "$ROOT/dist/Pulse.app" "$ROOT/Sino.app"` and `rm -rf "$APP"`, and prints
  `built and installed to $ROOTAPP`.
- Note: the release-zip branch (lines 8–10) also has a latent issue: if the zip lacks `Sino.app`,
  `APP` is empty and `cp -R "" "$DEST"` fails *after* `rm -rf "$DEST"`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Syntax | `bash -n install.sh` | exit 0, no output |
| No copy after build | `rg -n 'sino-main/Sino.app' install.sh` | no matches |

(`shellcheck` is not installed on the owner's machine; don't add it as a gate.)

## Scope

**In scope**: `install.sh`.

**Out of scope**: `build.sh` (it is the in-repo dev build; other plans edit it), `Formula/sino.rb`, README.

## Git workflow

- Branch `advisor/004-install-fallback`; commit `fix(install): keep the app build.sh installs in the source fallback`. Do not push.

## Steps

### Step 1: Restructure so the delete only happens when there is something to copy
Target shape (keep the existing messages):
```bash
if curl -fsSL -o "$ZIP" "https://github.com/Aduersarius/sino/releases/latest/download/Sino.app.zip"; then
  ditto -x -k "$ZIP" "$TMP"
  APP=$(find "$TMP" -maxdepth 2 -name 'Sino.app' | head -1)
  [ -n "$APP" ] || { echo "release zip has no Sino.app"; exit 1; }
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  find "$DEST" -exec xattr -c {} + 2>/dev/null || true
else
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "install CLT first: xcode-select --install"
    exit 1
  fi
  curl -fsSL https://github.com/Aduersarius/sino/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP"
  cd "$TMP"/sino-main
  chmod +x build.sh
  ./build.sh   # builds, signs and installs into /Applications/Sino.app itself
fi
open "$DEST"
echo "installed $DEST"
```
**Verify**: `bash -n install.sh` → exit 0; `rg -n 'sino-main/Sino.app' install.sh` → no matches;
`rg -c 'rm -rf "\$DEST"' install.sh` → `1` and it is inside the `then` branch.

### Step 2 (optional, operator-approved — it reinstalls /Applications/Sino.app from `main`)
Force the fallback without editing the script by making the release URL fail, e.g. run the script with
the release line pointed at a bogus tag in a scratch copy: `sed 's#releases/latest/download#releases/download/v0.0.0#' install.sh > /tmp/install-test.sh && bash /tmp/install-test.sh`.
**Verify**: output ends with `built and installed to /Applications/Sino.app` then `installed /Applications/Sino.app`;
`test -x /Applications/Sino.app/Contents/MacOS/Sino && echo ok` → `ok`.

## Test plan

No automated harness exists for shell scripts in this repo; Step 1's static checks are the gate,
Step 2 is the behavioral check when the operator allows it.

## Done criteria

- [ ] `bash -n install.sh` exits 0
- [ ] `rg -n 'sino-main/Sino.app' install.sh` → no matches
- [ ] `git diff --stat` shows only `install.sh` (+ `plans/README.md`)
- [ ] `plans/README.md` row updated

## STOP conditions

- `build.sh` no longer installs into `/Applications/Sino.app` (then the fallback needs a copy again — report).
- The release branch of the script differs from the excerpt.

## Maintenance notes

- If `build.sh` ever stops self-installing (e.g. gets an output-dir parameter), the fallback must copy again.
- The source fallback signs ad-hoc unless the machine has a "Sino Dev" identity; after plan 006 such
  builds have no fan control. That is expected; mention it in README if users hit it.
