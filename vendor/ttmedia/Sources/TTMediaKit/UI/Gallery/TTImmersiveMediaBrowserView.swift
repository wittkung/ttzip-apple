// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Layout classification for the public preview host.
/// Distinguishes full-bleed media canvases (video/image/audio) from structured documents with their own top toolbars.
public enum PreviewHostLayoutClass: String, Sendable, Equatable {
    case canvasMedia
    case structuredDocument
}

extension TTMediaPreviewType {
    /// Determines whether the preview host should mount a full-bleed canvas HUD or a stacked non-occluding document header.
    public var hostLayoutClass: PreviewHostLayoutClass {
        switch self {
        case .video, .image, .audio:
            return .canvasMedia
        case .pluginView, .pdf, .pdfData, .text, .docxDocument, .epubBook, .ebook,
             .hexViewer, .markdown, .htmlWeb, .spreadsheetTable, .officeSpreadsheet,
             .officePresentation, .quickLook, .unsupported:
            return .structuredDocument
        }
    }

    /// Returns `true` strictly when the resolved preview type is a video stream.
    public var isVideoPreview: Bool {
        if case .video = self { return true }
        return false
    }

    /// Returns `true` when the preview component owns horizontal arrow keys (`←` / `→`) for internal pagination,
    /// scrubbing, or cursor movement, prohibiting outer file/column switchers from hijacking them.
    public var ownsHorizontalNavigationKeys: Bool {
        switch self {
        case .epubBook, .ebook, .video, .audio,
             .spreadsheetTable, .officeSpreadsheet,
             .pdf, .pdfData, .text, .markdown, .htmlWeb,
             .hexViewer, .docxDocument, .officePresentation:
            return true
        case .image, .quickLook, .pluginView, .unsupported:
            return false
        }
    }
}

/// Describes the usable content bounds and header geometry allocated by the outer preview host (Contract v1).
public struct TTPreviewHostContentGeometry: Sendable, Equatable {
    public static let contractVersion = "v1"
    public let layoutClass: PreviewHostLayoutClass
    public let hostHeaderHeight: CGFloat
    public let contentTopSafeInset: CGFloat
    public let availableSize: CGSize
    public let isStandalonePlaybackWindow: Bool

    public init(
        layoutClass: PreviewHostLayoutClass = .structuredDocument,
        hostHeaderHeight: CGFloat = 0,
        contentTopSafeInset: CGFloat = 0,
        availableSize: CGSize = .zero,
        isStandalonePlaybackWindow: Bool = false
    ) {
        self.layoutClass = layoutClass
        self.hostHeaderHeight = hostHeaderHeight
        self.contentTopSafeInset = contentTopSafeInset
        self.availableSize = availableSize
        self.isStandalonePlaybackWindow = isStandalonePlaybackWindow
    }
}

private struct TTPreviewHostContentGeometryKey: EnvironmentKey {
    static let defaultValue = TTPreviewHostContentGeometry()
}

extension EnvironmentValues {
    public var previewHostContentGeometry: TTPreviewHostContentGeometry {
        get { self[TTPreviewHostContentGeometryKey.self] }
        set { self[TTPreviewHostContentGeometryKey.self] = newValue }
    }
}

/// Policy evaluating whether horizontal arrow keys (`←` / `→`) belong to the active inner preview
/// (such as EPUB pagination, video seek, or text/table cursor) rather than outer file switching (Contract v1).
@MainActor
public enum TTPreviewHorizontalKeyPolicy {
    public static let contractVersion = "v1"

    private static let ebookAndDocumentExtensions: Set<String> = [
        "epub", "mobi", "azw", "azw3", "fb2",
        "pdf", "csv", "tsv", "xlsx", "xlsm", "ods", "numbers",
        "txt", "md", "markdown", "html", "htm", "xhtml",
        "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "log",
        "swift", "rs", "py", "js", "ts", "jsx", "tsx", "c", "cpp", "h", "hpp",
        "go", "java", "kt", "cs", "rb", "php", "sh", "zsh", "bash", "sql", "css",
        "docx", "pptx", "pages", "key"
    ]

    /// Determines whether the given preview type or file URL owns horizontal arrow keys internally.
    public static func ownsHorizontalArrowKeys(
        previewType: TTMediaPreviewType? = nil,
        url: URL? = nil,
        fileName: String = ""
    ) -> Bool {
        if let previewType {
            if case .unsupported(let msg) = previewType, msg == "Loading..." {
                // Fall through to URL/extension inspection while async detection is still in flight.
            } else {
                return previewType.ownsHorizontalNavigationKeys
            }
        }
        let candidateName = !fileName.isEmpty ? fileName : (url?.lastPathComponent ?? "")
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: (candidateName as NSString).pathExtension)
        if ebookAndDocumentExtensions.contains(ext) {
            return true
        }
        if TTMediaCapabilityMatrix.videoExtensions.contains(ext) || TTMediaCapabilityMatrix.audioExtensions.contains(ext) {
            if let url, TTMediaCapabilityMatrix.ambiguousExtensions.contains(ext) {
                return TTMediaDetector.detectType(url: url).ownsHorizontalNavigationKeys
            }
            return true
        }
        return false
    }

    /// Returns `true` if `window`'s current first responder is an active text input or IME composition client.
    public static func isWindowTextInputActive(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let inputClient = responder as? NSTextInputClient, inputClient.hasMarkedText() {
            return true
        }
        return responder is NSTextView || responder is NSTextField
    }

    /// Evaluates whether the outer media browser or file switcher is allowed to intercept a horizontal arrow key.
    public static func shouldOuterBrowserInterceptHorizontalArrow(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        eventWindowNumber: Int? = nil,
        hostWindowNumber: Int? = nil,
        isAppKitTextInputActive: Bool = false,
        previewType: TTMediaPreviewType? = nil,
        url: URL? = nil,
        fileName: String = ""
    ) -> Bool {
        guard keyCode == 123 || keyCode == 124 else { return false }
        let cleanMods = modifiers.intersection(.deviceIndependentFlagsMask)
        if !cleanMods.intersection([.command, .option, .control, .shift]).isEmpty {
            return false
        }
        if let eventWindowNumber, let hostWindowNumber, eventWindowNumber != hostWindowNumber {
            return false
        }
        if isAppKitTextInputActive {
            return false
        }
        let query = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(
            windowNumber: eventWindowNumber ?? hostWindowNumber,
            keyCode: keyCode
        )
        if query.isTextInputActive || query.ownsHorizontalArrowKeys || query.isEventAlreadyHandled {
            return false
        }
        if ownsHorizontalArrowKeys(previewType: previewType, url: url, fileName: fileName) {
            return false
        }
        return true
    }
}

extension TTMediaDetector {
    /// Infers the initial host layout class from fast header probing and capability descriptors without blocking the main thread.
    /// Correctly distinguishes MPEG-TS video (`.canvasMedia`) from TypeScript `.ts` source code (`.structuredDocument`).
    nonisolated public static func inferHostLayoutClass(url: URL, fileName: String = "") -> PreviewHostLayoutClass {
        let fastType = fastTypeByExtension(url: url)
        switch fastType {
        case .video, .audio, .image:
            return .canvasMedia
        case .pdf, .pdfData, .text, .docxDocument, .epubBook, .ebook,
             .hexViewer, .markdown, .htmlWeb, .spreadsheetTable, .officeSpreadsheet,
             .officePresentation, .quickLook, .pluginView:
            return .structuredDocument
        case .unsupported:
            let candidateName = fileName.isEmpty ? url.lastPathComponent : fileName
            let ext = TTMediaCapabilityMatrix.cleanExtension(from: (candidateName as NSString).pathExtension)
            if TTMediaCapabilityMatrix.ambiguousExtensions.contains(ext) {
                return .structuredDocument
            }
            if TTMediaCapabilityMatrix.imageExtensions.contains(ext) && !TTMediaCapabilityMatrix.htmlWebExtensions.contains(ext) {
                return .canvasMedia
            }
            if TTMediaCapabilityMatrix.videoExtensions.contains(ext) || TTMediaCapabilityMatrix.audioExtensions.contains(ext) {
                let detected = detectType(url: url)
                return detected.hostLayoutClass
            }
            return .structuredDocument
        }
    }
}

/// Strongly-typed immutable descriptor for an item displayed in the immersive media browser.
/// Carries F4 archive source identity, deterministic cache key, and editability permissions across fullscreen and sibling navigation.
public struct ImmersiveMediaItem: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let fileSizeBytes: Int64?
    public let sourceArchivePath: String?
    public let archiveSubpath: String?
    public let resourceCacheKey: String?
    public let isEditable: Bool
    public let resourceContext: TTPreviewResourceContext?

    /// Indicates whether this item originates from an archive container or ephemeral staging cache.
    public var isFromArchive: Bool {
        if resourceContext?.isArchiveEntry == true || sourceArchivePath != nil || archiveSubpath != nil {
            return true
        }
        if !url.isFileURL {
            return true
        }
        if let query = url.query, query.contains("subpath=") {
            return true
        }
        return SpreadsheetTablePreviewView.isArchiveOrEphemeralStagingURL(url)
    }

    /// Canonical F4 `TTPreviewResourceContext` derived from the item's archive or disk origin.
    public var resolvedResourceContext: TTPreviewResourceContext {
        if let resourceContext {
            return resourceContext
        }
        let querySubpath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "subpath" })?
            .value
        if let archPath = sourceArchivePath ?? (querySubpath != nil ? url.path : nil) {
            let entryPath = archiveSubpath ?? querySubpath ?? name
            let stagedURL = (url.isFileURL && querySubpath == nil) ? url : nil
            return .archiveEntry(
                archivePath: archPath,
                entryPath: entryPath,
                stagedReadURL: stagedURL,
                fileName: name
            )
        }
        if isFromArchive {
            return .unknown(readableURL: url, fileName: name)
        }
        if url.isFileURL {
            return .diskFile(url: url, fileName: name, allowsEditing: isEditable)
        }
        return .unknown(readableURL: url, fileName: name)
    }

    public init(
        url: URL,
        name: String,
        fileSizeBytes: Int64? = nil,
        sourceArchivePath: String? = nil,
        archiveSubpath: String? = nil,
        resourceCacheKey: String? = nil,
        isEditable: Bool? = nil,
        resourceContext: TTPreviewResourceContext? = nil
    ) {
        self.url = url
        self.name = name
        self.fileSizeBytes = fileSizeBytes
        let resolvedArchPath = sourceArchivePath ?? resourceContext?.archiveIdentity?.archivePath
        let resolvedSubpath = archiveSubpath ?? resourceContext?.archiveIdentity?.entryPath
        self.sourceArchivePath = resolvedArchPath
        self.archiveSubpath = resolvedSubpath
        self.resourceCacheKey = resourceCacheKey
        self.resourceContext = resourceContext
        self.isEditable = Self.deriveIsEditable(
            url: url,
            name: name,
            hasArchiveOrigin: resourceContext?.isArchiveEntry == true || resolvedArchPath != nil || resolvedSubpath != nil,
            explicitEditable: isEditable,
            resourceContext: resourceContext
        )
    }

    private static func deriveIsEditable(
        url: URL,
        name: String,
        hasArchiveOrigin: Bool,
        explicitEditable: Bool?,
        resourceContext: TTPreviewResourceContext?
    ) -> Bool {
        if hasArchiveOrigin || !url.isFileURL || (url.query?.contains("subpath=") == true) {
            return false
        }
        if SpreadsheetTablePreviewView.isArchiveOrEphemeralStagingURL(url) {
            return false
        }
        if let context = resourceContext {
            return context.isEditableInPlace
        }
        if let explicit = explicitEditable {
            return explicit
        }
        let nameExt = (name as NSString).pathExtension
        let rawExt = nameExt.isEmpty ? url.pathExtension : nameExt
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: rawExt)
        let canEditFormat = TTMediaCapabilityMatrix.descriptor(for: ext)?.isEditableSource ?? false
        return canEditFormat && FileManager.default.isWritableFile(atPath: url.path)
    }
}

public typealias TTImmersiveMediaItem = ImmersiveMediaItem

/// Immersive full-viewport media browser presenting media files over a frosted dark scrim.
/// Separates `.canvasMedia` (full-bleed with auto-hiding HUD) from `.structuredDocument` (stacked dedicated top bar)
/// so document toolbars and scrollbars are never occluded and background clicks never accidentally dismiss the window.
public struct TTImmersiveMediaBrowserView: View {
    public let item: ImmersiveMediaItem
    public let onClose: () -> Void
    public let onNavigatePrevious: (() -> Void)?
    public let onNavigateNext: (() -> Void)?

    @State private var eventMonitor: Any? = nil
    @State private var isCopiedToastShown: Bool = false
    @State private var controls = MediaControlsVisibility()
    @State private var videoCornerState = PreviewCornerActionRevealCoordinator()
    @FocusState private var isVideoCornerFocused: Bool
    @State private var leaseBox: TTMediaEphemeralLeaseBox
    @State private var layoutClass: PreviewHostLayoutClass
    @State private var resolvedPreviewType: TTMediaPreviewType? = nil
    @State private var hostWindowNumber: Int? = nil
    private var isControlsVisible: Bool { controls.isVisible }

    private var isVideoCanvas: Bool {
        if let resolvedPreviewType {
            return resolvedPreviewType.isVideoPreview
        }
        let rawExt = (item.name as NSString).pathExtension.isEmpty
            ? item.url.pathExtension
            : (item.name as NSString).pathExtension
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: rawExt)
        return TTMediaCapabilityMatrix.videoExtensions.contains(ext) && layoutClass == .canvasMedia
    }

    public init(
        item: ImmersiveMediaItem,
        onClose: @escaping () -> Void,
        onNavigatePrevious: (() -> Void)? = nil,
        onNavigateNext: (() -> Void)? = nil
    ) {
        self.item = item
        self.onClose = onClose
        self.onNavigatePrevious = onNavigatePrevious
        self.onNavigateNext = onNavigateNext
        _leaseBox = State(initialValue: TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: item.url))
        _layoutClass = State(initialValue: TTMediaDetector.inferHostLayoutClass(url: item.url, fileName: item.name))
    }

    private var formatExtension: String {
        let nameExt = (item.name as NSString).pathExtension.uppercased()
        if !nameExt.isEmpty { return nameExt }
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }

    private var fileSizeDescription: String? {
        if let size = item.fileSizeBytes {
            return ByteCountFormatterFlyweight.shared.string(fromByteCount: size)
        }
        if let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            return ByteCountFormatterFlyweight.shared.string(fromByteCount: Int64(size))
        }
        return nil
    }

    private func computeHostGeometry(for geometry: GeometryProxy) -> TTPreviewHostContentGeometry {
        let headerHeight: CGFloat = (layoutClass == .structuredDocument) ? 52.0 : 0.0
        let contentHeight = max(0.0, geometry.size.height - headerHeight)
        return TTPreviewHostContentGeometry(
            layoutClass: layoutClass,
            hostHeaderHeight: headerHeight,
            contentTopSafeInset: 0.0,
            availableSize: CGSize(width: geometry.size.width, height: contentHeight),
            isStandalonePlaybackWindow: false
        )
    }

    public var body: some View {
        GeometryReader { geometry in
            Group {
                if layoutClass == .structuredDocument {
                    structuredDocumentLayout(geometry: geometry)
                } else {
                    canvasMediaLayout(geometry: geometry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TTPreviewHostWindowNumberReader(windowNumber: $hostWindowNumber))
            .environment(\.mediaControlsVisibility, controls)
            .environment(\.previewResourceContext, item.resolvedResourceContext)
            .environment(\.previewHostContentGeometry, computeHostGeometry(for: geometry))
            .animation(.spring(response: 0.16, dampingFraction: 1), value: isControlsVisible)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    controls.recordMouseMove(at: location)
                case .ended:
                    controls.setHovered(false)
                }
            }
            .onAppear {
                leaseBox.bind(url: item.url, consumeFullscreenHandoff: true)
                layoutClass = TTMediaDetector.inferHostLayoutClass(url: item.url, fileName: item.name)
                setupKeyboardMonitor()
                if !isVideoCanvas {
                    showControlsAndResetTimer()
                }
            }
            .onChange(of: item.url) { _, newURL in
                controls.resetForNewItem()
                videoCornerState.tearDown()
                leaseBox.bind(url: newURL, consumeFullscreenHandoff: true)
                resolvedPreviewType = nil
                layoutClass = TTMediaDetector.inferHostLayoutClass(url: newURL, fileName: item.name)
            }
            .task(id: item.url) {
                let detected = await TTMediaDetector.detectTypeAsync(url: item.url)
                if !Task.isCancelled {
                    resolvedPreviewType = detected
                    layoutClass = detected.hostLayoutClass
                }
            }
            .onDisappear {
                teardownKeyboardMonitor()
                controls.tearDown()
                videoCornerState.tearDown()
                TTMediaDetector.endFullscreenEphemeralHandoff(for: item.url)
                leaseBox.release()
            }
        }
    }

    // MARK: - Dual-Mode Host Layouts

    private func structuredDocumentLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            documentHostHeaderBar(geometry: geometry)
            Divider()
                .overlay(Color.white.opacity(0.14))
            TTMediaPreview(url: item.url, title: item.name, resourceContext: item.resolvedResourceContext)
                .id(item.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            Color.black.opacity(0.94)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
        )
    }

    private func canvasMediaLayout(geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black.opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture {
                    if !isControlsVisible && !isVideoCanvas {
                        showControlsAndResetTimer()
                    }
                }

            TTMediaPreview(url: item.url, title: item.name, resourceContext: item.resolvedResourceContext)
                .id(item.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if isVideoCanvas {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        trailingHeaderControls
                            .ttImmersiveVideoCornerReveal(
                                state: videoCornerState,
                                controls: controls,
                                isFocused: $isVideoCornerFocused
                            )
                    }
                } else {
                    topGradientHeader(geometry: geometry)
                        .opacity(isControlsVisible ? 1.0 : 0.0)
                        .allowsHitTesting(isControlsVisible)
                }
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - Host Header Bars

    private func documentHostHeaderBar(geometry: GeometryProxy) -> some View {
        headerBarContent(geometry: geometry)
            .padding(.leading, 84)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.black.opacity(0.82))
    }

    private func topGradientHeader(geometry: GeometryProxy) -> some View {
        headerBarContent(geometry: geometry)
            .padding(.leading, 84)
            .padding(.trailing, 24)
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 96, alignment: .top)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.75), Color.black.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private func headerBarContent(geometry: GeometryProxy) -> some View {
        HStack(alignment: .center, spacing: 14) {
            leadingBadgeAndTitle(geometry: geometry)
            Spacer()
            trailingHeaderControls
        }
    }

    private func leadingBadgeAndTitle(geometry: GeometryProxy) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: iconName(for: item.name))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TTMediaTheme.kintsugiGold)

                Text(formatExtension)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(TTMediaTheme.kintsugiGold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(TTMediaTheme.kintsugiGold.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(TTMediaTheme.kintsugiGold.opacity(0.4), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: min(640, max(80, geometry.size.width - 420)), alignment: .leading)

                if let sizeDesc = fileSizeDescription {
                    Text(sizeDesc)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
        }
    }

    private var trailingHeaderControls: some View {
        HStack(spacing: 10) {
            if onNavigatePrevious != nil || onNavigateNext != nil {
                headerNavigationCluster
            }

            Button(action: {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                    Text("Finder")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .ttButtonHelp(MediaLocalization.text(.finderHelp))
            .accessibilityLabel(MediaLocalization.text(.finder))

            Button(action: copyFilePath) {
                HStack(spacing: 4) {
                    Image(systemName: isCopiedToastShown ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCopiedToastShown ? TTMediaTheme.bambooGreen : .white.opacity(0.9))
                    Text(MediaLocalization.text(isCopiedToastShown ? .copied : .copyPath))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCopiedToastShown ? TTMediaTheme.bambooGreen : .white.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .ttButtonHelp(MediaLocalization.text(.copyPathHelp))
            .accessibilityLabel(MediaLocalization.text(.copyPathLabel))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .ttButtonHelp(MediaLocalization.text(.dismissHelp))
            .accessibilityLabel(MediaLocalization.text(.close))
            .accessibilityHint(MediaLocalization.text(.escapeHint))
            .accessibilityIdentifier("ImmersiveMediaCloseButton")
        }
    }

    private var headerNavigationCluster: some View {
        HStack(spacing: 4) {
            Button(action: { onNavigatePrevious?() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(onNavigatePrevious != nil ? .white.opacity(0.92) : .white.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(onNavigatePrevious == nil)
            .ttButtonHelp(MediaLocalization.text(.previousHelp))
            .accessibilityLabel(MediaLocalization.text(.previous))
            .accessibilityHint(MediaLocalization.text(.previousHint))
            .accessibilityIdentifier("ImmersiveMediaPreviousButton")

            Button(action: { onNavigateNext?() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(onNavigateNext != nil ? .white.opacity(0.92) : .white.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(onNavigateNext == nil)
            .ttButtonHelp(MediaLocalization.text(.nextHelp))
            .accessibilityLabel(MediaLocalization.text(.next))
            .accessibilityHint(MediaLocalization.text(.nextHint))
            .accessibilityIdentifier("ImmersiveMediaNextButton")
        }
    }

    // MARK: - Auto-Hide State Machine

    private func showControlsAndResetTimer() {
        controls.interact()
    }

    // MARK: - Actions & Keyboard

    private func copyFilePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            isCopiedToastShown = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopiedToastShown = false
            }
        }
    }

    private func setupKeyboardMonitor() {
        teardownKeyboardMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let eventWinNum = event.window?.windowNumber ?? NSApp?.keyWindow?.windowNumber
            if let hostWindowNumber, let eventWinNum, eventWinNum != hostWindowNumber {
                return event
            }
            let targetWindow = event.window ?? NSApp?.keyWindow
            let isInputActive = TTPreviewHorizontalKeyPolicy.isWindowTextInputActive(targetWindow)
            if event.keyCode == 53 {
                guard !isInputActive else { return event }
                onClose()
                return nil
            }
            if event.keyCode == 123 || event.keyCode == 124 {
                let disposition = TTPreviewKeyboardOwnershipCoordinator.shared.handleOrBlockOuterHorizontalArrow(event: event)
                if disposition == .consumedByPreviewOwner {
                    return nil
                }
                if disposition == .yieldToTextInput {
                    return event
                }
                guard TTPreviewHorizontalKeyPolicy.shouldOuterBrowserInterceptHorizontalArrow(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    eventWindowNumber: eventWinNum,
                    hostWindowNumber: hostWindowNumber,
                    isAppKitTextInputActive: isInputActive,
                    previewType: resolvedPreviewType,
                    url: item.url,
                    fileName: item.name
                ) else {
                    return event
                }
                if event.keyCode == 123, let prev = onNavigatePrevious {
                    prev()
                    return nil
                }
                if event.keyCode == 124, let next = onNavigateNext {
                    next()
                    return nil
                }
            }
            return event
        }
    }

    private func teardownKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func iconName(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp", "svg":
            return "photo"
        case "mp4", "mov", "mkv", "webm", "avi", "m4v":
            return "film"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return "music.note"
        case "csv", "tsv":
            return "tablecells"
        case "swift", "rs", "py", "js", "ts", "c", "cpp", "h", "go", "json", "yaml", "xml":
            return "curlybraces"
        default:
            return "doc"
        }
    }
}

// MARK: - Backward-Compatible Facade Alias

/// Backward-compatible typealias mapping `ImmersiveMediaBrowserView` to `TTImmersiveMediaBrowserView`.
public typealias ImmersiveMediaBrowserView = TTImmersiveMediaBrowserView
