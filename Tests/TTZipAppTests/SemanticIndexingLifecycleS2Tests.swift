// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipAppCommon
@testable import TTZipApp
@testable import TTZipAppModels
@testable import TTZipAppServices
@testable import TTZipAppViewModels
@testable import TTZipAppViews
import TTZipCore
import TTZipUI

final class SemanticIndexingLifecycleS2Tests: XCTestCase {

    @MainActor
    func testS2AuthorizedScopeBackfillAndHonestZeroSegmentState() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let uniffiDouble = S2LifecycleUniFFIDouble()
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let leaseTracker = LeaseLifecycleTracker()
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in leaseTracker.acquire(for: url) }
        )

        let reg = await engine.registerAuthorizedDirectory(
            url: tmpDir,
            isAuthorized: true,
            startIndexingImmediately: false
        )
        XCTAssertTrue(reg.loadedExistingIndex)
        let initialSummary = await engine.indexedCoverageSummary()
        XCTAssertEqual(initialSummary.authorizedScopeCount, 1)
        XCTAssertEqual(initialSummary.totalIndexedSegments, 0)

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: DefaultDirectoryRecursiveScanner(),
            systemSearchProvider: EmptySystemFileSearchProvider(),
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )
        coordinator.updateSearch(query: "quantum_entanglement_body_only", scope: .physicalDirectory(tmpDir))
        await coordinator.waitForActiveSearch()
        XCTAssertTrue(coordinator.fullDiskGroup.coverage.isSemanticQueryEncoded)
        XCTAssertEqual(coordinator.fullDiskGroup.coverage.indexedSegmentCount, 0)
        XCTAssertFalse(coordinator.fullDiskGroup.coverage.hasSemanticContentHits)

        let backfilled = await engine.backfillAuthorizedScopesIfNeeded()
        XCTAssertEqual(backfilled.count, 1)
        XCTAssertEqual(backfilled.first?.indexedSegments, 6)
        XCTAssertEqual(leaseTracker.acquireCount, 1)
        XCTAssertEqual(leaseTracker.activeCount, 0, "Security-scoped lease must be balanced on indexing completion")

        coordinator.updateSearch(
            query: "quantum_entanglement_body_only",
            scope: .physicalDirectory(tmpDir),
            forceRefresh: true
        )
        await coordinator.waitForActiveSearch()
        XCTAssertEqual(coordinator.fullDiskGroup.coverage.indexedSegmentCount, 6)
        XCTAssertTrue(coordinator.fullDiskGroup.coverage.hasSemanticContentHits)
        XCTAssertEqual(coordinator.currentDirectoryGroup.items.first?.title, "opaque_notes.txt")
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2BackgroundIndexingHoldsSecurityScopedLeaseAndPreservesIndexWhenLeaseOrReadDenied() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let leaseTracker = LeaseLifecycleTracker()
        let indexingCompletedReceipt = BoundedSignalReceipt()
        let uniffiDouble = S2LifecycleUniFFIDouble(
            onIndexingStarted: {
                leaseTracker.recordActiveCountAtIndexingEntry()
            },
            onIndexingFinished: {
                indexingCompletedReceipt.signal()
            }
        )
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in leaseTracker.acquire(for: url) }
        )

        let accessManager = RootFolderAccessManager.shared
        let prevEnabled = accessManager.isAutoSemanticIndexingEnabled
        let prevProvider = accessManager.autoSemanticIndexingEngineProvider
        accessManager.isAutoSemanticIndexingEnabled = true
        accessManager.autoSemanticIndexingEngineProvider = { engine }
        defer {
            accessManager.isAutoSemanticIndexingEnabled = prevEnabled
            accessManager.autoSemanticIndexingEngineProvider = prevProvider
            accessManager.revokeAccess(for: tmpDir)
        }

        _ = accessManager.persistBookmark(for: tmpDir)
        let didFinishAutoIndex = await indexingCompletedReceipt.wait(timeoutSeconds: 2.0)
        XCTAssertTrue(didFinishAutoIndex, "Auto-indexing triggered by persistBookmark must complete")

        let didReleaseLease = await leaseTracker.waitUntilActiveCountZero(timeoutSeconds: 2.0)
        XCTAssertTrue(didReleaseLease)

        let summaryAfterAuto = await engine.indexedCoverageSummary()
        XCTAssertEqual(summaryAfterAuto.authorizedScopeCount, 1)
        XCTAssertEqual(summaryAfterAuto.totalIndexedSegments, 6)
        XCTAssertEqual(leaseTracker.activeCountObservedDuringIndexing, 1, "Lease must be actively held while FFI indexing runs")
        XCTAssertEqual(leaseTracker.activeCount, 0, "Lease must be released after indexing completes")

        leaseTracker.shouldDenyAcquisition = true
        let scopeId = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)
        let deniedProgress = await engine.startIndexing(scopeId: scopeId)
        XCTAssertEqual(deniedProgress.phase, .failed)
        let summaryAfterDeniedLease = await engine.indexedCoverageSummary()
        XCTAssertEqual(
            summaryAfterDeniedLease.totalIndexedSegments,
            6,
            "Failed lease acquisition must preserve existing indexed segments rather than wiping them"
        )
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2RegressionA_LeaseAwaitSuspendedThenCancelledNeverStartsNativeAndReleasesLease() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let leaseGate = SuspendedLeaseGate()
        let leaseTracker = LeaseLifecycleTracker()
        let uniffiDouble = S2LifecycleUniFFIDouble()
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in
                await leaseGate.enterAndWaitRelease(timeoutSeconds: 2.0)
                return leaseTracker.acquire(for: url)
            }
        )
        defer { leaseGate.release() }

        _ = await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: false)
        let scopeId = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)

        let handleA = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeId) }
        let enteredLeaseAwait = await leaseGate.waitEntered(timeoutSeconds: 2.0)
        guard enteredLeaseAwait else {
            leaseGate.release()
            _ = await handleA.waitCompleted(timeoutSeconds: 1.0)
            _ = await engine.shutdown()
            XCTFail("Run A failed to enter directoryLeaseProvider await within bounded timeout")
            return
        }

        await engine.cancelIndexing(scopeId: scopeId)
        leaseGate.release()

        guard let progA = await handleA.valueIfCompleted(timeoutSeconds: 2.0) else {
            _ = await engine.shutdown()
            XCTFail("Run A did not complete within bounded timeout after lease gate release")
            return
        }
        XCTAssertEqual(progA.phase, .cancelled)
        XCTAssertEqual(
            uniffiDouble.directoryIndexingCallCount,
            0,
            "Native startDirectoryIndexing must never be called when run was cancelled during lease await"
        )
        XCTAssertEqual(leaseTracker.acquireCount, 1)
        XCTAssertEqual(leaseTracker.activeCount, 0, "Lease returned after cancellation must be released immediately")
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2RegressionB_NativeEncodeASuspendedCancelARequestBReleaseA_SerializesAdmissionAndPreventsStaleCommit() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gate = IndexingRunGateBox()
        let leaseTracker = LeaseLifecycleTracker()
        let uniffiDouble = S2LifecycleUniFFIDouble(runGate: gate)
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in leaseTracker.acquire(for: url) }
        )
        defer {
            gate.releaseRun1()
            gate.releaseRun2()
        }

        _ = await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: false)
        let scopeId = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)

        let handleA = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeId) }
        guard await gate.waitRun1Entered(timeoutSeconds: 2.0) else {
            gate.releaseRun1()
            _ = await handleA.waitCompleted(timeoutSeconds: 1.0)
            _ = await engine.shutdown()
            XCTFail("Run A failed to enter native indexing within bounded timeout")
            return
        }

        await engine.cancelIndexing(scopeId: scopeId)
        let handleB = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeId) }
        let handleC = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeId) }
        XCTAssertEqual(uniffiDouble.directoryIndexingCallCount, 1, "Run B admission must wait for retiring Run A")

        gate.releaseRun1()
        guard let progA = await handleA.valueIfCompleted(timeoutSeconds: 2.0) else {
            gate.releaseRun2()
            _ = await handleB.waitCompleted(timeoutSeconds: 1.0)
            _ = await handleC.waitCompleted(timeoutSeconds: 1.0)
            _ = await engine.shutdown()
            XCTFail("Run A did not complete within bounded timeout after gate release")
            return
        }
        XCTAssertEqual(progA.phase, .cancelled)

        guard await gate.waitRun2Entered(timeoutSeconds: 2.0) else {
            gate.releaseRun2()
            _ = await handleB.waitCompleted(timeoutSeconds: 1.0)
            _ = await handleC.waitCompleted(timeoutSeconds: 1.0)
            _ = await engine.shutdown()
            XCTFail("Run B failed to enter native indexing after Run A exited")
            return
        }
        XCTAssertEqual(uniffiDouble.segmentsCount(for: scopeId), 0, "Cancelled Run A must not commit stale segments")
        XCTAssertEqual(uniffiDouble.directoryIndexingCallCount, 2, "Request C must coalesce onto Run B")

        gate.releaseRun2()
        guard let progB = await handleB.valueIfCompleted(timeoutSeconds: 2.0),
              let progC = await handleC.valueIfCompleted(timeoutSeconds: 2.0)
        else {
            _ = await engine.shutdown()
            XCTFail("Run B/C did not complete within bounded timeout after gate release")
            return
        }
        XCTAssertEqual(progB.phase, .completed)
        XCTAssertEqual(progB.indexedSegments, 6)
        XCTAssertEqual(progC.indexedSegments, 6)
        XCTAssertEqual(uniffiDouble.directoryIndexingCallCount, 2)
        XCTAssertEqual(leaseTracker.activeCount, 0, "All security-scoped leases must be released after A and B drain")
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2RegressionC_CancelARevokeReauthorizeSameScopeC_DrainsInOrderWithoutStaleWrite() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gate = IndexingRunGateBox()
        let eventLog = OrderedLifecycleEventLog()
        let cancelSignal = BoundedSignalReceipt()
        let uniffiDouble = S2LifecycleUniFFIDouble(
            runGate: gate,
            eventLog: eventLog,
            onCancelIndexingCalled: { cancelSignal.signal() }
        )
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in
                eventLog.record("lease.acquired")
                return SecurityScopeLease(url: url) { _ in eventLog.record("lease.released") }
            }
        )
        defer { gate.releaseRun1() }

        _ = await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: false)
        let scopeId = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)

        let handleA = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeId) }
        guard await gate.waitRun1Entered(timeoutSeconds: 2.0) else {
            gate.releaseRun1()
            _ = await handleA.waitCompleted(timeoutSeconds: 1.0)
            _ = await engine.shutdown()
            XCTFail("Run A failed to enter native indexing")
            return
        }

        await engine.cancelIndexing(scopeId: scopeId)
        _ = await cancelSignal.wait(timeoutSeconds: 2.0)

        let revokeHandle = BoundedTaskHandle { () -> Bool in
            let res = await engine.revokeAuthorizedDirectory(url: tmpDir)
            eventLog.record("revoke.returned")
            return res
        }

        let snapshotWhileBlocked = eventLog.snapshot()
        XCTAssertFalse(snapshotWhileBlocked.contains("bridge.revokeScope"))
        XCTAssertFalse(snapshotWhileBlocked.contains("revoke.returned"))
        XCTAssertFalse(snapshotWhileBlocked.contains("lease.released"))

        gate.releaseRun1()
        guard let revoked = await revokeHandle.valueIfCompleted(timeoutSeconds: 2.0),
              let progA = await handleA.valueIfCompleted(timeoutSeconds: 2.0)
        else {
            _ = await engine.shutdown()
            XCTFail("Revoke or retiring Run A did not complete within bounded timeout after gate release")
            return
        }
        XCTAssertTrue(revoked)
        XCTAssertEqual(progA.phase, .cancelled)

        let finalEvents = eventLog.snapshot()
        let exitIdx = try XCTUnwrap(finalEvents.firstIndex(of: "run1.exitedNative"))
        let leaseRelIdx = try XCTUnwrap(finalEvents.firstIndex(of: "lease.released"))
        let bridgeRevokeIdx = try XCTUnwrap(finalEvents.firstIndex(of: "bridge.revokeScope"))
        let revokeRetIdx = try XCTUnwrap(finalEvents.firstIndex(of: "revoke.returned"))
        XCTAssertLessThan(exitIdx, leaseRelIdx, "Native work must exit before lease is released")
        XCTAssertLessThan(leaseRelIdx, bridgeRevokeIdx, "Lease must release before bridge.revokeScope completes")
        XCTAssertLessThan(bridgeRevokeIdx, revokeRetIdx, "bridge.revokeScope must precede revoke return")

        _ = await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: false)
        let summaryC = await engine.indexedCoverageSummary()
        XCTAssertEqual(summaryC.totalIndexedSegments, 0, "Stale Run A must never write into re-authorized Scope C")
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2BridgeSearchDoesNotBlockActorControlPlaneDuringNativeModelMutexContention() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-mutex-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let targetFile = tmpDir.appendingPathComponent("immediate_lexical_hit.txt")
        try Data("fast lexical body".utf8).write(to: targetFile)

        let mutexGate = NativeModelMutexSimulationGate()
        let uniffiDouble = S2LifecycleUniFFIDouble(mutexGate: mutexGate)
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in SecurityScopeLease(url: url, onRelease: { _ in }) }
        )
        defer { mutexGate.releaseIndexingMutex() }

        _ = await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: false)
        let scopeId = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)

        let indexHandle = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeId) }
        guard await mutexGate.waitIndexingEnteredMutex(timeoutSeconds: 2.0) else {
            mutexGate.releaseIndexingMutex()
            _ = await indexHandle.waitCompleted(timeoutSeconds: 1.0)
            _ = await engine.shutdown()
            XCTFail("Indexing failed to enter native model mutex")
            return
        }

        let blockedSearchHandle = BoundedTaskHandle {
            await engine.search(
                SemanticSearchRequest(requestId: 501, windowId: "win-mutex", query: "blocked_query")
            )
        }
        let stateHandle = BoundedTaskHandle { await bridge.modelState() }
        let stateWhileBlocked = await stateHandle.valueIfCompleted(timeoutSeconds: 1.0)
        XCTAssertNotNil(stateWhileBlocked, "Status reads must not wait behind native initialization")

        let progressWhileBlocked = await engine.indexProgress(scopeId: scopeId)
        XCTAssertNotNil(progressWhileBlocked)
        await engine.cancelSearch(requestId: 501)
        XCTAssertTrue(uniffiDouble.cancelledSearchIds.contains(501))

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: DefaultDirectoryRecursiveScanner(),
            systemSearchProvider: EmptySystemFileSearchProvider(),
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )
        coordinator.updateSearch(query: "immediate_lexical_hit", scope: .physicalDirectory(tmpDir))
        let didCompleteLexical = await waitForMainActorCondition(timeoutSeconds: 2.0) {
            coordinator.currentDirectoryGroup.phase == .completed
        }
        XCTAssertTrue(didCompleteLexical)
        XCTAssertEqual(coordinator.currentDirectoryGroup.items.map(\.title), ["immediate_lexical_hit.txt"])

        mutexGate.releaseIndexingMutex()
        guard let cancelledSearchResp = await blockedSearchHandle.valueIfCompleted(timeoutSeconds: 2.0),
              let _ = await indexHandle.valueIfCompleted(timeoutSeconds: 2.0)
        else {
            _ = await engine.shutdown()
            XCTFail("Search or indexing did not complete within bounded timeout after mutex release")
            return
        }
        XCTAssertTrue(cancelledSearchResp.isCancelled)
        await coordinator.waitForActiveSearch()
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2MissingModelBackfillDegradesToLexicalOnlyViaInjectedBinding() async throws {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("ttzip-s2-missing-model-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = tmpRoot.appendingPathComponent("authorized_notes", isDirectory: true)
        try fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        let noteURL = workspaceDir.appendingPathComponent("doc_771.md")
        try Data("# 运维记录\n第2行：生产环境数据库连接池出现超时，已启用指数退避重试机制。".utf8)
            .write(to: noteURL)

        let uniffiMissingModel = S2LifecycleUniFFIDouble(isModelInstalled: false)
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpRoot, uniffiEngine: uniffiMissingModel)
        let engine = SemanticSearchEngine(storageDirectory: tmpRoot, bridge: bridge)

        let isolatedState = await engine.modelState()
        XCTAssertEqual(isolatedState, .notInstalled)

        _ = await engine.registerAuthorizedDirectory(
            url: workspaceDir,
            isAuthorized: true,
            startIndexingImmediately: false
        )
        let degradedBackfill = await engine.backfillAuthorizedScopesIfNeeded()
        XCTAssertEqual(degradedBackfill.first?.phase, .degradedLexicalOnly)
        XCTAssertEqual(degradedBackfill.first?.indexedSegments, 0)
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2RealGGUFModelAuthorizedDirectoryBackfillAndCoordinatorContentRetrieval() async throws {
        guard ProcessInfo.processInfo.environment["TTZIP_REQUIRE_REAL_GGUF"] == "1" else {
            throw XCTSkip("Opt-in real-GGUF acceptance tier: pass --test_env=TTZIP_REQUIRE_REAL_GGUF=1 to execute")
        }

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-real-gguf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let (realStorage, workspaceDir, stagedModelURL, verifiedDigest) = try stageVerifiedRealGGUFFixture(in: tmpRoot)

        let engine = SemanticSearchEngine(storageDirectory: realStorage)
        await engine.setPluginEnabled(true)
        let state = await engine.reloadAndVerifyModelRuntime(at: stagedModelURL, requireExactChecksum: true)
        guard case let .ready(desc) = state else {
            _ = await engine.shutdown()
            XCTFail("Expected real GGUF model .ready state from staged fixture \(stagedModelURL.path), got \(state)")
            return
        }
        XCTAssertEqual(desc.modelFingerprint, PinnedSemanticModelConstants.modelFingerprint)

        _ = await engine.registerAuthorizedDirectory(
            url: workspaceDir,
            isAuthorized: true,
            startIndexingImmediately: false
        )
        let preSummary = await engine.indexedCoverageSummary()
        XCTAssertEqual(preSummary.authorizedScopeCount, 1)
        XCTAssertEqual(preSummary.totalIndexedSegments, 0)

        let backfilled = await engine.backfillAuthorizedScopesIfNeeded()
        XCTAssertEqual(backfilled.count, 1)
        XCTAssertEqual(backfilled.first?.phase, .completed)
        let segmentCount = backfilled.first?.indexedSegments ?? 0
        XCTAssertGreaterThan(segmentCount, 0)

        let coordinator = UnifiedExplorerSearchCoordinator(
            windowID: UUID(),
            semanticEngine: engine,
            directoryScanner: DefaultDirectoryRecursiveScanner(),
            systemSearchProvider: EmptySystemFileSearchProvider(),
            semanticDebounceNanoseconds: 0,
            fastProviderOverride: { _ in [] }
        )
        coordinator.updateSearch(query: "数据库连接超时退避重试", scope: .physicalDirectory(workspaceDir))
        await coordinator.waitForActiveSearch()

        XCTAssertTrue(coordinator.fullDiskGroup.coverage.isModelReady)
        XCTAssertTrue(coordinator.fullDiskGroup.coverage.isSemanticQueryEncoded)
        XCTAssertEqual(coordinator.fullDiskGroup.coverage.indexedSegmentCount, segmentCount)
        XCTAssertTrue(coordinator.fullDiskGroup.coverage.hasSemanticContentHits)
        XCTAssertEqual(coordinator.currentDirectoryGroup.items.first?.title, "doc_771.md")
        XCTAssertEqual(coordinator.fullDiskGroup.items.first?.title, "doc_771.md")
        print(
            "[S2_REAL_GGUF_ACCEPTANCE] staged_model=\(stagedModelURL.path) sha256=\(verifiedDigest) "
                + "fingerprint=\(desc.modelFingerprint) segments=\(segmentCount) top_hit=doc_771.md"
        )
        _ = await engine.shutdown()
    }

    @MainActor
    func testDisableWhileNativeHoldsLockRejectsAllWorkImmediatelyAndCompletesOnlyAfterNativeReleases() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        try FileManager.default.createDirectory(at: resolver.modelsDirectoryURL, withIntermediateDirectories: true)
        try (Data("GGUF".utf8) + Data(repeating: 0x33, count: 60)).write(to: resolver.canonicalModelFileURL)

        let tracker = ControlledGenerationBindingTracker()
        tracker.enableHoldFirstIndex()
        defer { tracker.releaseAll() }
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir) { _ in
            ControlledGenerationUniFFIDouble(tracker: tracker)
        }
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { SecurityScopeLease(url: $0, onRelease: { _ in }) },
            pluginEnabled: false
        )
        let suite = "ttzip.disable.drain.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            requireExactChecksum: false,
            userDefaults: defaults
        )
        await manager.refreshState()
        await manager.setPluginEnabled(true)
        _ = await engine.registerAuthorizedDirectory(
            url: tmpDir,
            isAuthorized: true,
            startIndexingImmediately: false
        )
        let scopeID = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)

        let indexHandle = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeID) }
        let firstEntered = await tracker.firstIndexEntered.wait(timeoutSeconds: 2.0)
        XCTAssertTrue(firstEntered)
        let activeSessionID = try XCTUnwrap(tracker.heldIndexInstanceID)

        let disableDone = BoundedSignalReceipt()
        let disableHandle = BoundedTaskHandle { @MainActor in
            await manager.setPluginEnabled(false)
            tracker.eventLog.record("disable.completed")
            disableDone.signal()
        }
        let enteredDisabling = await waitForMainActorCondition(timeoutSeconds: 2.0) {
            !manager.isPluginEnabled && manager.isDisabling
        }
        let enteredActorDrain = await waitForEngineAndBridgeDraining(
            engine: engine,
            bridge: bridge,
            timeoutSeconds: 2.0
        )
        XCTAssertTrue(enteredDisabling)
        XCTAssertTrue(enteredActorDrain)
        await assertAllNewWorkRejectedWhileDisableDrains(
            engine: engine,
            bridge: bridge,
            tracker: tracker,
            scopeID: scopeID,
            tmpDir: tmpDir,
            activeSessionID: activeSessionID
        )
        let prematureDisable = await disableDone.wait(timeoutSeconds: 0.05)
        XCTAssertFalse(prematureDisable, "disable receipt must not fire while native indexing holds lock")

        tracker.releaseAll()
        let disableSignaled = await disableDone.wait(timeoutSeconds: 2.0)
        let disableTaskDone = await disableHandle.waitCompleted(timeoutSeconds: 2.0)
        let indexProgress = await indexHandle.valueIfCompleted(timeoutSeconds: 2.0)
        let frozenIsDisablingAfterRelease = manager.isDisabling
        let isStillDrainingAfterRelease = await BoundedTaskHandle {
            await engine.isDrainingRuntime
        }.valueIfCompleted(timeoutSeconds: 1.0)
        let events = tracker.eventLog.snapshot()
        _ = await BoundedTaskHandle { await engine.shutdown() }.valueIfCompleted(timeoutSeconds: 1.0)

        XCTAssertTrue(disableSignaled)
        XCTAssertTrue(disableTaskDone)
        XCTAssertNotNil(indexProgress)
        XCTAssertFalse(frozenIsDisablingAfterRelease)
        XCTAssertEqual(isStillDrainingAfterRelease, false)
        let exitIdx = try XCTUnwrap(events.firstIndex(of: "native#\(activeSessionID).exited"))
        let destroyIdx = try XCTUnwrap(events.firstIndex(of: "destroy#\(activeSessionID)"))
        let doneIdx = try XCTUnwrap(events.firstIndex(of: "disable.completed"))
        XCTAssertLessThan(exitIdx, destroyIdx)
        XCTAssertLessThan(destroyIdx, doneIdx)
    }

    @MainActor
    func testConcurrentEnableDisableResetABAReentrancySerializesBindingsWithoutDuplicateRuntimes() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tracker = ControlledGenerationBindingTracker()
        tracker.enableHoldFirstIndex()
        defer { tracker.releaseAll() }
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir) { _ in
            ControlledGenerationUniFFIDouble(tracker: tracker)
        }
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir, bridge: bridge,
            directoryLeaseProvider: { SecurityScopeLease(url: $0, onRelease: { _ in }) },
            pluginEnabled: true
        )
        _ = await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: false)
        let scopeID = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)

        let indexHandle = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeID) }
        let firstEntered = await tracker.firstIndexEntered.wait(timeoutSeconds: 2.0)
        XCTAssertTrue(firstEntered)

        let t1 = BoundedTaskHandle { await engine.setPluginEnabled(false) }
        let t2 = BoundedTaskHandle { await engine.setPluginEnabled(true) }
        let t3 = BoundedTaskHandle { await engine.unloadModelRuntime() }
        let t4 = BoundedTaskHandle { await engine.setPluginEnabled(false) }

        tracker.releaseAll()
        let idxDone = await indexHandle.waitCompleted(timeoutSeconds: 2.0)
        let t1Done = await t1.waitCompleted(timeoutSeconds: 2.0)
        let t2Done = await t2.waitCompleted(timeoutSeconds: 2.0)
        let t3Done = await t3.waitCompleted(timeoutSeconds: 2.0)
        let t4Done = await t4.waitCompleted(timeoutSeconds: 2.0)
        let stateAfterABA = await BoundedTaskHandle { await engine.modelState() }.valueIfCompleted(timeoutSeconds: 1.0)
        let events = tracker.eventLog.snapshot()
        _ = await BoundedTaskHandle { await engine.shutdown() }.valueIfCompleted(timeoutSeconds: 1.0)

        XCTAssertTrue(idxDone && t1Done && t2Done && t3Done && t4Done)
        XCTAssertEqual(tracker.maxConcurrentLiveCount, 1, "ABA transitions must never hold two live bindings concurrently")
        XCTAssertEqual(stateAfterABA, .notInstalled)
        if let d1 = events.firstIndex(of: "destroy#1"), let c2 = events.firstIndex(of: "create#2") {
            XCTAssertLessThan(d1, c2, "Old binding #1 must be destroyed before binding #2 is created")
        }
    }

    @MainActor
    func testQueuedOperationsCancelledBeforeExecutionNeverInvokeNativeBinding() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tracker = ControlledGenerationBindingTracker()
        tracker.enableHoldFirstIndex()
        defer { tracker.releaseAll() }
        let admissionGate = SemanticCancellationAdmissionGate()
        defer { admissionGate.release() }
        let bridge = UniFFIRustSemanticCoreBridge(
            storageDirectory: tmpDir,
            engineFactory: { _ in ControlledGenerationUniFFIDouble(tracker: tracker) },
            beforeNativeQueueWait: { key in
                guard key == "search:888" else { return }
                await admissionGate.wait()
            }
        )
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir, bridge: bridge,
            directoryLeaseProvider: { SecurityScopeLease(url: $0, onRelease: { _ in }) },
            pluginEnabled: true
        )
        _ = await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: false)
        let scopeID = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)

        let runningIndex = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeID) }
        let firstEntered = await tracker.firstIndexEntered.wait(timeoutSeconds: 2.0)
        XCTAssertTrue(firstEntered)

        let queuedSearch = BoundedTaskHandle {
            await engine.search(SemanticSearchRequest(requestId: 888, windowId: "w", query: "queued"))
        }
        guard await admissionGate.waitEntered(timeoutSeconds: 2.0) else {
            admissionGate.release()
            tracker.releaseAll()
            XCTFail("Search did not reach the native admission boundary")
            return
        }
        await engine.cancelSearch(requestId: 888)
        admissionGate.release()
        tracker.releaseAll()

        let searchResp = await queuedSearch.valueIfCompleted(timeoutSeconds: 2.0)
        let indexDone = await runningIndex.waitCompleted(timeoutSeconds: 2.0)
        _ = await BoundedTaskHandle { await engine.shutdown() }.valueIfCompleted(timeoutSeconds: 1.0)
        XCTAssertTrue(indexDone)
        XCTAssertEqual(searchResp?.isCancelled, true)
        XCTAssertEqual(tracker.searchCount, 0, "Queued search cancelled before execution must never invoke native search")
    }

    /// Real `SemanticSearchEngine` entry-point regression for same-scope `P -> A -> B` retiring runs:
    /// P holds native gate -> cancel P -> A waits on P -> cancel A -> B waits on P/A -> cancel B -> release P.
    /// Must-red mutation: removing `&& $0.admissionSequence < beforeAdmissionSequence` in
    /// `SemanticSearchEngine.awaitPriorRetiringRuns` causes A to re-scan and await B while B awaits A,
    /// failing `aResult`, `bResult`, and `disableCompleted` within the bounded timeout.
    @MainActor
    func testSameScopeRetiringRunsPABCounterexampleCompletesBoundedlyWithoutWaitCycle() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tracker = ControlledGenerationBindingTracker()
        tracker.enableHoldFirstIndex()
        defer { tracker.releaseAll() }
        let waitLog = RetiringPredecessorWaitReceiptLog()
        let (engine, scopeID) = await makeControlledIndexingEngineAndScope(
            at: tmpDir, tracker: tracker, waitLog: waitLog
        )

        let runP = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeID) }
        let pEntered = await tracker.firstIndexEntered.wait(timeoutSeconds: 2.0)
        XCTAssertTrue(pEntered)
        await engine.cancelIndexing(scopeId: scopeID)

        let runA = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeID) }
        let aWaitReceipt = await waitLog.waitForReceipt(at: 0, timeoutSeconds: 2.0)
        XCTAssertEqual(aWaitReceipt?.priorAdmissionSequences.count, 1, "Run A must wait on retiring Run P")
        await engine.cancelIndexing(scopeId: scopeID)

        let runB = BoundedTaskHandle { await engine.startIndexing(scopeId: scopeID) }
        let bWaitReceipt = await waitLog.waitForReceipt(at: 1, timeoutSeconds: 2.0)
        XCTAssertEqual(bWaitReceipt?.priorRunIDs, aWaitReceipt.map { $0.priorRunIDs + [$0.waiterRunID] })
        XCTAssertEqual(
            bWaitReceipt?.priorAdmissionSequences,
            aWaitReceipt.map { $0.priorAdmissionSequences + [$0.waiterAdmissionSequence] }
        )
        await engine.cancelIndexing(scopeId: scopeID)

        let disableHandle = BoundedTaskHandle { await engine.setPluginEnabled(false) }
        let disableRevokedAdmission = await waitForEngineDrainingAdmissionRevoked(engine: engine, timeoutSeconds: 2.0)
        let rejectedWhileDraining = await engine.removeIndexedFile(scopeId: scopeID, relativePath: "probe.txt")
        XCTAssertTrue(disableRevokedAdmission, "setPluginEnabled(false) must revoke admission before P releases")
        XCTAssertFalse(rejectedWhileDraining)
        tracker.releaseAll()

        let pResult = await runP.valueIfCompleted(timeoutSeconds: 1.5)
        let aResult = await runA.valueIfCompleted(timeoutSeconds: 0.5)
        let bResult = await runB.valueIfCompleted(timeoutSeconds: 0.5)
        let disableCompleted = await disableHandle.waitCompleted(timeoutSeconds: 0.5)
        let shutdownCompleted = await BoundedTaskHandle { await engine.shutdown() }.waitCompleted(timeoutSeconds: 0.5)

        XCTAssertEqual(pResult?.phase, .cancelled)
        XCTAssertEqual(aResult?.phase, .cancelled, "Run A must not form a same-scope wait cycle with newer retiring Run B")
        XCTAssertEqual(bResult?.phase, .cancelled, "Run B must drain after predecessor Run A completes")
        XCTAssertTrue(disableCompleted, "setPluginEnabled(false) must drain boundedly after P/A/B cancellations")
        XCTAssertTrue(shutdownCompleted, "shutdown() must drain boundedly after P/A/B cancellations")
        XCTAssertEqual(waitLog.snapshot.count, 2, "Run A must never re-enter predecessor wait on newer Run B")
        XCTAssertEqual(tracker.indexCount, 1, "Cancelled runs A and B must never enter native indexing")
    }
}
