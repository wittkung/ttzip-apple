// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTMediaKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI

/// Coordinates deterministic window creation, sidebar "Open in New Window",
/// external Finder file/folder opens (with duplicate suppression), and global search routing.
@MainActor
public final class BrowserWindowRouter {
    public static let shared = BrowserWindowRouter()

    public let registry: BrowserWindowRegistry

    /// SwiftUI `openWindow(id: "main")` bridge registered by live `MainView` instances.
    public var swiftUIWindowOpener: (@MainActor () -> Void)?

    /// Optional factory hook used in unit tests or when creating standalone windows programmatically
    /// when SwiftUI's `WindowGroup` scene opener is unavailable.
    public var fallbackWindowCreator: (@MainActor (BrowserWindowLaunchSeed) -> (any BrowserWindowControlling)?)?

    private struct DeduplicatedBatchRecord {
        let signature: String
        let timestamp: TimeInterval
    }

    private var recentBatches: [DeduplicatedBatchRecord] = []
    private let deduplicationWindowSeconds: TimeInterval = 0.45

    public init(registry: BrowserWindowRegistry = .shared) {
        self.registry = registry
    }

    // MARK: - Window Creation ("New Window" & "Open in New Window")

    /// Creates a new browser window optionally seeded with an initial directory, selected item, or archive.
    @discardableResult
    public func openNewWindow(
        with directoryURL: URL? = nil,
        selecting selectedPath: String? = nil,
        archiveURL: URL? = nil,
        password: String? = nil,
        entrySubpath: String? = nil,
        highlightLine: Int? = nil
    ) -> BrowserWindowLaunchSeed {
        let resolvedDir: URL? = {
            if let directoryURL {
                return directoryURL.standardizedFileURL
            }
            if let activeDir = registry.activeController?.currentDirectoryURL {
                return activeDir
            }
            return nil
        }()

        let seed = BrowserWindowLaunchSeed(
            initialDirectoryURL: resolvedDir,
            initialSelectedPath: selectedPath,
            initialArchiveURL: archiveURL?.standardizedFileURL,
            initialPassword: password,
            initialArchiveEntrySubpath: entrySubpath,
            initialHighlightLine: highlightLine
        )
        let beforeCount = registry.windowCount
        registry.enqueueLaunchSeed(seed)

        if let opener = swiftUIWindowOpener {
            opener()
        } else if let creator = fallbackWindowCreator {
            if let consumed = registry.consumeNextLaunchSeed(),
               let created = creator(consumed) {
                created.applyLaunchSeed(consumed)
                registry.register(created)
                registry.activateWindow(id: created.windowID)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            _ = NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            if registry.windowCount == beforeCount {
                registry.discardLaunchSeed(id: seed.id)
            }
        }

        // If `swiftUIWindowOpener` ran in a unit test where SwiftUI did not instantiate a scene synchronously,
        // allow `fallbackWindowCreator` to fulfill the staged seed so tests remain deterministic.
        if registry.windowCount == beforeCount,
           let creator = fallbackWindowCreator,
           let pending = registry.consumeNextLaunchSeed(),
           let created = creator(pending) {
            created.applyLaunchSeed(pending)
            registry.register(created)
            registry.activateWindow(id: created.windowID)
        }

        return seed
    }

    /// Opens a specific folder or file URL in a brand-new browser window without mutating the source window.
    @discardableResult
    public func openInNewWindow(url: URL) -> BrowserWindowLaunchSeed {
        let standardized = url.standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir)
        if (exists && isDir.boolValue) || url.hasDirectoryPath {
            return openNewWindow(with: standardized)
        }
        let ext = standardized.pathExtension.lowercased()
        if ArchiveCompressionFormat.from(extensionOrName: ext) != nil ||
           ArchiveCompressionFormat.from(extensionOrName: standardized.lastPathComponent) != nil {
            return openNewWindow(
                with: standardized.deletingLastPathComponent(),
                selecting: standardized.path,
                archiveURL: standardized
            )
        }
        return openNewWindow(
            with: standardized.deletingLastPathComponent(),
            selecting: standardized.path
        )
    }

    // MARK: - External URL Routing (Finder Open / Drag-to-Dock / CLI)

    /// Routes external URLs opened via `AppDelegate.application(_:open:)` or SwiftUI `.onOpenURL`
    /// deterministically without broadcasting to multiple windows.
    /// Returns `true` if processed, or `false` if suppressed as a duplicate delivery of the same batch.
    @discardableResult
    public func routeExternalOpen(
        urls: [URL],
        preferredAction: String? = nil,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let validURLs = urls.filter(\.isFileURL).map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !validURLs.isEmpty else { return false }

        let archiveActionKey = preferredAction ?? UserDefaults.standard.string(forKey: "ttzip_double_click_action") ?? "browse"
        guard recordExternalBatchIfUnique(validURLs: validURLs, actionKey: archiveActionKey, now: now) else {
            return false
        }

        let partitioned = partitionExternalURLs(validURLs)
        let browserLeases = acquireExternalLeases(for: partitioned.directories + partitioned.archives)
        defer {
            for lease in browserLeases {
                lease.release()
            }
        }
        routeExternalDirectories(partitioned.directories)
        routeExternalArchives(
            partitioned.archives,
            actionKey: archiveActionKey,
            hasDirectories: !partitioned.directories.isEmpty
        )
        routeExternalPlainFiles(partitioned.plainFiles)
        return true
    }

    private func recordExternalBatchIfUnique(validURLs: [URL], actionKey: String, now: TimeInterval) -> Bool {
        let signature = "\(actionKey)|" + validURLs.map(\.path).sorted().joined(separator: "\n")
        recentBatches.removeAll { now - $0.timestamp > deduplicationWindowSeconds }
        guard !recentBatches.contains(where: { $0.signature == signature }) else {
            return false
        }
        recentBatches.append(DeduplicatedBatchRecord(signature: signature, timestamp: now))
        return true
    }

    private func acquireExternalLeases(for validURLs: [URL]) -> [SecurityScopeLease] {
        var leases: [SecurityScopeLease] = []
        leases.reserveCapacity(validURLs.count * 2)
        for url in validURLs {
            if let fileLease = RootFolderAccessManager.shared.acquireLease(for: url) {
                leases.append(fileLease)
            }
            if let parentLease = RootFolderAccessManager.shared.acquireLease(for: url.deletingLastPathComponent()) {
                leases.append(parentLease)
            }
        }
        return leases
    }

    private func partitionExternalURLs(_ validURLs: [URL]) -> (directories: [URL], archives: [URL], plainFiles: [URL]) {
        var directories: [URL] = []
        var archives: [URL] = []
        var plainFiles: [URL] = []

        for url in validURLs {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let isAppBundle = url.pathExtension.lowercased() == "app"
                || (try? url.resourceValues(forKeys: [.isApplicationKey]).isApplication) == true
            if exists && isDir.boolValue && !isAppBundle {
                directories.append(url)
            } else if !isAppBundle && isArchiveURL(url) {
                archives.append(url)
            } else {
                plainFiles.append(url)
            }
        }
        return (directories, archives, plainFiles)
    }

    private func isArchiveURL(_ url: URL) -> Bool {
        ArchiveCompressionFormat.from(extensionOrName: url.pathExtension.lowercased()) != nil
            || ArchiveCompressionFormat.from(extensionOrName: url.lastPathComponent) != nil
    }

    private func routeExternalDirectories(_ directories: [URL]) {
        for (idx, dirURL) in directories.enumerated() {
            if idx == 0, let target = ensureTargetWindowForExternalOpen(preferPristineOrActive: true) {
                target.navigateToDirectory(dirURL)
                focusWindow(for: target)
            } else {
                _ = openNewWindow(with: dirURL)
            }
        }
    }

    private static func makeBookmarkSession(for urls: [URL]) -> ActiveBookmarkSession {
        let scope = SecurityScopedResourceScope()
        for url in urls {
            let isScoped = SecurityScopedResourceManager.shared.startAccessing(url: url)
            scope.add(url, isSecurityScoped: isScoped)
        }
        return ActiveBookmarkSession(scope: scope)
    }

    private func routeExternalArchives(_ archives: [URL], actionKey: String, hasDirectories: Bool) {
        for (idx, archiveURL) in archives.enumerated() {
            let session = Self.makeBookmarkSession(for: [archiveURL])
            if actionKey == "extract" {
                let target = ensureTargetWindowForExternalOpen(preferPristineOrActive: true)
                target?.extractArchiveInWindow(
                    at: archiveURL,
                    to: nil,
                    password: nil,
                    isSmartExtract: true,
                    trashSourceAfterExtract: false,
                    bookmarkSession: session
                )
                if let target { focusWindow(for: target) }
            } else if idx == 0 && !hasDirectories,
                      let target = ensureTargetWindowForExternalOpen(preferPristineOrActive: true) {
                target.openArchiveInWindow(at: archiveURL, password: nil, bookmarkSession: session)
                focusWindow(for: target)
            } else {
                _ = openNewWindow(
                    with: archiveURL.deletingLastPathComponent(),
                    selecting: archiveURL.path,
                    archiveURL: archiveURL
                )
            }
        }
    }

    private func routeExternalPlainFiles(_ plainFiles: [URL]) {
        guard !plainFiles.isEmpty else { return }
        if let target = ensureTargetWindowForExternalOpen(preferPristineOrActive: true) {
            for fileURL in plainFiles {
                let handoffLease = RootFolderAccessManager.shared.acquireLease(for: fileURL)
                let openTask = target.receiveExternalFileInWindow(fileURL)
                Task { @MainActor in
                    defer { handoffLease?.release() }
                    _ = await openTask.value
                }
            }
            focusWindow(for: target)
        } else {
            for fileURL in plainFiles {
                let handoffLease = RootFolderAccessManager.shared.acquireLease(for: fileURL)
                Task { @MainActor in
                    defer { handoffLease?.release() }
                    _ = await Self.receiveStandaloneExternalFileHeadless(
                        url: fileURL,
                        createAppKitWindow: true
                    )
                }
            }
        }
    }

    @discardableResult
    public static func receiveStandaloneExternalFileHeadless(
        url: URL,
        createAppKitWindow: Bool = true,
        cacheManager: PreviewLRUCacheManager = .shared
    ) async -> Bool {
        let l10n = AppLocalizationState.shared
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir), !isDir.boolValue else {
            AppErrorReporter.shared.reportError(
                title: l10n.uiString(zh: "无法打开文件", en: "Unable to Open File"),
                message: l10n.uiString(
                    zh: "找不到文件“\(standardized.lastPathComponent)”。",
                    en: "The file \"\(standardized.lastPathComponent)\" could not be found."
                ),
                code: "ERR_FILE_NOT_FOUND",
                details: standardized.path
            )
            return false
        }
        let diskItem = DiskItemInfo(url: standardized)
        let probeItem = ImmersiveMediaItem(
            url: standardized,
            name: diskItem.displayName,
            fileSizeBytes: diskItem.fileSizeBytes,
            isEditable: true,
            resourceContext: .diskFile(url: standardized, fileName: diskItem.displayName, allowsEditing: true)
        )
        if StandalonePlaybackWindowManager.isVideoItem(probeItem) {
            return await StandalonePlaybackWindowManager.shared.openOrFocus(
                item: probeItem,
                originBrowserWindowID: nil,
                originSelectedItem: diskItem,
                createAppKitWindow: createAppKitWindow,
                cacheManager: cacheManager
            ) != nil
        }
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: standardized.pathExtension)
        guard let descriptor = TTMediaCapabilityMatrix.descriptor(for: ext),
              !descriptor.capabilities.contains(.archiveBrowse) else {
            AppErrorReporter.shared.reportError(
                title: l10n.uiString(zh: "无法打开文件", en: "Unable to Open File"),
                message: l10n.uiString(
                    zh: "TTZip 不支持直接预览或打开“\(diskItem.displayName)”的格式。",
                    en: "TTZip does not support opening \"\(diskItem.displayName)\" directly."
                ),
                code: "ERR_UNSUPPORTED_INCOMING_FORMAT",
                details: standardized.path
            )
            return false
        }
        let opened = await StandalonePreviewWindowManager.shared.open(
            item: probeItem,
            originWindowID: nil,
            resourceContext: probeItem.resourceContext,
            createAppKitWindow: createAppKitWindow,
            cacheManager: cacheManager
        )
        if !opened {
            AppErrorReporter.shared.reportError(
                title: l10n.uiString(zh: "无法打开文件", en: "Unable to Open File"),
                message: l10n.t(L10n.Preview.cannotPreviewFormat),
                code: "ERR_PREVIEW_OPEN_FAILED",
                details: standardized.path
            )
        }
        return opened
    }

    // MARK: - Global Search & Encrypted Prompt Routing

    public static func canonicalFilePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    @discardableResult
    public func routeGlobalSearchResult(_ item: GlobalSearchResultItem) -> Task<Bool, Never>? {
        switch item.targetKind {
        case .archiveEntry(let archivePath, let entrySubpath):
            return routeGlobalSearchArchiveEntry(
                archivePath: archivePath,
                entrySubpath: entrySubpath,
                preferredWindowID: item.targetWindowID,
                highlightLine: item.matchedLineStart
            )
        case .archiveFile(let archivePath):
            routeGlobalSearchArchive(archivePath: archivePath, preferredWindowID: item.targetWindowID)
            return nil
        case .diskItem(let diskPath):
            routeGlobalSearchDiskItem(url: URL(fileURLWithPath: diskPath), preferredWindowID: item.targetWindowID)
            return nil
        case .quickAction:
            return nil
        }
    }

    public func routeGlobalSearchResult(url: URL) {
        routeGlobalSearchResult(itemURL: url)
    }

    public func routeGlobalSearchResult(itemURL: URL) {
        let standardized = itemURL.standardizedFileURL
        if isArchiveURL(standardized) {
            routeGlobalSearchArchive(archivePath: standardized.path)
        } else {
            routeGlobalSearchDiskItem(url: standardized)
        }
    }

    public func routeGlobalSearchDiskItem(url: URL, preferredWindowID: UUID? = nil) {
        let standardized = url.standardizedFileURL
        let targetDir = standardized.deletingLastPathComponent().standardizedFileURL
        if let preferredWindowID, let preferred = registry.controller(for: preferredWindowID) {
            preferred.revealItemInWindow(standardized)
            focusWindow(for: preferred)
            return
        }
        if let matching = registry.allControllers.first(where: {
            $0.currentArchivePath == nil && $0.currentDirectoryURL.standardizedFileURL == targetDir
        }) {
            matching.revealItemInWindow(standardized)
            focusWindow(for: matching)
            return
        }
        if let target = ensureTargetWindowForExternalOpen(preferPristineOrActive: true) {
            target.revealItemInWindow(standardized)
            focusWindow(for: target)
        } else {
            _ = openInNewWindow(url: standardized)
        }
    }

    public func routeGlobalSearchArchive(archivePath: String, preferredWindowID: UUID? = nil) {
        let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
        let canonicalTarget = Self.canonicalFilePath(archiveURL.path)

        if let preferredWindowID, let preferred = registry.controller(for: preferredWindowID) {
            if Self.canonicalFilePath(preferred.currentArchivePath) != canonicalTarget {
                let session = Self.makeBookmarkSession(for: [archiveURL])
                preferred.openArchiveInWindow(at: archiveURL, password: nil, bookmarkSession: session)
            }
            focusWindow(for: preferred)
            return
        }

        if let existing = registry.allControllers.first(where: {
            Self.canonicalFilePath($0.currentArchivePath) == canonicalTarget
        }) {
            focusWindow(for: existing)
            return
        }

        if let target = ensureTargetWindowForExternalOpen(preferPristineOrActive: true) {
            let session = Self.makeBookmarkSession(for: [archiveURL])
            target.openArchiveInWindow(at: archiveURL, password: nil, bookmarkSession: session)
            focusWindow(for: target)
        } else {
            _ = openNewWindow(
                with: archiveURL.deletingLastPathComponent(),
                selecting: archiveURL.path,
                archiveURL: archiveURL
            )
        }
    }

    @discardableResult
    public func routeGlobalSearchArchiveEntry(
        archivePath: String,
        entrySubpath: String,
        preferredWindowID: UUID? = nil,
        highlightLine: Int? = nil
    ) -> Task<Bool, Never>? {
        let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
        let canonicalTarget = Self.canonicalFilePath(archiveURL.path)

        let resolvedTarget: (any BrowserWindowControlling)? = {
            if let preferredWindowID, let preferred = registry.controller(for: preferredWindowID) {
                return preferred
            }
            if let matchingArchiveWindow = registry.allControllers.first(where: {
                Self.canonicalFilePath($0.currentArchivePath) == canonicalTarget
            }) {
                return matchingArchiveWindow
            }
            return registry.activeController
        }()

        if let target = resolvedTarget {
            focusWindow(for: target)
            return target.selectArchiveEntryInWindow(
                archivePath: archiveURL.path,
                entrySubpath: entrySubpath,
                highlightLine: highlightLine
            )
        }

        _ = openNewWindow(
            with: archiveURL.deletingLastPathComponent(),
            selecting: archiveURL.path,
            archiveURL: archiveURL,
            entrySubpath: entrySubpath,
            highlightLine: highlightLine
        )
        if let created = registry.activeController {
            focusWindow(for: created)
            return created.selectArchiveEntryInWindow(
                archivePath: archiveURL.path,
                entrySubpath: entrySubpath,
                highlightLine: highlightLine
            )
        }
        return nil
    }

    public func routeEncryptedArchivePrompt(archivePath: String, targetWindowID: UUID? = nil) {
        if let targetWindowID, let ctrl = registry.controller(for: targetWindowID) {
            ctrl.handleFocusedEncryptionPrompt(for: archivePath)
            return
        }
        registry.activeController?.handleFocusedEncryptionPrompt(for: archivePath)
    }

    // MARK: - Unified Application Command Routing (Dock Menu & Main Menu)

    /// Routes an application command to the most recent valid browser window,
    /// or creates a new browser window and delivers the command exactly once when registered.
    @discardableResult
    public func dispatchApplicationCommand(
        _ command: ApplicationWindowCommand,
        preferredWindowID: UUID? = nil
    ) -> UUID? {
        if command == .openNewWindow {
            let seed = openNewWindow()
            if let active = registry.activeController {
                focusWindow(for: active)
                return active.windowID
            }
            return seed.id
        }

        let targetController: (any BrowserWindowControlling)? = {
            if let preferredWindowID,
               let preferred = registry.controller(for: preferredWindowID),
               !preferred.isWindowClosing {
                return preferred
            }
            return registry.activeController
        }()

        if let target = targetController {
            focusWindow(for: target)
            target.handleApplicationCommand(command)
            return target.windowID
        }

        // Zero active windows: stage command for one-shot delivery upon registration and open a window.
        registry.enqueuePendingWindowCommand(command)
        _ = openNewWindow()
        if let created = registry.activeController {
            focusWindow(for: created)
            return created.windowID
        }
        return nil
    }

    // MARK: - Helpers

    public func resetForTesting() {
        recentBatches.removeAll()
        swiftUIWindowOpener = nil
        fallbackWindowCreator = nil
        registry.resetForTesting()
    }

    private func ensureTargetWindowForExternalOpen(preferPristineOrActive: Bool) -> (any BrowserWindowControlling)? {
        if let active = registry.activeController {
            return active
        }
        _ = openNewWindow()
        return registry.activeController
    }

    private func focusWindow(for controller: any BrowserWindowControlling) {
        registry.activateWindow(id: controller.windowID)
        if let win = registry.nsWindow(for: controller.windowID) {
            win.makeKeyAndOrderFront(nil)
        }
    }
}

