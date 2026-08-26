# TTZip for Apple (macOS Desktop Client & System Extensions)

<p align="center">
  <img src="Assets/AppIcon.png" alt="TTZip Icon" width="128" height="128" onerror="this.style.display='none'"/>
</p>

<p align="center">
  <b>High-Precision Native macOS Archive Manager Powered by Apple Silicon Hardware Acceleration</b><br>
  Designed with Apple Silicon Translucency, WSJ Typography, and Swift 6 Strict Concurrency.
</p>

---

## ⚡️ Architecture & SDK Ecosystem

`ttzip-apple` is the native macOS desktop client, Finder sync extension, QuickLook previewer, and plugin host. It consumes the precompiled **`TTZipCore` SDK** and embeds the native **`TTZipPluginKit`** runtime.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        ttzip-apple Architecture                          │
├──────────────────────────────────────────────────────────────────────────┤
│ • Native macOS App (Sources/TTZipApp)                                    │
│ • Embedded Plugin SDK (Sources/TTZipPluginKit)                           │
│ • System Extensions: Finder Sync & QuickLook Preview                     │
│ • Microkernel Dependency: TTZipCore (SPM Package / Universal XCFramework)│
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 💎 Key Features

- **Native macOS SwiftUI & AppKit**: Full macOS 14+ Sonoma & macOS 15+ Sequoia support with Swift 6 strict concurrency (`-strict-concurrency=complete`).
- **Finder Sync Extension**: Seamless right-click context menu integration for instant packing, unpacking, hash checking, and container inspection.
- **QuickLook Preview Extension**: Spacebar instant archive preview in Finder powered by in-memory HTML rendering.
- **Dock Progress & Drag-and-Drop Queue**: 30Hz throttled macOS Dock Tile progress ring and concurrent operations queue manager.
- **Embedded Plugin Architecture**: Built-in `TTZipPluginKit` runtime supporting dynamic tool and cloud sync plugins (e.g. LarkSync).
- **Security & Integrity**: Integrated Anti-ZipSlip defense, Security-Scoped Bookmarks, and hardware CRC integrity checks.

---

## 🚀 Building Standalone from Source (Zero Rust Required)

`ttzip-apple` is a completely independent repository. **You do NOT need Rust, Cargo, uniffi-bindgen, or CMake installed on your machine.**

### Prerequisites
- macOS 14.0+ (Sonoma) or macOS 15.0+ (Sequoia)
- Xcode 16.0+ or Swift 6.0+ toolchain

### 1. Clone & Build Standalone
```bash
# Clone the standalone apple repository
git clone https://github.com/wittkung/ttzip-apple.git
cd ttzip-apple

# Build release binary (SPM automatically downloads prebuilt TTZipCore SDK)
swift build -c release

# Run the full unit & integration test suite (170 tests)
swift test

# Run single-file LOC architecture gate (Hard threshold: 800 LOC)
./scripts/lint_loc_gate.sh
```

### 2. Package Fully Signed macOS Application (`.app`)
```bash
# Package Direct Distribution build (.app with Sparkle auto-updates)
./scripts/bundle_app.sh --channel direct

# Output bundle: dist/TTZip.app
open dist/TTZip.app
```

---

## 🔄 Dual-Mode Microkernel Dependency Resolution

`apple/Package.swift` automatically adapts to your workflow:

1. **Standalone Mode (Default)**:
   - When cloned independently, SPM automatically resolves `TTZipCore` from the official Git repository (`https://github.com/wittkung/ttzip-core.git`), linking against the precompiled Universal (`arm64` + `x86_64`) `TTZipVendor.xcframework`. Zero local Rust setup required.
2. **Local Co-Development Mode (Automatic)**:
   - If a sibling `../core` repository exists locally, `Package.swift` automatically uses `.package(path: "../core")` for instant sub-second local Rust ↔ Swift iteration.
   - To force remote resolution even when `../core` exists, set `TTZIP_USE_REMOTE_CORE=1 swift build`.

---

## 📦 Multi-Channel Distribution Targets

Via `./scripts/bundle_app.sh`:
- `--channel direct` (Default): Website Release with Sparkle automatic updates and Hardened Runtime.
- `--channel mas`: Mac App Store build with strict App Sandbox.
- `--channel steam`: Steam Store build (DRM-Free, maximum I/O throughput).
- `--channel community`: Open-source build for local development.

---

## 📄 License

Licensed under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**.  
For commercial inquiries and core engine integrations, see [ttzip-core](https://github.com/wittkung/ttzip-core) (BSD-3-Clause OR Apache-2.0).

© 2026 Witt Kung. All rights reserved.
