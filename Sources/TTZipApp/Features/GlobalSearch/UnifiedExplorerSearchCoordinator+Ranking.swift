// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipSearchKit
import TTZipCore
import TTZipUI

extension UnifiedExplorerSearchCoordinator {
    // MARK: - Snapshot Assembly & Deduplication

    internal var orderedVisibleItems: [GlobalSearchResultItem] {
        currentDirectoryGroup.items + fullDiskGroup.items
    }

    internal func rebuildGroupSnapshots() {
        let modelReady = modelManager.isSemanticSearchAvailable || isSemanticQueryEncodedForRequest
        currentDirectoryGroup = buildCurrentDirectoryGroupSnapshot(modelReady: modelReady)
        fullDiskGroup = buildFullDiskGroupSnapshot(modelReady: modelReady)

        let items = orderedVisibleItems
        if hasExplicitUserSelection, let currentID = selectedResultID, items.contains(where: { $0.id == currentID }) {
            return
        }
        hasExplicitUserSelection = false
        selectedResultID = items.first?.id
    }

    public func moveSelectionDown() {
        let items = orderedVisibleItems
        guard !items.isEmpty else { selectedResultID = nil; hasExplicitUserSelection = false; return }
        hasExplicitUserSelection = true
        guard let currentID = selectedResultID, let idx = items.firstIndex(where: { $0.id == currentID }) else {
            selectedResultID = items.first?.id
            return
        }
        selectedResultID = items[min(idx + 1, items.count - 1)].id
    }

    public func moveSelectionUp() {
        let items = orderedVisibleItems
        guard !items.isEmpty else { selectedResultID = nil; hasExplicitUserSelection = false; return }
        hasExplicitUserSelection = true
        guard let currentID = selectedResultID, let idx = items.firstIndex(where: { $0.id == currentID }) else {
            selectedResultID = items.first?.id
            return
        }
        selectedResultID = items[max(idx - 1, 0)].id
    }

    @discardableResult
    public func openSelectedResult(
        in viewModel: AppViewState,
        clearQueryAfterNavigation: Bool = true
    ) -> Task<Bool, Never>? {
        let items = orderedVisibleItems
        guard let target = items.first(where: { $0.id == selectedResultID }) ?? items.first else { return nil }
        return activateResult(target, in: viewModel, clearQueryAfterNavigation: clearQueryAfterNavigation)
    }

    internal func buildCurrentDirectoryGroupSnapshot(modelReady: Bool) -> ExplorerSearchGroupSnapshot {
        let mergedCurrentItems = Self.deduplicateWithinGroup(
            primary: currentDirSemanticItems, secondary: currentDirLexicalItems
        )
        let isCurrentLoading = !currentDirLexicalCompleted || (!currentDirSemanticCompleted && mergedCurrentItems.isEmpty)
        let currentPhase = Self.resolveGroupPhase(
            errorMessage: currentDirError, isLoading: isCurrentLoading, isEmpty: mergedCurrentItems.isEmpty
        )
        let currentCoverage = ExplorerSearchCoverageNote(
            scopeDescription: activeScope.displayPath,
            visitedEntryCount: currentDirVisitedEntries,
            maxDepthVisited: currentDirMaxDepthVisited,
            truncationReasons: currentDirTruncationReasons,
            skippedUnauthorizedSubdirectoryCount: currentDirSkippedUnauthorized,
            skippedDatalessFileCount: currentDirSkippedDataless,
            isModelReady: modelReady,
            isSemanticQueryEncoded: isSemanticQueryEncodedForRequest,
            hasSemanticContentHits: currentDirSemanticItems.contains(where: { $0.matchBadge == "AI" }),
            indexedScopeCount: indexedScopeCountForRequest,
            indexedSegmentCount: indexedSegmentCountForRequest
        )
        return ExplorerSearchGroupSnapshot(
            title: Self.currentDirectoryGroupTitle(), subtitle: activeScope.displayPath,
            phase: currentPhase, items: mergedCurrentItems, coverage: currentCoverage
        )
    }

    internal func buildFullDiskGroupSnapshot(modelReady: Bool) -> ExplorerSearchGroupSnapshot {
        let mergedFullItems = Self.deduplicateWithinGroup(
            primary: fullDiskSemanticItems, secondary: fullDiskFastItems + fullDiskSpotlightItems
        )
        let isFullLoading = !fullDiskFastCompleted || !fullDiskSpotlightCompleted || (!fullDiskSemanticCompleted && mergedFullItems.isEmpty)
        let fullPhase = Self.resolveGroupPhase(
            errorMessage: nil, isLoading: isFullLoading, isEmpty: mergedFullItems.isEmpty
        )
        let fullCoverage = ExplorerSearchCoverageNote(
            scopeDescription: Self.fullDiskGroupSubtitle(),
            isModelReady: modelReady,
            isSemanticQueryEncoded: isSemanticQueryEncodedForRequest,
            hasSemanticContentHits: hasSemanticContentHitsForRequest,
            indexedScopeCount: indexedScopeCountForRequest,
            indexedSegmentCount: indexedSegmentCountForRequest
        )
        return ExplorerSearchGroupSnapshot(
            title: Self.fullDiskGroupTitle(), subtitle: Self.fullDiskGroupSubtitle(),
            phase: fullPhase, items: mergedFullItems, coverage: fullCoverage
        )
    }

    internal static func resolveGroupPhase(
        errorMessage: String?,
        isLoading: Bool,
        isEmpty: Bool
    ) -> ExplorerSearchGroupPhase {
        if let errorMessage, isEmpty {
            return .error(errorMessage)
        }
        if isLoading && isEmpty {
            return .loading
        }
        return isEmpty ? .empty : .completed
    }

    /// Deduplicates items within a single group by canonical target identity.
    /// Items in `primary` (e.g. semantic hits with snippets/line numbers) win over `secondary` (lexical hits),
    /// ensuring late lexical arrivals never overwrite already-arrived semantic items.
    public static func deduplicateWithinGroup(
        primary: [GlobalSearchResultItem],
        secondary: [GlobalSearchResultItem]
    ) -> [GlobalSearchResultItem] {
        var seenKeys: Set<String> = []
        var result: [GlobalSearchResultItem] = []
        result.reserveCapacity(primary.count + secondary.count)

        for item in primary {
            let key = canonicalTargetIdentityKey(for: item)
            if seenKeys.insert(key).inserted {
                result.append(item)
            }
        }
        for item in secondary {
            let key = canonicalTargetIdentityKey(for: item)
            if seenKeys.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    /// Computes a canonical identity key for intra-group deduplication (`diskPath` or `archivePath::entrySubpath`).
    public static func canonicalTargetIdentityKey(for item: GlobalSearchResultItem) -> String {
        switch item.targetKind {
        case .archiveEntry(let archivePath, let entrySubpath):
            let canonicalArchive = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
            let cleanEntry = ArchivePasswordProbePolicy.normalizeEntryPath(entrySubpath)
            return "archiveEntry:\(canonicalArchive)::\(cleanEntry)"
        case .archiveFile(let archivePath):
            let canonicalArchive = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
            return "File:\(canonicalArchive)"
        case .diskItem(let path):
            let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            return "File:\(canonicalPath)"
        case .quickAction:
            return "action:\(item.id)"
        }
    }

    public static func belongsToCurrentScope(
        item: GlobalSearchResultItem,
        scope: ExplorerSearchScopeIdentity
    ) -> Bool {
        switch scope {
        case .physicalDirectory(let dirURL):
            return belongsToPhysicalDirectoryScope(item: item, dirURL: dirURL)
        case .archiveContext(let archivePath, let subpath):
            return belongsToArchiveScope(item: item, archivePath: archivePath, subpath: subpath)
        case .externalDevice, .unsupported:
            return false
        }
    }

    private static func belongsToPhysicalDirectoryScope(
        item: GlobalSearchResultItem,
        dirURL: URL
    ) -> Bool {
        let rootCanonical = dirURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootCanonical.hasSuffix("/") ? rootCanonical : rootCanonical + "/"
        let candidatePath: String? = switch item.targetKind {
        case .diskItem(let path): path
        case .archiveFile(let archivePath): archivePath
        case .archiveEntry(let archivePath, _): archivePath
        case .quickAction: nil
        }
        guard let candidatePath else { return false }
        let canonicalCandidate = URL(fileURLWithPath: candidatePath).standardizedFileURL.resolvingSymlinksInPath().path
        return canonicalCandidate.hasPrefix(prefix)
    }

    private static func belongsToArchiveScope(
        item: GlobalSearchResultItem,
        archivePath: String,
        subpath: String
    ) -> Bool {
        let canonicalScopeArchive = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard case .archiveEntry(let hitArchive, let entrySubpath) = item.targetKind else {
            return false
        }
        let canonicalHitArchive = URL(fileURLWithPath: hitArchive).standardizedFileURL.resolvingSymlinksInPath().path
        guard canonicalHitArchive == canonicalScopeArchive else { return false }
        let cleanSubpath = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanSubpath.isEmpty else { return true }
        let cleanEntry = ArchivePasswordProbePolicy.normalizeEntryPath(entrySubpath)
        return cleanEntry == cleanSubpath || cleanEntry.hasPrefix(cleanSubpath + "/")
    }

    // MARK: - Navigation & Reveal in Existing Miller Columns

    /// Selects a search result item and reveals it in `viewModel`'s existing Miller columns
    /// and preview inspector, clearing `explorerState.searchQuery` so the columns become visible.
    @discardableResult
    public func activateResult(
        _ item: GlobalSearchResultItem,
        in viewModel: AppViewState,
        clearQueryAfterNavigation: Bool = true
    ) -> Task<Bool, Never>? {
        selectedResultID = item.id
        if clearQueryAfterNavigation {
            viewModel.explorerState.searchQuery = ""
            clearSearch()
        }

        switch item.targetKind {
        case .diskItem(let path):
            revealDiskPathInMillerColumns(path: path, in: viewModel)
            return nil

        case .archiveFile(let archivePath):
            let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
            viewModel.openArchiveAsFolder(url: archiveURL)
            return nil

        case .archiveEntry(let archivePath, let entrySubpath):
            return viewModel.selectArchiveEntryInWindow(
                archivePath: archivePath,
                entrySubpath: entrySubpath,
                highlightLine: item.matchedLineStart
            )

        case .quickAction:
            return nil
        }
    }

    private func revealDiskPathInMillerColumns(path: String, in viewModel: AppViewState) {
        let targetURL = URL(fileURLWithPath: path).standardizedFileURL
        let currentRoot = viewModel.navigationState.currentDirectory.standardizedFileURL
        let rootPrefix = currentRoot.path.hasSuffix("/") ? currentRoot.path : currentRoot.path + "/"

        if viewModel.explorerState.currentArchivePath != nil {
            viewModel.closeCurrentArchive()
        }
        viewModel.navigationState.activeTab = .home

        if targetURL.path != currentRoot.path && targetURL.path.hasPrefix(rootPrefix) {
            viewModel.initialSelectedFilePath = targetURL.path
            let diskItem = DiskItemInfo(url: targetURL)
            viewModel.selectionState.select(diskItem)
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipRevealDescendantInMillerColumns"),
                object: targetURL.path,
                userInfo: ["windowID": viewModel.windowID]
            )
        } else {
            viewModel.revealItemInWindow(targetURL)
        }
    }
}
