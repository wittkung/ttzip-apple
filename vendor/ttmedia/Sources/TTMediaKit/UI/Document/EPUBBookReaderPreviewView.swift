// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import WebKit
import TTI18nCore
import TTI18nUI

// MARK: - Interactive EPUB Reader View

public struct InteractiveEPUBReaderView: View {
    public let bookModel: EPUBBookModel
    @Environment(\.epubReaderDocumentIdentity) var stableDocumentIdentity
    @Environment(\.epubReaderPersistence) var readerPersistence
    @StateObject var annotationSession = EPUBReaderAnnotationSession()
    @State var showNotes = false
    @State var progressCheckpoint = EPUBReaderProgressCheckpoint()
    @State var cjkFontFamily = "serif"

    @State var selectedChapterIndex: Int = 0
    @StateObject var paginationController: EPUBPaginationController
    @State var fontSize: Int = 17
    @State var fontFamily: String = "serif"
    @State var themeMode: String = "light"
    @State var layoutMode: String = "paginated"
    @State private var showTypographyPopover: Bool = false

    public init(
        bookModel: EPUBBookModel,
        paginationController: EPUBPaginationController? = nil
    ) {
        self.bookModel = bookModel
        let resolvedController = paginationController ?? EPUBPaginationController(
            initialChapterIndex: 0,
            totalChapters: max(bookModel.chapters.count, 1)
        )
        self._paginationController = StateObject(wrappedValue: resolvedController)
    }

    private struct ChapterLocationIdentity {
        let exactKey: String
        let foldedKey: String
        let foldedDirectoryKey: String
        let foldedBasename: String
    }

    public static func resolveChapterIndex(
        matching url: URL,
        in chapters: [EPUBChapterItem],
        baseDirectory: URL? = nil
    ) -> Int? {
        guard let target = makeChapterLocationIdentity(for: url) else {
            return nil
        }
        let candidates: [(index: Int, identity: ChapterLocationIdentity)] = chapters.enumerated().compactMap { idx, chapter in
            guard EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
                assetURL: chapter.fileURL,
                chapterURL: chapter.fileURL,
                baseDirectory: baseDirectory
            ),
            EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
                assetURL: url,
                chapterURL: chapter.fileURL,
                baseDirectory: baseDirectory
            ),
            let identity = makeChapterLocationIdentity(for: chapter.fileURL) else {
                return nil
            }
            return (idx, identity)
        }
        guard !candidates.isEmpty else { return nil }

        let exactMatches = candidates.filter { $0.identity.exactKey == target.exactKey }
        if exactMatches.count == 1 { return exactMatches[0].index }
        if exactMatches.count > 1 { return nil }

        let foldedMatches = candidates.filter { $0.identity.foldedKey == target.foldedKey }
        if foldedMatches.count == 1 { return foldedMatches[0].index }
        if foldedMatches.count > 1 { return nil }

        guard !target.foldedBasename.isEmpty,
              isSpineCompatibleFallbackDirectory(target.foldedDirectoryKey, candidates: candidates) else {
            return nil
        }
        let basenameMatches = candidates.filter { $0.identity.foldedBasename == target.foldedBasename }
        guard basenameMatches.count == 1 else { return nil }
        return basenameMatches[0].index
    }

    public func resolveChapterIndex(matching url: URL) -> Int? {
        Self.resolveChapterIndex(
            matching: url,
            in: bookModel.chapters,
            baseDirectory: bookModel.extractDir
        )
    }

    @discardableResult
    public func selectChapter(matching url: URL) -> Int? {
        guard let idx = resolveChapterIndex(matching: url) else { return nil }
        let landing: EPUBBoundaryLanding = if let frag = url.fragment, !frag.isEmpty {
            .fragment(frag)
        } else {
            .firstPage
        }
        selectedChapterIndex = idx
        paginationController.selectChapterExplicitly(idx, landing: landing)
        persistReadingProgress()
        return idx
    }

    private static func isSpineCompatibleFallbackDirectory(
        _ targetDirectoryKey: String,
        candidates: [(index: Int, identity: ChapterLocationIdentity)]
    ) -> Bool {
        let targetPrefix = targetDirectoryKey.hasSuffix("/") ? targetDirectoryKey : targetDirectoryKey + "/"
        return candidates.contains { candidate in
            let chapterDir = candidate.identity.foldedDirectoryKey
            return chapterDir == targetDirectoryKey || chapterDir.hasPrefix(targetPrefix)
        }
    }

    private static func makeChapterLocationIdentity(for url: URL) -> ChapterLocationIdentity? {
        let raw = url.absoluteString.components(separatedBy: "#").first ?? url.absoluteString
        let withoutQuery = raw.components(separatedBy: "?").first ?? raw
        guard let parsed = URL(string: withoutQuery),
              let scheme = parsed.scheme?.lowercased(),
              let authority = canonicalContainerAuthority(for: parsed, scheme: scheme) else {
            return nil
        }
        let decodedPath = parsed.path.removingPercentEncoding ?? parsed.path
        let exactPath = normalizeRelativeSegments(decodedPath)
        guard !exactPath.isEmpty else { return nil }
        let foldedPath = exactPath.lowercased()
        let foldedDir = (foldedPath as NSString).deletingLastPathComponent
        let foldedBasename = (foldedPath as NSString).lastPathComponent
        return ChapterLocationIdentity(
            exactKey: "\(scheme)://\(authority)/\(exactPath)",
            foldedKey: "\(scheme)://\(authority)/\(foldedPath)",
            foldedDirectoryKey: "\(scheme)://\(authority)/\(foldedDir)",
            foldedBasename: foldedBasename
        )
    }

    private static func canonicalContainerAuthority(for url: URL, scheme: String) -> String? {
        switch scheme {
        case "ttzip-vfs":
            return canonicalVfsAuthority(for: url)
        case "file":
            return canonicalLocalFileAuthority(for: url)
        default:
            return nil
        }
    }

    private static func canonicalVfsAuthority(for url: URL) -> String? {
        guard let rawHost = url.host else { return nil }
        let host = (rawHost.removingPercentEncoding ?? rawHost).lowercased()
        guard !host.isEmpty else { return nil }
        let user = url.user ?? ""
        let password = url.password.map { ":\($0)" } ?? ""
        let userInfo = (user.isEmpty && password.isEmpty) ? "" : "\(user)\(password)@"
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(userInfo)\(host)\(port)"
    }

    private static func canonicalLocalFileAuthority(for url: URL) -> String? {
        guard url.isFileURL, url.user == nil, url.password == nil, url.port == nil else {
            return nil
        }
        let host = (url.host ?? "").lowercased()
        return (host.isEmpty || host == "localhost") ? "localhost" : nil
    }

    private static func normalizeChapterLocation(_ url: URL) -> String {
        let raw = url.absoluteString.components(separatedBy: "#").first ?? url.absoluteString
        let withoutQuery = raw.components(separatedBy: "?").first ?? raw
        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        guard let parsed = URL(string: withoutQuery) else {
            return normalizeRelativeSegments(decoded).lowercased()
        }
        let scheme = (parsed.scheme ?? "").lowercased()
        let host = (parsed.host?.removingPercentEncoding ?? parsed.host ?? "").lowercased()
        let decodedPath = parsed.path.removingPercentEncoding ?? parsed.path
        let normalizedPath = normalizeRelativeSegments(decodedPath).lowercased()
        if !scheme.isEmpty && !host.isEmpty {
            return "\(scheme)://\(host)/\(normalizedPath)"
        }
        return normalizedPath
    }

    private static func normalizeRelativeSegments(_ path: String) -> String {
        var clean = path.replacingOccurrences(of: "\\", with: "/")
        while clean.hasPrefix("/") { clean.removeFirst() }
        var parts: [String] = []
        for seg in clean.split(separator: "/") {
            if seg == "." || seg.isEmpty { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(seg))
            }
        }
        return parts.joined(separator: "/")
    }

    private var bookProgressStorageKey: String {
        "TTMedia_EPUB_Progress_" + Self.stableBookDigest(for: Self.normalizeChapterLocation(bookModel.url))
    }

    /// Legacy keys used the last path component only, which collided across folders and archive entries.
    private var legacyProgressStorageKey: String {
        let normalized = Self.normalizeChapterLocation(bookModel.url)
        let bookIdentity = (normalized as NSString).lastPathComponent
        let safeSuffix = bookIdentity.isEmpty ? normalized : bookIdentity
        let cleaned = safeSuffix.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "TTMedia_EPUB_Progress_" + cleaned
    }

    /// Deterministic FNV-1a 64-bit digest of the normalized book identity.
    ///
    /// The identity is the book URL itself (`file:` path or `ttzip-vfs://<archiveId>/<entry>`), never the
    /// transient extraction/spool directory, so the same book reopened later resolves to the same key.
    static func stableBookDigest(for normalizedIdentity: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalizedIdentity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private func restoreReadingProgress() {
        let defaults = UserDefaults.standard
        let key = bookProgressStorageKey
        let hasNewKey = defaults.object(forKey: key + "_chapter") != nil
        var savedChapter = defaults.integer(forKey: key + "_chapter")
        var savedPage = defaults.integer(forKey: key + "_page")
        var savedAnchor = defaults.object(forKey: key + "_anchor") as? Int
        var savedCharOffset = defaults.object(forKey: key + "_char") as? Int
        var savedRatio = defaults.object(forKey: key + "_ratio") as? Double

        if !hasNewKey {
            let legacy = legacyProgressStorageKey
            if defaults.object(forKey: legacy + "_chapter") != nil {
                savedChapter = defaults.integer(forKey: legacy + "_chapter")
                savedPage = defaults.integer(forKey: legacy + "_page")
                savedAnchor = nil
                savedCharOffset = nil
                savedRatio = nil
                defaults.set(savedChapter, forKey: key + "_chapter")
                defaults.set(savedPage, forKey: key + "_page")
                defaults.removeObject(forKey: legacy + "_chapter")
                defaults.removeObject(forKey: legacy + "_page")
            }
        }

        guard bookModel.chapters.indices.contains(savedChapter) else { return }
        selectedChapterIndex = savedChapter
        let hasPosition = savedPage > 0 || (savedAnchor ?? 0) > 0 || (savedRatio ?? 0) > 0
        let landing: EPUBBoundaryLanding = hasPosition
            ? .preserveAnchor(
                progressRatio: savedRatio ?? 0,
                anchorBlockIndex: savedAnchor,
                anchorCharOffset: savedCharOffset ?? 0
            )
            : .firstPage
        paginationController.restoreReadingPosition(chapterIndex: savedChapter, landing: landing)
    }

    func persistReadingProgress() {
        guard paginationController.isPaginationReady else { return }
        if let readerPersistence {
            do {
                try progressCheckpoint.saveIfChanged(
                    identity: readerDocumentIdentity, anchor: currentReaderAnchor,
                    using: readerPersistence.savePosition
                )
            }
            catch { annotationSession.errorMessage = error.localizedDescription }
            return
        }
        // Standalone TTMediaKit clients without a host core retain the legacy adapter.
        let defaults = UserDefaults.standard
        let key = bookProgressStorageKey
        defaults.set(selectedChapterIndex, forKey: key + "_chapter")
        defaults.set(paginationController.currentPageIndex, forKey: key + "_page")
        defaults.set(paginationController.anchorBlockIndex ?? 0, forKey: key + "_anchor")
        defaults.set(paginationController.anchorCharOffset, forKey: key + "_char")
        defaults.set(paginationController.normalizedProgressInChapter, forKey: key + "_ratio")
    }

    public var body: some View {
        VStack(spacing: 0) {
            readerTopToolbar

            if bookModel.chapters.indices.contains(selectedChapterIndex) {
                EPUBNativeWKWebView(
                    chapterURL: bookModel.chapters[selectedChapterIndex].fileURL,
                    baseDirectory: bookModel.extractDir,
                    fontSize: Double(fontSize),
                    fontStyle: fontFamily + "|" + cjkFontFamily,
                    readerTheme: themeMode,
                    chapterIndex: selectedChapterIndex,
                    chapters: bookModel.chapters,
                    paginationController: paginationController,
                    onNavigateToChapterURL: { targetURL in
                        _ = selectChapter(matching: targetURL)
                    },
                    layoutMode: layoutMode,
                    annotationSession: annotationSession
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(8)
            } else {
                Spacer()
                Text(EBookPreviewLocalization.text(.noChapterContent))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(EPUBReaderFocusRegionBackground(instanceID: paginationController.instanceID))
        .onAppear {
            restoreLegacyReaderPreferences()
            let initialLayout = EPUBReadingLayoutPreference.resolve(stored: layoutMode)
            paginationController.setLayoutMode(initialLayout)
            paginationController.configureBook(
                totalChapters: max(bookModel.chapters.count, 1),
                initialChapterIndex: selectedChapterIndex
            )
            restoreReadingProgress()
            restoreReaderWorkspace()
            paginationController.onRequestChapterIndexChange = { newIndex, _ in
                selectedChapterIndex = newIndex
                persistReadingProgress()
            }
        }
        .onDisappear {
            persistReadingProgress()
        }
        .onChange(of: paginationController.isPaginationReady) { _, isReady in
            if isReady { persistReadingProgress() }
        }
        .onChange(of: paginationController.currentPageIndex) { _, _ in
            persistReadingProgress()
        }
        .onChange(of: paginationController.anchorBlockIndex) { _, _ in
            persistReadingProgress()
        }
        .onChange(of: paginationController.anchorCharOffset) { _, _ in
            persistReadingProgress()
        }
        .onChange(of: layoutMode) { _, newMode in
            persistReaderPreferences()
            let resolved = EPUBReadingLayoutPreference.resolve(stored: newMode)
            paginationController.setLayoutMode(resolved)
            TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionLayoutMode(
                instanceID: paginationController.instanceID,
                layoutMode: resolved
            )
        }
        .onChange(of: bookModel.url) { _, _ in
            selectedChapterIndex = 0
            paginationController.configureBook(
                totalChapters: max(bookModel.chapters.count, 1),
                initialChapterIndex: 0
            )
            annotationSession.annotations = []
            annotationSession.selection = nil
            restoreLegacyReaderPreferences()
            restoreReadingProgress()
            restoreReaderWorkspace()
        }
        .onReceive(NotificationCenter.default.publisher(for: .epubReaderAnnotationsChanged)) { notification in
            guard notification.object as? String == readerDocumentIdentity else { return }
            do { try refreshReaderAnnotations() }
            catch { annotationSession.errorMessage = error.localizedDescription }
        }
        .onChange(of: fontFamily) { _, _ in persistReaderPreferences() }
        .onChange(of: cjkFontFamily) { _, _ in persistReaderPreferences() }
        .onChange(of: fontSize) { _, _ in persistReaderPreferences() }
        .onChange(of: themeMode) { _, _ in persistReaderPreferences() }
        .onChange(of: showTypographyPopover) { _, isPresented in
            TTPreviewKeyboardOwnershipCoordinator.shared.notifyToolbarInteraction(
                instanceID: paginationController.instanceID
            )
            if !isPresented {
                paginationController.onRequestRestoreReaderFocus?()
            }
        }
    }

    private var readerTopToolbar: some View {
        HStack(spacing: 6) {
            tableOfContentsMenu
            Spacer(minLength: 4)
            layoutModeToggleButton
            typographyPopoverButton
            notesButton
            Spacer(minLength: 4)
            chapterPaginationStepper
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    var layoutModeToggleButton: some View {
        let isScrolling = (layoutMode == "scrolling")
        let helpText = isScrolling
            ? EPUBPaginationLocalization.text(.layoutModeScrolling)
            : EPUBPaginationLocalization.text(.layoutModePaginated)
        return Button(action: {
            layoutMode = isScrolling ? "paginated" : "scrolling"
        }) {
            HStack(spacing: 4) {
                Image(systemName: isScrolling ? "scroll.fill" : "book.pages.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(helpText)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .ttButtonHelp(helpText)
        .accessibilityLabel(helpText)
    }

    private var tableOfContentsMenu: some View {
        let currentTitle = bookModel.chapters.indices.contains(selectedChapterIndex)
            ? bookModel.chapters[selectedChapterIndex].title
            : EBookPreviewLocalization.text(.chapterFallback)
        let tocHelp = EBookPreviewLocalization.text(.tableOfContentsHelp)
        return Menu {
            ForEach(Array(bookModel.chapters.enumerated()), id: \.offset) { idx, chapter in
                Button(action: {
                    selectedChapterIndex = idx
                    paginationController.selectChapterExplicitly(idx, landing: .firstPage)
                    persistReadingProgress()
                    paginationController.onRequestRestoreReaderFocus?()
                }) {
                    HStack {
                        Text(chapter.title)
                            .lineLimit(1)
                        if selectedChapterIndex == idx {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Text(currentTitle)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())

                HStack(spacing: 3) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .ttButtonHelp(tocHelp)
        .accessibilityLabel(tocHelp)
    }

    private var typographyPopoverButton: some View {
        let helpText = EBookPreviewLocalization.text(.typographyHelp)
        return Button(action: {
            TTPreviewKeyboardOwnershipCoordinator.shared.notifyToolbarInteraction(
                instanceID: paginationController.instanceID
            )
            showTypographyPopover.toggle()
        }) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Image(systemName: "textformat")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text(EBookPreviewLocalization.text(.typography))
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())

                HStack(spacing: 2) {
                    Image(systemName: "textformat")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .ttButtonHelp(helpText)
        .accessibilityLabel(helpText)
        .popover(isPresented: $showTypographyPopover, arrowEdge: .bottom) {
            EPUBTypographyPopoverView(
                fontFamily: $fontFamily,
                fontSize: $fontSize,
                themeMode: $themeMode,
                layoutMode: $layoutMode,
                cjkFontFamily: $cjkFontFamily
            )
        }
    }

    private var chapterPaginationStepper: some View {
        let prevHelp = EPUBPaginationLocalization.text(.previousPageHelp)
        let nextHelp = EPUBPaginationLocalization.text(.nextPageHelp)
        let canGoPrevious = selectedChapterIndex > 0 || paginationController.currentPageIndex > 0
        let canGoNext = selectedChapterIndex < max(bookModel.chapters.count - 1, 0)
            || (paginationController.currentPageIndex + 1 < paginationController.totalPagesInChapter)
        let fullLabel = EPUBPaginationLocalization.chapterPageAndProgressIndicator(
            chapterIndex: selectedChapterIndex,
            totalChapters: bookModel.chapters.count,
            pageIndex: paginationController.currentPageIndex,
            totalPages: paginationController.totalPagesInChapter,
            progressRatio: paginationController.estimatedOverallBookProgress
        )
        let compactLabel = "\(paginationController.currentPageIndex + 1)/\(max(paginationController.totalPagesInChapter, 1))"
        return ViewThatFits(in: .horizontal) {
            stepperCapsule(label: fullLabel, canGoPrevious: canGoPrevious, canGoNext: canGoNext, prevHelp: prevHelp, nextHelp: nextHelp)
            stepperCapsule(label: compactLabel, canGoPrevious: canGoPrevious, canGoNext: canGoNext, prevHelp: prevHelp, nextHelp: nextHelp)
        }
    }

    private func stepperCapsule(
        label: String,
        canGoPrevious: Bool,
        canGoNext: Bool,
        prevHelp: String,
        nextHelp: String
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: {
                _ = paginationController.handleHorizontalArrow(isRightArrow: false)
                paginationController.onRequestRestoreReaderFocus?()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(!canGoPrevious)
            .opacity(canGoPrevious ? 1.0 : 0.4)
            .ttButtonHelp(prevHelp)
            .accessibilityLabel(prevHelp)

            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(action: {
                _ = paginationController.handleHorizontalArrow(isRightArrow: true)
                paginationController.onRequestRestoreReaderFocus?()
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(!canGoNext)
            .opacity(canGoNext ? 1.0 : 0.4)
            .ttButtonHelp(nextHelp)
            .accessibilityLabel(nextHelp)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
    }
}

// MARK: - Compatibility Aliases

public typealias EPUBBookReaderPreviewView = InteractiveEPUBReaderView
