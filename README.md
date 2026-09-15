# Sino

Native macOS menu-bar system monitor. CPU, GPU, RAM, storage, network, fans, battery. No third-party libraries.

**Unsigned / ad-hoc signed.** Gatekeeper will warn until it’s Developer ID + notarized.

## Install

One line (builds from source, puts `Sino.app` in `/Applications`):

```bash
curl -fsSL https://raw.githubusercontent.com/Aduersarius/sino/main/install.sh | bash
```

Homebrew (Apple Silicon, CLT required):

```bash
brew tap Aduersarius/sino https://github.com/Aduersarius/sino
brew install sino
cp -R "$(brew --prefix)/opt/sino/Sino.app" /Applications && open /Applications/Sino.app
```

## Requirements

- Apple Silicon Mac
- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)

## Build from a clone

```bash
./build.sh
open Sino.app
```

## Notes

- Menu extra only (`LSUIElement`) — no Dock icon.
- Wi-Fi **SSID** needs Location (macOS 14+). Deny → row stays “Wi-Fi”.
- Process list and `nettop` run only while the dropdown is open.

## License

MIT
