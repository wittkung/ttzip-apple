// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AVKit
import PDFKit
import WebKit
import class TTI18nUI.LocalizationState
import TTMediaKit
import TTZipUI

public extension Notification.Name {
    static let ttZipVideoFullscreenRequested = Notification.Name("TTMediaToggleMediaFocusNotification")
}

/// Media preview router and container view for native formats.
public struct MediaPreviewView: View {
    @Environment(\.isImmersiveFullscreen) private var envIsImmersiveFullscreen: Bool
    @Environment(\.previewBottomTrailingReservedWidth) private var envBottomTrailingReservedWidth: CGFloat
    var l10n = LocalizationState.shared
    public let isImmersiveFullscreen: Bool?
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
    
    @State var previewType: MediaPreviewType = .unsupported("Loading...")
    @State private var previewTask: Task<Void, Never>?
    @State private var leaseBox: TTMediaEphemeralLeaseBox
    @State private var isExtractingTemp = false
    @State var isFullScreenActive = false
    @State var cornerActionCoordinator = PreviewCornerActionRevealCoordinator()
    @State private var hasCompletedInitialLoad = false
    @State public private(set) var latestPipelineMetrics: TTPreviewPipelineStageMetrics? = nil
    private let detectorSessionKey = "MediaPreviewView.\(UUID().uuidString)"
    
    public init(
        fileURL: URL?,
        fileName: String,
        isImmersiveFullscreen: Bool? = nil,
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
    
    var effectiveIsImmersive: Bool {
        isImmersiveFullscreen ?? envIsImmersiveFullscreen
    }

    /// Evaluates whether the previewed resource originates from an archive container or ephemeral staging cache.
    public var effectiveIsFromArchive: Bool {
        PreviewStagingPolicy.isArchiveBacked(
            fileURL,
            context: resourceContext,
            hasArchiveIdentity: sourceArchivePath != nil || archiveSubpath != nil
        )
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
            return PreviewStagingPolicy.restrictDiskWriteBack(resourceContext, archiveBacked: effectiveIsFromArchive)
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

    /// Sanitized file URL passed down to child preview views.
    /// Prevents passing disk file URLs for converted documents (such as DOCX converted to Markdown)
    /// or read-only archive staged files, blocking accidental writeback to temporary cache files.
    var effectiveFileURL: URL? {
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

    var resolvedMarkdownPreview: TTZipMarkdownPreviewView? {
        guard case .markdown(let markdown, let targetURL) = effectivePreviewTypeForRendering else {
            return nil
        }
        let context = effectiveResourceContext
        return TTZipMarkdownPreviewView(
            initialMarkdown: markdown,
            fileURL: context.readableURL ?? targetURL ?? effectiveFileURL,
            fileName: fileName,
            resourceContext: context
        )
    }

    public var body: some View {
        let _ = PreviewPlaybackPersistence.prepare(url: fileURL ?? effectiveFileURL, context: effectiveResourceContext)
        let readerIdentity = PreviewReadingIdentity.resolve(context: effectiveResourceContext, fallbackURL: fileURL)
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            
            if case .epubBook(let bookModel) = effectivePreviewTypeForRendering {
                // The EPUB workspace chrome belongs to the product. TTMediaKit renders the
                // document surface and owns the reading engine behind the session.
                EPUBReaderPreviewView(bookModel: bookModel)
                    .id(bookModel.url.absoluteString)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .image(let image) = effectivePreviewTypeForRendering {
                ImagePreviewView(image: image, fallbackURL: effectiveFileURL)
                    .id(ImagePreviewView.Identity(image: ObjectIdentifier(image), fallbackURL: effectiveFileURL))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .pdf(let url) = effectivePreviewTypeForRendering {
                TTZipPDFPreviewView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.previewResourceContext, effectiveResourceContext)
            } else if case .pdfData(let data, let url) = effectivePreviewTypeForRendering {
                TTZipPDFPreviewView(data: data, url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.previewResourceContext, effectiveResourceContext)
            } else if case .hexViewer(let data, let targetURL) = effectivePreviewTypeForRendering {
                TTZipHexPreviewView(
                    data: data,
                    fileURL: targetURL ?? effectiveResourceContext.readableURL ?? effectiveFileURL,
                    fileName: fileName
                )
                .environment(\.previewResourceContext, effectiveResourceContext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resolvedMarkdownPreview {
                resolvedMarkdownPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .spreadsheetTable(let content, let targetURL) = effectivePreviewTypeForRendering {
                let context = effectiveIsEditable ? effectiveResourceContext : effectiveResourceContext.forcingReadOnly()
                TTZipSpreadsheetPreviewView(
                    content: content,
                    fileURL: context.readableURL ?? targetURL ?? effectiveFileURL,
                    fileName: fileName,
                    resourceContext: context
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .officeSpreadsheet(let workbook) = effectivePreviewTypeForRendering {
                let context = TTPreviewResourceContext.resolvingPreview(
                    explicitContext: effectiveResourceContext,
                    type: .officeSpreadsheet(workbook),
                    fileName: fileName,
                    fileURL: effectiveFileURL
                )
                TTZipSpreadsheetPreviewView(workbook: workbook, resourceContext: context)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .docxDocument(let content, let url) = effectivePreviewTypeForRendering {
                DocxTextEditorNSView(attributedString: content, fileURL: url)
                    .environment(\.previewResourceContext, effectiveResourceContext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .officePresentation(let model) = effectivePreviewTypeForRendering {
                let context = TTPreviewResourceContext.resolvingPreview(
                    explicitContext: effectiveResourceContext,
                    type: .officePresentation(model),
                    fileName: fileName,
                    fileURL: effectiveFileURL
                )
                TTZipPresentationPreviewView(model: model)
                    .environment(\.previewResourceContext, context)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .ebook(let metadata) = effectivePreviewTypeForRendering {
                let context = resourceContext == nil && fileURL == nil && fileData == nil && !effectiveIsFromArchive
                    ? .unknown(readableURL: metadata.url, fileName: fileName)
                    : effectiveResourceContext
                TTZipEBookInspectionView(metadata: metadata, resourceContext: context)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .video(let url) = effectivePreviewTypeForRendering {
                let isFullScreen = effectiveIsImmersive || isFullScreenActive
                TTMediaEphemeralLeaseHostView(url: url, isFullScreen: isFullScreen) {
                    AVSampleBufferVideoPlayerView(
                        url: url,
                        isFullScreen: isFullScreen,
                        renderStatus: { status in AnyView(TTZipVideoPlaybackStatusView(status: status)) },
                        renderNotices: { notices in
                            AnyView(TTZipVideoPlaybackNoticesView(notices: notices, isFullScreen: isFullScreen))
                        },
                        playbackMenus: TTZipVideoPlaybackMenus.presentation,
                        renderFeedback: { feedback in AnyView(TTZipVideoPlaybackFeedbackView(feedback: feedback)) },
                        subtitlePresentation: TTZipVideoSubtitlePresentation.presentation,
                        onFullscreenRequest: { url in
                            NotificationCenter.default.post(
                                name: .ttZipVideoFullscreenRequested,
                                object: url,
                                userInfo: ["url": url, "name": url.lastPathComponent]
                            )
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.previewResourceContext, effectiveResourceContext)
            } else if case .audio(let url) = effectivePreviewTypeForRendering {
                AudioPreviewHostView(
                    url: url,
                    fileName: fileName,
                    resourceContext: effectiveResourceContext,
                    isFullScreen: effectiveIsImmersive || isFullScreenActive
                )
            } else if case .htmlWeb(let content, let url) = effectivePreviewTypeForRendering {
                let context = effectiveResourceContext
                TTZipWebPreviewView(
                    content: content,
                    fileURL: url ?? context.readableURL ?? effectiveFileURL,
                    fileName: fileName,
                    resourceContext: context
                )
            } else if case .quickLook(let url) = effectivePreviewTypeForRendering {
                TTMediaEphemeralLeaseHostView(url: url, isFullScreen: effectiveIsImmersive || isFullScreenActive) {
                    QuickLookNativePreviewView(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .environment(\.previewResourceContext, effectiveResourceContext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .unsupported(let message) = effectivePreviewTypeForRendering {
                unsupportedPreview(message: message)
                    .environment(\.previewResourceContext, effectiveResourceContext)
            } else if case .text(let text) = effectivePreviewTypeForRendering {
                let context = effectiveResourceContext
                TTZipCodePreviewView(
                    text: text,
                    fileURL: context.readableURL ?? effectiveFileURL,
                    fileName: fileName,
                    resourceContext: context
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            if effectiveShowsStandaloneWindowButton {
                standaloneExpandFloatingButton
            }
        }
        .environment(\.videoPlaybackControls) { context in
            AnyView(TTZipVideoPlaybackControls(context: context))
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

    private func unsupportedPreview(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage(message))
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}
