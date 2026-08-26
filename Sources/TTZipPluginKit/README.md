# TTZipPluginKit: Official Plugin SDK for TTZip & ttsubs

<p align="center">
  <a href="README.zh-CN.md">简体中文</a> | <b>English</b>
</p>

`TTZipPluginKit` is the unified, high-performance, and secure extension contract and lifecycle protocol library designed for the **TTZip / ttsubs** desktop application ecosystem.

---

## Core Capabilities

1. **8 Standard Extension Points**:
   - Sidebar Contribution (`TTZipSidebarContribution`)
   - 3-Column Miller Columns Workspace (`makeWorkspaceView`)
   - Pro Inspector Panel (`makeInspectorView`)
   - Native QuickLook Preview Provider (`TTZipPreviewProvider`)
   - Virtual Archive Streaming DataSource (`TTZipVirtualArchiveDataSource`)
   - Global Omnibar Command (`TTZipOmnibarCommand`)
   - File Context Menu Contribution (`TTZipContextMenuContribution`)
   - Tenant-Scoped Encrypted Vault (`TTZipKeychainStore`)

2. **Zero-Trust Security & Cryptographic Gateways**:
   - `TTZipPluginSecurity`: O(1) memory streaming SHA-256 integrity digests, Apple CryptoKit Ed25519 publisher signature validation, and Zip Slip path traversal auditing.

3. **Two-Phase Commit (2PC) Atomic Installer**:
   - `TTZipPluginInstaller`: Supports `URLSession` streaming downloads (byte-level progress, real-time throughput MB/s), Staging sandbox isolation, and APFS `replaceItem` atomic directory swapping.

4. **Dynamic Runtime Loader**:
   - `TTZipPluginLoader` & `TTZipPluginRegistry`: Powers zero-downtime live hot-mounting and reactive unregistration without requiring host application restarts.

5. **Internationalization & Localization (i18n)**:
   - `TTZipPluginL10n`: Built-in dual language support (`zhHans` / `en`) synchronized with `AppLocalizationState`.
