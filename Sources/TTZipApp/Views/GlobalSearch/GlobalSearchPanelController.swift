// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import Quartz
import SwiftUI
import TTLogKit
import TTZipCore
import TTZipUI

@MainActor
private protocol ForcedActivationProtocol {
    func activate(ignoringOtherApps: Bool)
}

extension NSApplication: ForcedActivationProtocol {}

@MainActor
public final class GlobalSearchPanelController: NSObject, ObservableObject {
    public static let shared = GlobalSearchPanelController()

    public static let panelWidth: CGFloat = 720
    public static let fieldHeight: CGFloat = 58
    public static let rowHeight: CGFloat = 46
    public static let maxExpandedHeight: CGFloat = 480

    @Published public var query: String = "" {
        didSet {
            if query != oldValue {
                queryDidChange()
            }
        }
    }

    @Published public var results: [GlobalSearchResultItem] = []
    @Published public var selectedIndex: Int = 0
    @Published public var isSearching: Bool = false
    @Published public private(set) var isSemanticSearchActive: Bool = false

    public let semanticEngine: SemanticSearchEngine
    public let modelManager: LocalModelManager
    private let stage2DebounceNanoseconds: UInt64

    private var selectedItemID: String?
    private var window: GlobalSearchPanelWindow?
    private var keyMonitor: Any?
    private var activity: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?
    private var currentGeneration: UInt64 = 0

    public var onActivateItem: ((GlobalSearchResultItem) -> Void)?
    public var onOpenArchive: ((String) -> Void)?
    public var onSelectEntry: ((String, String) -> Void)?

    public init(
        semanticEngine: SemanticSearchEngine? = nil,
        modelManager: LocalModelManager = .shared,
        stage2DebounceNanoseconds: UInt64 = 120_000_000
    ) {
        self.modelManager = modelManager
        self.semanticEngine = semanticEngine ?? modelManager.engine
        self.stage2DebounceNanoseconds = stage2DebounceNanoseconds
        self.isSemanticSearchActive = modelManager.isSemanticSearchAvailable
        super.init()
    }

    public var isVisible: Bool {
        window?.isVisible == true
    }

    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    public func show() {
        let win = self.window ?? makeWindow()
        placeWindow(win)

        bringAppToFront()
        win.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        PresentationCoordinator.shared.present(.globalSearch)

        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "TTZip Global Search Panel Open"
            )
        }
    }

    public func hide() {
        PresentationCoordinator.shared.dismiss(.globalSearch)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        window?.orderOut(nil)
        removeKeyMonitor()
        if let currentActivity = activity {
            ProcessInfo.processInfo.endActivity(currentActivity)
            activity = nil
        }
        searchTask?.cancel()
        searchTask = nil
        let activeGen = currentGeneration
        if activeGen > 0 {
            let engine = semanticEngine
            Task { await engine.cancelSearch(requestId: activeGen) }
        }
        isSearching = false
    }

    public func dismissAndRestoreFocus() {
        hide()
        if let mainWindow = NSApp.windows.first(where: { $0.canBecomeKey && $0 != self.window && $0.isVisible }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    public func selectPrevious() {
        if !results.isEmpty {
            selectedIndex = max(0, selectedIndex - 1)
            selectedItemID = results[selectedIndex].id
        }
    }

    public func selectNext() {
        if !results.isEmpty {
            selectedIndex = min(results.count - 1, selectedIndex + 1)
            selectedItemID = results[selectedIndex].id
        }
    }

    private var currentDesiredHeight: CGFloat {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || results.isEmpty {
            return Self.fieldHeight
        }
        let total = Self.fieldHeight + CGFloat(results.count) * Self.rowHeight + 12
        return min(total, Self.maxExpandedHeight)
    }

    private func makeWindow() -> GlobalSearchPanelWindow {
        let rect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.fieldHeight)
        let win = GlobalSearchPanelWindow(contentRect: rect)
        self.window = win
        return win
    }

    public func setWindowContentView(_ view: NSView) {
        let win = self.window ?? makeWindow()
        win.contentView = Self.buildVisualEffectContainer(content: view)
    }

    private static func buildVisualEffectContainer(content: NSView) -> NSView {
        let radius: CGFloat = 16
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = radius
        backdrop.layer?.masksToBounds = true

        let container = NSView()
        for v in [backdrop, content] {
            v.frame = container.bounds
            v.autoresizingMask = [.width, .height]
            container.addSubview(v)
        }
        return container
    }

    private func placeWindow(_ win: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = area.maxY - area.height * 0.16
        let height = currentDesiredHeight
        win.setFrame(
            NSRect(x: area.midX - Self.panelWidth / 2, y: top - height, width: Self.panelWidth, height: height),
            display: true
        )
    }

    private func resizeWindow() {
        guard let win = window else { return }
        let height = currentDesiredHeight
        guard abs(win.frame.height - height) > 0.5 else { return }
        DispatchQueue.main.async {
            var frame = win.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            win.setFrame(frame, display: true)
        }
    }

    private func bringAppToFront() {
        (NSApp as any ForcedActivationProtocol).activate(ignoringOtherApps: true)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // IME Safety Guard: Never intercept keys when user is composing candidate words
        if let fieldEditor = window?.firstResponder as? NSTextView, fieldEditor.hasMarkedText() {
            return false
        }

        switch event.keyCode {
        case 53: // Escape
            dismissAndRestoreFocus()
            return true
        case 126: // Up Arrow
            selectPrevious()
            return true
        case 125: // Down Arrow
            selectNext()
            return true
        case 36: // Return / Enter
            if event.modifierFlags.contains(.command) {
                revealSelectedInFinder()
            } else {
                activateSelectedItem()
            }
            return true
        case 49: // Space
            // Space only triggers Quick Look when accompanied by command/control modifiers
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                toggleQuickLook()
                return true
            }
            return false
        default:
            return false
        }
    }

    public func activateSelectedItem() {
        guard !results.isEmpty, selectedIndex >= 0, selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        hide()
        dispatchSearchResultActivation(item)
    }

    private func dispatchSearchResultActivation(_ item: GlobalSearchResultItem) {
        switch item.targetKind {
        case .archiveEntry(let archivePath, let entrySubpath):
            if let onActivateItem {
                onActivateItem(item)
            } else if let onSelectEntry {
                onSelectEntry(archivePath, entrySubpath)
            } else {
                _ = BrowserWindowRouter.shared.routeGlobalSearchResult(item)
            }
        case .archiveFile(let archivePath):
            if let onActivateItem {
                onActivateItem(item)
            } else if let onOpenArchive {
                onOpenArchive(archivePath)
            } else {
                _ = BrowserWindowRouter.shared.routeGlobalSearchResult(item)
            }
        case .diskItem(let path):
            if let onActivateItem {
                onActivateItem(item)
            } else if let onOpenArchive {
                onOpenArchive(path)
            } else {
                _ = BrowserWindowRouter.shared.routeGlobalSearchResult(item)
            }
        case .quickAction:
            break
        }
    }

    public func revealSelectedInFinder() {
        guard !results.isEmpty, selectedIndex >= 0, selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        if let path = item.diskPath ?? item.archivePath {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            hide()
        }
    }

    public func toggleQuickLook() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        if let path = item.diskPath ?? item.archivePath {
            window?.previewURL = URL(fileURLWithPath: path)
            let panel = QLPreviewPanel.shared()!
            if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
                panel.orderOut(nil)
            } else {
                QLPreviewPanel.shared().reloadData()
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func applyResults(_ hits: [GlobalSearchResultItem]) {
        self.results = hits
        if let currentID = self.selectedItemID, let idx = hits.firstIndex(where: { $0.id == currentID }) {
            self.selectedIndex = idx
        } else {
            self.selectedIndex = 0
            self.selectedItemID = hits.first?.id
        }
        self.resizeWindow()
    }

    private func queryDidChange() {
        let previousGen = currentGeneration
        if previousGen > 0 {
            let engine = semanticEngine
            Task { await engine.cancelSearch(requestId: previousGen) }
        }
        currentGeneration = SearchRequestIDAllocator.nextRequestID()
        let gen = currentGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSemanticSearchActive = modelManager.isSemanticSearchAvailable

        guard !trimmed.isEmpty, !modelManager.isShuttingDown, !modelManager.isShutDown else {
            searchTask?.cancel()
            searchTask = nil
            results = []
            selectedItemID = nil
            selectedIndex = 0
            isSearching = false
            resizeWindow()
            return
        }

        searchTask?.cancel()
        isSearching = true

        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.performSemanticAndSpotlightSearch(query: trimmed, generation: gen)
        }
    }

    /// Waits for any in-flight search task to complete (for deterministic tests).
    public func waitForActiveSearch() async {
        await searchTask?.value
    }

    private func performSemanticAndSpotlightSearch(query trimmed: String, generation gen: UInt64) async {
        // Stage 1: In-memory active VFS + Recent archives (< 1.5ms)
        let fastHits = await executeFastSearch(query: trimmed)
        guard !Task.isCancelled, gen == currentGeneration else { return }
        applyResults(fastHits)

        if stage2DebounceNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stage2DebounceNanoseconds)
            guard !Task.isCancelled, gen == currentGeneration else { return }
        }

        // Stage 2A: Semantic search when local model is ready
        if modelManager.isSemanticSearchAvailable {
            let semResponse = await semanticEngine.search(
                SemanticSearchRequest(
                    requestId: gen,
                    windowId: "global-search-panel",
                    query: trimmed,
                    scopeIds: [],
                    topK: 30
                )
            )
            guard !Task.isCancelled, gen == currentGeneration else { return }
            if !semResponse.isCancelled {
                isSemanticSearchActive = !semResponse.degradedLexicalOnly
                mergeHitsIntoResults(semResponse.hits.map { $0.toGlobalSearchResultItem() })
            }
        } else {
            isSemanticSearchActive = false
        }

        // Stage 2B: Spotlight disk archive search (always functional regardless of model state)
        let diskHits = await SpotlightArchiveSearchProvider.shared.search(query: trimmed, maxResults: 20)
        guard !Task.isCancelled, gen == currentGeneration else { return }
        mergeHitsIntoResults(diskHits)
        isSearching = false
    }

    private func mergeHitsIntoResults(_ incoming: [GlobalSearchResultItem]) {
        guard !incoming.isEmpty else { return }
        var merged = results
        for hit in incoming {
            let hitPath = (hit.diskPath ?? hit.archivePath).map(Self.canonicalPath)
            let isDuplicate = merged.contains { existing in
                guard (existing.entrySubpath ?? "") == (hit.entrySubpath ?? "") else { return false }
                let existingPath = (existing.diskPath ?? existing.archivePath).map(Self.canonicalPath)
                return existingPath != nil && existingPath == hitPath
            }
            if !isDuplicate {
                merged.append(hit)
            }
        }
        applyResults(merged)
    }

    public func executeFastSearch(query: String) async -> [GlobalSearchResultItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowerQuery = trimmed.lowercased()

        var items: [GlobalSearchResultItem] = []
        var seenArchivePaths: Set<String> = []
        var seenEntryKeys: Set<String> = []

        items.append(contentsOf: collectLiveWindowSearchHits(
            query: trimmed,
            lowerQuery: lowerQuery,
            seenArchivePaths: &seenArchivePaths,
            seenEntryKeys: &seenEntryKeys
        ))
        items.append(contentsOf: collectRegisteredSessionSearchHits(
            query: trimmed,
            lowerQuery: lowerQuery,
            seenArchivePaths: &seenArchivePaths,
            seenEntryKeys: &seenEntryKeys
        ))
        items.append(contentsOf: await collectCachedHierarchySearchHits(
            query: trimmed,
            lowerQuery: lowerQuery,
            seenArchivePaths: &seenArchivePaths,
            seenEntryKeys: &seenEntryKeys
        ))
        items.append(contentsOf: collectRecentArchiveSearchHits(
            lowerQuery: lowerQuery,
            seenArchivePaths: &seenArchivePaths
        ))

        return items
    }

    private func collectLiveWindowSearchHits(
        query: String,
        lowerQuery: String,
        seenArchivePaths: inout Set<String>,
        seenEntryKeys: inout Set<String>
    ) -> [GlobalSearchResultItem] {
        var hits: [GlobalSearchResultItem] = []
        let controllers = BrowserWindowRegistry.shared.allControllers.compactMap { $0 as? AppViewState }
        for state in controllers {
            guard !state.isWindowClosing,
                  let path = state.explorerState.currentArchivePath,
                  !path.isEmpty else {
                continue
            }
            let canonicalArchive = Self.canonicalPath(path)
            let archiveName = (path as NSString).lastPathComponent

            if (archiveName.lowercased().contains(lowerQuery) || path.lowercased().contains(lowerQuery)),
               seenArchivePaths.insert(canonicalArchive).inserted {
                hits.append(Self.makeArchiveFileHit(
                    idPrefix: "archive",
                    path: path,
                    archiveName: archiveName,
                    hitType: .archiveFile,
                    byteSize: 0,
                    score: 1.0,
                    targetWindowID: state.windowID
                ))
            }

            hits.append(contentsOf: collectWindowEntryHits(
                state: state,
                archivePath: path,
                canonicalArchive: canonicalArchive,
                archiveName: archiveName,
                query: query,
                lowerQuery: lowerQuery,
                seenEntryKeys: &seenEntryKeys
            ))
        }
        return hits
    }

    private func collectWindowEntryHits(
        state: AppViewState,
        archivePath: String,
        canonicalArchive: String,
        archiveName: String,
        query: String,
        lowerQuery: String,
        seenEntryKeys: inout Set<String>
    ) -> [GlobalSearchResultItem] {
        var hits: [GlobalSearchResultItem] = []
        if let vfsSession = state.explorerState.vfsSession,
           let paged = try? vfsSession.searchTopK(query: query, limit: 30) {
            for node in paged {
                let entryKey = Self.entryDedupKey(canonicalArchive: canonicalArchive, subpath: node.path)
                guard seenEntryKeys.insert(entryKey).inserted else { continue }
                hits.append(Self.makeArchiveEntryHit(
                    archivePath: archivePath,
                    archiveName: archiveName,
                    entryPath: node.path,
                    entryName: node.name,
                    isDirectory: node.isDir,
                    byteSize: Int64(clamping: node.size),
                    score: 0.96,
                    targetWindowID: state.windowID
                ))
            }
        }

        var count = 0
        for entry in state.explorerState.currentEntries {
            guard entry.name.lowercased().contains(lowerQuery) || entry.path.lowercased().contains(lowerQuery) else {
                continue
            }
            let entryKey = Self.entryDedupKey(canonicalArchive: canonicalArchive, subpath: entry.path)
            guard seenEntryKeys.insert(entryKey).inserted else { continue }
            hits.append(Self.makeArchiveEntryHit(
                archivePath: archivePath,
                archiveName: archiveName,
                entryPath: entry.path,
                entryName: entry.name,
                isDirectory: entry.isDirectory,
                byteSize: entry.uncompressedSize,
                score: 0.90,
                targetWindowID: state.windowID
            ))
            count += 1
            if count >= 30 { break }
        }
        return hits
    }

    private func collectRegisteredSessionSearchHits(
        query: String,
        lowerQuery: String,
        seenArchivePaths: inout Set<String>,
        seenEntryKeys: inout Set<String>
    ) -> [GlobalSearchResultItem] {
        var hits: [GlobalSearchResultItem] = []
        for session in AppIntentDispatcher.shared.allSessions {
            guard let path = session.currentArchivePath, !path.isEmpty, !session.isClosed else { continue }
            let canonicalArchive = Self.canonicalPath(path)
            let archiveName = (path as NSString).lastPathComponent
            let preferredWindowID = session.id

            if archiveName.lowercased().contains(lowerQuery),
               seenArchivePaths.insert(canonicalArchive).inserted {
                hits.append(Self.makeArchiveFileHit(
                    idPrefix: "archive",
                    path: path,
                    archiveName: archiveName,
                    hitType: .archiveFile,
                    byteSize: 0,
                    score: 1.0,
                    targetWindowID: preferredWindowID
                ))
            }

            if let vfs = session.vfsTree {
                for match in vfs.search(query: query, maxResults: 30) {
                    let entryKey = Self.entryDedupKey(canonicalArchive: canonicalArchive, subpath: match.path)
                    guard seenEntryKeys.insert(entryKey).inserted else { continue }
                    hits.append(Self.makeArchiveEntryHit(
                        archivePath: path,
                        archiveName: archiveName,
                        entryPath: match.path,
                        entryName: match.name,
                        isDirectory: match.isDirectory,
                        byteSize: Int64(match.size),
                        score: 0.95,
                        targetWindowID: preferredWindowID
                    ))
                }
            } else if !session.currentEntries.isEmpty {
                var count = 0
                for entry in session.currentEntries {
                    guard entry.name.lowercased().contains(lowerQuery) || entry.path.lowercased().contains(lowerQuery) else {
                        continue
                    }
                    let entryKey = Self.entryDedupKey(canonicalArchive: canonicalArchive, subpath: entry.path)
                    guard seenEntryKeys.insert(entryKey).inserted else { continue }
                    hits.append(Self.makeArchiveEntryHit(
                        archivePath: path,
                        archiveName: archiveName,
                        entryPath: entry.path,
                        entryName: entry.name,
                        isDirectory: entry.isDirectory,
                        byteSize: entry.uncompressedSize,
                        score: 0.85,
                        targetWindowID: preferredWindowID
                    ))
                    count += 1
                    if count >= 30 { break }
                }
            }
        }
        return hits
    }

    private func collectCachedHierarchySearchHits(
        query: String,
        lowerQuery: String,
        seenArchivePaths: inout Set<String>,
        seenEntryKeys: inout Set<String>
    ) async -> [GlobalSearchResultItem] {
        var hits: [GlobalSearchResultItem] = []
        let cachedPaths = await ArchiveHierarchySessionCache.shared.cachedArchivePaths()
        for path in cachedPaths {
            guard let cached = await ArchiveHierarchySessionCache.shared.cachedSession(for: path) else { continue }
            let canonicalArchive = Self.canonicalPath(path)
            let archiveName = (path as NSString).lastPathComponent

            if archiveName.lowercased().contains(lowerQuery),
               seenArchivePaths.insert(canonicalArchive).inserted {
                hits.append(Self.makeArchiveFileHit(
                    idPrefix: "archive",
                    path: path,
                    archiveName: archiveName,
                    hitType: .archiveFile,
                    byteSize: cached.fileByteSize,
                    score: 0.95,
                    targetWindowID: nil
                ))
            }

            if let vfs = cached.vfsTree {
                for match in vfs.search(query: query, maxResults: 20) {
                    let entryKey = Self.entryDedupKey(canonicalArchive: canonicalArchive, subpath: match.path)
                    guard seenEntryKeys.insert(entryKey).inserted else { continue }
                    hits.append(Self.makeArchiveEntryHit(
                        archivePath: path,
                        archiveName: archiveName,
                        entryPath: match.path,
                        entryName: match.name,
                        isDirectory: match.isDirectory,
                        byteSize: Int64(match.size),
                        score: 0.90,
                        targetWindowID: nil
                    ))
                }
            }
        }
        return hits
    }

    private func collectRecentArchiveSearchHits(
        lowerQuery: String,
        seenArchivePaths: inout Set<String>
    ) -> [GlobalSearchResultItem] {
        guard let data = UserDefaults.standard.data(forKey: "TTZipRecentArchivesKey"),
              let records = try? JSONDecoder().decode([RecentArchiveRecord].self, from: data) else {
            return []
        }
        var hits: [GlobalSearchResultItem] = []
        for rec in records {
            let canonicalArchive = Self.canonicalPath(rec.path)
            guard !seenArchivePaths.contains(canonicalArchive) else { continue }
            guard rec.name.lowercased().contains(lowerQuery) || rec.path.lowercased().contains(lowerQuery) else {
                continue
            }
            guard FileManager.default.fileExists(atPath: rec.path) else { continue }
            seenArchivePaths.insert(canonicalArchive)
            hits.append(Self.makeArchiveFileHit(
                idPrefix: "recent",
                path: rec.path,
                archiveName: rec.name,
                hitType: .recentArchive,
                byteSize: 0,
                score: 0.70,
                targetWindowID: nil
            ))
        }
        return hits
    }

    private static func makeArchiveFileHit(
        idPrefix: String,
        path: String,
        archiveName: String,
        hitType: GlobalSearchHitType,
        byteSize: Int64,
        score: Float,
        targetWindowID: UUID?
    ) -> GlobalSearchResultItem {
        GlobalSearchResultItem(
            id: "\(idPrefix):\(path)",
            title: archiveName,
            subtitle: path,
            hitType: hitType,
            archivePath: path,
            targetWindowID: targetWindowID,
            isDirectory: false,
            byteSize: byteSize,
            score: score,
            matchBadge: nil
        )
    }

    private static func makeArchiveEntryHit(
        archivePath: String,
        archiveName: String,
        entryPath: String,
        entryName: String,
        isDirectory: Bool,
        byteSize: Int64,
        score: Float,
        targetWindowID: UUID?
    ) -> GlobalSearchResultItem {
        GlobalSearchResultItem(
            id: "entry:\(archivePath):\(entryPath)",
            title: entryName,
            subtitle: "\(archiveName) → \(entryPath)",
            hitType: .archiveEntry,
            archivePath: archivePath,
            entrySubpath: entryPath,
            targetWindowID: targetWindowID,
            isDirectory: isDirectory,
            byteSize: byteSize,
            score: score,
            matchBadge: nil
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func entryDedupKey(canonicalArchive: String, subpath: String) -> String {
        let normalized = ArchivePasswordProbePolicy.normalizeEntryPath(subpath)
        return "\(canonicalArchive)::\(normalized)"
    }
}
