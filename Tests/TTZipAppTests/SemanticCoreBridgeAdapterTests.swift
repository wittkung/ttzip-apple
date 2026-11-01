// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipCore
@testable import TTZipApp
@testable import TTZipAppServices

extension SemanticSearchTests {

    func testUniFFIRustSemanticCoreBridgeForwardsAllOperationsToUniFFIEngine() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_uniffi_fwd_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let recordingUniFFI = RecordingUniFFISemanticSearchEngine()
        let bridge = UniFFIRustSemanticCoreBridge(
            storageDirectory: tmpRoot,
            uniffiEngine: recordingUniFFI
        )
        let engine = SemanticSearchEngine(storageDirectory: tmpRoot, bridge: bridge)

        let modelState = await engine.modelState()
        guard case let .ready(desc) = modelState else {
            XCTFail("Expected .ready from forwarded UniFFI engine, got \(modelState)")
            return
        }
        XCTAssertEqual(desc.modelFingerprint, PinnedSemanticModelConstants.modelFingerprint)
        XCTAssertEqual(desc.backend, .metal)

        let dirScope = SemanticScopeDescriptor(
            scopeId: "dir_1",
            kind: .authorizedDirectory,
            rootPath: "/Volumes/Work/docs",
            displayName: "docs"
        )
        let registered = await engine.registerScope(dirScope)
        XCTAssertTrue(registered)

        let dirProg = await engine.startIndexing(scopeId: "dir_1")
        XCTAssertEqual(dirProg.phase, .completed)
        XCTAssertEqual(dirProg.processedFiles, 3)
        XCTAssertEqual(dirProg.indexedSegments, 9)

        let polledProg = await engine.indexProgress(scopeId: "dir_1")
        XCTAssertEqual(polledProg?.phase, .completed)

        await engine.cancelIndexing(scopeId: "dir_1")
        XCTAssertEqual(recordingUniFFI.lastCancelledIndexingScope, "dir_1")

        let archProg = await engine.upsertArchiveEntries(
            scopeId: "arch_1",
            entries: [
                (
                    entryPath: "inner/src/retry.rs",
                    data: Data("pub fn retry_backoff() {}".utf8),
                    mtimeNs: 777
                )
            ]
        )
        XCTAssertEqual(archProg.phase, .completed)
        XCTAssertEqual(archProg.processedFiles, 1)

        let removed = await engine.removeIndexedFile(
            scopeId: "dir_1",
            relativePath: "old/obsolete.txt"
        )
        XCTAssertTrue(removed)
        XCTAssertEqual(recordingUniFFI.lastRemovedPath, "old/obsolete.txt")

        let searchRes = await engine.search(
            SemanticSearchRequest(
                requestId: 55,
                windowId: "win_a",
                query: "retry backoff",
                scopeIds: ["arch_1"]
            )
        )
        XCTAssertTrue(searchRes.isEngineLinked)
        XCTAssertNil(searchRes.engineUnlinkedReason)
        XCTAssertFalse(searchRes.degradedLexicalOnly)
        XCTAssertEqual(searchRes.hits.count, 1)

        let openReq = engine.buildOpenRequest(for: searchRes.hits[0])
        XCTAssertEqual(openReq.outerPath, "/Volumes/Work/bundle.zip")
        XCTAssertEqual(openReq.archiveEntryPath, "inner/src/retry.rs")
        XCTAssertEqual(openReq.lineNumber, 42)

        await engine.cancelSearch(requestId: 55)
        XCTAssertTrue(recordingUniFFI.cancelledRequestIds.contains(55))

        let revoked = await engine.revokeScope(scopeId: "dir_1")
        XCTAssertTrue(revoked)
    }

    func testThinAdapterForwardsRequestsCancelsStaleWindowQueriesAndBuildsArchiveOpenRequest() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_sem_adapter_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let stubBridge = UniFFIRustSemanticCoreBridge(
            storageDirectory: tmpRoot,
            uniffiEngine: RecordingUniFFISemanticSearchEngine(useTestDoubleFingerprint: true)
        )
        let engine = SemanticSearchEngine.forTesting(storageDirectory: tmpRoot, bridge: stubBridge)

        let archiveScope = SemanticScopeDescriptor(
            scopeId: "scope_arch",
            kind: .openArchive,
            rootPath: "/Volumes/Data/bundle.zip",
            displayName: "bundle.zip"
        )
        _ = await engine.registerScope(archiveScope)
        _ = await engine.upsertArchiveEntries(
            scopeId: "scope_arch",
            entries: [
                (
                    entryPath: "nested/docs/tax_2026.txt",
                    data: Data("Annual corporate tax invoice summary.".utf8),
                    mtimeNs: 100
                )
            ]
        )

        let resArch = await engine.search(
            SemanticSearchRequest(
                requestId: 10,
                windowId: "win_1",
                query: "tax invoice",
                scopeIds: ["scope_arch"]
            )
        )
        XCTAssertFalse(resArch.isCancelled)
        guard let archHit = resArch.hits.first else {
            XCTFail("Expected stubbed bridge hit")
            return
        }
        XCTAssertEqual(archHit.modelFingerprint, PinnedSemanticModelConstants.testDoubleModelFingerprint)

        let openReq = engine.buildOpenRequest(for: archHit)
        XCTAssertEqual(openReq.outerPath, "/Volumes/Data/bundle.zip")
        XCTAssertEqual(openReq.archiveEntryPath, "nested/docs/tax_2026.txt")
        XCTAssertEqual(openReq.lineNumber, 12)

        // Older requestId=9 on win_1 must be superseded by requestId=10
        let staleRes = await engine.search(
            SemanticSearchRequest(
                requestId: 9,
                windowId: "win_1",
                query: "tax",
                scopeIds: ["scope_arch"]
            )
        )
        XCTAssertTrue(staleRes.isCancelled)

        let revoked = await engine.revokeScope(scopeId: "scope_arch")
        XCTAssertTrue(revoked)
    }

    func testProductionServiceOnboardingHelpersAndGlobalSearchResultItemMapping() async {
        let recorder = RecordingUniFFISemanticSearchEngine()
        let storageURL = URL(fileURLWithPath: "/tmp/ttzip_onboard")
        let engine = SemanticSearchEngine(
            storageDirectory: storageURL,
            bridge: UniFFIRustSemanticCoreBridge(storageDirectory: storageURL, uniffiEngine: recorder)
        )
        let dirURL = URL(fileURLWithPath: "/Volumes/Work/Projects/../Projects/Docs")
        XCTAssertEqual(SemanticSearchEngine.scopeId(forDirectoryURL: dirURL), "dir:/Volumes/Work/Projects/Docs")
        XCTAssertEqual(SemanticSearchEngine.scopeId(forArchivePath: "/Volumes/Work/a.zip"), "archive:/Volumes/Work/a.zip")

        let onboarded = await engine.registerAuthorizedDirectory(url: dirURL, startIndexingImmediately: true)
        XCTAssertTrue(onboarded.loadedExistingIndex)
        if case .completed = onboarded.progress?.phase {} else {
            XCTFail("Expected .completed")
        }
        XCTAssertEqual(
            recorder.registeredScopes["dir:/Volumes/Work/Projects/Docs"]?.rootPath,
            "/Volumes/Work/Projects/Docs"
        )
        let revoked = await engine.revokeAuthorizedDirectory(url: dirURL)
        XCTAssertTrue(revoked)

        let dirHit = SemanticSearchHit(
            scopeId: "dir:/Volumes/Work/Docs",
            sourceKind: .authorizedDirectory,
            containerOrRootPath: "/Volumes/Work/Docs",
            displayPath: "sub/report.md",
            archiveEntryPath: nil,
            snippet: "quarterly revenue forecast",
            lineStart: 10,
            lineEnd: 14,
            matchKind: .contentSemantic,
            lexicalScore: 0.2,
            semanticScore: 0.88,
            combinedScore: 0.85,
            indexGeneration: 1,
            modelFingerprint: PinnedSemanticModelConstants.modelFingerprint
        )
        XCTAssertEqual(dirHit.resolvedOuterFilePath, "/Volumes/Work/Docs/sub/report.md")
        let dirItem = dirHit.toGlobalSearchResultItem()
        XCTAssertEqual(dirItem.targetKind, .diskItem(path: "/Volumes/Work/Docs/sub/report.md"))
        XCTAssertEqual(dirItem.diskPath, "/Volumes/Work/Docs/sub/report.md")
        XCTAssertNil(dirItem.archivePath)
        XCTAssertNil(dirItem.entrySubpath)
        XCTAssertEqual(dirItem.matchedLineStart, 10)
        XCTAssertTrue(dirItem.subtitle.contains("L10-L14"))
        XCTAssertEqual(dirItem.matchBadge, "AI")

        let archHit = SemanticSearchHit(
            scopeId: "archive:/Volumes/Work/b.zip",
            sourceKind: .openArchive,
            containerOrRootPath: "/Volumes/Work/b.zip",
            displayPath: "src/lib.rs",
            archiveEntryPath: "src/lib.rs",
            snippet: "pub fn init()",
            lineStart: 5,
            lineEnd: 5,
            matchKind: .pathSemantic,
            lexicalScore: 0.7,
            semanticScore: 0.9,
            combinedScore: 0.92,
            indexGeneration: 2,
            modelFingerprint: PinnedSemanticModelConstants.modelFingerprint
        )
        let archItem = archHit.toGlobalSearchResultItem()
        XCTAssertEqual(
            archItem.targetKind,
            .archiveEntry(archivePath: "/Volumes/Work/b.zip", entrySubpath: "src/lib.rs")
        )
        XCTAssertEqual(archItem.archivePath, "/Volumes/Work/b.zip")
        XCTAssertEqual(archItem.entrySubpath, "src/lib.rs")
        XCTAssertNil(archItem.diskPath)
        XCTAssertEqual(archItem.matchedLineStart, 5)
        XCTAssertTrue(archItem.subtitle.contains("L5"))
        XCTAssertEqual(archItem.matchBadge, "AI")
    }
}

final class RecordingUniFFISemanticSearchEngine: UniFFISemanticSearchEngineBindingProtocol, @unchecked Sendable {
    let missingModel: Bool
    let useTestDoubleFingerprint: Bool
    var registeredScopes: [String: UniFFISemanticScopeDescriptor] = [:]
    var lastCancelledIndexingScope: String?
    var lastRemovedPath: String?
    var cancelledRequestIds: Set<UInt64> = []

    init(missingModel: Bool = false, useTestDoubleFingerprint: Bool = false) {
        self.missingModel = missingModel
        self.useTestDoubleFingerprint = useTestDoubleFingerprint
    }

    func modelState() -> UniFFISemanticModelState {
        if missingModel {
            return .notInstalled
        }
        return .ready(
            info: UniFFISemanticModelInfo(
                modelId: PinnedSemanticModelConstants.modelId,
                modelRevision: PinnedSemanticModelConstants.modelRevision,
                ggufFilename: PinnedSemanticModelConstants.ggufFilename,
                expectedBytes: PinnedSemanticModelConstants.ggufSizeBytes,
                expectedSha256: PinnedSemanticModelConstants.ggufSha256,
                llamaCppTag: PinnedSemanticModelConstants.llamaCppTag,
                llamaCppCommit: PinnedSemanticModelConstants.llamaCppCommit,
                modelFingerprint: useTestDoubleFingerprint
                    ? PinnedSemanticModelConstants.testDoubleModelFingerprint
                    : PinnedSemanticModelConstants.modelFingerprint,
                backend: useTestDoubleFingerprint ? .deterministicTestDouble : .metal
            )
        )
    }

    func registerScope(descriptor: UniFFISemanticScopeDescriptor) -> Bool {
        registeredScopes[descriptor.scopeId] = descriptor
        return !missingModel
    }

    func revokeScope(scopeId: String) -> Bool {
        registeredScopes.removeValue(forKey: scopeId) != nil
    }

    func startDirectoryIndexing(scopeId: String) -> UniFFISemanticIndexProgress {
        UniFFISemanticIndexProgress(
            scopeId: scopeId,
            phase: missingModel ? .degradedLexicalOnly : .completed,
            processedFiles: missingModel ? 1 : 3,
            totalFiles: missingModel ? 1 : 3,
            indexedSegments: missingModel ? 1 : 9,
            indexGeneration: missingModel ? 1 : 2,
            errorMessage: nil
        )
    }

    func cancelIndexing(scopeId: String) {
        lastCancelledIndexingScope = scopeId
    }

    func scopeProgress(scopeId: String) -> UniFFISemanticIndexProgress? {
        startDirectoryIndexing(scopeId: scopeId)
    }

    func upsertArchiveEntries(
        scopeId: String,
        entries: [UniFFISemanticArchiveEntryInput]
    ) -> UniFFISemanticIndexProgress {
        UniFFISemanticIndexProgress(
            scopeId: scopeId,
            phase: missingModel ? .degradedLexicalOnly : .completed,
            processedFiles: UInt32(entries.count),
            totalFiles: UInt32(entries.count),
            indexedSegments: UInt32(entries.count),
            indexGeneration: 3,
            errorMessage: nil
        )
    }

    func removeIndexedFile(scopeId: String, relativePath: String) -> Bool {
        lastRemovedPath = relativePath
        return true
    }

    func search(request: UniFFISemanticSearchRequest) -> UniFFISemanticSearchResponse {
        let hit = makeHit()
        return UniFFISemanticSearchResponse(
            requestId: request.requestId,
            windowId: request.windowId,
            isCancelled: cancelledRequestIds.contains(request.requestId),
            degradedLexicalOnly: missingModel,
            hits: [hit]
        )
    }

    private func makeHit() -> UniFFISemanticSearchHit {
        if missingModel {
            return UniFFISemanticSearchHit(
                scopeId: "scope_missing_model",
                sourceKind: .authorizedDirectory,
                containerOrRootPath: "/Volumes/Work/docs",
                displayPath: "invoice_ledger.txt",
                archiveEntryPath: nil,
                snippet: "invoice_ledger.txt",
                lineStart: 0,
                lineEnd: 0,
                matchKind: .lexicalOnly,
                lexicalScore: 0.9,
                semanticScore: 0.0,
                combinedScore: 0.9,
                indexGeneration: 1,
                modelFingerprint: PinnedSemanticModelConstants.modelFingerprint
            )
        }
        if useTestDoubleFingerprint {
            return UniFFISemanticSearchHit(
                scopeId: "scope_arch",
                sourceKind: .openArchive,
                containerOrRootPath: "/Volumes/Data/bundle.zip",
                displayPath: "nested/docs/tax_2026.txt",
                archiveEntryPath: "nested/docs/tax_2026.txt",
                snippet: "pub fn retry_backoff() {}",
                lineStart: 12,
                lineEnd: 15,
                matchKind: .contentSemantic,
                lexicalScore: 0.5,
                semanticScore: 0.9,
                combinedScore: 0.78,
                indexGeneration: 3,
                modelFingerprint: PinnedSemanticModelConstants.testDoubleModelFingerprint
            )
        }
        return UniFFISemanticSearchHit(
            scopeId: "arch_1",
            sourceKind: .openArchive,
            containerOrRootPath: "/Volumes/Work/bundle.zip",
            displayPath: "inner/src/retry.rs",
            archiveEntryPath: "inner/src/retry.rs",
            snippet: "pub fn retry_backoff() {}",
            lineStart: 42,
            lineEnd: 48,
            matchKind: .contentSemantic,
            lexicalScore: 0.5,
            semanticScore: 0.9,
            combinedScore: 0.78,
            indexGeneration: 3,
            modelFingerprint: PinnedSemanticModelConstants.modelFingerprint
        )
    }

    func cancelSearch(requestId: UInt64) {
        cancelledRequestIds.insert(requestId)
    }

    func buildOpenRequest(hit: UniFFISemanticSearchHit) -> UniFFISemanticOpenRequest {
        UniFFISemanticOpenRequest(
            scopeId: hit.scopeId,
            sourceKind: hit.sourceKind,
            outerPath: hit.containerOrRootPath,
            archiveEntryPath: hit.archiveEntryPath,
            lineNumber: hit.lineStart
        )
    }
}
