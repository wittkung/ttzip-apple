// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import WebKit

// MARK: - EPUB Reading Session

/// Reading-session domain object for the EPUB engine.
///
/// TTMediaKit owns the reading engine, the pagination model, the annotation model and the
/// persistence contract. The workspace chrome — toolbar, typography panel, notes panel — is
/// owned by the host product: the host observes this session and renders its own controls
/// around the document surface that TTMediaKit renders.
///
/// The session never reaches back into the host library. Everything the host contributes
/// arrives through the injected `persistence` / `documentIdentity` contracts, mirroring
/// `EPUBReaderPersistence`.
@MainActor
public final class EPUBReaderSession: ObservableObject {

    // MARK: Inputs

    /// The parsed book the session reads.
    ///
    /// Module internal: the host supplied this model when it created the session, and every
    /// field of it is immutable, so handing it back would only let a host read state it
    /// already owns. Hosts read the chapter list through `chapters` instead.
    let bookModel: EPUBBookModel
    let fileURL: URL?
    let epubData: Data?

    /// The chapters of the current book, in reading order.
    public var chapters: [EPUBChapterItem] { bookModel.chapters }

    // MARK: Engine collaborators

    public let paginationController: EPUBPaginationController
    public let annotationSession: EPUBReaderAnnotationSession
    public var progressCheckpoint: EPUBReaderProgressCheckpoint

    // MARK: Reading state

    /// The five reading preferences.
    ///
    /// The setters are internal, so a host cannot assign a preference directly. A direct
    /// assignment would mark the snapshot pending without ever reaching the host contract,
    /// and the change would silently never persist. Hosts go through the public setters
    /// below, which write the value and then persist the preference set.
    @Published public var selectedChapterIndex: Int
    @Published public internal(set) var fontSize: Int {
        didSet { if oldValue != fontSize { schedulePreferenceWrite() } }
    }
    @Published public internal(set) var fontFamily: String {
        didSet { if oldValue != fontFamily { schedulePreferenceWrite() } }
    }
    @Published public internal(set) var cjkFontFamily: String {
        didSet { if oldValue != cjkFontFamily { schedulePreferenceWrite() } }
    }
    @Published public internal(set) var themeMode: String {
        didSet { if oldValue != themeMode { schedulePreferenceWrite() } }
    }
    @Published public internal(set) var layoutMode: String {
        didSet {
            guard oldValue != layoutMode else { return }
            // Engine behavior first, then the host write.
            //
            // A restore is silent: the legacy seed and the authoritative document value
            // both land here, and pushing each one would relayout the engine twice for
            // a single book. The restore path applies the final value instead.
            guard !isRestoringPreferences else { return }
            applyLayoutModeToEngine(layoutMode)
            schedulePreferenceWrite()
        }
    }

    // MARK: Preference persistence

    /// Suppresses preference writes while authoritative values are restored.
    ///
    /// The host contract persists the whole preference set at once, so a write
    /// between two assignments would persist a half-restored mix and overwrite the
    /// stored values with defaults.
    private var isRestoringPreferences = false

    /// Set when a preference changed and the snapshot still has to reach the host.
    ///
    /// The write lands in `flushReaderPreferences()`. The flag guards the write itself:
    /// it is raised by a change and consumed by the flush that follows, so a change
    /// never writes twice and a flush without a change never writes at all. The restore
    /// path is held back by `isRestoringPreferences` instead, which stops the change
    /// from ever raising this flag.
    private var pendingPreferenceWrite = false

    /// Marks the current preference snapshot as pending a host write.
    private func schedulePreferenceWrite() {
        guard !isRestoringPreferences else { return }
        pendingPreferenceWrite = true
    }

    /// Runs `body` with preference writes suspended.
    ///
    /// Used by the restore path, which assigns every preference in turn. Module
    /// internal because the restore path lives in `EPUBReaderSession+Workspace.swift`.
    func withPreferenceWritesSuspended(_ body: () -> Void) {
        isRestoringPreferences = true
        body()
        isRestoringPreferences = false
    }

    /// Writes the pending preference snapshot to the host persistence contract.
    ///
    /// The public setters call this right after they change a value, so a host never
    /// has to flush by hand. It stays module internal because the setters are the only
    /// supported way to change a preference.
    func flushReaderPreferences() {
        guard pendingPreferenceWrite, !isRestoringPreferences else { return }
        pendingPreferenceWrite = false
        persistReaderPreferences()
    }

    /// Sets the Latin font family and persists the preference snapshot.
    public func setFontFamily(_ value: String) {
        guard fontFamily != value else { return }
        fontFamily = value
        flushReaderPreferences()
    }

    /// Sets the CJK font family and persists the preference snapshot.
    public func setCJKFontFamily(_ value: String) {
        guard cjkFontFamily != value else { return }
        cjkFontFamily = value
        flushReaderPreferences()
    }

    /// Sets the reading font size and persists the preference snapshot.
    public func setFontSize(_ value: Int) {
        guard fontSize != value else { return }
        fontSize = value
        flushReaderPreferences()
    }

    /// Sets the reading theme and persists the preference snapshot.
    public func setThemeMode(_ value: String) {
        guard themeMode != value else { return }
        themeMode = value
        flushReaderPreferences()
    }

    /// Sets the reading layout and persists the preference snapshot.
    public func setLayoutMode(_ value: String) {
        guard layoutMode != value else { return }
        layoutMode = value
        flushReaderPreferences()
    }

    // MARK: Host-injected contracts

    /// Host-injected persistence. When absent the session keeps the legacy `UserDefaults` adapter.
    public var persistence: EPUBReaderPersistence?
    /// Host-injected stable document identity used as the persistence key.
    public var documentIdentity: String?

    // MARK: Presentation state

    @Published public var isSearchPopoverPresented: Bool = false
    @Published public var isTOCPopoverPresented: Bool = false
    @Published public var searchQuery: String = ""
    @Published public var searchMatches: [String] = []
    var searchTask: Task<Void, Never>?

    public init(
        bookModel: EPUBBookModel,
        fileURL: URL? = nil,
        epubData: Data? = nil,
        paginationController: EPUBPaginationController? = nil
    ) {
        self.bookModel = bookModel
        self.fileURL = fileURL ?? bookModel.url
        self.epubData = epubData
        let resolvedController = paginationController ?? EPUBPaginationController(
            initialChapterIndex: 0,
            totalChapters: max(bookModel.chapters.count, 1)
        )
        self.paginationController = resolvedController
        self.annotationSession = EPUBReaderAnnotationSession()
        self.progressCheckpoint = EPUBReaderProgressCheckpoint()
        self.selectedChapterIndex = 0
        self.fontSize = 17
        self.fontFamily = "serif"
        self.cjkFontFamily = "serif"
        self.themeMode = "light"
        self.layoutMode = "paginated"
    }

    // MARK: Identity

    static func makeTaskIdentity(fileURL: URL?, epubData: Data?) -> String {
        "\(fileURL?.path ?? "")|\(epubData?.count ?? 0)|\(epubData?.prefix(32).hashValue ?? 0)"
    }

    public var taskIdentityKey: String {
        Self.makeTaskIdentity(fileURL: fileURL, epubData: epubData)
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

    public var readerDocumentIdentity: String {
        documentIdentity ?? bookModel.url.absoluteString
    }

    public var bookProgressStorageKey: String {
        "TTMedia_EPUB_Progress_" + Self.stableBookDigest(for: Self.normalizeChapterLocation(bookModel.url))
    }

    /// Legacy keys used the last path component only, which collided across folders and archive entries.
    public var legacyProgressStorageKey: String {
        let normalized = Self.normalizeChapterLocation(bookModel.url)
        let bookIdentity = (normalized as NSString).lastPathComponent
        let safeSuffix = bookIdentity.isEmpty ? normalized : bookIdentity
        let cleaned = safeSuffix.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "TTMedia_EPUB_Progress_" + cleaned
    }

    public var currentReaderAnchor: EPUBReaderAnchor {
        if !paginationController.isPaginationReady,
           case .preserveAnchor(let ratio, let block, let character) = paginationController.pendingLanding {
            return EPUBReaderAnchor(
                chapterIndex: UInt32(clamping: selectedChapterIndex), blockIndex: UInt32(clamping: block ?? 0),
                characterOffset: UInt32(clamping: character), chapterRatio: ratio
            )
        }
        return EPUBReaderAnchor(
            chapterIndex: UInt32(clamping: selectedChapterIndex),
            blockIndex: UInt32(clamping: paginationController.anchorBlockIndex ?? 0),
            characterOffset: UInt32(clamping: paginationController.anchorCharOffset),
            chapterRatio: paginationController.normalizedProgressInChapter
        )
    }

    // MARK: Chapter navigation

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
        let normalizedPath = normalizeRelativeSegments(parsed.path).lowercased()
        guard !scheme.isEmpty && !host.isEmpty else {
            return normalizedPath
        }
        return "\(scheme)://\(host)/\(normalizedPath)"
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

    // MARK: Lifecycle

    /// Prepares the engine for the current book. Call once when the reader appears.
    public func prepareForReading() {
        restoreLegacyReaderPreferences()
        paginationController.configureBook(
            totalChapters: max(bookModel.chapters.count, 1),
            initialChapterIndex: selectedChapterIndex
        )
        restoreReadingProgress()
        restoreReaderWorkspace()
        // The restores are silent: the legacy seed and the authoritative document value
        // both land in `layoutMode`, and the engine takes the final value once.
        applyLayoutModeToEngine(layoutMode)
        paginationController.onRequestChapterIndexChange = { [weak self] newIndex, _ in
            guard let self else { return }
            self.selectedChapterIndex = newIndex
            self.persistReadingProgress()
        }
    }

    /// Resets every piece of session state before a different package is loaded.
    public func loadEPUBPackage() {
        searchTask?.cancel()
        searchTask = nil
        isSearchPopoverPresented = false
        isTOCPopoverPresented = false
        searchQuery = ""
        searchMatches = []
        selectedChapterIndex = 0
        paginationController.configureBook(
            totalChapters: max(bookModel.chapters.count, 1),
            initialChapterIndex: 0
        )
        annotationSession.annotations = []
        annotationSession.selection = nil
        annotationSession.errorMessage = nil
        restoreLegacyReaderPreferences()
        restoreReadingProgress()
        restoreReaderWorkspace()
        // The restores are silent: the legacy seed and the authoritative document value
        // both land in `layoutMode`, and the engine takes the final value once.
        applyLayoutModeToEngine(layoutMode)
    }

    /// Seeds the preferences from the legacy `UserDefaults` values.
    ///
    /// Module internal: the seed is only meaningful as the first half of a restore, and
    /// on its own it neither persists nor reaches the engine. Callers restore through
    /// `prepareForReading()` or `loadEPUBPackage()`.
    func restoreLegacyReaderPreferences() {
        let defaults = UserDefaults.standard
        // The legacy `UserDefaults` values are only a fallback seed: the host
        // document restores the authoritative preferences right after, and writing
        // the seed first would overwrite the stored values with defaults.
        withPreferenceWritesSuspended {
            fontFamily = defaults.string(forKey: "TTMedia_EPUB_FontFamily") ?? "serif"
            cjkFontFamily = defaults.string(forKey: "TTMedia_EPUB_CJKFontFamily") ?? "serif"
            fontSize = defaults.object(forKey: "TTMedia_EPUB_FontSize") as? Int ?? 17
            themeMode = defaults.string(forKey: "TTMedia_EPUB_ThemeMode") ?? "light"
            layoutMode = defaults.string(forKey: "TTMedia_EPUB_LayoutMode") ?? "paginated"
        }
    }

    public func restoreReadingProgress() {
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

    public func persistReadingProgress() {
        guard paginationController.isPaginationReady else { return }
        if let persistence {
            do {
                try progressCheckpoint.saveIfChanged(
                    identity: readerDocumentIdentity, anchor: currentReaderAnchor,
                    using: persistence.savePosition
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

    // MARK: Layout & focus handoff

    /// Applies a layout mode to the engine without touching the host contract.
    private func applyLayoutModeToEngine(_ mode: String) {
        let resolved = EPUBReadingLayoutPreference.resolve(stored: mode)
        paginationController.setLayoutMode(resolved)
        TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionLayoutMode(
            instanceID: paginationController.instanceID,
            layoutMode: resolved
        )
    }

    /// Tells the keyboard ownership coordinator that the host chrome took the interaction.
    public func notifyToolbarInteraction() {
        TTPreviewKeyboardOwnershipCoordinator.shared.notifyToolbarInteraction(
            instanceID: paginationController.instanceID
        )
    }

    /// Returns the reading surface focus after a host chrome interaction ended.
    public func requestReaderFocusRestore() {
        paginationController.onRequestRestoreReaderFocus?()
    }

    // MARK: Testing hooks

    func stageSearchAndPopoverStateForTesting(
        isSearchPresented: Bool = true,
        isTOCPresented: Bool = true,
        query: String = "chapter",
        matches: [String] = ["Match 1"],
        task: Task<Void, Never>? = nil
    ) {
        isSearchPopoverPresented = isSearchPresented
        isTOCPopoverPresented = isTOCPresented
        searchQuery = query
        searchMatches = matches
        searchTask = task
    }

    var effectiveIsSearchPopoverPresented: Bool { isSearchPopoverPresented }
    var effectiveIsTOCPopoverPresented: Bool { isTOCPopoverPresented }
    var effectiveSearchQuery: String { searchQuery }
    var effectiveSearchMatches: [String] { searchMatches }
}
