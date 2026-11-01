// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AVKit
import PDFKit
import WebKit
import TTMediaKit
import TTZipCore
import TTZipUI

private struct UsesMediaKitPreviewKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    public var usesMediaKitPreview: Bool {
        get { self[UsesMediaKitPreviewKey.self] }
        set { self[UsesMediaKitPreviewKey.self] = newValue }
    }
}

extension View {
    public func usesMediaKitPreview(_ enabled: Bool = true) -> some View {
        environment(\.usesMediaKitPreview, enabled)
    }
}

/// Media preview router and container view for native formats.
public struct MediaPreviewView: View {
    @Environment(\.isImmersiveFullscreen) private var envIsImmersiveFullscreen: Bool
    @Environment(\.usesMediaKitPreview) private var envUsesMediaKitPreview: Bool
    @Environment(\.previewBottomTrailingReservedWidth) private var envBottomTrailingReservedWidth: CGFloat
    private var l10n = AppLocalizationState.shared
    public let isImmersiveFullscreen: Bool?
    public let usesMediaKitPreview: Bool?
    public let showsFloatingFullScreenButton: Bool
    public let sourceArchivePath: String?
    public let archiveSubpath: String?
    public let resourceCacheKey: String?
    public let isEditable: Bool?
    public let resourceContext: TTPreviewResourceContext?
    public var onPreviewTypeResolved: ((MediaPreviewType) -> Void)?
    let fileURL: URL?
    let fileData: Data?
    let fileName: String
    private let hasPreResolvedPreview: Bool
    
    @State private var previewType: MediaPreviewType = .unsupported("Loading...")
    @State private var previewTask: Task<Void, Never>?
    @State private var leaseBox: TTMediaEphemeralLeaseBox
    @State private var isExtractingTemp = false
    @State private var isFullScreenActive = false
    @State private var cornerActionCoordinator = PreviewCornerActionRevealCoordinator()
    @State private var hasCompletedInitialLoad = false
    @State public private(set) var latestPipelineMetrics: TTPreviewPipelineStageMetrics? = nil
    private let detectorSessionKey = "MediaPreviewView.\(UUID().uuidString)"
    
    public init(
        fileURL: URL?,
        fileName: String,
        isImmersiveFullscreen: Bool? = nil,
        usesMediaKitPreview: Bool? = nil,
        showsFloatingFullScreenButton: Bool = true,
        sourceArchivePath: String? = nil,
        archiveSubpath: String? = nil,
        resourceCacheKey: String? = nil,
        isEditable: Bool? = nil,
        resourceContext: TTPreviewResourceContext? = nil,
        onPreviewTypeResolved: ((MediaPreviewType) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.fileData = nil
        self.fileName = fileName
        self.hasPreResolvedPreview = false
        self.isImmersiveFullscreen = isImmersiveFullscreen
        self.usesMediaKitPreview = usesMediaKitPreview
        self.showsFloatingFullScreenButton = showsFloatingFullScreenButton
        self.sourceArchivePath = sourceArchivePath ?? resourceContext?.archiveIdentity?.archivePath
        self.archiveSubpath = archiveSubpath ?? resourceContext?.archiveIdentity?.entryPath
        self.resourceCacheKey = resourceCacheKey
        self.isEditable = isEditable
        self.resourceContext = resourceContext
        self.onPreviewTypeResolved = onPreviewTypeResolved
        let initialType: MediaPreviewType
        if let url = fileURL {
            initialType = MediaPreviewFactory.fastTypeByExtension(url: url)
        } else {
            initialType = .unsupported("Select a file from the explorer to preview")
        }
        _previewType = State(initialValue: initialType)
        _leaseBox = State(initialValue: TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: initialType.ephemeralMediaURL ?? fileURL))
    }

    public init(
        fileData: Data,
        fileName: String,
        fileURL: URL? = nil,
        isImmersiveFullscreen: Bool? = nil,
        usesMediaKitPreview: Bool? = nil,
        showsFloatingFullScreenButton: Bool = true,
        sourceArchivePath: String? = nil,
        archiveSubpath: String? = nil,
        resourceCacheKey: String? = nil,
        isEditable: Bool? = nil,
        resourceContext: TTPreviewResourceContext? = nil,
        onPreviewTypeResolved: ((MediaPreviewType) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.fileData = fileData
        self.fileName = fileName
        self.hasPreResolvedPreview = true
        self.isImmersiveFullscreen = isImmersiveFullscreen
        self.usesMediaKitPreview = usesMediaKitPreview
        self.showsFloatingFullScreenButton = showsFloatingFullScreenButton
        self.sourceArchivePath = sourceArchivePath ?? resourceContext?.archiveIdentity?.archivePath
        self.archiveSubpath = archiveSubpath ?? resourceContext?.archiveIdentity?.entryPath
        self.resourceCacheKey = resourceCacheKey
        self.isEditable = isEditable
        self.resourceContext = resourceContext
        self.onPreviewTypeResolved = onPreviewTypeResolved
        let initialType = MediaPreviewFactory.detectTypeFromMemory(
            data: fileData,
            suggestedName: fileName,
            sourceURL: fileURL
        )
        _previewType = State(initialValue: initialType)
        _leaseBox = State(initialValue: TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: initialType.ephemeralMediaURL ?? fileURL))
    }

    public init(
        previewType: MediaPreviewType,
        fileName: String,
        fileURL: URL? = nil,
        isImmersiveFullscreen: Bool? = nil,
        usesMediaKitPreview: Bool? = nil,
        showsFloatingFullScreenButton: Bool = true,
        sourceArchivePath: String? = nil,
        archiveSubpath: String? = nil,
        resourceCacheKey: String? = nil,
        isEditable: Bool? = nil,
        resourceContext: TTPreviewResourceContext? = nil,
        onPreviewTypeResolved: ((MediaPreviewType) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.fileData = nil
        self.fileName = fileName
        self.hasPreResolvedPreview = true
        self.isImmersiveFullscreen = isImmersiveFullscreen
        self.usesMediaKitPreview = usesMediaKitPreview
        self.showsFloatingFullScreenButton = showsFloatingFullScreenButton
        self.sourceArchivePath = sourceArchivePath ?? resourceContext?.archiveIdentity?.archivePath
        self.archiveSubpath = archiveSubpath ?? resourceContext?.archiveIdentity?.entryPath
        self.resourceCacheKey = resourceCacheKey
        self.isEditable = isEditable
        self.resourceContext = resourceContext
        self.onPreviewTypeResolved = onPreviewTypeResolved
        _previewType = State(initialValue: previewType)
        _leaseBox = State(initialValue: TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: previewType.ephemeralMediaURL ?? fileURL))
    }
    
    private var effectiveIsImmersive: Bool {
        isImmersiveFullscreen ?? envIsImmersiveFullscreen
    }

    private var effectiveUsesMediaKit: Bool {
        usesMediaKitPreview ?? envUsesMediaKitPreview
    }

    /// Evaluates whether the previewed resource originates from an archive container or ephemeral staging cache.
    public var effectiveIsFromArchive: Bool {
        if resourceContext?.isArchiveEntry == true || sourceArchivePath != nil || archiveSubpath != nil {
            return true
        }
        guard let url = fileURL else { return false }
        if !url.isFileURL { return true }
        if let query = url.query, query.contains("subpath=") { return true }
        return SpreadsheetTablePreviewView.isArchiveOrEphemeralStagingURL(url)
    }

    /// Evaluates whether the previewed resource permits in-place editing and disk writeback.
    /// Archive entries and ephemeral staged files are strictly read-only (`false`).
    public var effectiveIsEditable: Bool {
        if effectiveIsFromArchive {
            return false
        }
        if let context = resourceContext {
            return context.isEditableInPlace
        }
        if let explicit = isEditable {
            return explicit
        }
        guard let url = fileURL, url.isFileURL else { return false }
        let rawExt = (fileName as NSString).pathExtension.isEmpty ? url.pathExtension : (fileName as NSString).pathExtension
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: rawExt)
        let canEditFormat = TTMediaCapabilityMatrix.descriptor(for: ext)?.isEditableSource ?? false
        return canEditFormat && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// Canonical F4 `TTPreviewResourceContext` resolved for this preview view.
    public var effectiveResourceContext: TTPreviewResourceContext {
        if let resourceContext {
            return resourceContext
        }
        if let archPath = sourceArchivePath {
            let entryPath = archiveSubpath ?? fileName
            let stagedURL = (fileURL?.isFileURL == true && fileURL?.query == nil) ? fileURL : nil
            return .archiveEntry(
                archivePath: archPath,
                entryPath: entryPath,
                stagedReadURL: stagedURL,
                fileName: fileName
            )
        }
        if effectiveIsFromArchive {
            return .unknown(readableURL: fileURL, fileName: fileName)
        }
        if let url = fileURL, url.isFileURL {
            return .diskFile(url: url, fileName: fileName, allowsEditing: effectiveIsEditable)
        }
        return .unknown(readableURL: fileURL, fileName: fileName)
    }

    /// Checks whether the target file is eligible for direct TTMediaPreview rendering.
    private var isMediaKitEligible: Bool {
        guard let url = effectiveFileURL ?? fileURL else { return false }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3", "wav", "aac", "flac", "m4a", "ogg", "opus", "aiff",
             "csv", "tsv",
             "md", "markdown", "txt", "rtf", "json", "yaml", "yml", "xml", "swift", "rs", "toml", "log", "c", "cpp", "h", "py", "js", "ts",
             "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg":
            return true
        default:
            return false
        }
    }
    
    /// Sanitized file URL passed down to child preview views.
    /// Prevents passing disk file URLs for converted documents (such as DOCX converted to Markdown)
    /// or read-only archive staged files, blocking accidental writeback to temporary cache files.
    private var effectiveFileURL: URL? {
        switch previewType {
        case .video(let targetURL), .audio(let targetURL), .quickLook(let targetURL):
            return targetURL
        case .markdown(_, let targetURL):
            return effectiveIsEditable ? targetURL : nil
        case .htmlWeb(_, let targetURL):
            return effectiveIsEditable ? (targetURL ?? fileURL) : nil
        case .text, .spreadsheetTable:
            return effectiveIsEditable ? fileURL : nil
        default:
            return fileURL
        }
    }

    /// Preview type adjusted for read-only archive/permission constraints so document editors do not treat staged cache files as writable.
    private var effectivePreviewTypeForRendering: MediaPreviewType {
        guard !effectiveIsEditable else { return previewType }
        switch previewType {
        case .markdown(let text, _):
            return .markdown(text, nil)
        case .htmlWeb(let content, _):
            return .htmlWeb(content: content, fileURL: nil)
        case .spreadsheetTable(let csv, _):
            return .spreadsheetTable(csv, nil)
        default:
            return previewType
        }
    }

    /// Determines whether the outer floating fullscreen capsule button should be displayed.
    /// Structured documents with their own top toolbars and media players never overlay a floating top-right button.
    public var effectiveShowsFloatingFullScreenButton: Bool {
        if !showsFloatingFullScreenButton || effectiveIsImmersive { return false }
        switch previewType {
        case .image, .quickLook:
            return true
        case .pdf, .pdfData, .text, .spreadsheetTable, .audio,
             .docxDocument, .officeSpreadsheet, .officePresentation, .hexViewer,
             .video, .unsupported, .pluginView, .epubBook, .ebook, .htmlWeb, .markdown:
            return false
        }
    }
    
    /// A dedicated row keeps the window action clear of each format's own toolbar.
    public var effectiveShowsStandaloneWindowButton: Bool {
        guard showsFloatingFullScreenButton, !effectiveIsImmersive else { return false }
        switch previewType {
        case .unsupported, .pluginView, .video: return false
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
    
    public var body: some View {
        let _ = PreviewPlaybackPersistence.prepare(url: fileURL ?? effectiveFileURL, context: effectiveResourceContext)
        let readerIdentity = PreviewReadingIdentity.resolve(context: effectiveResourceContext, fallbackURL: fileURL)
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            
            if effectiveUsesMediaKit && isMediaKitEligible, let targetURL = fileURL ?? effectiveFileURL {
                TTMediaPreview(url: targetURL, title: fileName, resourceContext: effectiveResourceContext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TTMediaPreviewFactory.makePreviewView(
                    type: effectivePreviewTypeForRendering,
                    fileName: fileName,
                    fileURL: effectiveFileURL,
                    resourceContext: effectiveResourceContext,
                    isFullScreenActive: effectiveIsImmersive || isFullScreenActive
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            if effectiveShowsStandaloneWindowButton {
                standaloneExpandFloatingButton
            }
        }
        .environment(\.isImmersiveFullscreen, effectiveIsImmersive)
        .environment(
            \.previewBottomTrailingReservedWidth,
            effectiveShowsStandaloneWindowButton ? 34.0 : envBottomTrailingReservedWidth
        )
        .environment(\.epubReaderPersistence, readerAdapter(identity: readerIdentity))
        .environment(\.epubReaderDocumentIdentity, readerIdentity)
        .onAppear {
            leaseBox.bind(
                previewType: previewType,
                fallbackURL: fileURL,
                consumeFullscreenHandoff: effectiveIsImmersive || isFullScreenActive
            )
            onPreviewTypeResolved?(previewType)
        }
        .task(id: fileURL) {
            loadPreview()
        }
        .onChange(of: fileURL) { _, newURL in
            if let newURL = newURL {
                replacePreviewType(with: MediaPreviewFactory.fastTypeByExtension(url: newURL), fallbackURL: newURL)
            } else if !hasPreResolvedPreview {
                replacePreviewType(
                    with: .unsupported("Select a file from the explorer to preview"),
                    fallbackURL: nil
                )
            }
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            if effectiveIsImmersive, let url = fileURL ?? effectiveFileURL {
                TTMediaDetector.endFullscreenEphemeralHandoff(for: url)
            }
            leaseBox.release()
        }
    }
    
    private var standaloneExpandFloatingButton: some View {
        let label = l10n.t(L10n.Preview.fullScreen)
        return PreviewCornerActionOverlayView(
            id: "PreviewStandaloneExpandButton",
            symbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityLabel: label,
            helpText: label,
            coordinator: cornerActionCoordinator,
            action: toggleFullScreen
        )
    }

    private func readerAdapter(identity: String?) -> EPUBReaderPersistence? {
        switch previewType {
        case .epubBook, .ebook:
            return identity == nil ? ReaderPersistenceBridge.unidentifiedSourceAdapter : ReaderPersistenceBridge.applicationAdapter
        default: return nil
        }
    }

    /// Acquires a distinct consumer lease for an independent player window BEFORE the caller
    /// releases or switches its own preview lease (acquire-before-release handoff).
    public func retainIndependentPlayerLease() -> TTMediaEphemeralLeaseBox {
        leaseBox.retainForIndependentPlayer(for: previewType.ephemeralMediaURL ?? fileURL ?? effectiveFileURL)
    }

    private func replacePreviewType(with newType: MediaPreviewType, fallbackURL: URL?) {
        self.previewType = newType
        leaseBox.bind(
            previewType: newType,
            fallbackURL: fallbackURL,
            consumeFullscreenHandoff: effectiveIsImmersive || isFullScreenActive
        )
        onPreviewTypeResolved?(newType)
    }

    private func isDefinitelyResolvedFastRoute(_ type: MediaPreviewType, for targetURL: URL) -> Bool {
        let targetStd = targetURL.standardizedFileURL
        switch type {
        case .video(let u), .audio(let u), .pdf(let u), .quickLook(let u):
            return u.standardizedFileURL == targetStd
        default:
            return false
        }
    }
    
    private func loadPreview() {
        previewTask?.cancel()
        if hasPreResolvedPreview && fileURL == nil {
            hasCompletedInitialLoad = true
            leaseBox.bind(
                previewType: previewType,
                fallbackURL: nil,
                consumeFullscreenHandoff: effectiveIsImmersive || isFullScreenActive
            )
            onPreviewTypeResolved?(previewType)
            return
        }
        guard let targetURL = fileURL else {
            replacePreviewType(
                with: .unsupported("Select a file from the explorer to preview"),
                fallbackURL: nil
            )
            return
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let isArchiveDerived = effectiveIsFromArchive || effectiveResourceContext.isArchiveEntry
        if isDefinitelyResolvedFastRoute(previewType, for: targetURL) {
            hasCompletedInitialLoad = true
            applyDetectedPreviewType(previewType, targetURL: targetURL)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000.0
            latestPipelineMetrics = TTPreviewPipelineStageMetrics(
                fileURLPath: targetURL.path,
                scheduleWaitMs: 0,
                detectionMs: elapsedMs,
                firstFrameMs: elapsedMs,
                isArchiveSource: isArchiveDerived,
                isWarmCacheHit: true,
                usedFastExtensionRoute: true
            )
            return
        }
        let shouldDebounce = hasCompletedInitialLoad && !effectiveIsImmersive && !isFullScreenActive
        previewTask = Task { @MainActor in
            await executeAsyncDetectionPipeline(
                targetURL: targetURL,
                t0: t0,
                isArchiveDerived: isArchiveDerived,
                shouldDebounce: shouldDebounce
            )
        }
    }

    @MainActor
    private func executeAsyncDetectionPipeline(
        targetURL: URL,
        t0: UInt64,
        isArchiveDerived: Bool,
        shouldDebounce: Bool
    ) async {
        if shouldDebounce {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let scheduleWaitMs = Double(t1 &- t0) / 1_000_000.0
        guard let deepType = await TTMediaBackgroundDetector.shared.detectLatest(
            url: targetURL,
            sessionKey: detectorSessionKey
        ) else {
            return
        }
        let t2 = DispatchTime.now().uptimeNanoseconds
        let detectionMs = Double(t2 &- t1) / 1_000_000.0
        guard !Task.isCancelled, self.fileURL == targetURL else {
            deepType.releaseEphemeralMediaLease()
            return
        }
        hasCompletedInitialLoad = true
        applyDetectedPreviewType(deepType, targetURL: targetURL)
        let t3 = DispatchTime.now().uptimeNanoseconds
        latestPipelineMetrics = TTPreviewPipelineStageMetrics(
            fileURLPath: targetURL.path,
            scheduleWaitMs: scheduleWaitMs,
            detectionMs: detectionMs,
            rendererCreationMs: Double(t3 &- t2) / 1_000_000.0,
            firstFrameMs: Double(t3 &- t0) / 1_000_000.0,
            isArchiveSource: isArchiveDerived,
            isWarmCacheHit: detectionMs < 0.25
        )
    }

    private func applyDetectedPreviewType(_ deepType: MediaPreviewType, targetURL: URL) {
        switch (self.previewType, deepType) {
        case (.video(let oldU), .video(let newU)) where oldU == newU,
             (.audio(let oldU), .audio(let newU)) where oldU == newU,
             (.pdf(let oldU), .pdf(let newU)) where oldU == newU,
             (.quickLook(let oldU), .quickLook(let newU)) where oldU == newU:
            leaseBox.bind(
                previewType: deepType,
                fallbackURL: targetURL,
                consumeFullscreenHandoff: effectiveIsImmersive || isFullScreenActive
            )
            onPreviewTypeResolved?(deepType)
        default:
            replacePreviewType(with: deepType, fallbackURL: targetURL)
        }
    }

    nonisolated public static func readTextContent(from url: URL) -> String? {
        PreviewContentReader.readTextContent(from: url)
    }
    
    nonisolated public static func decodeText(data: Data) -> String? {
        PreviewContentReader.decodeText(data: data)
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
