// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import XCTest
import TTZipCore
@testable import TTZipApp

// MARK: - Controlled Bridge for Lifecycle Termination Tests

actor ControlledLifecycleSemanticBridge: RustSemanticCoreBridging {
    private var currentModelState: SemanticModelInstallState
    private(set) var modelStateCallCount: Int = 0
    private(set) var resetCount: Int = 0
    private(set) var shutdownCount: Int = 0
    private(set) var startIndexingCount: Int = 0
    private(set) var searchRequestIds: [UInt64] = []
    private(set) var cancelledSearchRequestIds: Set<UInt64> = []
    private(set) var isBindingReleased: Bool = false

    private var gateModelState = false
    private let modelStateEnteredLatch = BoundedAsyncLatch()
    private let modelStateBarrierLatch = BoundedAsyncLatch()

    private var gateSearch = false
    private let searchEnteredLatch = BoundedAsyncLatch()
    private let searchBarrierLatch = BoundedAsyncLatch()
    private let searchCancelledLatch = BoundedAsyncLatch()

    private var gateShutdown = false
    private let shutdownEnteredLatch = BoundedAsyncLatch()
    private let shutdownBarrierLatch = BoundedAsyncLatch()

    init(initialState: SemanticModelInstallState = .notInstalled) {
        self.currentModelState = initialState
    }

    func setModelState(_ state: SemanticModelInstallState) {
        currentModelState = state
    }

    func enableModelStateBarrier() {
        gateModelState = true
    }

    func waitForModelStateEntered(timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        if modelStateCallCount > 0 {
            return true
        }
        return await modelStateEnteredLatch.wait(timeoutNanoseconds: timeoutNanoseconds)
    }

    func releaseModelStateBarrier() async {
        gateModelState = false
        await modelStateBarrierLatch.signal()
    }

    func enableSearchBarrier() {
        gateSearch = true
    }

    func waitForSearchEntered(timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        if !searchRequestIds.isEmpty {
            return true
        }
        return await searchEnteredLatch.wait(timeoutNanoseconds: timeoutNanoseconds)
    }

    func waitForSearchCancelled(requestId: UInt64, timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        if cancelledSearchRequestIds.contains(requestId) {
            return true
        }
        return await searchCancelledLatch.wait(timeoutNanoseconds: timeoutNanoseconds)
    }

    func releaseSearchBarrier() async {
        gateSearch = false
        await searchBarrierLatch.signal()
    }

    func enableShutdownBarrier() {
        gateShutdown = true
    }

    func waitForShutdownEntered(timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        if shutdownCount > 0 {
            return true
        }
        return await shutdownEnteredLatch.wait(timeoutNanoseconds: timeoutNanoseconds)
    }

    func releaseShutdownBarrier() async {
        gateShutdown = false
        await shutdownBarrierLatch.signal()
    }

    func releaseAllBarriers() async {
        await releaseModelStateBarrier()
        await releaseSearchBarrier()
        await releaseShutdownBarrier()
    }

    func resetEngine() async throws {
        resetCount += 1
    }

    func shutdown() async -> Bool {
        shutdownCount += 1
        await shutdownEnteredLatch.signal()
        if gateShutdown {
            _ = await shutdownBarrierLatch.wait(timeoutNanoseconds: 10_000_000_000)
        }
        isBindingReleased = true
        currentModelState = .notInstalled
        return true
    }

    func modelState() async -> SemanticModelInstallState {
        modelStateCallCount += 1
        await modelStateEnteredLatch.signal()
        if gateModelState {
            _ = await modelStateBarrierLatch.wait(timeoutNanoseconds: 10_000_000_000)
        }
        return currentModelState
    }

    func registerScope(_ descriptor: SemanticScopeDescriptor) async -> Bool {
        true
    }

    func revokeScope(scopeId: String) async -> Bool {
        true
    }

    func startDirectoryIndexing(scopeId: String) async -> SemanticIndexProgress {
        startIndexingCount += 1
        return SemanticIndexProgress(
            scopeId: scopeId,
            phase: .completed,
            processedFiles: 0,
            totalFiles: 0,
            indexedSegments: 0,
            indexGeneration: 1
        )
    }

    func cancelIndexing(scopeId: String) async {}

    func scopeProgress(scopeId: String) async -> SemanticIndexProgress? {
        nil
    }

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

    func removeIndexedFile(scopeId: String, relativePath: String) async -> Bool {
        true
    }

    func search(_ request: SemanticSearchRequest) async -> SemanticSearchResponse {
        searchRequestIds.append(request.requestId)
        await searchEnteredLatch.signal()
        if gateSearch {
            _ = await searchBarrierLatch.wait(timeoutNanoseconds: 10_000_000_000)
        }
        return SemanticSearchResponse(
            requestId: request.requestId,
            windowId: request.windowId,
            isCancelled: isBindingReleased || cancelledSearchRequestIds.contains(request.requestId),
            degradedLexicalOnly: currentModelState != .ready(SemanticModelDescriptor()),
            hits: []
        )
    }

    func cancelSearch(requestId: UInt64) async {
        cancelledSearchRequestIds.insert(requestId)
        await searchCancelledLatch.signal()
    }

    nonisolated func buildOpenRequest(for hit: SemanticSearchHit) -> SemanticOpenRequest {
        SemanticOpenRequest(
            scopeId: hit.scopeId,
            sourceKind: hit.sourceKind,
            outerPath: hit.containerOrRootPath,
            archiveEntryPath: hit.archiveEntryPath,
            lineNumber: hit.lineStart
        )
    }
}

private struct NoOpLifecycleDownloadTransport: LocalModelDownloadTransport {
    let failOnDownload: Bool

    init(failOnDownload: Bool = false) {
        self.failOnDownload = failOnDownload
    }

    func downloadModel(
        from url: URL,
        to destinationPartURL: URL,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws {
        if failOnDownload {
            throw SemanticSearchError.downloadFailed(reason: "Must not download on exit")
        }
    }
}

// MARK: - LocalModelTerminationLifecycleTests

final class LocalModelTerminationLifecycleTests: XCTestCase {

    private func makeIsolatedTempDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 1. Terminal Shutdown Releases Binding Without Factory Recreation

    func testTerminalShutdownReleasesBindingWithoutFactoryRecreationAndIsIdempotent() async throws {
        let tmpDir = try makeIsolatedTempDirectory(prefix: "TTZipTerminalFactory")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lifecycleLog = BindingLifecycleRecorderLog()
        let bridge = UniFFIRustSemanticCoreBridge(
            storageDirectory: tmpDir,
            engineFactory: { _ in
                let id = lifecycleLog.nextInstanceID()
                return LifecycleRecordingUniFFIBinding(instanceID: id, log: lifecycleLog)
            }
        )
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: bridge)

        XCTAssertEqual(lifecycleLog.eventsSnapshot(), ["create#1"])
        let initialHasBinding = await bridge.hasActiveBinding
        XCTAssertTrue(initialHasBinding)

        try await bridge.resetEngine()
        XCTAssertEqual(lifecycleLog.eventsSnapshot(), ["create#1", "destroy#1", "create#2"])

        let firstShutdownOK = await engine.shutdown()
        XCTAssertTrue(firstShutdownOK)
        XCTAssertEqual(
            lifecycleLog.eventsSnapshot(),
            ["create#1", "destroy#1", "create#2", "destroy#2"],
            "Terminal shutdown must destroy the active binding and never call engineFactory to recreate it"
        )
        let hasBindingAfterFirst = await bridge.hasActiveBinding
        let isTerminatedAfterFirst = await bridge.isTerminated
        XCTAssertFalse(hasBindingAfterFirst)
        XCTAssertTrue(isTerminatedAfterFirst)

        let secondShutdownOK = await engine.shutdown()
        XCTAssertTrue(secondShutdownOK)
        XCTAssertEqual(lifecycleLog.eventsSnapshot(), ["create#1", "destroy#1", "create#2", "destroy#2"])

        try await bridge.resetEngine()
        let stateAfterShutdown = await engine.modelState()
        XCTAssertEqual(stateAfterShutdown, .notInstalled)
        let hasBindingAfterResetAttempt = await bridge.hasActiveBinding
        XCTAssertFalse(hasBindingAfterResetAttempt)
        XCTAssertEqual(lifecycleLog.eventsSnapshot(), ["create#1", "destroy#1", "create#2", "destroy#2"])
    }

    // MARK: 2. Unloaded Exit Does Not Implicitly Load GGUF or Download

    @MainActor
    func testUnloadedExitDoesNotTriggerModelStateOrDownloadAndRepliesAfterShutdown() async throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "TTZipUnloadedExitTests")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tempRoot)
        let bridge = ControlledLifecycleSemanticBridge(initialState: .notInstalled)
        let engine = SemanticSearchEngine(storageDirectory: resolver.semanticStorageDirectoryURL, bridge: bridge)
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: NoOpLifecycleDownloadTransport(failOnDownload: true),
            requireExactChecksum: false
        )

        var replies: [Bool] = []
        let replyLatch = BoundedAsyncLatch()
        let appDelegate = AppDelegate(
            modelManager: manager,
            terminationReplyHandler: { shouldTerminate in
                replies.append(shouldTerminate)
                Task { await replyLatch.signal() }
            }
        )

        let decision = appDelegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(decision, .terminateLater)
        let replyArrivedInTime = await replyLatch.wait()
        let frozenReplies = replies
        await bridge.releaseAllBarriers()

        XCTAssertTrue(replyArrivedInTime, "Termination reply did not arrive within budget")
        XCTAssertEqual(frozenReplies, [true])
        XCTAssertTrue(manager.isShutDown)
        let modelStateCalls = await bridge.modelStateCallCount
        let resetCalls = await bridge.resetCount
        let shutdownCalls = await bridge.shutdownCount
        let isReleased = await bridge.isBindingReleased
        XCTAssertEqual(modelStateCalls, 0, "Unloaded exit must never query modelState() or implicitly load GGUF")
        XCTAssertEqual(resetCalls, 0, "Unloaded exit must not call resetEngine()")
        XCTAssertEqual(shutdownCalls, 1)
        XCTAssertTrue(isReleased)
    }

    // MARK: 3. Exit During Model Load Drains In-Flight Load, Prevents Ready Revival & Preserves Files

    @MainActor
    func testExitDuringModelLoadDrainsInFlightLoadPreventsReadyRevivalAndPreservesInstalledFiles() async throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "TTZipLoadExitTests")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tempRoot)
        try FileManager.default.createDirectory(at: resolver.modelsDirectoryURL, withIntermediateDirectories: true)
        var fixtureGGUF = Data("GGUF".utf8)
        fixtureGGUF.append(Data(repeating: 0x42, count: 60))
        try fixtureGGUF.write(to: resolver.canonicalModelFileURL)
        let indexFileURL = resolver.semanticStorageDirectoryURL.appendingPathComponent("scope_user.ttvec")
        try Data("persisted_index_payload".utf8).write(to: indexFileURL)

        let suiteName = "TTZipLoadExitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: LocalSemanticPluginPreferences.enabledKey)

        let bridge = ControlledLifecycleSemanticBridge(initialState: .ready(SemanticModelDescriptor()))
        await bridge.enableModelStateBarrier()
        let engine = SemanticSearchEngine(storageDirectory: resolver.semanticStorageDirectoryURL, bridge: bridge)
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: NoOpLifecycleDownloadTransport(),
            requireExactChecksum: false,
            userDefaults: defaults
        )

        let refreshCompletedLatch = BoundedAsyncLatch()
        _ = Task { @MainActor in
            await manager.refreshState()
            await refreshCompletedLatch.signal()
        }
        let enteredModelState = await bridge.waitForModelStateEntered()
        if !enteredModelState {
            await bridge.releaseAllBarriers()
            _ = await refreshCompletedLatch.wait(timeoutNanoseconds: 1_000_000_000)
        }
        XCTAssertTrue(enteredModelState, "refreshState() did not enter bridge.modelState() within budget")

        var replies: [Bool] = []
        let replyLatch = BoundedAsyncLatch()
        let appDelegate = AppDelegate(
            modelManager: manager,
            terminationReplyHandler: { shouldTerminate in
                replies.append(shouldTerminate)
                Task { await replyLatch.signal() }
            }
        )

        let decision = appDelegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(decision, .terminateLater)
        let frozenRepliesWhileGated = replies
        let shutdownCountWhileGated = await bridge.shutdownCount

        await bridge.releaseModelStateBarrier()
        let refreshCompletedInTime = await refreshCompletedLatch.wait()
        let replyCompletedInTime = await replyLatch.wait()
        let frozenRepliesAfterRelease = replies
        let frozenInstallState = manager.installState
        await bridge.releaseAllBarriers()
        _ = await refreshCompletedLatch.wait(timeoutNanoseconds: 1_000_000_000)

        XCTAssertTrue(frozenRepliesWhileGated.isEmpty, "Termination reply must not fire before in-flight load finishes")
        XCTAssertEqual(shutdownCountWhileGated, 0, "Bridge shutdown must wait for in-flight load to exit")
        XCTAssertTrue(refreshCompletedInTime, "refreshState() did not complete within budget")
        XCTAssertTrue(replyCompletedInTime, "Termination reply did not arrive within budget")
        XCTAssertEqual(frozenRepliesAfterRelease, [true])
        XCTAssertEqual(frozenInstallState, .notInstalled, "Late load completion must not revive .ready state")
        XCTAssertFalse(manager.isSemanticSearchAvailable)
        let shutdownCountAfter = await bridge.shutdownCount
        let isReleased = await bridge.isBindingReleased
        XCTAssertEqual(shutdownCountAfter, 1)
        XCTAssertTrue(isReleased)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resolver.canonicalModelFileURL.path),
            "Normal termination shutdown must preserve installed verified GGUF model on disk"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: indexFileURL.path),
            "Normal termination shutdown must preserve user index files on disk"
        )
    }

    // MARK: 4. Exit During Active Search Drains Accepted Search, Rejects New Work & Releases Binding

    @MainActor
    func testExitDuringActiveSearchCancelsAndDrainsSearchRejectsNewWorkAndReleasesBinding() async throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "TTZipSearchExitTests")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tempRoot)
        let bridge = ControlledLifecycleSemanticBridge(initialState: .ready(SemanticModelDescriptor()))
        await bridge.enableSearchBarrier()
        let engine = SemanticSearchEngine(storageDirectory: resolver.semanticStorageDirectoryURL, bridge: bridge)
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: NoOpLifecycleDownloadTransport(),
            requireExactChecksum: false
        )
        let controller = GlobalSearchPanelController(modelManager: manager, stage2DebounceNanoseconds: 0)
        XCTAssertTrue(ObjectIdentifier(controller.semanticEngine) == ObjectIdentifier(manager.engine))

        let searchProbe = BoundedValueProbe<SemanticSearchResponse>()
        _ = Task {
            let response = await engine.search(
                SemanticSearchRequest(requestId: 77, windowId: "win_search", query: "invoice")
            )
            await searchProbe.fulfill(response)
        }
        let enteredSearch = await bridge.waitForSearchEntered()
        if !enteredSearch {
            await bridge.releaseAllBarriers()
            _ = await searchProbe.wait(timeoutNanoseconds: 1_000_000_000)
        }
        XCTAssertTrue(enteredSearch, "In-flight search did not enter bridge within budget")

        var replies: [Bool] = []
        let replyLatch = BoundedAsyncLatch()
        let appDelegate = AppDelegate(
            modelManager: manager,
            terminationReplyHandler: { shouldTerminate in
                replies.append(shouldTerminate)
                Task { await replyLatch.signal() }
            },
            onPrepareForTermination: {
                controller.hide()
            }
        )

        let decision = appDelegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(decision, .terminateLater)
        let cancelledInTime = await bridge.waitForSearchCancelled(requestId: 77)

        let rejectedSearch = await engine.search(
            SemanticSearchRequest(requestId: 78, windowId: "win_search", query: "late query")
        )
        let rejectedReload = await engine.reloadModelRuntime()
        let rejectedIndex = await engine.startIndexing(scopeId: "dir:/tmp")

        let searchIdsBeforeRelease = await bridge.searchRequestIds
        let indexingCount = await bridge.startIndexingCount
        let frozenRepliesWhileSearchGated = replies

        await bridge.releaseSearchBarrier()
        let frozenInFlightResult = await searchProbe.wait()
        let replyCompletedInTime = await replyLatch.wait()
        let frozenRepliesAfterRelease = replies
        await bridge.releaseAllBarriers()
        _ = await searchProbe.wait(timeoutNanoseconds: 1_000_000_000)

        XCTAssertTrue(cancelledInTime, "Active search was not cancelled within budget")
        XCTAssertTrue(rejectedSearch.isCancelled)
        XCTAssertEqual(rejectedReload, .notInstalled)
        XCTAssertEqual(rejectedIndex.phase, .cancelled)
        XCTAssertEqual(searchIdsBeforeRelease, [77])
        XCTAssertEqual(indexingCount, 0)
        XCTAssertTrue(frozenRepliesWhileSearchGated.isEmpty, "Termination reply must wait until accepted search exits")
        XCTAssertEqual(frozenInFlightResult?.isCancelled, true)
        XCTAssertTrue(replyCompletedInTime)
        XCTAssertEqual(frozenRepliesAfterRelease, [true])
        let shutdownCount = await bridge.shutdownCount
        let isReleased = await bridge.isBindingReleased
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertTrue(isReleased)
    }

    // MARK: 5. Repeated CmdQ Coalesces Into Single Shutdown & Single Termination Reply

    @MainActor
    func testRepeatedCmdQDeduplicatesIntoSingleShutdownAndSingleTerminationReply() async throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "TTZipRepeatedCmdQTests")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tempRoot)
        let bridge = ControlledLifecycleSemanticBridge(initialState: .notInstalled)
        await bridge.enableShutdownBarrier()
        let engine = SemanticSearchEngine(storageDirectory: resolver.semanticStorageDirectoryURL, bridge: bridge)
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: NoOpLifecycleDownloadTransport(),
            requireExactChecksum: false
        )

        var replies: [Bool] = []
        let replyLatch = BoundedAsyncLatch()
        let appDelegate = AppDelegate(
            modelManager: manager,
            terminationReplyHandler: { shouldTerminate in
                replies.append(shouldTerminate)
                Task { await replyLatch.signal() }
            }
        )

        let r1 = appDelegate.applicationShouldTerminate(NSApplication.shared)
        let enteredShutdown = await bridge.waitForShutdownEntered()
        let r2 = appDelegate.applicationShouldTerminate(NSApplication.shared)
        let r3 = appDelegate.applicationShouldTerminate(NSApplication.shared)
        let frozenRepliesWhileGated = replies

        await bridge.releaseShutdownBarrier()
        let replyCompletedInTime = await replyLatch.wait()
        let frozenRepliesAfterRelease = replies
        await bridge.releaseAllBarriers()

        XCTAssertTrue(enteredShutdown, "Shutdown did not enter bridge within budget")
        XCTAssertEqual(r1, .terminateLater)
        XCTAssertEqual(r2, .terminateLater)
        XCTAssertEqual(r3, .terminateLater)
        XCTAssertTrue(frozenRepliesWhileGated.isEmpty, "No termination reply may fire while shutdown is still gated")
        XCTAssertTrue(replyCompletedInTime)
        XCTAssertEqual(frozenRepliesAfterRelease, [true], "Repeated CmdQ during shutdown must produce one reply")
        let shutdownCount = await bridge.shutdownCount
        XCTAssertEqual(shutdownCount, 1, "Repeated CmdQ must execute shutdown exactly once")

        let r4 = appDelegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(r4, .terminateNow, "Subsequent query after completed shutdown may proceed immediately")
        XCTAssertEqual(replies.count, 1)
    }

    // MARK: 6. Cancelled Download Retains Ownership Until Uncooperative Transport Drains on CmdQ

    @MainActor
    func testCancelDownloadThenTerminateWaitsForUncooperativeTransportBeforeReplying() async throws {
        let tmpDir = try makeIsolatedTempDirectory(prefix: "TTZipCancelThenTerminate")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        var fixtureData = Data("GGUF".utf8)
        fixtureData.append(Data([0x03, 0x00, 0x00, 0x00]))
        fixtureData.append(Data(repeating: 0xAB, count: 56))

        let bridge = ControllableSemanticCoreBridge(
            storageDirectory: tmpDir,
            simulatedState: .notInstalled
        )
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: bridge)
        let transport = ControlledDownloadTransport(behavior: .gatedWriteBytes(fixtureData))
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: false
        )

        manager.startDownload()
        let entered = await transport.waitForEntered(request: 1)
        if !entered {
            await transport.releaseAllGates()
        }
        XCTAssertTrue(entered, "Download did not enter transport within budget")

        // User cancels first while transport #1 remains held (does not finish on Task.cancel())
        manager.cancelDownload()
        XCTAssertEqual(manager.installState, .notInstalled)
        XCTAssertTrue(manager.hasAcceptedDownloadTasksInFlight)

        var replies: [Bool] = []
        let replyLatch = BoundedAsyncLatch()
        let appDelegate = AppDelegate(
            modelManager: manager,
            terminationReplyHandler: { shouldTerminate in
                replies.append(shouldTerminate)
                Task { await replyLatch.signal() }
            }
        )

        let decision = appDelegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(decision, .terminateLater)

        // Observe during a bounded window while the cancelled transport gate is STILL held:
        // shutdown/termination reply MUST NOT complete before the uncooperative transport exits.
        let prematureReplyWhileTransportHeld = await replyLatch.wait(timeoutNanoseconds: 40_000_000)
        let frozenRepliesWhileHeld = replies
        let frozenManagerShutDownWhileHeld = manager.isShutDown
        let frozenTransportExitedWhileHeld = await transport.hasExited(request: 1)

        // Unconditionally release the transport gate; only now may shutdown complete and reply once.
        await transport.releaseAllGates()
        let replyAfterRelease = await replyLatch.wait()
        let req1Exited = await transport.waitForExited(request: 1)
        let frozenRepliesAfterRelease = replies

        XCTAssertFalse(
            prematureReplyWhileTransportHeld,
            "AppDelegate must not reply to termination while a previously cancelled download transport is still held"
        )
        XCTAssertTrue(frozenRepliesWhileHeld.isEmpty)
        XCTAssertFalse(frozenManagerShutDownWhileHeld)
        XCTAssertFalse(frozenTransportExitedWhileHeld)
        XCTAssertTrue(req1Exited)
        XCTAssertTrue(replyAfterRelease, "Termination reply did not fire after transport gate was released")
        XCTAssertEqual(frozenRepliesAfterRelease, [true])
        XCTAssertTrue(manager.isShutDown)
        XCTAssertFalse(manager.hasAcceptedDownloadTasksInFlight)
    }

    // MARK: 7. Bounded Failure-Path Probes (Missing-Entered & Missing-Completion)

    @MainActor
    func testBoundedObservationFailureProbesFreezePreCleanupStateAndReleaseCleanly() async throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "TTZipBoundedProbeTests")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bridge = ControlledLifecycleSemanticBridge(initialState: .ready(SemanticModelDescriptor()))
        await bridge.enableSearchBarrier()
        let engine = SemanticSearchEngine(storageDirectory: tempRoot, bridge: bridge)

        // Probe 1: Missing-entered observation times out cleanly and freezes false before cleanup
        let frozenEnteredWhenNeverCalled = await bridge.waitForSearchEntered(timeoutNanoseconds: 35_000_000)
        XCTAssertFalse(frozenEnteredWhenNeverCalled, "Missing entered event must time out and return false")

        // Probe 2: Missing-completion observation freezes nil before unconditional barrier release drains the task
        let searchCompletionProbe = BoundedValueProbe<SemanticSearchResponse>()
        _ = Task {
            let response = await engine.search(
                SemanticSearchRequest(requestId: 91, windowId: "win_probe", query: "bounded")
            )
            await searchCompletionProbe.fulfill(response)
        }
        let enteredAfterStart = await bridge.waitForSearchEntered(timeoutNanoseconds: 1_000_000_000)
        let frozenCompletionWhileHeld = await searchCompletionProbe.wait(timeoutNanoseconds: 35_000_000)
        await bridge.releaseAllBarriers()
        let drainedAfterUnconditionalRelease = await searchCompletionProbe.wait(timeoutNanoseconds: 1_000_000_000)

        XCTAssertTrue(enteredAfterStart)
        XCTAssertNil(
            frozenCompletionWhileHeld,
            "Pre-cleanup completion observation must remain nil when barrier is not released within budget"
        )
        XCTAssertNotNil(
            drainedAfterUnconditionalRelease,
            "Unconditional gate release during cleanup must drain the blocked operation without satisfying the pre-cleanup probe"
        )
    }
}

func stageVerifiedRealGGUFFixture(
    in tmpRoot: URL
) throws -> (realStorage: URL, workspaceDir: URL, stagedModelURL: URL, verifiedDigest: String) {
    let fm = FileManager.default
    let realStorage = tmpRoot.appendingPathComponent("staged_real_model", isDirectory: true)
    let modelsDir = realStorage.appendingPathComponent("models", isDirectory: true)
    let workspaceDir = tmpRoot.appendingPathComponent("authorized_notes", isDirectory: true)
    try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

    let noteURL = workspaceDir.appendingPathComponent("doc_771.md")
    try Data("# 运维记录\n第2行：生产环境数据库连接池出现超时，已启用指数退避重试机制。".utf8).write(to: noteURL)

    guard let explicitPath = ProcessInfo.processInfo.environment["TTZIP_REAL_GGUF_MODEL_PATH"],
          !explicitPath.isEmpty else {
        throw SemanticSearchError.modelNotInstalled
    }
    let sourceModelURL = URL(fileURLWithPath: explicitPath)
    let verifiedDigest = try GGUFModelVerifier.verifyModelFile(at: sourceModelURL, requireExactChecksum: true)
    let stagedModelURL = modelsDir.appendingPathComponent(PinnedSemanticModelConstants.ggufFilename)
    try fm.createSymbolicLink(at: stagedModelURL, withDestinationURL: sourceModelURL)
    return (realStorage, workspaceDir, stagedModelURL, verifiedDigest)
}

@MainActor
func waitForMainActorCondition(
    timeoutSeconds: Double,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

/// A real synchronous gate for proving the native lane does not occupy a Swift task executor.
final class SemanticBlockingLaneProbe: @unchecked Sendable {
    let entered = BoundedSignalReceipt()
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var active = 0
    private var maximumActive = 0
    private var cooperativeEntries = 0

    func perform() -> Bool {
        let onTaskExecutor = withUnsafeCurrentTask { $0 != nil }
        lock.withLock {
            active += 1
            maximumActive = max(maximumActive, active)
            if onTaskExecutor {
                cooperativeEntries += 1
            }
        }
        entered.signal()
        let released = release.wait(timeout: .now() + 10) == .success
        lock.withLock { active -= 1 }
        return released
    }

    func releaseAll() {
        for _ in 0..<20 {
            release.signal()
        }
    }

    var observations: (maximumActive: Int, cooperativeEntries: Int) {
        lock.withLock { (maximumActive, cooperativeEntries) }
    }
}

final class MockSemanticVfsSession: VfsSemanticSearchable, @unchecked Sendable {
    var hasEmbeddings: Bool
    var hybridMatchesToReturn: [VfsHybridMatch]
    var onHybridSearchCalled: ((String, [Int8]?, UInt32, Float, Float) -> Void)?

    init(
        hasEmbeddings: Bool = true,
        hybridMatchesToReturn: [VfsHybridMatch] = []
    ) {
        self.hasEmbeddings = hasEmbeddings
        self.hybridMatchesToReturn = hybridMatchesToReturn
    }

    func hasVectorEmbeddings() -> Bool {
        hasEmbeddings
    }

    func searchHybridTopK(
        query: String,
        queryVector: [Int8]?,
        limit: UInt32,
        lexicalWeight: Float,
        semanticWeight: Float
    ) throws -> [VfsHybridMatch] {
        onHybridSearchCalled?(query, queryVector, limit, lexicalWeight, semanticWeight)
        return hybridMatchesToReturn
    }

    func searchSemanticTopK(
        queryVector: [Int8],
        limit: UInt32
    ) throws -> [VfsPagedNode] {
        []
    }
}
