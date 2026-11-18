// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import TTZipArchiveContract
import TTZipUI

extension MediaPreviewView {
    /// Determines whether the outer floating fullscreen capsule button should be displayed.
    /// Structured documents with their own top toolbars and media players never overlay a floating top-right button.
    public var effectiveShowsFloatingFullScreenButton: Bool {
        if !showsFloatingFullScreenButton || effectiveIsImmersive { return false }
        switch previewType {
        case .image, .quickLook:
            return true
        case .pdf, .pdfData, .text, .spreadsheetTable, .audio,
             .docxDocument, .officeSpreadsheet, .officePresentation, .hexViewer,
             .video, .unsupported, .epubBook, .ebook, .htmlWeb, .markdown:
            return false
        }
    }

    /// A dedicated row keeps the window action clear of each format's own toolbar.
    public var effectiveShowsStandaloneWindowButton: Bool {
        guard showsFloatingFullScreenButton, !effectiveIsImmersive else { return false }
        switch previewType {
        case .unsupported, .video: return false
        default: return true
        }
    }

    public func toggleFullScreen() {
        isFullScreenActive.toggle()
        if let targetURL = fileURL ?? effectiveFileURL {
            TTMediaDetector.beginFullscreenEphemeralHandoff(for: targetURL)
            let resolvedContext = effectiveResourceContext
            let item = ImmersiveMediaItem(
                url: targetURL,
                name: fileName,
                sourceArchivePath: sourceArchivePath,
                archiveSubpath: archiveSubpath,
                resourceCacheKey: resourceCacheKey,
                isEditable: effectiveIsEditable,
                resourceContext: resolvedContext
            )
            var extraInfo: [String: Any] = [
                "url": targetURL,
                "name": fileName,
                "isEditable": effectiveIsEditable
            ]
            if let sourceArchivePath { extraInfo["sourceArchivePath"] = sourceArchivePath }
            if let archiveSubpath { extraInfo["archiveSubpath"] = archiveSubpath }
            if let resourceCacheKey { extraInfo["resourceCacheKey"] = resourceCacheKey }
            let userInfo = resolvedContext.toUserInfoDictionary(additional: extraInfo)
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
                object: item,
                userInfo: userInfo
            )
        } else {
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
                object: nil
            )
        }
    }

    var standaloneExpandFloatingButton: some View {
        let label = l10n.t(PreviewWindowActionLocaleKey.fullScreen)
        return PreviewCornerActionOverlayView(
            id: "PreviewStandaloneExpandButton",
            symbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityLabel: label,
            helpText: label,
            coordinator: cornerActionCoordinator,
            action: toggleFullScreen
        )
    }

    // MARK: - Comic Archive Recognition (U1-012) & F4 Immersive Identity Resolution

    /// Canonical comic archive extensions (`cbz`, `cbr`, `cb7`, `cbt`) routed into archive browsing.
    nonisolated public static let comicArchiveExtensions: Set<String> = ["cbz", "cbr", "cb7", "cbt"]

    /// Returns `true` when the candidate filename or path carries a comic archive extension.
    nonisolated public static func isComicArchiveNameOrPath(_ nameOrPath: String) -> Bool {
        let ext = (nameOrPath as NSString).pathExtension.lowercased()
        return comicArchiveExtensions.contains(ext)
    }

    public struct ResolvedImmersiveF4Identity: Sendable {
        public let archivePath: String?
        public let subpath: String?
        public let cacheKey: String?
        public let resolvedURL: URL
        public let isEditable: Bool
        public let isPhysicalComicArchive: Bool
        public let resourceContext: TTPreviewResourceContext
    }

    nonisolated public static func resolveImmersiveF4Identity(
        url: URL,
        name: String,
        selectedDiskItemPath: String?,
        currentArchivePath: String?,
        currentEntries: [ArchiveEntry],
        sourceArchivePath: String?,
        archiveSubpath: String?,
        resourceCacheKey: String?,
        explicitEditable: Bool?
    ) -> ResolvedImmersiveF4Identity {
        let meta = inferArchiveMetadata(
            url: url,
            name: name,
            selectedDiskItemPath: selectedDiskItemPath,
            currentArchivePath: currentArchivePath,
            currentEntries: currentEntries,
            sourceArchivePath: sourceArchivePath,
            archiveSubpath: archiveSubpath,
            resourceCacheKey: resourceCacheKey
        )
        let isComic = isPhysicalComicArchiveFile(url: url, name: name, meta: meta)
        let resolvedURL = resolveCachedOrStandardizedURL(url: url, name: name, meta: meta)
        let isEditable = computeImmersiveEditability(
            resolvedURL: resolvedURL,
            meta: meta,
            explicitEditable: explicitEditable
        )
        let resourceContext = makeImmersiveResourceContext(
            resolvedURL: resolvedURL,
            name: name,
            meta: meta,
            isEditable: isEditable
        )
        return ResolvedImmersiveF4Identity(
            archivePath: meta.archivePath,
            subpath: meta.subpath,
            cacheKey: meta.cacheKey,
            resolvedURL: resolvedURL,
            isEditable: isEditable,
            isPhysicalComicArchive: isComic,
            resourceContext: resourceContext
        )
    }

    nonisolated private static func isPhysicalComicArchiveFile(
        url: URL,
        name: String,
        meta: (archivePath: String?, subpath: String?, cacheKey: String?)
    ) -> Bool {
        guard meta.archivePath == nil && meta.cacheKey == nil && url.isFileURL else { return false }
        let nameExt = (name as NSString).pathExtension
        let ext = (nameExt.isEmpty ? url.pathExtension : nameExt).lowercased()
        return comicArchiveExtensions.contains(ext)
    }

    nonisolated private static func resolveCachedOrStandardizedURL(
        url: URL,
        name: String,
        meta: (archivePath: String?, subpath: String?, cacheKey: String?)
    ) -> URL {
        if let key = meta.cacheKey {
            let candidateName = meta.subpath.map { ($0 as NSString).lastPathComponent } ?? name
            if let cached = PreviewLRUCacheManager.shared.existingCachedURL(forKey: key, filename: candidateName) {
                return cached
            }
        }
        return url.isFileURL ? url.standardizedFileURL.resolvingSymlinksInPath() : url
    }

    nonisolated private static func computeImmersiveEditability(
        resolvedURL: URL,
        meta: (archivePath: String?, subpath: String?, cacheKey: String?),
        explicitEditable: Bool?
    ) -> Bool {
        if meta.archivePath != nil || meta.subpath != nil || meta.cacheKey != nil { return false }
        if !resolvedURL.isFileURL
            || resolvedURL.path.contains("/TTZipLRUPreviewCache/")
            || resolvedURL.path.contains("/TTMediaEphemeralStorage/") {
            return false
        }
        return explicitEditable ?? true
    }

    nonisolated private static func makeImmersiveResourceContext(
        resolvedURL: URL,
        name: String,
        meta: (archivePath: String?, subpath: String?, cacheKey: String?),
        isEditable: Bool
    ) -> TTPreviewResourceContext {
        if let archPath = meta.archivePath {
            let entryPath = meta.subpath ?? name
            let stagedURL = (resolvedURL.isFileURL && resolvedURL.query == nil) ? resolvedURL : nil
            return .archiveEntry(
                archivePath: archPath,
                entryPath: entryPath,
                stagedReadURL: stagedURL,
                fileName: name
            )
        }
        if resolvedURL.isFileURL && !resolvedURL.path.contains("/TTZipLRUPreviewCache/") {
            return .diskFile(url: resolvedURL, fileName: name, allowsEditing: isEditable)
        }
        return .unknown(readableURL: resolvedURL, fileName: name)
    }

    nonisolated private static func inferArchiveMetadata(
        url: URL,
        name: String,
        selectedDiskItemPath: String?,
        currentArchivePath: String?,
        currentEntries: [ArchiveEntry],
        sourceArchivePath: String?,
        archiveSubpath: String?,
        resourceCacheKey: String?
    ) -> (archivePath: String?, subpath: String?, cacheKey: String?) {
        var archPath = sourceArchivePath
        var sub = archiveSubpath
        var key = resourceCacheKey

        if let qSub = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "subpath" })?.value {
            archPath = archPath ?? url.path
            sub = sub ?? qSub
        } else if url.path.contains("/TTZipLRUPreviewCache/") {
            let inferred = inferFromCacheDirectory(
                url: url,
                selectedDiskItemPath: selectedDiskItemPath,
                currentArchivePath: currentArchivePath,
                currentEntries: currentEntries,
                existingArchive: archPath,
                existingSubpath: sub,
                existingKey: key
            )
            archPath = inferred.archivePath
            sub = inferred.subpath
            key = inferred.cacheKey
        } else if !url.isFileURL, url.scheme == "ttzip-vfs" {
            archPath = archPath ?? currentArchivePath
            let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            sub = sub ?? (trimmed.isEmpty ? name : trimmed)
        }

        if key == nil, let a = archPath, let s = sub, !a.isEmpty, !s.isEmpty {
            key = PreviewLRUCacheManager.deterministicCacheKey(archivePath: a, subpath: s)
        }
        return (archPath, sub, key)
    }

    nonisolated private static func inferFromCacheDirectory(
        url: URL,
        selectedDiskItemPath: String?,
        currentArchivePath: String?,
        currentEntries: [ArchiveEntry],
        existingArchive: String?,
        existingSubpath: String?,
        existingKey: String?
    ) -> (archivePath: String?, subpath: String?, cacheKey: String?) {
        let parentKey = url.deletingLastPathComponent().lastPathComponent
        var key = existingKey ?? ((parentKey.isEmpty || parentKey == "TTZipLRUPreviewCache") ? nil : parentKey)
        var archPath = existingArchive
        var sub = existingSubpath

        if let selPath = selectedDiskItemPath,
           let u = URL(string: selPath),
           let qSub = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "subpath" })?.value {
            let candidateKey = PreviewLRUCacheManager.deterministicCacheKey(archivePath: u.path, subpath: qSub)
            if key == nil || key == candidateKey {
                archPath = archPath ?? u.path
                sub = sub ?? qSub
                key = key ?? candidateKey
            }
        }
        if let currentArch = currentArchivePath {
            archPath = archPath ?? currentArch
            if sub == nil, let k = key {
                sub = currentEntries.first(where: {
                    PreviewLRUCacheManager.deterministicCacheKey(archivePath: currentArch, subpath: $0.path) == k
                })?.path
            }
        }
        return (archPath, sub, key)
    }

    nonisolated public static func buildArchiveMediaSiblings(
        entries: [ArchiveEntry],
        archivePath: String?,
        fallbackURL: URL
    ) -> [ImmersiveMediaItem] {
        entries.compactMap { entry in
            guard !entry.isDirectory else { return nil }
            let ext = (entry.path as NSString).pathExtension.lowercased()
            guard !MediaPreviewFactory.archiveExtensions.contains(ext) else { return nil }
            let entryName = (entry.path as NSString).lastPathComponent
            let cacheKey = archivePath.map {
                PreviewLRUCacheManager.deterministicCacheKey(archivePath: $0, subpath: entry.path)
            }
            let resolvedURL: URL = {
                if let cacheKey,
                   let cached = PreviewLRUCacheManager.shared.existingCachedURL(forKey: cacheKey, filename: entryName) {
                    return cached
                }
                return URL(string: "ttzip-vfs://entry/\(entry.path)") ?? fallbackURL
            }()
            return ImmersiveMediaItem(
                url: resolvedURL,
                name: entryName,
                fileSizeBytes: Int64(entry.uncompressedSize),
                sourceArchivePath: archivePath,
                archiveSubpath: entry.path,
                resourceCacheKey: cacheKey,
                isEditable: false
            )
        }
    }
}
