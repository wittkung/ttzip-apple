# Contributing to TTZip for Apple (macOS Desktop Client)

Thank you for your interest in contributing to TTZip!

---

## 🛠 Prerequisites & Environment Setup

`ttzip-apple` is completely decoupled from the Rust microkernel toolchain for frontend and macOS contributors.

- **Required**: macOS 14.0+ with Xcode 16.0+ (Swift 6.0 toolchain).
- **NOT Required**: You do **NOT** need Rust, Cargo, `uniffi-bindgen`, or CMake installed to build, test, or contribute to `ttzip-apple`.

---

## 💻 Local Development Workflow

```bash
# 1. Clone the repository
git clone https://github.com/wittkung/ttzip-apple.git
cd ttzip-apple

# 2. Build the app product in debug or release mode
swift build
swift build -c release

# 3. Verify the repository: the single-file LOC gate and the Swift package test suite
ttaction run

# ... or run the same two stages directly
./scripts/lint_loc_gate.sh
swift test

# 4. Assemble and test the .app bundle locally
./scripts/bundle_app.sh --channel direct --open
```

---

## 🔄 Dual-Mode Microkernel Resolution

1. **Standalone Contributor (Default)**:
   - SPM automatically resolves `TTZipCore` from `https://github.com/wittkung/ttzip-core.git` and links the prebuilt Universal XCFramework (`arm64` + `x86_64`).
2. **Core Engine Co-Developer**:
   - If you also have `ttzip-core` cloned alongside `ttzip-apple` (e.g. `../core`), `Package.swift` will automatically detect and link the local path for sub-second iteration.
   - To force remote resolution, set `TTZIP_USE_REMOTE_CORE=1 swift build`.

---

## 🛡 Pull Request Quality Checklist

Before submitting a PR, ensure all gates pass:
1. `ttaction run` passes: the single-file LOC gate and `swift test` with 0 failures.
2. `./scripts/lint_loc_gate.sh` passes with all files $\le 800$ LOC.
3. `./scripts/bundle_app.sh --channel direct` successfully builds and signs `dist/TTZip.app`.
4. All new Swift source files include the standard dual-license SPDX header:
   ```swift
   // Copyright 2026 MetastudyLine. All rights reserved.
   // SPDX-License-Identifier: MIT OR Apache-2.0
   ```
5. All code comments and documentation are written in professional English.

---

## 📄 License & Attribution

All code in this repository is dual-licensed under the MIT License and the Apache License, Version 2.0, at your option. See the root `LICENSE` file for the full text. Every first-party source file carries the `SPDX-License-Identifier: MIT OR Apache-2.0` header.

