// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI

@MainActor
extension AppViewState {
    @discardableResult
    public func openStandaloneMediaIfSupported(
        url: URL, name: String, fileSizeBytes: Int64? = nil,
        sourceArchivePath: String? = nil, archiveSubpath: String? = nil,
        resourceCacheKey: String? = nil, isEditable: Bool? = nil
    ) -> Bool {
        if openStandalonePlaybackIfVideo(url: url, name: name, fileSizeBytes: fileSizeBytes,
            sourceArchivePath: sourceArchivePath, archiveSubpath: archiveSubpath,
            resourceCacheKey: resourceCacheKey, isEditable: isEditable) { return true }
        let identity = MediaPreviewView.resolveImmersiveF4Identity(
            url: url, name: name, selectedDiskItemPath: selectionState.selectedDiskItem?.path,
            currentArchivePath: explorerState.currentArchivePath,
            currentEntries: explorerState.currentEntries, sourceArchivePath: sourceArchivePath,
            archiveSubpath: archiveSubpath, resourceCacheKey: resourceCacheKey,
            explicitEditable: isEditable)
        guard !identity.isPhysicalComicArchive else { return false }
        let item = ImmersiveMediaItem(url: identity.resolvedURL, name: name, fileSizeBytes: fileSizeBytes,
            sourceArchivePath: identity.archivePath, archiveSubpath: identity.subpath,
            resourceCacheKey: identity.cacheKey, isEditable: identity.isEditable,
            resourceContext: identity.resourceContext)
        let shouldCreateWindow = BrowserWindowRegistry.shared.controller(for: windowID) != nil
        Task { @MainActor in
            let opened = await StandalonePreviewWindowManager.shared.open(
                item: item,
                originWindowID: windowID,
                resourceContext: identity.resourceContext,
                createAppKitWindow: shouldCreateWindow
            )
            if !opened, !isWindowClosing {
                reportFileActivationFailure(
                    message: AppLocalizationState.shared.t(L10n.Preview.cannotPreviewFormat),
                    code: "ERR_PREVIEW_OPEN_FAILED",
                    details: item.url.path
                )
            }
        }
        return true
    }

    /// Canonical check for whether TTZip's incoming file receiver supports opening a plain local file
    /// in a standalone immersive full window (video player or standalone preview host) based on `TTMediaCapabilityMatrix`.
    public static func isSupportedIncomingStandaloneFile(url: URL, name: String? = nil) -> Bool {
        let resolvedName = name ?? url.lastPathComponent
        let probeItem = ImmersiveMediaItem(url: url, name: resolvedName)
        if StandalonePlaybackWindowManager.isVideoItem(probeItem) {
            return true
        }
        let rawExt = (resolvedName as NSString).pathExtension.isEmpty
            ? url.pathExtension
            : (resolvedName as NSString).pathExtension
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: rawExt)
        guard let descriptor = TTMediaCapabilityMatrix.descriptor(for: ext) else {
            return false
        }
        return !descriptor.capabilities.contains(.archiveBrowse)
    }

    /// Reports a file activation or preview failure through both the visible error sheet (`AppErrorReporter`)
    /// and `taskState.statusMessage`.
    public func reportFileActivationFailure(
        title: String? = nil,
        message: String,
        code: String = "ERR_FILE_OPEN_FAILED",
        details: String? = nil
    ) {
        let l10n = AppLocalizationState.shared
        let resolvedTitle = title ?? l10n.uiString(zh: "无法打开文件", en: "Unable to Open File")
        taskState.statusMessage = message
        AppErrorReporter.shared.reportError(
            title: resolvedTitle,
            message: message,
            code: code,
            details: details
        )
    }

    /// Opens a physical local disk file (or `.app` application bundle) with its system-associated default application
    /// via the injectable `fileViewer` (Outgoing Request Layer).
    /// Rejects virtual archive URLs (`?subpath=`) and missing files with a visible error.
    @discardableResult
    public func openFileWithDefaultApp(url: URL) -> Bool {
        let l10n = AppLocalizationState.shared
        guard url.isFileURL,
              url.scheme != "ttzip",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .contains(where: { $0.name == "subpath" }) != true else {
            let msg = l10n.uiString(
                zh: "虚拟归档条目不能直接作为本地磁盘文件打开。",
                en: "Virtual archive entries cannot be opened directly as local disk files."
            )
            reportFileActivationFailure(message: msg, code: "ERR_VIRTUAL_PATH_REJECTED", details: url.absoluteString)
            return false
        }
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            let msg = l10n.uiString(
                zh: "找不到文件“\(standardized.lastPathComponent)”。",
                en: "The file \"\(standardized.lastPathComponent)\" could not be found."
            )
            reportFileActivationFailure(message: msg, code: "ERR_FILE_NOT_FOUND", details: standardized.path)
            return false
        }
        let scopeLease = RootFolderAccessManager.shared.acquireLease(for: standardized)
        defer { scopeLease?.release() }
        guard fileViewer.openFile(at: standardized) else {
            let msg = l10n.uiString(
                zh: "系统无法使用默认应用程序打开“\(standardized.lastPathComponent)”。",
                en: "macOS could not open \"\(standardized.lastPathComponent)\" with the default application."
            )
            reportFileActivationFailure(message: msg, code: "ERR_FILE_OPEN_FAILED", details: standardized.path)
            return false
        }
        return true
    }

    /// Canonical double-click activation dispatcher for Miller column and Explorer file items.
    /// - Ordinary directories (`isBrowsableDirectory == true`) are handled by column navigation before reaching here.
    /// - Local `.app` application bundles (`isApplicationBundle == true`) and all physical non-archive local files
    ///   (including images, videos, text, PDFs, `.command` scripts) uniformly dispatch through `openFileWithDefaultApp(url:)`.
    /// - Navigable archives continue Miller column archive-as-folder navigation idempotently.
    /// - Virtual archive file entries (`?subpath=...`) materialize and open in-app read-only standalone preview/playback.
    @discardableResult
    public func activateExplorerItem(
        _ item: DiskItemInfo,
        createAppKitWindow: Bool? = nil,
        cacheManager: PreviewLRUCacheManager = .shared,
        customExtractor: VirtualEntryExtractor? = nil
    ) async -> Bool {
        guard !item.isEncryptedLockItem, !item.isBrowsableDirectory else { return false }
        if let virtualTarget = Self.parseVirtualArchivePath(item.path) {
            return await activateVirtualArchiveFileEntry(
                item: item,
                archivePath: virtualTarget.archivePath,
                subpath: virtualTarget.subpath,
                createAppKitWindow: createAppKitWindow,
                cacheManager: cacheManager,
                customExtractor: customExtractor
            )
        }
        let physicalURL = Self.resolvePhysicalFileURL(from: item.path)
        if !item.isApplicationBundle,
           ((item.isArchive && item.taxonomy.isNavigableContainer)
            || MediaPreviewView.isComicArchiveNameOrPath(item.name)) {
            if explorerState.acceptedArchiveProjection(
                for: navigationState.activeSessionID, archivePath: physicalURL.path
            ) == nil {
                openArchiveAsFolder(url: physicalURL)
            }
            return true
        }
        return openFileWithDefaultApp(url: physicalURL)
    }

    @discardableResult
    public func receiveExternalFileInWindow(_ fileURL: URL) -> Task<Bool, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.receiveExternalOpenFile(url: fileURL)
        }
    }

    /// Incoming TTZip file receiver handler (Incoming Handling Layer).
    /// Invoked when macOS routes a file to TTZip (because TTZip is the default handler for that format,
    /// or via Finder "Open With TTZip" / Drag-to-Dock).
    /// Opens supported formats in a standalone immersive full window (`StandalonePlaybackWindowManager` or
    /// `StandalonePreviewWindowManager`) and NEVER calls `openFileWithDefaultApp` / `fileViewer.openFile`,
    /// guaranteeing zero self-recursion.
    @discardableResult
    public func receiveExternalOpenFile(
        url: URL,
        createAppKitWindow: Bool? = nil,
        cacheManager: PreviewLRUCacheManager = .shared
    ) async -> Bool {
        let l10n = AppLocalizationState.shared
        guard url.isFileURL,
              url.scheme != "ttzip",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .contains(where: { $0.name == "subpath" }) != true else {
            reportFileActivationFailure(
                message: l10n.t(L10n.Preview.cannotPreviewFormat),
                code: "ERR_EXTERNAL_OPEN_INVALID_URL",
                details: url.absoluteString
            )
            return false
        }
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir), !isDir.boolValue else {
            let msg = l10n.uiString(
                zh: "找不到文件“\(standardized.lastPathComponent)”。",
                en: "The file \"\(standardized.lastPathComponent)\" could not be found."
            )
            reportFileActivationFailure(message: msg, code: "ERR_FILE_NOT_FOUND", details: standardized.path)
            return false
        }
        let diskItem = DiskItemInfo(url: standardized)
        guard Self.isSupportedIncomingStandaloneFile(url: standardized, name: diskItem.name) else {
            let msg = l10n.uiString(
                zh: "TTZip 不支持直接预览或打开“\(diskItem.displayName)”的格式。",
                en: "TTZip does not support opening \"\(diskItem.displayName)\" directly."
            )
            reportFileActivationFailure(message: msg, code: "ERR_UNSUPPORTED_INCOMING_FORMAT", details: standardized.path)
            return false
        }
        return await openReceivedStandaloneFile(
            item: diskItem,
            url: standardized,
            createAppKitWindow: createAppKitWindow,
            cacheManager: cacheManager
        )
    }

    private func openReceivedStandaloneFile(
        item: DiskItemInfo,
        url: URL,
        createAppKitWindow: Bool?,
        cacheManager: PreviewLRUCacheManager
    ) async -> Bool {
        let l10n = AppLocalizationState.shared
        let shouldCreateWindow = createAppKitWindow ?? true
        let size = item.fileSizeBytes ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        let mediaItem = ImmersiveMediaItem(
            url: url,
            name: item.displayName,
            fileSizeBytes: size,
            isEditable: true,
            resourceContext: .diskFile(url: url, fileName: item.displayName, allowsEditing: true)
        )
        if StandalonePlaybackWindowManager.isVideoItem(mediaItem) {
            let session = await StandalonePlaybackWindowManager.shared.openOrFocus(
                item: mediaItem,
                originBrowserWindowID: windowID,
                originSelectedItem: item,
                originDirectoryURL: navigationState.currentDirectory,
                originArchivePath: explorerState.currentArchivePath,
                createAppKitWindow: shouldCreateWindow,
                cacheManager: cacheManager
            )
            guard session != nil else {
                reportFileActivationFailure(
                    message: l10n.t(L10n.Preview.cannotPreviewFormat),
                    code: "ERR_PLAYBACK_OPEN_FAILED",
                    details: url.path
                )
                return false
            }
            return true
        }
        let opened = await StandalonePreviewWindowManager.shared.open(
            item: mediaItem,
            originWindowID: windowID,
            resourceContext: mediaItem.resourceContext,
            createAppKitWindow: shouldCreateWindow,
            cacheManager: cacheManager
        )
        guard opened else {
            reportFileActivationFailure(
                message: l10n.t(L10n.Preview.cannotPreviewFormat),
                code: "ERR_PREVIEW_OPEN_FAILED",
                details: url.path
            )
            return false
        }
        return true
    }

    private func activateVirtualArchiveFileEntry(
        item: DiskItemInfo,
        archivePath: String,
        subpath: String,
        createAppKitWindow: Bool?,
        cacheManager: PreviewLRUCacheManager,
        customExtractor: VirtualEntryExtractor?
    ) async -> Bool {
        let l10n = AppLocalizationState.shared
        guard !archivePath.isEmpty, !subpath.isEmpty else {
            reportFileActivationFailure(
                message: l10n.t(L10n.Preview.cannotPreviewFormat),
                code: "ERR_INVALID_VIRTUAL_ENTRY",
                details: item.path
            )
            return false
        }
        if selectionState.selectedDiskItem?.path != item.path {
            selectionState.select(item)
        }
        selectArchiveEntry(path: subpath, inArchive: archivePath)
        let request = captureArchiveEntryPreviewRequest(itemPath: item.path)
        let passwordRequiredWithoutCache = request.map {
            requiresPasswordForArchiveEntryPreview($0)
        } ?? false
        let archiveLease = RootFolderAccessManager.shared.acquireLease(for: URL(fileURLWithPath: archivePath))
        defer { archiveLease?.release() }

        let resolved = await Self.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: subpath,
            estimatedBytes: item.rawSizeBytes,
            consumerID: UUID(),
            previousLease: nil,
            cacheManager: cacheManager,
            passwordRequiredWithoutCache: passwordRequiredWithoutCache,
            customExtractor: customExtractor
        )
        if let failure = resolved.failure {
            return handleVirtualEntryActivationFailure(failure, request: request, archivePath: archivePath, itemPath: item.path)
        }
        guard let stagedURL = resolved.url, let stagedLease = resolved.lease else {
            reportFileActivationFailure(
                message: l10n.t(L10n.Preview.cannotPreviewFormat),
                code: "ERR_VIRTUAL_MATERIALIZATION_FAILED",
                details: item.path
            )
            return false
        }
        return await openMaterializedVirtualEntry(
            item: item,
            stagedURL: stagedURL,
            stagedLease: stagedLease,
            archivePath: archivePath,
            subpath: subpath,
            createAppKitWindow: createAppKitWindow,
            cacheManager: cacheManager
        )
    }

    private func handleVirtualEntryActivationFailure(
        _ failure: ArchiveEntryPreviewFailure,
        request: ArchiveEntryPreviewRequest?,
        archivePath: String,
        itemPath: String
    ) -> Bool {
        let l10n = AppLocalizationState.shared
        if failure == .cancelled { return false }
        if case .archive(let archiveError, let attempted) = failure, archiveError.isPasswordRelated {
            if let request {
                acceptArchiveEntryPreviewFailure(failure, request: request)
            }
            if pendingPasswordContext == nil {
                stagePasswordPromptContext(archivePath: archivePath, kind: .browse, failedPassword: attempted)
            }
            taskState.statusMessage = l10n.t(L10n.Errors.passwordRequired)
            return false
        }
        reportFileActivationFailure(
            message: l10n.t(L10n.Preview.cannotPreviewFormat),
            code: "ERR_VIRTUAL_EXTRACTION_FAILED",
            details: itemPath
        )
        return false
    }

    private func openMaterializedVirtualEntry(
        item: DiskItemInfo,
        stagedURL: URL,
        stagedLease: PreviewCacheLease,
        archivePath: String,
        subpath: String,
        createAppKitWindow: Bool?,
        cacheManager: PreviewLRUCacheManager
    ) async -> Bool {
        let l10n = AppLocalizationState.shared
        let shouldCreateWindow = createAppKitWindow ?? (BrowserWindowRegistry.shared.controller(for: windowID) != nil)
        let mediaItem = ImmersiveMediaItem(
            url: stagedURL,
            name: item.displayName,
            fileSizeBytes: item.fileSizeBytes,
            sourceArchivePath: archivePath,
            archiveSubpath: subpath,
            resourceCacheKey: stagedLease.key,
            isEditable: false,
            resourceContext: .archiveEntry(
                archivePath: archivePath,
                entryPath: subpath,
                stagedReadURL: stagedURL,
                fileName: item.displayName
            )
        )
        if StandalonePlaybackWindowManager.isVideoItem(mediaItem) {
            let session = await StandalonePlaybackWindowManager.shared.openOrFocus(
                item: mediaItem,
                originBrowserWindowID: windowID,
                originSelectedItem: item,
                originDirectoryURL: navigationState.currentDirectory,
                originArchivePath: archivePath,
                createAppKitWindow: shouldCreateWindow,
                cacheManager: cacheManager
            )
            await cacheManager.releaseLease(stagedLease)
            guard session != nil else {
                reportFileActivationFailure(
                    message: l10n.t(L10n.Preview.cannotPreviewFormat),
                    code: "ERR_VIRTUAL_PLAYBACK_OPEN_FAILED",
                    details: item.path
                )
                return false
            }
            return true
        }
        let opened = await StandalonePreviewWindowManager.shared.open(
            item: mediaItem,
            originWindowID: windowID,
            resourceContext: mediaItem.resourceContext,
            createAppKitWindow: shouldCreateWindow,
            cacheManager: cacheManager
        )
        await cacheManager.releaseLease(stagedLease)
        guard opened else {
            reportFileActivationFailure(
                message: l10n.t(L10n.Preview.cannotPreviewFormat),
                code: "ERR_VIRTUAL_PREVIEW_OPEN_FAILED",
                details: item.path
            )
            return false
        }
        return true
    }

    public static func parseVirtualArchivePath(_ rawPath: String) -> (archivePath: String, subpath: String)? {
        guard let url = URL(string: rawPath),
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let subpath = comp.queryItems?.first(where: { $0.name == "subpath" })?.value else {
            return nil
        }
        let archivePath = url.path.isEmpty ? rawPath : url.path
        return (archivePath, subpath)
    }

    private static func resolvePhysicalFileURL(from rawPath: String) -> URL {
        if rawPath.hasPrefix("file://"), let parsed = URL(string: rawPath), parsed.isFileURL {
            return parsed.standardizedFileURL.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
    }
}
