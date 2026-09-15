<p align="center">
  <img height="128" src="Assets/AppIcon-1024.png?v=3" alt="Sino">
</p>
<h1 align="center">Sino</h1>
<p align="center">
  Fast, ultra-lightweight native macOS menu-bar system monitor for Apple Silicon.
</p>
<p align="center">
  <a href="https://github.com/Aduersarius/sino/stargazers"><img src="https://img.shields.io/github/stars/Aduersarius/sino?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/Aduersarius/sino/blob/main/LICENSE"><img src="https://img.shields.io/github/license/Aduersarius/sino?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon-black?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/RAM-~30MB-brightgreen?style=flat-square" alt="RAM ~30MB">
  <img src="https://img.shields.io/badge/bundle-2.7MB-brightgreen?style=flat-square" alt="Bundle 2.7MB">
</p>

<p align="center">
  <img src="docs/menubar.png" alt="Menu bar" width="560">
</p>
<p align="center">
  <img src="docs/dropdown.png" alt="Dropdown" width="240">
</p>

---

## Ultra-Lightweight by Design

Unlike Electron-based utilities that idle at 400MB+ RAM and waste battery cycles, Sino is engineered from the ground up for minimal overhead:

- **~30 MB Resident Memory (RSS):** Extremely lean memory footprint.
- **Tiny 2.7 MB App Bundle:** Single 1.6 MB Mach-O binary. Zero npm dependencies, zero SPM packages.
- **Sub-1% Idle CPU:** Runs in the background without draining your Mac's battery or spinning fans.
- **Adaptive Sampling:** Heavy per-process profiling (top CPU, memory, energy, and nettop tables) and deep filesystem scans run **only** when the dropdown dashboard is open. When closed, it rests in low-overhead monitoring mode.
- **Pure Native Darwin & Mach Primitives:** Direct kernel syscalls (`statfs`, `host_processor_info`, `host_statistics64`), IOKit accelerator queries, and direct Apple SMC C bridging. No external shell commands (`top`, `ps`, `df`) spawned.

---

## Deep Customization

Tailor Sino to match your workflow and macOS aesthetic:

- **Modular Menu Bar Chips:** Choose exactly what appears on your menu bar (CPU, GPU, RAM, SSD, Network ↑↓, Fans, Battery) and drag to reorder.
- **Dynamic Theme Switcher:** Instant toggle between **Light**, **Dark**, and **System** modes with an adaptive toolbar icon.
- **Liquid Glass & Materials:** Configurable frosted glass backdrops (HUD, Menu, Popover, Sidebar, Window) with custom tint colors and opacity.
- **Adjustable Refresh Intervals:** Cycle between **0.5s**, **1s**, **2s**, and **5s** polling speeds with a single click in the toolbar.
- **Custom App Shortcuts:** Pin your favorite utility or diagnostic apps directly to the dropdown toolbar for 1-click launching.

---

## Core Monitoring Features

- **CPU & Performance Cores:** Real-time load, sparkline history, and individual breakdowns for **Performance (P-cores)** and **Efficiency (E-cores)** on Apple Silicon.
- **Memory & Swap:** Live tracking of wired, active, compressed, and swap memory with memory pressure indicators.
- **GPU & Metal Acceleration:** Real-time GPU utilization %, renderer and tiler engines, allocated and in-use VRAM, and core count.
- **Network Bandwidth & Diagnostics:** Real-time download/upload speeds, peak counters, Wi-Fi SSID, public & local IPv4/IPv6, router gateway IP, and hardware MAC address.
- **Disk & Storage Health:** Instant capacity usage, free space, and mounted volume list.
- **Thermals & Fans:** Direct Apple SMC register reads for real-time fan RPMs and sensor temperatures.
- **Battery & Power:** Live charge percentage, health rating, cycle count, and AC charging status.
- **Interactive Side Detail Panels:** Hover over any card in the main dropdown to slide out deep diagnostic inspection panels.
- **Top Process Inspector:** Spot resource hogs instantly with on-demand top CPU, Memory, Energy, and Network processes.

---

## OS Requirements

macOS 14+ on Apple Silicon (M1/M2/M3/M4). Command Line Tools only if compiling from source.

---

## Installation

### Download

Grab the [Latest release](https://github.com/Aduersarius/sino/releases/latest) — `Sino.app.zip` (Apple Silicon, unsigned).

### One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/Aduersarius/sino/main/install.sh | bash
```

Prefers the release zip; falls back to building `main`. Installs directly to `/Applications` and launches.

### Homebrew

```bash
brew install Aduersarius/tap/sino
```

### From Source

```bash
git clone https://github.com/Aduersarius/sino.git
cd sino
./build.sh
open /Applications/Sino.app
```

> **Note on Security:** As an ad-hoc signed build, macOS Gatekeeper may require **Right-click → Open** on the first launch.

---

## Notes

- **Menu Extra (`LSUIElement`):** Operates exclusively in the status bar with zero Dock clutter.
- **Wi-Fi SSID:** macOS requires Location permission to display the active Wi-Fi SSID. If denied, Sino gracefully displays "Wi-Fi".
- **Zero-Waste Profiling:** `nettop` and process inspection tables run strictly while the dropdown is open.

---

## License

[MIT](LICENSE)
