# TTZip for Apple (macOS Desktop Client & System Extensions)

<p align="center">
  <img src="Assets/AppIcon.png" alt="TTZip Icon" width="128" height="128" onerror="this.style.display='none'"/>
</p>

<p align="center">
  <b>High-Precision Native macOS Archive Manager Powered by Apple Silicon Hardware Acceleration</b><br>
  Designed with Apple Silicon Translucency, WSJ Typography, and Ultra-Fast Async Concurrency.
</p>

---

## ⚡️ Powered by TTZip Core Engine

`ttzip-apple` is the native macOS GUI client and system integration layer consuming `TTZipCore` over Swift Package Manager:

```swift
// Monorepo Workspace Dependency
dependencies: [
    .package(path: "../core"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.0")
]
```

---

## 💎 Features

- **Native macOS SwiftUI & AppKit Architecture**: Full macOS 14+ / 15+ Sequoia support.
- **Finder Sync Extension**: Seamless right-click context menu integration for instant packing, unpacking, and inspection.
- **QuickLook Preview Extension**: Instant zero-disk-IO archive previews in Finder via spacebar.
- **Menu Bar Assistant**: Background drag-and-drop batch extraction and compression.
- **Security & Integrity**: Integrated Anti-ZipSlip protection, quarantine detection, and hardware CRC integrity checks.

---

## 🚀 Download & Installation

### Option 1: Direct DMG Installer (Recommended)

Download the official standalone Retina installer from [Releases](https://github.com/wittkung/ttzip/releases/latest):
- **[`TTZip-1.0.0.dmg`](https://github.com/wittkung/ttzip/releases/download/v1.0.0/TTZip-1.0.0.dmg)** (Self-contained, Ad-hoc / Developer ID Signed)
- Open the DMG and drag **TTZip.app** into `/Applications`.
- Automatic silent background updates are handled via **Sparkle 2.0** (`appcast.xml`).

### Option 2: Homebrew

```bash
brew install --cask wittkung/ttzip/ttzip
```

---

## 🛠 Building from Source

```bash
# Clone repository
git clone https://github.com/wittkung/ttzip.git
cd ttzip/apple

# Build release application
swift build -c release

# Run test suite
swift test
```

---

## 📄 License

Licensed under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**.  
For commercial inquiries and core engine integrations, see [ttzip-core](https://github.com/wittkung/ttzip-core).

© 2026 Witt Kung. All rights reserved.
