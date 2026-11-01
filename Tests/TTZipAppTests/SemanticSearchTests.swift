// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipCore
@testable import TTZipApp
@testable import TTZipAppServices

final class SemanticSearchTests: XCTestCase {

    func testMockSemanticQueryEncoderProduces128DimVector() async throws {
        let encoder = MockSemanticQueryEncoder()
        let vec = try await encoder.encode(query: "billing controller")
        XCTAssertEqual(vec.count, 128)
        XCTAssertTrue(vec.contains(where: { $0 != 0 }), "Vector should contain non-zero values")
    }

    func testMockSemanticQueryEncoderHandlesModelNotAvailable() async {
        let encoder = MockSemanticQueryEncoder(shouldThrowModelNotAvailable: true)
        do {
            _ = try await encoder.encode(query: "settings")
            XCTFail("Expected modelNotAvailable error")
        } catch let error as SemanticQueryEncoderError {
            guard case .modelNotAvailable = error else {
                XCTFail("Expected .modelNotAvailable, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCoreMLSemanticQueryEncoderGracefulFallbackWhenNoModel() async {
        let encoder = CoreMLSemanticQueryEncoder(modelURL: URL(fileURLWithPath: "/nonexistent/model.mlpackage"))
        do {
            _ = try await encoder.encode(query: "test query")
            XCTFail("Expected modelNotAvailable error for nonexistent model")
        } catch let error as SemanticQueryEncoderError {
            guard case .modelNotAvailable = error else {
                XCTFail("Expected .modelNotAvailable, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testSemanticSearchServiceDispatchesAndReturnsMatches() async throws {
        let encoder = MockSemanticQueryEncoder()
        let service = SemanticSearchService(encoder: encoder)

        let expectedMatch = VfsHybridMatch(
            nodeId: 42,
            name: "billing_service.rs",
            path: "src/billing/billing_service.rs",
            isDir: false,
            size: 2048,
            lexicalScore: 80,
            semanticScore: 110,
            fusedRankScore: 0.025
        )

        let session = MockSemanticVfsSession(hasEmbeddings: true, hybridMatchesToReturn: [expectedMatch])

        let expectation = expectation(description: "Hybrid search completes")
        var receivedMatches: [VfsHybridMatch] = []

        service.performHybridSearch(
            query: "invoice",
            generation: 1,
            session: session,
            limit: 1000,
            lexicalWeight: 0.6,
            semanticWeight: 0.4
        ) { matches in
            receivedMatches = matches
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedMatches.count, 1)
        XCTAssertEqual(receivedMatches.first?.nodeId, 42)
        XCTAssertEqual(receivedMatches.first?.name, "billing_service.rs")
    }

    @MainActor
    func testSemanticSearchServiceIgnoresStaleGeneration() async throws {
        let encoder = MockSemanticQueryEncoder()
        let service = SemanticSearchService(encoder: encoder)

        let matchGen1 = VfsHybridMatch(
            nodeId: 1,
            name: "gen1.txt",
            path: "gen1.txt",
            isDir: false,
            size: 10,
            lexicalScore: 10,
            semanticScore: 10,
            fusedRankScore: 0.1
        )
        let session = MockSemanticVfsSession(hasEmbeddings: true, hybridMatchesToReturn: [matchGen1])

        var receivedGen1 = false
        service.performHybridSearch(
            query: "query1",
            generation: 1,
            session: session
        ) { _ in
            receivedGen1 = true
        }

        // Immediately cancel by starting gen 2
        let matchGen2 = VfsHybridMatch(
            nodeId: 2,
            name: "gen2.txt",
            path: "gen2.txt",
            isDir: false,
            size: 20,
            lexicalScore: 20,
            semanticScore: 20,
            fusedRankScore: 0.2
        )
        session.hybridMatchesToReturn = [matchGen2]

        let expectation2 = expectation(description: "Gen 2 completes")
        var receivedGen2Matches: [VfsHybridMatch] = []

        service.performHybridSearch(
            query: "query2",
            generation: 2,
            session: session
        ) { matches in
            receivedGen2Matches = matches
            expectation2.fulfill()
        }

        await fulfillment(of: [expectation2], timeout: 2.0)
        XCTAssertFalse(receivedGen1, "Stale generation 1 should be dropped")
        XCTAssertEqual(receivedGen2Matches.count, 1)
        XCTAssertEqual(receivedGen2Matches.first?.nodeId, 2)
    }

    @MainActor
    func testArchiveExplorerStatePreserves120HzFastPath() {
        let explorer = ArchiveExplorerState()
        explorer.currentEntries = [
            ArchiveEntry(path: "src/auth/login.rs", uncompressedSize: 100, isDirectory: false),
            ArchiveEntry(path: "src/billing/invoice.rs", uncompressedSize: 200, isDirectory: false),
            ArchiveEntry(path: "docs/readme.md", uncompressedSize: 300, isDirectory: false)
        ]

        // Fast path query
        explorer.searchQuery = "login"

        // Immediate synchronous results on @MainActor without waiting for async
        let filtered = explorer.filteredEntries
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.path, "src/auth/login.rs")
    }

    @MainActor
    func testArchiveExplorerStateBackgroundSemanticEnrichment() async throws {
        let encoder = MockSemanticQueryEncoder()
        let service = SemanticSearchService(encoder: encoder)
        let explorer = ArchiveExplorerState(semanticSearchService: service)

        explorer.currentEntries = [
            ArchiveEntry(path: "src/auth/login.rs", uncompressedSize: 100, isDirectory: false),
            ArchiveEntry(path: "src/billing/invoice.rs", uncompressedSize: 200, isDirectory: false),
            ArchiveEntry(path: "docs/readme.md", uncompressedSize: 300, isDirectory: false)
        ]

        // Mock session with vector embeddings
        let semanticMatch = VfsHybridMatch(
            nodeId: 1, // index for src/billing/invoice.rs
            name: "invoice.rs",
            path: "src/billing/invoice.rs",
            isDir: false,
            size: 200,
            lexicalScore: 10,
            semanticScore: 90,
            fusedRankScore: 0.9
        )
        let mockSession = MockSemanticVfsSession(hasEmbeddings: true, hybridMatchesToReturn: [semanticMatch])

        // Trigger search with hybrid capability
        service.performHybridSearch(
            query: "payment",
            generation: 1,
            session: mockSession
        ) { matches in
            // Simulate the ArchiveExplorerState completion hook
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.nodeId, 1)
        }

        await service.waitForActiveSearch()
    }

    func testCanonicalPromptTemplatesAndCodePrefixStripping() {
        XCTAssertEqual(
            SemanticPromptFormatter.formatQueryPrompt("tax document"),
            "task: search result | query: tax document"
        )
        XCTAssertEqual(
            SemanticPromptFormatter.formatCodeQueryPrompt("retry backoff"),
            "task: code retrieval | query: retry backoff"
        )
        XCTAssertEqual(
            SemanticPromptFormatter.formatDocumentPrompt(relativePath: nil, text: "invoice_2026.pdf"),
            "title: none | text: invoice_2026.pdf"
        )
        XCTAssertEqual(
            SemanticPromptFormatter.formatDocumentPrompt(
                relativePath: "src/net/client.rs",
                text: "pub fn connect() {}"
            ),
            "title: src/net/client.rs | text: pub fn connect() {}"
        )

        let stripped = SemanticPromptFormatter.stripCodeQueryPrefix("CODE: socket timeout")
        XCTAssertTrue(stripped.isCodeQuery)
        XCTAssertEqual(stripped.cleanQuery, "socket timeout")
    }

    func testGGUFCheckpointReportsBlockedWhenModelMissingAndRejectsCorruptFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_gguf_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let missingURL = tmpDir.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
        let report = GGUFModelVerifier.runCheckpoint(modelURL: missingURL)
        XCTAssertEqual(report.status, .blocked)

        let corruptURL = tmpDir.appendingPathComponent("corrupt.gguf")
        try Data("GGUF_truncated".utf8).write(to: corruptURL)
        let corruptReport = GGUFModelVerifier.runCheckpoint(modelURL: corruptURL)
        XCTAssertEqual(corruptReport.status, .fail)
    }

    func testExplicitUnlinkedBridgeReportsEngineUnlinkedAndNeverPretendsLexicalDegradation() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_sem_unlinked_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let explicitUnlinkedBridge = UniFFIRustSemanticCoreBridge(
            storageDirectory: tmpRoot,
            uniffiEngine: nil
        )
        let engine = SemanticSearchEngine(
            storageDirectory: tmpRoot,
            bridge: explicitUnlinkedBridge
        )
        let state = await engine.modelState()
        guard case let .engineUnlinked(reason) = state else {
            XCTFail("Expected .engineUnlinked from explicit unlinked bridge, got \(state)")
            return
        }
        XCTAssertTrue(reason.hasPrefix(PinnedSemanticModelConstants.engineUnlinkedPrefix))

        let scope = SemanticScopeDescriptor(
            scopeId: "scope_unlinked",
            kind: .authorizedDirectory,
            rootPath: tmpRoot.path,
            displayName: "unlinked_workspace"
        )
        let loaded = await engine.registerScope(scope)
        XCTAssertFalse(loaded)

        let progress = await engine.startIndexing(scopeId: "scope_unlinked")
        XCTAssertEqual(
            progress.phase,
            .engineUnlinked,
            "Unlinked bridge must explicitly report .engineUnlinked, never masquerade as .degradedLexicalOnly"
        )
        XCTAssertEqual(progress.errorMessage, UniFFIRustSemanticCoreBridge.unlinkedReasonMessage)

        let response = await engine.search(
            SemanticSearchRequest(
                requestId: 1,
                windowId: "win_unlinked",
                query: "corporate fiscal billing receipt",
                scopeIds: ["scope_unlinked"]
            )
        )
        XCTAssertFalse(response.isCancelled)
        XCTAssertFalse(
            response.degradedLexicalOnly,
            "Unlinked bridge must not pretend lexical degradation succeeded"
        )
        XCTAssertFalse(response.isEngineLinked)
        XCTAssertEqual(response.engineUnlinkedReason, UniFFIRustSemanticCoreBridge.unlinkedReasonMessage)
        XCTAssertTrue(response.hits.isEmpty)
    }

    func testLinkedBridgeWithMissingModelReportsNotInstalledAndDegradedLexicalOnly() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_sem_missing_model_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let linkedMissingModelBridge = UniFFIRustSemanticCoreBridge(
            storageDirectory: tmpRoot,
            uniffiEngine: RecordingUniFFISemanticSearchEngine(missingModel: true)
        )
        let engine = SemanticSearchEngine(
            storageDirectory: tmpRoot,
            bridge: linkedMissingModelBridge
        )
        let state = await engine.modelState()
        XCTAssertEqual(
            state,
            .notInstalled,
            "Linked UniFFI bridge with missing GGUF model must report .notInstalled, distinct from .engineUnlinked"
        )

        let scope = SemanticScopeDescriptor(
            scopeId: "scope_missing_model",
            kind: .authorizedDirectory,
            rootPath: tmpRoot.path,
            displayName: "missing_model_workspace"
        )
        _ = await engine.registerScope(scope)

        let progress = await engine.startIndexing(scopeId: "scope_missing_model")
        XCTAssertEqual(progress.phase, .degradedLexicalOnly)
        XCTAssertNil(progress.errorMessage)

        let response = await engine.search(
            SemanticSearchRequest(
                requestId: 2,
                windowId: "win_missing_model",
                query: "invoice_ledger",
                scopeIds: ["scope_missing_model"]
            )
        )
        XCTAssertTrue(response.isEngineLinked)
        XCTAssertNil(response.engineUnlinkedReason)
        XCTAssertTrue(response.degradedLexicalOnly)
        XCTAssertEqual(response.hits.count, 1)
        XCTAssertEqual(response.hits[0].matchKind, .lexicalOnly)
        XCTAssertEqual(response.hits[0].semanticScore, 0.0)
    }

    func testProductionSemanticSearchEngineConstructorMatchesCompileTimeLinkState() async throws {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("ttzip_sem_prod_ctor_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpRoot.path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
            try? fm.removeItem(at: tmpRoot)
        }

        let engine = SemanticSearchEngine(storageDirectory: tmpRoot)
        let state = await engine.modelState()
        #if TTZIP_UNIFFI_SEMANTIC_SEARCH_LINKED
        if case .engineUnlinked = state {
            XCTFail("When TTZIP_UNIFFI_SEMANTIC_SEARCH_LINKED is enabled, production constructor must not report .engineUnlinked")
        }
        XCTAssertEqual(state, .notInstalled, "Production constructor in isolated storage/HOME must report .notInstalled without loading personal GGUF")
        #else
        guard case .engineUnlinked = state else {
            XCTFail("When TTZIP_UNIFFI_SEMANTIC_SEARCH_LINKED is not enabled, expected .engineUnlinked, got \(state)")
            return
        }
        #endif
    }

    func testRealGGUFModelEndToEndBilingualSemanticRetrievalViaUniFFI() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TTZIP_REQUIRE_REAL_GGUF"] == "1" || env["TTZIP_RUN_REAL_GGUF_TESTS"] == "1" else {
            throw XCTSkip("Opt-in real-GGUF acceptance tier: pass --test_env=TTZIP_REQUIRE_REAL_GGUF=1 with TTZIP_REAL_GGUF_MODEL_PATH")
        }
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("ttzip_sem_real_e2e_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmpRoot) }
        let (realStorage, workspaceDir, stagedModelURL, _) = try stageVerifiedRealGGUFFixture(in: tmpRoot)
        try fm.createDirectory(at: workspaceDir.appendingPathComponent("notes"), withIntermediateDirectories: true)

        try Data("Line 1: Memo.\nLine 2: Submit 2026 corporate tax deduction receipts and vendor billing invoices.".utf8)
            .write(to: workspaceDir.appendingPathComponent("notes/alpha_memo_901.txt"))
        try Data("# 运维记录\n第2行：生产环境数据库连接池出现超时，已启用指数退避重试机制。".utf8)
            .write(to: workspaceDir.appendingPathComponent("notes/zeta_record_402.md"))

        let engine = SemanticSearchEngine(storageDirectory: realStorage)
        await engine.setPluginEnabled(true)
        let state = await engine.reloadAndVerifyModelRuntime(at: stagedModelURL, requireExactChecksum: true)
        guard case let .ready(desc) = state else {
            _ = await engine.shutdown()
            XCTFail("BLOCKED or FAILED: Real GGUF model end-to-end Swift test requires .ready state, got \(state)")
            return
        }
        XCTAssertEqual(desc.modelFingerprint, PinnedSemanticModelConstants.modelFingerprint)

        let scope = SemanticScopeDescriptor(
            scopeId: "real_swift_scope",
            kind: .authorizedDirectory,
            rootPath: workspaceDir.path,
            displayName: "workspace"
        )
        let registered = await engine.registerScope(scope)
        XCTAssertFalse(registered)

        let progress = await engine.startIndexing(scopeId: "real_swift_scope")
        XCTAssertEqual(progress.phase, .completed)
        XCTAssertGreaterThanOrEqual(progress.processedFiles, 2)
        XCTAssertGreaterThanOrEqual(progress.indexedSegments, 2)

        let enRes = await engine.search(
            SemanticSearchRequest(
                requestId: 100,
                windowId: "win_real_swift",
                query: "corporate fiscal billing receipt",
                scopeIds: ["real_swift_scope"]
            )
        )
        XCTAssertTrue(enRes.isEngineLinked)
        XCTAssertFalse(enRes.degradedLexicalOnly)
        XCTAssertEqual(enRes.hits.first?.displayPath, "notes/alpha_memo_901.txt")
        XCTAssertEqual(enRes.hits.first?.matchKind, .contentSemantic)

        let zhRes = await engine.search(
            SemanticSearchRequest(
                requestId: 101,
                windowId: "win_real_swift",
                query: "数据库连接超时退避重试",
                scopeIds: ["real_swift_scope"]
            )
        )
        XCTAssertEqual(zhRes.hits.first?.displayPath, "notes/zeta_record_402.md")
        XCTAssertEqual(zhRes.hits.first?.matchKind, .contentSemantic)

        // Explicit test-instance teardown only: releases this test's local `SemanticSearchEngine(storageDirectory: tmpRoot)`
        // prior to XCTest process exit. Does NOT constitute evidence of `LocalModelManager.shared` or GUI `.app` CmdQ exit.
        await engine.unloadModelRuntime()
    }
}

