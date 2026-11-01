// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CryptoKit
import Foundation
import XCTest
import TTZipCore
@testable import TTZipApp
@testable import TTZipAppServices

// MARK: - Controlled Test Doubles for LocalModelManager & SemanticCoreBridging

actor ControlledDownloadTransport: LocalModelDownloadTransport {
    enum Behavior: Sendable {
        case writeBytes(Data)
        case failWithError(SemanticSearchError)
        case gatedWriteBytes(Data)
    }

    private var defaultBehavior: Behavior
    private var perRequestBehaviors: [Int: Behavior] = [:]
    private(set) var invocationCount: Int = 0
    private var partURLsByRequest: [Int: URL] = [:]
    private var enteredLatches: [Int: BoundedAsyncLatch] = [:]
    private var gateLatches: [Int: BoundedAsyncLatch] = [:]
    private var exitedLatches: [Int: BoundedAsyncLatch] = [:]

    init(behavior: Behavior) {
        self.defaultBehavior = behavior
    }

    func setBehavior(_ newBehavior: Behavior) {
        self.defaultBehavior = newBehavior
    }

    func setBehavior(_ newBehavior: Behavior, forRequest requestIndex: Int) {
        perRequestBehaviors[requestIndex] = newBehavior
    }

    private func enteredLatch(for requestIndex: Int) -> BoundedAsyncLatch {
        if let existing = enteredLatches[requestIndex] { return existing }
        let latch = BoundedAsyncLatch()
        enteredLatches[requestIndex] = latch
        return latch
    }

    private func gateLatch(for requestIndex: Int) -> BoundedAsyncLatch {
        if let existing = gateLatches[requestIndex] { return existing }
        let latch = BoundedAsyncLatch()
        gateLatches[requestIndex] = latch
        return latch
    }

    private func exitedLatch(for requestIndex: Int) -> BoundedAsyncLatch {
        if let existing = exitedLatches[requestIndex] { return existing }
        let latch = BoundedAsyncLatch()
        exitedLatches[requestIndex] = latch
        return latch
    }

    func waitForEntered(request requestIndex: Int = 1, timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        await enteredLatch(for: requestIndex).wait(timeoutNanoseconds: timeoutNanoseconds)
    }

    func releaseGate(forRequest requestIndex: Int = 1) async {
        await gateLatch(for: requestIndex).signal()
    }

    func releaseAllGates() async {
        for index in 1...max(invocationCount + 2, 4) {
            await gateLatch(for: index).signal()
        }
    }

    func waitForExited(request requestIndex: Int = 1, timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        await exitedLatch(for: requestIndex).wait(timeoutNanoseconds: timeoutNanoseconds)
    }

    func hasExited(request requestIndex: Int = 1) async -> Bool {
        await exitedLatch(for: requestIndex).isCurrentlySignaled()
    }

    func partURL(forRequest requestIndex: Int) -> URL? {
        partURLsByRequest[requestIndex]
    }

    func downloadModel(
        from url: URL,
        to destinationPartURL: URL,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws {
        invocationCount += 1
        let requestIndex = invocationCount
        partURLsByRequest[requestIndex] = destinationPartURL
        let activeBehavior = perRequestBehaviors[requestIndex] ?? defaultBehavior
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationPartURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let exitSignal = exitedLatch(for: requestIndex)
        defer { Task { await exitSignal.signal() } }

        switch activeBehavior {
        case let .failWithError(err):
            try Data("partial_incomplete".utf8).write(to: destinationPartURL)
            await enteredLatch(for: requestIndex).signal()
            await onProgress(LocalModelDownloadProgress(bytesReceived: 18, totalBytesExpected: 100))
            throw err

        case let .writeBytes(payload):
            await enteredLatch(for: requestIndex).signal()
            try Task.checkCancellation()
            let half = payload.count / 2
            try payload.prefix(half).write(to: destinationPartURL)
            await onProgress(
                LocalModelDownloadProgress(bytesReceived: Int64(half), totalBytesExpected: Int64(payload.count))
            )
            try Task.checkCancellation()
            try payload.write(to: destinationPartURL)
            await onProgress(
                LocalModelDownloadProgress(
                    bytesReceived: Int64(payload.count),
                    totalBytesExpected: Int64(payload.count)
                )
            )

        case let .gatedWriteBytes(payload):
            try Data("GGUF_staging_req_\(requestIndex)".utf8).write(to: destinationPartURL)
            await onProgress(
                LocalModelDownloadProgress(
                    bytesReceived: 18,
                    totalBytesExpected: Int64(max(36, payload.count))
                )
            )
            await enteredLatch(for: requestIndex).signal()
            // Uncooperative wait: does NOT exit on Task.cancel() until gate is explicitly released.
            _ = await gateLatch(for: requestIndex).wait(timeoutNanoseconds: 10_000_000_000)
            // Simulate an uncooperative transport flushing trailing bytes to its destinationPartURL before noticing cancel.
            try Data("GGUF_post_gate_req_\(requestIndex)".utf8).write(to: destinationPartURL)
            try Task.checkCancellation()
            try payload.write(to: destinationPartURL)
            await onProgress(
                LocalModelDownloadProgress(
                    bytesReceived: Int64(payload.count),
                    totalBytesExpected: Int64(payload.count)
                )
            )
        }
    }
}

// MARK: - LocalModelManagerTests

final class LocalModelManagerTests: XCTestCase {

    private func makePluginDefaults() -> UserDefaults {
        let suite = "ttzip.localPlugin.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private static func makeValidFixtureGGUFData() -> Data {
        var data = Data("GGUF".utf8)
        data.append(Data([0x03, 0x00, 0x00, 0x00]))
        data.append(Data(repeating: 0xAB, count: 56))
        return data
    }

    private func makeIsolatedTempDirectory(prefix: String = "ttzip_model_mgr") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func testInstallationAndPersistentPluginOptInAreIndependent() async throws {
        let directory = try makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makePluginDefaults()
        let resolver = LocalModelPathResolver(semanticStorageDirectory: directory)
        let bridge = ControllableSemanticCoreBridge(simulatedState: .ready(SemanticModelDescriptor()))
        let engine = SemanticSearchEngine(storageDirectory: directory, bridge: bridge)
        let manager = LocalModelManager(pathResolver: resolver, engine: engine,
            transport: ControlledDownloadTransport(behavior: .writeBytes(Self.makeValidFixtureGGUFData())),
            requireExactChecksum: false, userDefaults: defaults)
        XCTAssertFalse(manager.isPluginEnabled)
        await manager.performDownload()
        XCTAssertTrue(manager.isModelInstalled)
        XCTAssertFalse(manager.isPluginEnabled)
        XCTAssertFalse(manager.isSemanticSearchAvailable)
        XCTAssertFalse(defaults.bool(forKey: LocalSemanticPluginPreferences.enabledKey))
        let installedPresentation = LocalModelSettingsPresentation.make(from: manager)
        XCTAssertTrue(installedPresentation.canDelete)
        XCTAssertFalse(installedPresentation.canDownload)
        await manager.setPluginEnabled(true)
        XCTAssertTrue(manager.isSemanticSearchAvailable)
        XCTAssertTrue(defaults.bool(forKey: LocalSemanticPluginPreferences.enabledKey))
        await manager.setPluginEnabled(false)
        XCTAssertTrue(manager.isModelInstalled)
        XCTAssertFalse(manager.isSemanticSearchAvailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolver.canonicalModelFileURL.path))
        XCTAssertFalse(defaults.bool(forKey: LocalSemanticPluginPreferences.enabledKey))
        let restarted = LocalModelManager(pathResolver: resolver, engine: engine,
            requireExactChecksum: false, userDefaults: defaults)
        await restarted.refreshState()
        XCTAssertTrue(restarted.isModelInstalled)
        XCTAssertFalse(restarted.isPluginEnabled)
        XCTAssertFalse(restarted.isSemanticSearchAvailable)
    }

    // MARK: 1. Unified Path Resolution Across Channels

    func testUnifiedPathResolutionAcrossChannelsWithoutHardcodedHomePaths() throws {
        let sandboxAppSupport = URL(
            fileURLWithPath: "/Volumes/TestSandbox/Containers/com.metastudyline.ttzip/Data/Library/Application Support",
            isDirectory: true
        )
        let masResolver = LocalModelPathResolver.resolver(
            applicationSupportBaseURL: sandboxAppSupport,
            bundleIdentifier: "com.metastudyline.ttzip"
        )
        XCTAssertEqual(
            masResolver.containerRootURL.path,
            "/Volumes/TestSandbox/Containers/com.metastudyline.ttzip/Data/Library/Application Support/com.metastudyline.ttzip"
        )
        XCTAssertEqual(
            masResolver.semanticStorageDirectoryURL.path,
            "/Volumes/TestSandbox/Containers/com.metastudyline.ttzip/Data/Library/Application Support/com.metastudyline.ttzip/SemanticIndex"
        )
        XCTAssertEqual(
            masResolver.modelsDirectoryURL.path,
            "/Volumes/TestSandbox/Containers/com.metastudyline.ttzip/Data/Library/Application Support/com.metastudyline.ttzip/SemanticIndex/models"
        )
        XCTAssertEqual(
            masResolver.canonicalModelFileURL.path,
            "/Volumes/TestSandbox/Containers/com.metastudyline.ttzip/Data/Library/Application Support/com.metastudyline.ttzip/SemanticIndex/models/embeddinggemma-2-Q8_0.gguf"
        )
        XCTAssertEqual(
            masResolver.stagingPartFileURL.path,
            "/Volumes/TestSandbox/Containers/com.metastudyline.ttzip/Data/Library/Application Support/com.metastudyline.ttzip/SemanticIndex/models/embeddinggemma-2-Q8_0.gguf.part"
        )
        XCTAssertEqual(
            masResolver.legacyModelFileURL?.path,
            "/Volumes/TestSandbox/Containers/com.metastudyline.ttzip/Data/Library/Application Support/com.metastudyline.ttzip/Models/embeddinggemma-2-Q8_0.gguf"
        )
        XCTAssertFalse(masResolver.canonicalModelFileURL.path.contains("/Users/"))

        let directAppSupport = URL(
            fileURLWithPath: "/Volumes/DirectHost/Library/Application Support",
            isDirectory: true
        )
        let directResolver = LocalModelPathResolver.resolver(
            applicationSupportBaseURL: directAppSupport,
            bundleIdentifier: "com.metastudyline.ttzip"
        )
        XCTAssertEqual(
            directResolver.canonicalModelFileURL.path,
            "/Volumes/DirectHost/Library/Application Support/com.metastudyline.ttzip/SemanticIndex/models/embeddinggemma-2-Q8_0.gguf"
        )

        let isolatedDir = try makeIsolatedTempDirectory(prefix: "ttzip_isolated_resolver")
        defer { try? FileManager.default.removeItem(at: isolatedDir) }
        let isolatedResolver = LocalModelPathResolver(semanticStorageDirectory: isolatedDir)
        XCTAssertNil(
            isolatedResolver.legacyModelFileURL,
            "Isolated test resolver must have nil legacyModelFileURL so host ~/Library/Application Support is never consulted"
        )
    }

    // MARK: 2. Download / Checksum / Magic / Size / Runtime Failure Never Shows Available

    @MainActor
    func testNetworkFailureCleansUpPartFileAndNeverReportsAvailable() async throws {
        let tmpDir = try makeIsolatedTempDirectory(prefix: "ttzip_net_fail")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        let bridge = ControllableSemanticCoreBridge()
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: bridge)
        let transport = ControlledDownloadTransport(
            behavior: .failWithError(.downloadFailed(reason: "Simulated network timeout"))
        )
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: false,
            userDefaults: makePluginDefaults()
        )

        await manager.performDownload()

        if case let .failed(reason) = manager.installState {
            XCTAssertTrue(reason.contains("Simulated network timeout"))
        } else {
            XCTFail("Expected .failed state on network error, got \(manager.installState)")
        }
        XCTAssertFalse(manager.isSemanticSearchAvailable)
        XCTAssertTrue(manager.isLexicalSearchAvailable)
        XCTAssertEqual(manager.diskUsageBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.stagingPartFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.canonicalModelFileURL.path))
    }

    @MainActor
    func testCorruptedMagicSizeAndSha256MismatchAreRejectedAndNeverInstalled() async throws {
        let tmpDir = try makeIsolatedTempDirectory(prefix: "ttzip_corrupt_verify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        let bridge = ControllableSemanticCoreBridge()
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: bridge)

        // Case A: Invalid magic header ("BAD!" instead of "GGUF")
        let badMagicData = Data("BAD!0000111122223333444455556666".utf8)
        let transport = ControlledDownloadTransport(behavior: .writeBytes(badMagicData))
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: false,
            userDefaults: makePluginDefaults()
        )

        await manager.performDownload()
        guard case .failed = manager.installState else {
            XCTFail("Expected .failed for invalid GGUF magic header, got \(manager.installState)")
            return
        }
        XCTAssertFalse(manager.isSemanticSearchAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.canonicalModelFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.stagingPartFileURL.path))

        // Case B: Exact checksum enforcement rejects wrong byte size / SHA-256
        await transport.setBehavior(.writeBytes(Self.makeValidFixtureGGUFData()))
        let strictManager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: true,
            userDefaults: makePluginDefaults()
        )
        await strictManager.performDownload()
        guard case let .failed(strictReason) = strictManager.installState else {
            XCTFail("Expected .failed when exact size/SHA-256 does not match pinned constants")
            return
        }
        XCTAssertTrue(strictReason.contains("size mismatch") || strictReason.contains("SHA-256"))
        XCTAssertFalse(strictManager.isSemanticSearchAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.canonicalModelFileURL.path))
    }

    @MainActor
    func testRuntimeLoadFailurePreventsReadyStateEvenWhenFileVerificationPasses() async throws {
        let tmpDir = try makeIsolatedTempDirectory(prefix: "ttzip_runtime_fail")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        let failingBridge = ControllableSemanticCoreBridge(
            simulatedState: .failed(reason: "Runtime init failed: Metal context unavailable")
        )
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: failingBridge)
        let transport = ControlledDownloadTransport(
            behavior: .writeBytes(Self.makeValidFixtureGGUFData())
        )
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: false,
            userDefaults: makePluginDefaults()
        )

        await manager.performDownload()
        XCTAssertTrue(manager.isModelInstalled)
        XCTAssertFalse(manager.isPluginEnabled)
        await manager.setPluginEnabled(true)

        if case let .failed(reason) = manager.installState {
            XCTAssertTrue(reason.contains("Runtime init failed"))
        } else {
            XCTFail("Expected .failed when runtime load fails, got \(manager.installState)")
        }
        XCTAssertFalse(manager.isSemanticSearchAvailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolver.canonicalModelFileURL.path),
                      "Runtime activation failure must preserve the separately verified installation")
    }

    // MARK: 3. Per-Request Staging Ownership, Interleaved Cancel/Retry & Cancelled-Download Termination

    private struct InterleavedCancelRetryObservation {
        var req1Entered = false
        var countDuringFlight = 0
        var progressWhileReq1Gated: Double?
        var stateAfterCancel: SemanticModelInstallState = .notInstalled
        var hasAcceptedTasksAfterCancel = false
        var req2Entered = false
        var rawPartURL1: URL?
        var rawPartURL2: URL?
        var expectedPart2StagingBytes: Data?
        var req1Exited = false
        var req1PipelineCompletedInTime = false
        var frozenPart2ExistsAfterReq1Cleanup = false
        var frozenPart2BytesAfterReq1Cleanup: Data?
        var frozenPart1ExistsAfterReq1Cleanup = true
        var req2PipelineCompletedInTime = false
        var prepareCountBeforeEnable = -1
        var prepareCountAfterEnable = -1
        var installStateAfterEnable: SemanticModelInstallState = .notInstalled
        var lastFailureReasonAfterEnable: String?
        var frozenReadyAfterReq2 = false
        var frozenDiskUsageBytes: Int64 = 0
        var frozenCanonicalExistsAfterReq2 = false
        var frozenPart2ExistsAfterReq2 = true
    }

    @MainActor
    func testDuplicateStartDownloadDeduplicatesRetiredCleanupPreservesNewerPartAndRetrySucceeds() async throws {
        let fixtureData = Self.makeValidFixtureGGUFData()
        let tmpDir = try makeIsolatedTempDirectory(prefix: "ttzip_cancel_retry")
        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        let bridge = ControllableSemanticCoreBridge(
            storageDirectory: tmpDir,
            simulatedState: .ready(SemanticModelDescriptor())
        )
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: bridge)
        let transport = ControlledDownloadTransport(behavior: .gatedWriteBytes(fixtureData))
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: false,
            userDefaults: makePluginDefaults()
        )

        let obs = await executeInterleavedCancelRetryScenario(
            manager: manager,
            bridge: bridge,
            transport: transport,
            resolver: resolver,
            tmpDir: tmpDir
        )
        assertInterleavedCancelRetryOutcome(obs, expectedSize: Int64(fixtureData.count))
    }

    @MainActor
    private func executeInterleavedCancelRetryScenario(
        manager: LocalModelManager,
        bridge: ControllableSemanticCoreBridge,
        transport: ControlledDownloadTransport,
        resolver: LocalModelPathResolver,
        tmpDir: URL
    ) async -> InterleavedCancelRetryObservation {
        var obs = InterleavedCancelRetryObservation()
        let req1PipelineDone = BoundedAsyncLatch()
        _ = Task { @MainActor in
            await manager.performDownload()
            await req1PipelineDone.signal()
        }
        obs.req1Entered = await transport.waitForEntered(request: 1)
        manager.startDownload()
        obs.countDuringFlight = await transport.invocationCount
        obs.progressWhileReq1Gated = manager.downloadProgressFraction

        manager.cancelDownload()
        obs.stateAfterCancel = manager.installState
        obs.hasAcceptedTasksAfterCancel = manager.hasAcceptedDownloadTasksInFlight

        manager.retryDownload()
        let req2PipelineDone = BoundedAsyncLatch()
        _ = Task { @MainActor in
            await manager.performDownload()
            await req2PipelineDone.signal()
        }
        obs.req2Entered = await transport.waitForEntered(request: 2)

        obs.rawPartURL1 = await transport.partURL(forRequest: 1)
        obs.rawPartURL2 = await transport.partURL(forRequest: 2)
        obs.expectedPart2StagingBytes = obs.rawPartURL2.flatMap { try? Data(contentsOf: $0) }

        await transport.releaseGate(forRequest: 1)
        obs.req1Exited = await transport.waitForExited(request: 1)
        obs.req1PipelineCompletedInTime = await req1PipelineDone.wait()

        obs.frozenPart2ExistsAfterReq1Cleanup = obs.rawPartURL2.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        obs.frozenPart2BytesAfterReq1Cleanup = obs.rawPartURL2.flatMap { try? Data(contentsOf: $0) }
        obs.frozenPart1ExistsAfterReq1Cleanup = obs.rawPartURL1.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? true

        await transport.releaseGate(forRequest: 2)
        obs.req2PipelineCompletedInTime = await req2PipelineDone.wait()
        obs.prepareCountBeforeEnable = await bridge.prepareEngineCountSnapshot()
        await manager.setPluginEnabled(true)
        obs.prepareCountAfterEnable = await bridge.prepareEngineCountSnapshot()
        obs.installStateAfterEnable = manager.installState
        obs.lastFailureReasonAfterEnable = manager.lastFailureReason
        obs.frozenReadyAfterReq2 = manager.isSemanticSearchAvailable
        obs.frozenDiskUsageBytes = manager.diskUsageBytes
        obs.frozenCanonicalExistsAfterReq2 = FileManager.default.fileExists(
            atPath: resolver.canonicalModelFileURL.path
        )
        obs.frozenPart2ExistsAfterReq2 = obs.rawPartURL2.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? true

        await transport.releaseAllGates()
        _ = await req1PipelineDone.wait(timeoutNanoseconds: 1_000_000_000)
        _ = await req2PipelineDone.wait(timeoutNanoseconds: 1_000_000_000)
        try? FileManager.default.removeItem(at: tmpDir)
        return obs
    }

    private func assertInterleavedCancelRetryOutcome(
        _ obs: InterleavedCancelRetryObservation,
        expectedSize: Int64
    ) {
        XCTAssertTrue(obs.req1Entered, "Download request #1 did not enter transport within budget")
        XCTAssertEqual(obs.countDuringFlight, 1, "Duplicate startDownload() while downloading must be ignored")
        XCTAssertNotNil(obs.progressWhileReq1Gated)
        XCTAssertEqual(obs.stateAfterCancel, .notInstalled)
        XCTAssertTrue(
            obs.hasAcceptedTasksAfterCancel,
            "Cancelled download must remain owned by manager until its transport body exits"
        )
        XCTAssertTrue(obs.req2Entered, "Retry download request #2 did not enter transport within budget")
        XCTAssertNotNil(obs.rawPartURL1)
        XCTAssertNotNil(obs.rawPartURL2)
        XCTAssertNotEqual(
            obs.rawPartURL1,
            obs.rawPartURL2,
            "Each download generation must allocate an independent staging .part URL"
        )
        XCTAssertNotNil(obs.expectedPart2StagingBytes)
        XCTAssertFalse(obs.expectedPart2StagingBytes?.isEmpty ?? true)
        XCTAssertTrue(obs.req1Exited)
        XCTAssertTrue(
            obs.req1PipelineCompletedInTime,
            "Retired download #1 pipeline did not complete within budget after gate release"
        )
        XCTAssertTrue(
            obs.frozenPart2ExistsAfterReq1Cleanup,
            "Retired download #1 cleanup must not delete newer in-flight download #2's staging .part file"
        )
        XCTAssertEqual(
            obs.frozenPart2BytesAfterReq1Cleanup,
            obs.expectedPart2StagingBytes,
            "Newer in-flight download #2's staging .part bytes must remain intact when retired download #1 exits"
        )
        XCTAssertFalse(
            obs.frozenPart1ExistsAfterReq1Cleanup,
            "Retired download #1 must remove its own staging .part file upon pipeline completion"
        )
        XCTAssertTrue(
            obs.req2PipelineCompletedInTime,
            "Retry download #2 pipeline did not complete within budget after gate release"
        )
        XCTAssertEqual(obs.prepareCountBeforeEnable, 0, "Download completion must not implicitly prepare runtime")
        XCTAssertEqual(obs.prepareCountAfterEnable, 1, "Explicit setPluginEnabled(true) must prepare runtime once")
        XCTAssertEqual(obs.installStateAfterEnable, .ready(SemanticModelDescriptor()))
        XCTAssertNil(obs.lastFailureReasonAfterEnable)
        XCTAssertTrue(obs.frozenReadyAfterReq2)
        XCTAssertEqual(obs.frozenDiskUsageBytes, expectedSize)
        XCTAssertTrue(obs.frozenCanonicalExistsAfterReq2)
        XCTAssertFalse(obs.frozenPart2ExistsAfterReq2)
    }

    // MARK: 4. App Restart State Recovery & Leftover .part Rejection

    @MainActor
    func testAppRestartStateRecoveryRemovesLeftoverPartAndRestoresValidModel() async throws {
        let tmpDir = try makeIsolatedTempDirectory(prefix: "ttzip_restart_recovery")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        try FileManager.default.createDirectory(at: resolver.modelsDirectoryURL, withIntermediateDirectories: true)

        // 4A: Leftover .part file + corrupted canonical model file on disk at startup
        try Data("leftover_staging_bytes".utf8).write(to: resolver.stagingPartFileURL)
        try Data("NOT_A_GGUF_HEADER_CORRUPT_DATA".utf8).write(to: resolver.canonicalModelFileURL)

        let bridge = ControllableSemanticCoreBridge(
            storageDirectory: tmpDir,
            simulatedState: .ready(SemanticModelDescriptor())
        )
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: bridge)
        let managerAfterCrash = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: ControlledDownloadTransport(behavior: .writeBytes(Data())),
            requireExactChecksum: false,
            userDefaults: makePluginDefaults()
        )

        // Init immediately purges leftover .part
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.stagingPartFileURL.path))

        await managerAfterCrash.refreshState()
        guard case .failed = managerAfterCrash.installState else {
            XCTFail("Corrupted model on disk must transition to .failed on refreshState, got \(managerAfterCrash.installState)")
            return
        }
        XCTAssertFalse(managerAfterCrash.isSemanticSearchAvailable)

        // 4B: Replace with valid model file and simulate clean app restart
        let validData = Self.makeValidFixtureGGUFData()
        try validData.write(to: resolver.canonicalModelFileURL, options: .atomic)

        let managerAfterRestart = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: ControlledDownloadTransport(behavior: .writeBytes(validData)),
            requireExactChecksum: false,
            userDefaults: makePluginDefaults()
        )
        await managerAfterRestart.refreshState()
        XCTAssertTrue(managerAfterRestart.isModelInstalled)
        XCTAssertFalse(managerAfterRestart.isSemanticSearchAvailable)
        await managerAfterRestart.setPluginEnabled(true)

        guard case .ready = managerAfterRestart.installState else {
            XCTFail("Valid model on disk must restore to .ready on refreshState, got \(managerAfterRestart.installState)")
            return
        }
        XCTAssertTrue(managerAfterRestart.isSemanticSearchAvailable)
        XCTAssertEqual(managerAfterRestart.diskUsageBytes, Int64(validData.count))
    }

    // MARK: 5. Safe Delete Lifecycle While Model Is In Use

    @MainActor
    func testDeleteModelSafelyUnloadsRuntimeAndRemovesOnlyRegisteredModelFiles() async throws {
        let tmpDir = try makeIsolatedTempDirectory(prefix: "ttzip_safe_delete")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        try FileManager.default.createDirectory(at: resolver.modelsDirectoryURL, withIntermediateDirectories: true)

        let validData = Self.makeValidFixtureGGUFData()
        try validData.write(to: resolver.canonicalModelFileURL)

        // Create an unrelated file in the parent semanticStorageDirectoryURL and modelsDirectoryURL
        let unrelatedIndexFile = resolver.semanticStorageDirectoryURL.appendingPathComponent("scope_1.ttvec")
        let unrelatedSiblingFile = resolver.modelsDirectoryURL.appendingPathComponent("custom_notes.txt")
        try Data("keep_index".utf8).write(to: unrelatedIndexFile)
        try Data("keep_notes".utf8).write(to: unrelatedSiblingFile)

        let bridge = ControllableSemanticCoreBridge(
            storageDirectory: tmpDir,
            simulatedState: .ready(SemanticModelDescriptor())
        )
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: bridge)
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: ControlledDownloadTransport(behavior: .writeBytes(validData)),
            requireExactChecksum: false,
            userDefaults: makePluginDefaults()
        )

        await manager.refreshState()
        await manager.setPluginEnabled(true)
        XCTAssertTrue(manager.isSemanticSearchAvailable)

        try await manager.deleteModel()

        XCTAssertEqual(manager.installState, .notInstalled)
        XCTAssertFalse(manager.isSemanticSearchAvailable)
        XCTAssertEqual(manager.diskUsageBytes, 0)
        XCTAssertNil(manager.lastFailureReason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.canonicalModelFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolver.stagingPartFileURL.path))

        // Unrelated files must remain untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedIndexFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedSiblingFile.path))

        // Engine runtime must have been unloaded and reset
        let resetCount = await bridge.resetEngineCountSnapshot()
        XCTAssertGreaterThanOrEqual(resetCount, 1)
        let engineState = await engine.modelState()
        XCTAssertEqual(engineState, .notInstalled)
    }

    // MARK: 6. Production Search Consumer (GlobalSearchPanelController) End-to-End Wiring & Lexical Fallback

    private static func makeSampleSemanticHit(rootPath: String) -> SemanticSearchHit {
        SemanticSearchHit(
            scopeId: "dir:\(rootPath)",
            sourceKind: .authorizedDirectory,
            containerOrRootPath: rootPath,
            displayPath: "finance/deduction_2026_memo.md",
            archiveEntryPath: nil,
            snippet: "Submit corporate tax deduction receipts",
            lineStart: 14,
            lineEnd: 18,
            matchKind: .contentSemantic,
            lexicalScore: 0.25,
            semanticScore: 0.92,
            combinedScore: 0.89,
            indexGeneration: 1,
            modelFingerprint: PinnedSemanticModelConstants.modelFingerprint
        )
    }

    @MainActor
    func testGlobalSearchPanelControllerLexicalFallbackAndSemanticEnrichmentWhenReady() async throws {
        let tmpDir = try makeIsolatedTempDirectory(prefix: "ttzip_global_search_e2e")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sampleArchiveURL = tmpDir.appendingPathComponent("quarterly_tax_bundle.zip")
        try Data("PK\u{03}\u{04}".utf8).write(to: sampleArchiveURL)

        let previousRecentsData = UserDefaults.standard.data(forKey: "TTZipRecentArchivesKey")
        defer {
            if let previousRecentsData {
                UserDefaults.standard.set(previousRecentsData, forKey: "TTZipRecentArchivesKey")
            } else {
                UserDefaults.standard.removeObject(forKey: "TTZipRecentArchivesKey")
            }
        }
        let recents = [RecentArchiveRecord(path: sampleArchiveURL.path)]
        UserDefaults.standard.set(try JSONEncoder().encode(recents), forKey: "TTZipRecentArchivesKey")

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        let bridge = ControllableSemanticCoreBridge(
            simulatedState: .ready(SemanticModelDescriptor()),
            stubbedHits: [Self.makeSampleSemanticHit(rootPath: tmpDir.path)],
            degradedLexicalOnly: false
        )
        let engine = SemanticSearchEngine(storageDirectory: tmpDir, bridge: bridge)
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: ControlledDownloadTransport(behavior: .writeBytes(Self.makeValidFixtureGGUFData())),
            requireExactChecksum: false,
            userDefaults: makePluginDefaults()
        )
        let controller = GlobalSearchPanelController(
            modelManager: manager,
            stage2DebounceNanoseconds: 0
        )
        XCTAssertTrue(
            ObjectIdentifier(controller.semanticEngine) == ObjectIdentifier(manager.engine),
            "Default GlobalSearchPanelController composition must derive its semanticEngine from the injected modelManager"
        )
        XCTAssertTrue(
            ObjectIdentifier(LocalModelManager.shared.engine) == ObjectIdentifier(SemanticSearchEngine.shared),
            "Production LocalModelManager.shared must share the exact same SemanticSearchEngine.shared instance"
        )

        // Phase A: Model is .notInstalled -> basic lexical search works, semantic search is inactive
        XCTAssertEqual(manager.installState, .notInstalled)
        controller.query = "tax"
        await controller.waitForActiveSearch()

        XCTAssertFalse(controller.isSemanticSearchActive)
        XCTAssertTrue(controller.results.contains(where: { $0.archivePath == sampleArchiveURL.path }))
        XCTAssertFalse(controller.results.contains(where: { $0.diskPath?.hasSuffix("deduction_2026_memo.md") == true }))

        // Phase B: Download installs only; explicit opt-in enables semantic hits on the same recorder
        await manager.performDownload()
        XCTAssertFalse(manager.isSemanticSearchAvailable)
        await manager.setPluginEnabled(true)
        XCTAssertTrue(manager.isSemanticSearchAvailable)

        controller.query = "tax deduction"
        await controller.waitForActiveSearch()

        XCTAssertTrue(controller.isSemanticSearchActive)
        XCTAssertTrue(
            controller.results.contains(where: { $0.diskPath?.hasSuffix("finance/deduction_2026_memo.md") == true })
        )
        let recordedQueries = await bridge.recordedSearchQueriesSnapshot()
        XCTAssertEqual(recordedQueries, ["tax deduction"])
    }
}
