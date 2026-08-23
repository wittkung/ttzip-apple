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

`ttzip-apple` is the native macOS GUI client and system integration layer consuming [`ttzip-core`](https://github.com/wittkung/ttzip-core) over Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/wittkung/ttzip-core.git", branch: "main"),
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

## 🛠 Building from Source

```bash
# Clone repository
git clone https://github.com/wittkung/ttzip-apple.git
cd ttzip-apple

# Build release application
swift build -c release

# Run test suite (107 UI & Extension tests)
swift test
```

---

## 📄 License

Licensed under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**.  
For commercial inquiries and core engine integrations, see [ttzip-core](https://github.com/wittkung/ttzip-core).

© 2026 Witt Kung. All rights reserved.
