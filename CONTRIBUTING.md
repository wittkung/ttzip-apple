# Contributing to TTZip Desktop Application

Thank you for your interest in contributing to TTZip!

## Code Architecture & Philosophy
1. **Zero-Subprocess Core**: Native Swift 6 and Rust FFI architecture. No external process invocations (`/bin/tar`, `7z`, `ditto`).
2. **Apple Silicon First**: SIMD NEON acceleration, APFS copy-on-write clonefile, 16KB physical memory page alignment.
3. **Open Source & Clean Licensing**: The core engine and desktop application are open-source and free to build and use.

## Multi-Channel Build System
TTZip supports four distribution targets via `./scripts/bundle_app.sh`:
- `--channel direct` (Default): Website Release DMG with Sparkle automatic updates and Ed25519 offline license verification.
- `--channel mas`: Mac App Store build with strict App Sandbox.
- `--channel steam`: Steam Store build (DRM-Free, unsandboxed for maximum performance).
- `--channel community`: Open-source build for local development.

## Quality & Verification Gates
Before submitting a Pull Request, please ensure:
```bash
# 1. Swift unit tests pass
swift test --package-path apple
swift test --package-path core

# 2. LOC Defense Gate (All files <= 800 LOC)
python3 core/scripts/audit_loc.py

# 3. Multi-channel bundling test
./apple/scripts/bundle_app.sh --channel community
```
