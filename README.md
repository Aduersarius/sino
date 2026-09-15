# Sino

Native macOS menu-bar system monitor. CPU, GPU, RAM, storage, network, fans, battery. No third-party libraries.

**Unsigned / ad-hoc signed.** Gatekeeper will warn until it’s Developer ID + notarized. For now this repo is **source**.

## Requirements

- Apple Silicon Mac
- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)

## Build

```bash
./build.sh
open Sino.app
```

Binary: `Sino.app` and `dist/Sino.app`.

## Notes

- Menu extra only (`LSUIElement`) — no Dock icon.
- Wi-Fi **SSID** needs Location (macOS 14+). Deny → row stays “Wi-Fi”.
- Process list and `nettop` run only while the dropdown is open.

## License

MIT
