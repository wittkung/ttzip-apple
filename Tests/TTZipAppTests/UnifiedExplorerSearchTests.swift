// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import TTZipApp
import TTZipCore
import TTZipUI

// MARK: - Test Doubles for Deterministic S1 Search Verification

actor ControlledRecursiveScanner: DirectoryRecursiveSearching {
    private var outcomeByRoot: [String: DirectoryRecursiveSearchOutcome] = [:]
    private var delayNanosecondsByQuery: [String: UInt64] = [:]
    private(set) var recordedCalls: [(rootPath: String, query: String)] = []

    func setOutcome(_ outcome: DirectoryRecursiveSearchOutcome, forRoot path: String) {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        outcomeByRoot[canonical] = outcome
    }

    func setDelay(_ nanoseconds: UInt64, forQuery query: String) {
        delayNanosecondsByQuery[query] = nanoseconds
    }

    func searchDirectoryRecursively(
        rootURL: URL,
        query: String,
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int
    ) async throws -> DirectoryRecursiveSearchOutcome {
        let canonical = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        recordedCalls.append((canonical, query))
        if let delay = delayNanosecondsByQuery[query], delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        try Task.checkCancellation()
        return outcomeByRoot[canonical] ?? DirectoryRecursiveSearchOutcome(items: [])
    }
}

actor ControlledSystemSearchProvider: SystemFileSearchProviding {
    private var resultsByQuery: [String: [GlobalSearchResultItem]] = [:]
    private var delayNanosecondsByQuery: [String: UInt64] = [:]

    func setResults(_ items: [GlobalSearchResultItem], forQuery query: String) {
        resultsByQuery[query] = items
    }

    func setDelay(_ nanoseconds: UInt64, forQuery query: String) {
        delayNanosecondsByQuery[query] = nanoseconds
    }

    func searchAllAccessibleItems(
        query: String,
        maxResults: Int,
        additionalScopes: [URL]
    ) async -> [GlobalSearchResultItem] {
        if let delay = delayNanosecondsByQuery[query], delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        guard !Task.isCancelled else { return [] }
        return Array((resultsByQuery[query] ?? []).prefix(maxResults))
    }
}

actor ControlledSemanticEngine: SemanticSearchEngineProtocol {
    private var responseByQuery: [String: SemanticSearchResponse] = [:]
    private var delayNanosecondsByQuery: [String: UInt64] = [:]
    private(set) var cancelledRequestIDs: [UInt64] = []
    private(set) var receivedRequests: [SemanticSearchRequest] = []

    func setResponse(_ response: SemanticSearchResponse, forQuery query: String) {
        responseByQuery[query] = response
    }

    func setDelay(_ nanoseconds: UInt64, forQuery query: String) {
        delayNanosecondsByQuery[query] = nanoseconds
    }

    func modelState() async -> SemanticModelInstallState {
        .ready(SemanticModelDescriptor())
    }

    func registerScope(_ descriptor: SemanticScopeDescriptor) async -> Bool { true }
    func revokeScope(scopeId: String) async -> Bool { true }

    func startIndexing(scopeId: String) async -> SemanticIndexProgress {
        SemanticIndexProgress(
            scopeId: scopeId,
            phase: .completed,
            processedFiles: 0,
            totalFiles: 0,
            indexedSegments: 0,
            indexGeneration: 1
        )
    }

    func cancelIndexing(scopeId: String) async {}
    func indexProgress(scopeId: String) async -> SemanticIndexProgress? { nil }

    func upsertArchiveEntries(
        scopeId: String,
        entries: [(entryPath: String, data: Data, mtimeNs: Int64)]
    ) async -> SemanticIndexProgress {
        SemanticIndexProgress(
            scopeId: scopeId,
            phase: .completed,
            processedFiles: UInt32(entries.count),
            totalFiles: UInt32(entries.count),
            indexedSegments: UInt32(entries.count),
            indexGeneration: 1
        )
    }

    func removeIndexedFile(scopeId: String, relativePath: String) async -> Bool { true }

    func search(_ request: SemanticSearchRequest) async -> SemanticSearchResponse {
        receivedRequests.append(request)
        if let delay = delayNanosecondsByQuery[request.query], delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        if Task.isCancelled || cancelledRequestIDs.contains(request.requestId) {
            return SemanticSearchResponse(
                requestId: request.requestId,
                windowId: request.windowId,
                isCancelled: true,
                degradedLexicalOnly: true,
                hits: []
            )
        }
        if let preset = responseByQuery[request.query] {
            return SemanticSearchResponse(
                requestId: request.requestId,
                windowId: request.windowId,
                isCancelled: preset.isCancelled,
                degradedLexicalOnly: preset.degradedLexicalOnly,
                hits: preset.hits
            )
        }
        return SemanticSearchResponse(
            requestId: request.requestId,
            windowId: request.windowId,
            isCancelled: false,
            degradedLexicalOnly: true,
            hits: []
        )
    }

    func cancelSearch(requestId: UInt64) async {
        cancelledRequestIDs.append(requestId)
    }

    nonisolated func buildOpenRequest(for hit: SemanticSearchHit) -> SemanticOpenRequest {
        SemanticOpenRequest(
            scopeId: hit.scopeId,
            sourceKind: hit.sourceKind,
            outerPath: hit.resolvedOuterFilePath,
            archiveEntryPath: hit.archiveEntryPath,
            lineNumber: hit.lineStart
        )
    }

    @discardableResult
    func shutdown() async -> Bool { true }
}

final class UnifiedExplorerSearchTests: XCTestCase {

    @MainActor
    func testDualGroupSimultaneousSearchAndRecursiveSubdirectoryScan() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("ttzip-s1-dual-\(UUID().uuidString)", isDirectory: true)
        let nestedDir = tempRoot.appendingPathComponent("docs/sub/deep", isDirectory: true)
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let rootFile = tempRoot.appendingPathComponent("roadmap_notes.txt")
        let nestedFile = nestedDir.appendingPathComponent("roadmap_architecture.md")
        let datalessFile = nestedDir.appendingPathComponent("roadmap_cloud_only.txt")
        try Data("root".utf8).write(to: rootFile)
        try Data("nested".utf8).write(to: nestedFile)
        try Data("cloud".utf8).write(to: datalessFile)
        let datalessCanonicalPath = datalessFile.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(DefaultDirectoryRecursiveScanner.isStatFlagDataless(UInt32(SF_DATALESS)))
        XCTAssertFalse(DefaultDirectoryRecursiveScanner.isStatFlagDataless(0))

        let systemProvider = ControlledSystemSearchProvider()
        await systemProvider.setResults(
            [
                GlobalSearchResultItem(
                    id: "spotlight:item:/Users/shared/roadmap_guide.epub",
                    title: "roadmap_guide.epub",
                    subtitle: "/Users/shared",
                    hitType: .archiveEntry,
                    diskPath: "/Users/shared/roadmap_guide.epub",
                    isDirectory: false,
                    byteSize: 4096,
                    score: 0.72
                ),
                GlobalSearchResultItem(
                    id: "spotlight:item:/Users/shared/roadmap_summary.txt",
                    title: "roadmap_summary.txt",
                    subtitle: "/Users/shared",
                    hitType: .archiveEntry,
                    diskPath: "/Users/shared/roadmap_summary.txt",
                    isDirectory: false,
                    byteSize: 1024,
                    score: 0.71
                )
            ],
            forQuery: "roadmap"
        )

        let engine = ControlledSemanticEngine()
        let scanner = DefaultDirectoryRecursiveScanner(
            customDatalessDetector: { path, flags in
                DefaultDirectoryRecursiveScanner.isStatFlagDataless(flags)
                    || path.hasSuffix("roadmap_cloud_only.txt")
                    || path == datalessCanonicalPath
            }
        )
        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: scanner,
            systemSearchProvider: systemProvider,
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )

        coordinator.updateSearch(
            query: "roadmap",
            scope: .physicalDirectory(tempRoot)
        )
        await coordinator.waitForActiveSearch()

        XCTAssertEqual(coordinator.currentDirectoryGroup.phase, .completed)
        let currentTitles = Set(coordinator.currentDirectoryGroup.items.map(\.title))
        XCTAssertTrue(currentTitles.contains("roadmap_notes.txt"))
        XCTAssertTrue(currentTitles.contains("roadmap_architecture.md"))
        XCTAssertFalse(currentTitles.contains("roadmap_cloud_only.txt"))
        XCTAssertEqual(coordinator.currentDirectoryGroup.coverage.skippedDatalessFileCount, 1)

        XCTAssertEqual(coordinator.fullDiskGroup.phase, .completed)
        let fullTitles = Set(coordinator.fullDiskGroup.items.map(\.title))
        XCTAssertTrue(fullTitles.contains("roadmap_guide.epub"))
        XCTAssertTrue(fullTitles.contains("roadmap_summary.txt"))
    }

    @MainActor
    func testSpotlightFilterModePreservesArchiveDefaultAndAllowsGeneralFiles() async {
        let records: [SpotlightQueryRecord] = [
            SpotlightQueryRecord(path: "/tmp/bundle.zip", byteSize: 512, isDirectory: false),
            SpotlightQueryRecord(path: "/tmp/manual.txt", byteSize: 128, isDirectory: false),
            SpotlightQueryRecord(path: "/tmp/book.epub", byteSize: 2048, isDirectory: false),
            SpotlightQueryRecord(path: "/tmp/DesignDocs", byteSize: 0, isDirectory: true)
        ]

        let archiveOnly = makeSpotlightResultItems(from: records, maxResults: 20, filterMode: .archivesOnly)
        XCTAssertEqual(archiveOnly.count, 1)
        XCTAssertEqual(archiveOnly.first?.targetKind, GlobalSearchTargetKind.archiveFile(archivePath: "/tmp/bundle.zip"))

        let allItems = makeSpotlightResultItems(from: records, maxResults: 20, filterMode: .allAccessibleItems)
        XCTAssertEqual(allItems.count, 4)
        let targetKinds: [GlobalSearchTargetKind] = allItems.map { $0.targetKind }
        XCTAssertTrue(targetKinds.contains(.archiveFile(archivePath: "/tmp/bundle.zip")))
        XCTAssertTrue(targetKinds.contains(.diskItem(path: "/tmp/manual.txt")))
        XCTAssertTrue(targetKinds.contains(.diskItem(path: "/tmp/book.epub")))
        XCTAssertTrue(targetKinds.contains(.diskItem(path: "/tmp/DesignDocs")))
    }

    @MainActor
    func testZeroMatchesDistinguishedFromEmptyFolder() async {
        let scanner = ControlledRecursiveScanner()
        let systemProvider = ControlledSystemSearchProvider()
        let engine = ControlledSemanticEngine()

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: scanner,
            systemSearchProvider: systemProvider,
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )

        let dirURL = URL(fileURLWithPath: "/tmp/ttzip-zero-match-dir")
        coordinator.updateSearch(query: "nonexistent_token_xyz", scope: .physicalDirectory(dirURL))
        await coordinator.waitForActiveSearch()

        XCTAssertEqual(coordinator.currentDirectoryGroup.phase, .empty)
        XCTAssertEqual(coordinator.fullDiskGroup.phase, .empty)
        XCTAssertFalse(coordinator.currentDirectoryGroup.allowsCreationInEmptyState)
        XCTAssertFalse(coordinator.fullDiskGroup.allowsCreationInEmptyState)

        let placeholder = SearchNoMatchesPlaceholderView(query: "nonexistent_token_xyz")
        XCTAssertFalse(placeholder.allowsCreation)
        XCTAssertTrue(placeholder.titleText.contains("未找到匹配") || placeholder.titleText.contains("No matches found"))

        coordinator.clearSearch()
        XCTAssertEqual(coordinator.currentDirectoryGroup.phase, .idle)
        XCTAssertEqual(coordinator.fullDiskGroup.phase, .idle)
        XCTAssertTrue(coordinator.activeQuery.isEmpty)
    }

    @MainActor
    func testIntraGroupDeduplicationAndCrossGroupPreservation() async {
        let sharedPath = "/tmp/ttzip-dedup-root/sub/spec.md"
        let scanner = ControlledRecursiveScanner()
        await scanner.setOutcome(
            DirectoryRecursiveSearchOutcome(
                items: [
                    GlobalSearchResultItem(
                        id: "dirscan:item:\(sharedPath)",
                        title: "spec.md",
                        subtitle: "sub/spec.md",
                        hitType: .archiveEntry,
                        diskPath: sharedPath,
                        isDirectory: false,
                        byteSize: 256,
                        score: 0.90
                    )
                ]
            ),
            forRoot: "/tmp/ttzip-dedup-root"
        )

        let systemProvider = ControlledSystemSearchProvider()
        await systemProvider.setResults(
            [
                GlobalSearchResultItem(
                    id: "spotlight:item:\(sharedPath)",
                    title: "spec.md",
                    subtitle: "/tmp/ttzip-dedup-root/sub",
                    hitType: .archiveEntry,
                    diskPath: sharedPath,
                    isDirectory: false,
                    byteSize: 256,
                    score: 0.72
                )
            ],
            forQuery: "spec"
        )

        let engine = ControlledSemanticEngine()
        await engine.setResponse(
            SemanticSearchResponse(
                requestId: 1,
                windowId: "test-win",
                isCancelled: false,
                degradedLexicalOnly: false,
                hits: [
                    SemanticSearchHit(
                        scopeId: "dir:/tmp/ttzip-dedup-root",
                        sourceKind: .authorizedDirectory,
                        containerOrRootPath: "/tmp/ttzip-dedup-root",
                        displayPath: "sub/spec.md",
                        snippet: "matched semantic snippet",
                        lineStart: 12,
                        lineEnd: 15,
                        matchKind: .hybridPathAndContent,
                        lexicalScore: 0.80,
                        semanticScore: 0.95,
                        combinedScore: 0.95,
                        indexGeneration: 1,
                        modelFingerprint: 1
                    )
                ]
            ),
            forQuery: "spec"
        )

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: scanner,
            systemSearchProvider: systemProvider,
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )

        coordinator.updateSearch(
            query: "spec",
            scope: .physicalDirectory(URL(fileURLWithPath: "/tmp/ttzip-dedup-root"))
        )
        await coordinator.waitForActiveSearch()

        // Both groups contain the item, but within each group it appears once (with semantic enrichment winning)
        XCTAssertEqual(coordinator.currentDirectoryGroup.items.count, 1)
        XCTAssertEqual(coordinator.fullDiskGroup.items.count, 1)
        XCTAssertTrue(coordinator.currentDirectoryGroup.items.first?.subtitle.contains("matched semantic snippet") == true)
        XCTAssertTrue(coordinator.fullDiskGroup.items.first?.subtitle.contains("matched semantic snippet") == true)
    }

    @MainActor
    func testLateLexicalDoesNotOverwriteEarlySemantic() async {
        let targetPath = "/tmp/ttzip-race-root/design.md"
        let scanner = ControlledRecursiveScanner()
        // Lexical scan takes longer (80ms) than semantic (0ms)
        await scanner.setDelay(80_000_000, forQuery: "design")
        await scanner.setOutcome(
            DirectoryRecursiveSearchOutcome(
                items: [
                    GlobalSearchResultItem(
                        id: "dirscan:item:\(targetPath)",
                        title: "design.md",
                        subtitle: "design.md",
                        hitType: .archiveEntry,
                        diskPath: targetPath,
                        isDirectory: false,
                        byteSize: 512,
                        score: 0.85,
                        matchBadge: nil
                    )
                ]
            ),
            forRoot: "/tmp/ttzip-race-root"
        )

        let systemProvider = ControlledSystemSearchProvider()
        await systemProvider.setDelay(80_000_000, forQuery: "design")
        await systemProvider.setResults(
            [
                GlobalSearchResultItem(
                    id: "spotlight:item:\(targetPath)",
                    title: "design.md",
                    subtitle: "/tmp/ttzip-race-root",
                    hitType: .archiveEntry,
                    diskPath: targetPath,
                    isDirectory: false,
                    byteSize: 512,
                    score: 0.72,
                    matchBadge: nil
                )
            ],
            forQuery: "design"
        )

        let engine = ControlledSemanticEngine()
        await engine.setResponse(
            SemanticSearchResponse(
                requestId: 1,
                windowId: "test-win",
                isCancelled: false,
                degradedLexicalOnly: false,
                hits: [
                    SemanticSearchHit(
                        scopeId: "dir:/tmp/ttzip-race-root",
                        sourceKind: .authorizedDirectory,
                        containerOrRootPath: "/tmp/ttzip-race-root",
                        displayPath: "design.md",
                        snippet: "AI semantic content match",
                        lineStart: 42,
                        lineEnd: 45,
                        matchKind: .contentSemantic,
                        lexicalScore: 0.5,
                        semanticScore: 0.96,
                        combinedScore: 0.96,
                        indexGeneration: 1,
                        modelFingerprint: 1
                    )
                ]
            ),
            forQuery: "design"
        )

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: scanner,
            systemSearchProvider: systemProvider,
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )

        coordinator.updateSearch(
            query: "design",
            scope: .physicalDirectory(URL(fileURLWithPath: "/tmp/ttzip-race-root"))
        )
        await coordinator.waitForActiveSearch()

        XCTAssertEqual(coordinator.currentDirectoryGroup.items.count, 1)
        XCTAssertEqual(coordinator.currentDirectoryGroup.items.first?.matchBadge, "AI")
        XCTAssertTrue(coordinator.currentDirectoryGroup.items.first?.subtitle.contains("AI semantic content match") == true)
        XCTAssertEqual(coordinator.fullDiskGroup.items.count, 1)
        XCTAssertEqual(coordinator.fullDiskGroup.items.first?.matchBadge, "AI")
    }

    @MainActor
    func testQueryAndDirectorySupersedingIsolation() async {
        let scanner = ControlledRecursiveScanner()
        await scanner.setDelay(90_000_000, forQuery: "alpha")
        await scanner.setOutcome(
            DirectoryRecursiveSearchOutcome(
                items: [
                    GlobalSearchResultItem(
                        id: "dirscan:alpha",
                        title: "alpha_stale.txt",
                        subtitle: "alpha_stale.txt",
                        hitType: .archiveEntry,
                        diskPath: "/tmp/dirA/alpha_stale.txt"
                    )
                ]
            ),
            forRoot: "/tmp/dirA"
        )
        await scanner.setOutcome(
            DirectoryRecursiveSearchOutcome(
                items: [
                    GlobalSearchResultItem(
                        id: "dirscan:beta",
                        title: "beta_fresh.txt",
                        subtitle: "beta_fresh.txt",
                        hitType: .archiveEntry,
                        diskPath: "/tmp/dirB/beta_fresh.txt"
                    )
                ]
            ),
            forRoot: "/tmp/dirB"
        )

        let systemProvider = ControlledSystemSearchProvider()
        let engine = ControlledSemanticEngine()

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: scanner,
            systemSearchProvider: systemProvider,
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )

        let dirA = ExplorerSearchScopeIdentity.physicalDirectory(URL(fileURLWithPath: "/tmp/dirA"))
        let dirB = ExplorerSearchScopeIdentity.physicalDirectory(URL(fileURLWithPath: "/tmp/dirB"))

        coordinator.updateSearch(query: "alpha", scope: dirA)
        let firstReqID = coordinator.activeRequestID
        coordinator.updateSearch(query: "beta", scope: dirB)
        let secondReqID = coordinator.activeRequestID
        XCTAssertGreaterThan(secondReqID, firstReqID)

        await coordinator.waitForActiveSearch()

        XCTAssertEqual(coordinator.activeQuery, "beta")
        XCTAssertEqual(coordinator.activeScope, dirB)
        XCTAssertEqual(coordinator.currentDirectoryGroup.items.map(\.title), ["beta_fresh.txt"])
        let cancelled = await engine.cancelledRequestIDs
        XCTAssertTrue(cancelled.contains(firstReqID))
    }

    @MainActor
    func testMultiWindowIsolation() async {
        let scanner = ControlledRecursiveScanner()
        await scanner.setOutcome(
            DirectoryRecursiveSearchOutcome(
                items: [
                    GlobalSearchResultItem(
                        id: "winA:item",
                        title: "winA_report.txt",
                        subtitle: "winA_report.txt",
                        hitType: .archiveEntry,
                        diskPath: "/tmp/winA/winA_report.txt"
                    )
                ]
            ),
            forRoot: "/tmp/winA"
        )
        await scanner.setOutcome(
            DirectoryRecursiveSearchOutcome(
                items: [
                    GlobalSearchResultItem(
                        id: "winB:item",
                        title: "winB_invoice.txt",
                        subtitle: "winB_invoice.txt",
                        hitType: .archiveEntry,
                        diskPath: "/tmp/winB/winB_invoice.txt"
                    )
                ]
            ),
            forRoot: "/tmp/winB"
        )

        let engine = ControlledSemanticEngine()
        let systemProvider = ControlledSystemSearchProvider()

        let coordA = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: scanner,
            systemSearchProvider: systemProvider,
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )
        let coordB = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: scanner,
            systemSearchProvider: systemProvider,
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )

        coordA.updateSearch(query: "report", scope: .physicalDirectory(URL(fileURLWithPath: "/tmp/winA")))
        coordB.updateSearch(query: "invoice", scope: .physicalDirectory(URL(fileURLWithPath: "/tmp/winB")))

        XCTAssertNotEqual(coordA.activeRequestID, coordB.activeRequestID)

        await coordA.waitForActiveSearch()
        await coordB.waitForActiveSearch()

        XCTAssertEqual(coordA.currentDirectoryGroup.items.map(\.title), ["winA_report.txt"])
        XCTAssertEqual(coordB.currentDirectoryGroup.items.map(\.title), ["winB_invoice.txt"])
    }

    @MainActor
    func testResultActivationRevealsNestedDiskFileAndArchiveEntry() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("ttzip-s1-reveal-\(UUID().uuidString)", isDirectory: true)
        let subA = tempRoot.appendingPathComponent("alpha", isDirectory: true)
        let subB = subA.appendingPathComponent("beta", isDirectory: true)
        try fm.createDirectory(at: subB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let targetFile = subB.appendingPathComponent("deep_target.txt")
        try Data("hello".utf8).write(to: targetFile)

        let hierarchy = FinderMillerColumnsView.resolveValidDescendantHierarchy(
            for: targetFile.path,
            under: tempRoot
        )
        let resolved = try XCTUnwrap(hierarchy)
        XCTAssertEqual(resolved.columns.map { $0.standardizedFileURL.path }, [
            tempRoot.standardizedFileURL.path,
            subA.standardizedFileURL.path,
            subB.standardizedFileURL.path
        ])
        XCTAssertEqual(resolved.item.path, targetFile.standardizedFileURL.path)

        let vm = AppViewState()
        vm.navigationState.currentDirectory = tempRoot
        vm.explorerState.searchQuery = "deep_target"

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: vm.windowID,
            semanticEngine: ControlledSemanticEngine(),
            directoryScanner: ControlledRecursiveScanner(),
            systemSearchProvider: ControlledSystemSearchProvider(),
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )

        let diskHit = GlobalSearchResultItem(
            id: "dirscan:item:\(targetFile.path)",
            title: "deep_target.txt",
            subtitle: "alpha/beta/deep_target.txt",
            hitType: .archiveEntry,
            diskPath: targetFile.path,
            isDirectory: false,
            byteSize: 5
        )
        coordinator.activateResult(diskHit, in: vm)

        XCTAssertEqual(vm.navigationState.currentDirectory.standardizedFileURL.path, tempRoot.standardizedFileURL.path)
        XCTAssertEqual(vm.selectionState.selectedDiskItem?.path, targetFile.standardizedFileURL.path)
        XCTAssertTrue(vm.explorerState.searchQuery.isEmpty)
    }
}
