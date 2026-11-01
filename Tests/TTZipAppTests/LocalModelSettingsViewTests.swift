// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import XCTest
import TTZipCore
import TTZipUI
@testable import TTZipApp
@testable import TTZipAppServices

// MARK: - Bounded Async Observation Primitives (No Uncooperative TaskGroup Joins)

actor BoundedAsyncLatch {
    private var isSignaled = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    func signal() {
        isSignaled = true
        let activeWaiters = waiters
        waiters.removeAll()
        for (id, continuation) in activeWaiters {
            timeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(returning: true)
        }
    }

    func isCurrentlySignaled() -> Bool {
        isSignaled
    }

    func wait(timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        if isSignaled {
            return true
        }
        let waiterID = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if isSignaled {
                continuation.resume(returning: true)
                return
            }
            waiters[waiterID] = continuation
            timeoutTasks[waiterID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.expireWaiter(id: waiterID)
            }
        }
    }

    private func expireWaiter(id: UUID) {
        timeoutTasks.removeValue(forKey: id)
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(returning: false)
        }
    }
}

actor BoundedValueProbe<Value: Sendable> {
    private var value: Value?
    private let latch = BoundedAsyncLatch()

    func fulfill(_ newValue: Value) async {
        if value == nil {
            value = newValue
        }
        await latch.signal()
    }

    func isFulfilled() async -> Bool {
        await latch.isCurrentlySignaled()
    }

    func wait(timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Value? {
        let completed = await latch.wait(timeoutNanoseconds: timeoutNanoseconds)
        return completed ? value : nil
    }
}

// MARK: - Controlled Bridge & Binding Recorders

final class BindingLifecycleRecorderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: Int = 0
    private var events: [String] = []

    func nextInstanceID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        events.append("create#\(counter)")
        return counter
    }

    func recordDestroy(id: Int) {
        lock.lock()
        defer { lock.unlock() }
        events.append("destroy#\(id)")
    }

    func eventsSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class LifecycleRecordingUniFFIBinding: UniFFISemanticSearchEngineBindingProtocol, @unchecked Sendable {
    let instanceID: Int
    let log: BindingLifecycleRecorderLog

    init(instanceID: Int, log: BindingLifecycleRecorderLog) {
        self.instanceID = instanceID
        self.log = log
    }

    deinit {
        log.recordDestroy(id: instanceID)
    }

    func modelState() -> UniFFISemanticModelState {
        .notInstalled
    }

    func registerScope(descriptor: UniFFISemanticScopeDescriptor) -> Bool {
        false
    }

    func revokeScope(scopeId: String) -> Bool {
        false
    }

    func startDirectoryIndexing(scopeId: String) -> UniFFISemanticIndexProgress {
        UniFFISemanticIndexProgress(
            scopeId: scopeId,
            phase: .degradedLexicalOnly,
            processedFiles: 0,
            totalFiles: 0,
            indexedSegments: 0,
            indexGeneration: 0,
            errorMessage: nil
        )
    }

    func cancelIndexing(scopeId: String) {}

    func scopeProgress(scopeId: String) -> UniFFISemanticIndexProgress? {
        nil
    }

    func upsertArchiveEntries(
        scopeId: String,
        entries: [UniFFISemanticArchiveEntryInput]
    ) -> UniFFISemanticIndexProgress {
        startDirectoryIndexing(scopeId: scopeId)
    }

    func removeIndexedFile(scopeId: String, relativePath: String) -> Bool {
        false
    }

    func search(request: UniFFISemanticSearchRequest) -> UniFFISemanticSearchResponse {
        UniFFISemanticSearchResponse(
            requestId: request.requestId,
            windowId: request.windowId,
            isCancelled: false,
            degradedLexicalOnly: true,
            hits: []
        )
    }

    func cancelSearch(requestId: UInt64) {}

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

// MARK: - Controlled Transport for Settings View Presentation Tests

actor ControllableSemanticCoreBridge: RustSemanticCoreBridging {
    let storageDirectory: URL?
    var simulatedState: SemanticModelInstallState
    private var configuredPreparedState: SemanticModelInstallState
    var stubbedHits: [SemanticSearchHit]
    var degradedLexicalOnly: Bool
    private(set) var prepareCount: Int = 0
    private(set) var resetCount: Int = 0
    private(set) var shutdownCount: Int = 0
    private(set) var isShutDown: Bool = false
    private(set) var isBindingReleased: Bool = false
    private(set) var registeredScopes: [String: SemanticScopeDescriptor] = [:]
    private(set) var cancelledRequestIds: Set<UInt64> = []
    private(set) var recordedSearchQueries: [String] = []

    init(
        storageDirectory: URL? = nil,
        simulatedState: SemanticModelInstallState = .ready(SemanticModelDescriptor()),
        stubbedHits: [SemanticSearchHit] = [],
        degradedLexicalOnly: Bool = false
    ) {
        self.storageDirectory = storageDirectory
        self.simulatedState = simulatedState
        self.configuredPreparedState = simulatedState
        self.stubbedHits = stubbedHits
        self.degradedLexicalOnly = degradedLexicalOnly
    }

    func setSimulatedState(_ state: SemanticModelInstallState) {
        self.simulatedState = state
        self.configuredPreparedState = state
    }

    func setStubbedHits(_ hits: [SemanticSearchHit], degradedLexicalOnly: Bool = false) {
        self.stubbedHits = hits
        self.degradedLexicalOnly = degradedLexicalOnly
    }

    func prepareEngineCountSnapshot() -> Int {
        prepareCount
    }

    func resetEngineCountSnapshot() -> Int {
        resetCount
    }

    func recordedSearchQueriesSnapshot() -> [String] {
        recordedSearchQueries
    }

    func resetEngine() async throws {
        guard !isShutDown else { return }
        resetCount += 1
        if let storageDirectory {
            let modelURL = LocalModelPathResolver(semanticStorageDirectory: storageDirectory).canonicalModelFileURL
            if !FileManager.default.fileExists(atPath: modelURL.path) {
                simulatedState = .notInstalled
            }
        }
    }

    func shutdown() async -> Bool {
        shutdownCount += 1
        isShutDown = true
        isBindingReleased = true
        simulatedState = .notInstalled
        registeredScopes.removeAll()
        return true
    }

    func modelState() async -> SemanticModelInstallState {
        if isShutDown {
            return .notInstalled
        }
        return simulatedState
    }

    func prepareModelRuntime() async -> SemanticModelInstallState {
        guard !isShutDown else { return .notInstalled }
        prepareCount += 1
        if let storageDirectory {
            let modelURL = LocalModelPathResolver(semanticStorageDirectory: storageDirectory).canonicalModelFileURL
            guard FileManager.default.fileExists(atPath: modelURL.path) else {
                simulatedState = .notInstalled
                return .notInstalled
            }
            do {
                _ = try GGUFModelVerifier.verifyModelFile(at: modelURL, requireExactChecksum: false)
                simulatedState = configuredPreparedState
            } catch {
                simulatedState = .failed(reason: error.localizedDescription)
            }
        }
        return simulatedState
    }

    func registerScope(_ descriptor: SemanticScopeDescriptor) async -> Bool {
        registeredScopes[descriptor.scopeId] = descriptor
        if case .ready = simulatedState {
            return true
        }
        return false
    }

    func revokeScope(scopeId: String) async -> Bool {
        registeredScopes.removeValue(forKey: scopeId) != nil
    }

    func startDirectoryIndexing(scopeId: String) async -> SemanticIndexProgress {
        SemanticIndexProgress(
            scopeId: scopeId,
            phase: .completed,
            processedFiles: 1,
            totalFiles: 1,
            indexedSegments: 1,
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
        recordedSearchQueries.append(request.query)
        return SemanticSearchResponse(
            requestId: request.requestId,
            windowId: request.windowId,
            isCancelled: isShutDown || cancelledRequestIds.contains(request.requestId),
            degradedLexicalOnly: degradedLexicalOnly,
            hits: isShutDown ? [] : stubbedHits
        )
    }

    func cancelSearch(requestId: UInt64) async {
        cancelledRequestIds.insert(requestId)
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
}

private actor ControlledModelDownloadTransport: LocalModelDownloadTransport {
    enum Mode {
        case pauseAtHalfUntilReleased
        case fail(reason: String)
        case succeedWithSyntheticGGUF
    }

    private var mode: Mode
    private let halfReachedLatch = BoundedAsyncLatch()
    private let releaseHalfLatch = BoundedAsyncLatch()

    init(mode: Mode) {
        self.mode = mode
    }

    func setMode(_ newMode: Mode) {
        self.mode = newMode
    }

    func waitForHalfProgressReached(timeoutNanoseconds: UInt64 = 3_000_000_000) async -> Bool {
        await halfReachedLatch.wait(timeoutNanoseconds: timeoutNanoseconds)
    }

    func releaseHalfGate() async {
        await releaseHalfLatch.signal()
    }

    func downloadModel(
        from url: URL,
        to destinationPartURL: URL,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationPartURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let total = Int64(SemanticModelSpec.expectedGGUFSizeBytes)

        switch mode {
        case .pauseAtHalfUntilReleased:
            let partialData = Data("GGUF-PARTIAL-PAYLOAD".utf8)
            try partialData.write(to: destinationPartURL)
            await onProgress(
                LocalModelDownloadProgress(bytesReceived: total / 2, totalBytesExpected: total)
            )
            await halfReachedLatch.signal()
            _ = await releaseHalfLatch.wait(timeoutNanoseconds: 10_000_000_000)
            throw CancellationError()

        case .fail(let reason):
            await onProgress(
                LocalModelDownloadProgress(bytesReceived: total / 4, totalBytesExpected: total)
            )
            throw SemanticSearchError.downloadFailed(reason: reason)

        case .succeedWithSyntheticGGUF:
            var payload = Data("GGUF".utf8)
            payload.append(Data(repeating: 0x42, count: 60))
            try payload.write(to: destinationPartURL)
            await onProgress(
                LocalModelDownloadProgress(bytesReceived: total, totalBytesExpected: total)
            )
        }
    }
}

// MARK: - LocalModelSettingsViewTests

final class LocalModelSettingsViewTests: XCTestCase {

    // MARK: - 1. Settings Entrypoint Reachability Guard

    @MainActor
    func testSettingsTabContainsLocalModelsEntrypointAndHostsViewAcrossLocales() {
        XCTAssertTrue(
            SettingsView.SettingsTab.allCases.contains(.localModels),
            "SettingsView.SettingsTab.allCases must include .localModels"
        )
        XCTAssertEqual(SettingsView.SettingsTab.localModels.icon, "square.stack.3d.up")

        let l10n = AppLocalizationState.shared
        let originalLanguage = l10n.currentLanguage
        defer { l10n.setLanguage(originalLanguage) }

        for language in [AppLanguage.zhHans, .zhHant, .en] {
            l10n.setLanguage(language)
            let tabTitle = SettingsView.SettingsTab.localModels.title
            XCTAssertEqual(tabTitle, L10n.Settings.localModels)
            XCTAssertFalse(tabTitle.isEmpty, "Local Models tab title must be non-empty in \(language.bcp47)")
            XCTAssertNotEqual(tabTitle, L10n.LocalModel.tabTitle.rawKey)
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipLocalModelEntrypointTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let resolver = LocalModelPathResolver(semanticStorageDirectory: tempRoot)
        let bridge = ControlledLifecycleSemanticBridge(initialState: .notInstalled)
        let engine = SemanticSearchEngine.forTesting(
            storageDirectory: resolver.semanticStorageDirectoryURL,
            bridge: bridge
        )
        let isolatedManager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: ControlledModelDownloadTransport(mode: .succeedWithSyntheticGGUF),
            requireExactChecksum: false
        )

        let settingsView = SettingsView(initialTab: .localModels, modelManager: isolatedManager)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 540)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertNotNil(hostingView.fittingSize)
    }

    // MARK: - 2. State Presentation & Action Gating Across All Lifecycle States

    @MainActor
    func testNotInstalledAndDownloadingPresentationAndCancelReset() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipLocalModelViewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tempRoot)
        let bridge = ControlledLifecycleSemanticBridge(initialState: .notInstalled)
        let engine = SemanticSearchEngine.forTesting(
            storageDirectory: resolver.semanticStorageDirectoryURL,
            bridge: bridge
        )

        let transport = ControlledModelDownloadTransport(mode: .pauseAtHalfUntilReleased)
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: false
        )

        await manager.refreshState()
        let initialSnapshot = LocalModelSettingsPresentation.make(from: manager)
        XCTAssertFalse(initialSnapshot.isSemanticAvailable)
        XCTAssertNotNil(initialSnapshot.basicSearchFallbackNotice)
        XCTAssertTrue(initialSnapshot.canDownload)
        XCTAssertFalse(initialSnapshot.canCancel)
        XCTAssertFalse(initialSnapshot.canRetry)
        XCTAssertFalse(initialSnapshot.canDelete)
        XCTAssertTrue(initialSnapshot.diskUsageText.contains("0"))

        manager.startDownload()
        let reachedHalf = await transport.waitForHalfProgressReached()
        let downloadingSnapshot = LocalModelSettingsPresentation.make(from: manager)

        manager.cancelDownload()
        await transport.releaseHalfGate()
        let cancelledSnapshot = LocalModelSettingsPresentation.make(from: manager)

        XCTAssertTrue(reachedHalf, "Download did not reach 50% progress within budget")
        XCTAssertFalse(downloadingSnapshot.isSemanticAvailable)
        XCTAssertFalse(downloadingSnapshot.canDownload)
        XCTAssertTrue(downloadingSnapshot.canCancel)
        XCTAssertFalse(downloadingSnapshot.canDelete)
        let progress = try XCTUnwrap(downloadingSnapshot.progressFraction)
        XCTAssertEqual(progress, 0.5, accuracy: 0.05)

        XCTAssertEqual(manager.installState, .notInstalled)
        XCTAssertFalse(cancelledSnapshot.isSemanticAvailable)
        XCTAssertTrue(cancelledSnapshot.canDownload)
        XCTAssertFalse(cancelledSnapshot.canCancel)
        XCTAssertNotNil(cancelledSnapshot.basicSearchFallbackNotice)
    }

    @MainActor
    func testFailedRetryReadyAndDeleteLifecyclePresentation() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipLocalModelLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tempRoot)
        let bridge = ControlledLifecycleSemanticBridge(initialState: .notInstalled)
        let engine = SemanticSearchEngine.forTesting(
            storageDirectory: resolver.semanticStorageDirectoryURL,
            bridge: bridge
        )
        let transport = ControlledModelDownloadTransport(
            mode: .fail(reason: "Network connection interrupted during transfer.")
        )
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: false
        )

        await manager.performDownload()
        let failedSnapshot = LocalModelSettingsPresentation.make(from: manager)
        XCTAssertFalse(failedSnapshot.isSemanticAvailable)
        XCTAssertNotNil(failedSnapshot.failureReasonText)
        XCTAssertTrue(failedSnapshot.canRetry)
        XCTAssertFalse(failedSnapshot.canDownload)
        XCTAssertFalse(failedSnapshot.canDelete)
        XCTAssertNotNil(failedSnapshot.basicSearchFallbackNotice)

        await bridge.setModelState(.ready(SemanticModelDescriptor()))
        await transport.setMode(.succeedWithSyntheticGGUF)

        manager.retryDownload()
        await manager.performDownload()

        let installedDisabledSnapshot = LocalModelSettingsPresentation.make(from: manager)
        XCTAssertTrue(manager.isModelInstalled)
        XCTAssertFalse(manager.isPluginEnabled)
        XCTAssertFalse(installedDisabledSnapshot.isSemanticAvailable)
        XCTAssertTrue(installedDisabledSnapshot.canDelete)
        XCTAssertFalse(installedDisabledSnapshot.canDownload)

        await manager.setPluginEnabled(true)

        let readySnapshot = LocalModelSettingsPresentation.make(from: manager)
        XCTAssertTrue(readySnapshot.isSemanticAvailable)
        XCTAssertTrue(readySnapshot.canDelete)
        XCTAssertFalse(readySnapshot.canDownload)
        XCTAssertFalse(readySnapshot.canCancel)
        XCTAssertFalse(readySnapshot.canRetry)
        XCTAssertNil(readySnapshot.basicSearchFallbackNotice)
        XCTAssertNil(readySnapshot.failureReasonText)
        XCTAssertGreaterThan(manager.diskUsageBytes, 0)

        try await manager.deleteModel()
        let deletedSnapshot = LocalModelSettingsPresentation.make(from: manager)
        XCTAssertFalse(deletedSnapshot.isSemanticAvailable)
        XCTAssertTrue(deletedSnapshot.canDownload)
        XCTAssertFalse(deletedSnapshot.canDelete)
        XCTAssertNotNil(deletedSnapshot.basicSearchFallbackNotice)
        XCTAssertEqual(manager.diskUsageBytes, 0)
    }

    // MARK: - 3. No Internal Implementation Detail Leakage

    @MainActor
    func testPresentationDoesNotLeakRawPathsGGUFOrBackendDetails() async {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipLocalModelHygieneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolver = LocalModelPathResolver(semanticStorageDirectory: tempRoot)
        let bridge = ControlledLifecycleSemanticBridge(initialState: .notInstalled)
        let engine = SemanticSearchEngine.forTesting(
            storageDirectory: resolver.semanticStorageDirectoryURL,
            bridge: bridge
        )
        let leakyPath = "/" + "Users" + "/developer/Models/embeddinggemma.gguf"
        let leakyReason = "Failed to load \(leakyPath) with llama.cpp and CoreML backend"
        let transport = ControlledModelDownloadTransport(mode: .fail(reason: leakyReason))
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: transport,
            requireExactChecksum: false
        )

        await manager.performDownload()
        let snapshot = LocalModelSettingsPresentation.make(from: manager)

        let userFacingStrings: [String] = [
            snapshot.modelName,
            snapshot.purposeText,
            snapshot.downloadSizeText,
            snapshot.diskUsageText,
            snapshot.statusBadgeText,
            snapshot.searchCapabilityBannerText,
            snapshot.basicSearchFallbackNotice ?? "",
            snapshot.failureReasonText ?? ""
        ]

        let homePrefix = ("/" + "Users" + "/").lowercased()
        for text in userFacingStrings {
            let lower = text.lowercased()
            XCTAssertFalse(lower.contains(".gguf"), "Presentation leaked '.gguf' in: \(text)")
            XCTAssertFalse(lower.contains(homePrefix), "Presentation leaked developer home path in: \(text)")
            XCTAssertFalse(lower.contains("llama.cpp"), "Presentation leaked 'llama.cpp' in: \(text)")
            XCTAssertFalse(lower.contains("coreml"), "Presentation leaked 'CoreML' in: \(text)")
            XCTAssertFalse(lower.contains("core ml"), "Presentation leaked 'Core ML' in: \(text)")
            XCTAssertFalse(
                lower.contains(PinnedSemanticModelConstants.ggufSha256.lowercased()),
                "Presentation leaked raw SHA-256 hash in: \(text)"
            )
        }
    }

    @MainActor
    func testOpeningSettingsPerformsZeroPrepareDownloadDoesNotEnableAndDisabledRemoveNeverEntersRust() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        let fixture = Data("GGUF".utf8) + Data([0x03, 0x00, 0x00, 0x00]) + Data(repeating: 0xCD, count: 56)

        let tracker = ControlledGenerationBindingTracker()
        let bridge = UniFFIRustSemanticCoreBridge(
            storageDirectory: tmpDir,
            uniffiEngine: ControlledGenerationUniFFIDouble(tracker: tracker)
        )
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { SecurityScopeLease(url: $0, onRelease: { _ in }) },
            pluginEnabled: false
        )
        let suite = "ttzip.settings.zero.prep.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            transport: ControlledDownloadTransport(behavior: .writeBytes(fixture)),
            requireExactChecksum: false,
            userDefaults: defaults
        )

        await manager.refreshState()
        XCTAssertEqual(tracker.prepareCount, 0, "Opening settings before install must perform zero prepare calls")
        await manager.performDownload()
        XCTAssertTrue(manager.isModelInstalled)
        XCTAssertFalse(manager.isPluginEnabled)
        XCTAssertEqual(tracker.prepareCount, 0, "Downloading model must not enable or prepare runtime")

        let removedWhileDisabled = await engine.removeIndexedFile(scopeId: "dir:/tmp", relativePath: "doc.md")
        XCTAssertFalse(removedWhileDisabled)
        XCTAssertEqual(tracker.removeFileCount, 0, "disabled removeIndexedFile must never enter Rust binding")
        XCTAssertEqual(tracker.prepareCount, 0, "disabled removeIndexedFile must never trigger prepare")

        defaults.set(true, forKey: LocalSemanticPluginPreferences.enabledKey)
        let reopenedManager = LocalModelManager(
            pathResolver: resolver,
            engine: engine,
            requireExactChecksum: false,
            userDefaults: defaults
        )
        await reopenedManager.refreshState()
        XCTAssertEqual(
            tracker.prepareCount,
            0,
            "Opening settings with enabled preference must only read state and never reload/prepare"
        )
        await reopenedManager.setPluginEnabled(true)
        XCTAssertEqual(tracker.prepareCount, 1, "Explicit setPluginEnabled(true) prepares runtime exactly once")
        _ = await BoundedTaskHandle { await engine.shutdown() }.valueIfCompleted(timeoutSeconds: 1.0)
    }

    func testNativeExecutionLaneSerializesEighteenBlockingCallsOutsideCooperativePool() async {
        let executor = SemanticCoreBlockingExecutor()
        let probe = SemanticBlockingLaneProbe()
        defer { probe.releaseAll() }
        let firstTicket = executor.admit(key: "first")
        let first = BoundedTaskHandle {
            await executor.run(ticket: firstTicket, cancelled: false) { probe.perform() }
        }
        let entered = await probe.entered.wait(timeoutSeconds: 2)
        let queuedTickets = (0..<17).map { executor.admit(key: "queued-\($0)") }
        let rest = BoundedTaskHandle {
            await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for ticket in queuedTickets {
                    group.addTask {
                        await executor.run(ticket: ticket, cancelled: false) { probe.perform() }
                    }
                }
                var results: [Bool] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
        }
        // This continuation must run while the first synchronous native call is still held.
        let independentWork = BoundedTaskHandle {
            await Task.yield()
            return true
        }
        let independentResult = await independentWork.valueIfCompleted(timeoutSeconds: 1)
        probe.releaseAll()
        let firstResult = await first.valueIfCompleted(timeoutSeconds: 2)
        let results = await rest.valueIfCompleted(timeoutSeconds: 2)
        XCTAssertTrue(entered)
        XCTAssertEqual(independentResult, true)
        XCTAssertEqual(firstResult, true)
        XCTAssertEqual(results?.count, 17)
        XCTAssertTrue(results?.allSatisfy { $0 } == true)
        XCTAssertEqual(probe.observations.maximumActive, 1)
        XCTAssertEqual(probe.observations.cooperativeEntries, 0)
    }

    @MainActor
    func testDisabledPluginDoesNotIndexSearchOrPrepareAnInstalledModel() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let binding = S2LifecycleUniFFIDouble(isModelInstalled: true)
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: root, uniffiEngine: binding)
        let engine = SemanticSearchEngine(
            storageDirectory: root,
            bridge: bridge,
            directoryLeaseProvider: { SecurityScopeLease(url: $0, onRelease: { _ in }) },
            pluginEnabled: false
        )
        let registration = await engine.registerAuthorizedDirectory(
            url: root,
            startIndexingImmediately: true
        )
        let scopeID = SemanticSearchEngine.scopeId(forDirectoryURL: root)
        let disabledProgress = await engine.startIndexing(scopeId: scopeID)
        let disabledState = await engine.reloadModelRuntime()
        let disabledSearch = await engine.search(
            SemanticSearchRequest(requestId: 901, windowId: "disabled", query: "text")
        )
        XCTAssertNil(registration.progress)
        XCTAssertEqual(disabledProgress.phase, .cancelled)
        XCTAssertEqual(disabledState, .notInstalled)
        XCTAssertEqual(binding.directoryIndexingCallCount, 0)
        XCTAssertTrue(disabledSearch.hits.isEmpty)
        XCTAssertTrue(disabledSearch.degradedLexicalOnly)
        await engine.setPluginEnabled(true)
        _ = await engine.startIndexing(scopeId: scopeID)
        XCTAssertEqual(binding.directoryIndexingCallCount, 1)
        await engine.setPluginEnabled(false)
        _ = await engine.startIndexing(scopeId: scopeID)
        XCTAssertEqual(binding.directoryIndexingCallCount, 1)
        _ = await engine.shutdown()
    }
}
