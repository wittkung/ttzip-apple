// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@testable import TTZipApp
import TTZipCore

// MARK: - Deterministic Synchronization Gates & Lifecycle Test Doubles

struct EmptySystemFileSearchProvider: SystemFileSearchProviding {
    func searchAllAccessibleItems(
        query: String,
        maxResults: Int,
        additionalScopes: [URL]
    ) async -> [GlobalSearchResultItem] {
        []
    }
}

final class BoundedSignalReceipt: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var signalled = false

    func signal() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !signalled else { return false }
            signalled = true
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = self.semaphore.wait(timeout: .now() + timeoutSeconds)
                continuation.resume(returning: status == .success)
            }
        }
    }
}

final class BoundedTaskHandle<Value: Sendable>: @unchecked Sendable {
    private let completionReceipt = BoundedSignalReceipt()
    private let task: Task<Value, Never>

    init(operation: @escaping @Sendable () async -> Value) {
        let receipt = completionReceipt
        self.task = Task {
            let result = await operation()
            receipt.signal()
            return result
        }
    }

    func cancel() {
        task.cancel()
    }

    func waitCompleted(timeoutSeconds: Double) async -> Bool {
        await completionReceipt.wait(timeoutSeconds: timeoutSeconds)
    }

    func valueIfCompleted(timeoutSeconds: Double) async -> Value? {
        guard await completionReceipt.wait(timeoutSeconds: timeoutSeconds) else {
            return nil
        }
        return await task.value
    }
}

final class SuspendedLeaseGate: @unchecked Sendable {
    private let enteredSemaphore = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didEnter = false
    private var didRelease = false

    func enterAndWaitRelease(timeoutSeconds: Double) async {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !didEnter else { return false }
            didEnter = true
            return true
        }
        if shouldSignal {
            enteredSemaphore.signal()
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.releaseSemaphore.wait(timeout: .now() + timeoutSeconds)
                continuation.resume()
            }
        }
    }

    func waitEntered(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = self.enteredSemaphore.wait(timeout: .now() + timeoutSeconds)
                continuation.resume(returning: status == .success)
            }
        }
    }

    func release() {
        let shouldRelease = lock.withLock { () -> Bool in
            guard !didRelease else { return false }
            didRelease = true
            return true
        }
        if shouldRelease {
            releaseSemaphore.signal()
        }
    }
}

final class OrderedLifecycleEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

final class LeaseLifecycleTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let zeroSemaphore = DispatchSemaphore(value: 0)
    private var _acquireCount: Int = 0
    private var _activeCount: Int = 0
    private var _activeCountObservedDuringIndexing: Int = 0
    private var _shouldDenyAcquisition: Bool = false

    var acquireCount: Int {
        lock.withLock { _acquireCount }
    }

    var activeCount: Int {
        lock.withLock { _activeCount }
    }

    var activeCountObservedDuringIndexing: Int {
        lock.withLock { _activeCountObservedDuringIndexing }
    }

    var shouldDenyAcquisition: Bool {
        get { lock.withLock { _shouldDenyAcquisition } }
        set { lock.withLock { _shouldDenyAcquisition = newValue } }
    }

    func acquire(for url: URL) -> SecurityScopeLease? {
        let allowed = lock.withLock { () -> Bool in
            guard !_shouldDenyAcquisition else { return false }
            _acquireCount += 1
            _activeCount += 1
            return true
        }
        guard allowed else { return nil }
        return SecurityScopeLease(url: url) { [weak self] _ in
            guard let self else { return }
            let becameZero = self.lock.withLock { () -> Bool in
                self._activeCount -= 1
                return self._activeCount == 0
            }
            if becameZero {
                self.zeroSemaphore.signal()
            }
        }
    }

    func recordActiveCountAtIndexingEntry() {
        lock.withLock {
            _activeCountObservedDuringIndexing = _activeCount
        }
    }

    func waitUntilActiveCountZero(timeoutSeconds: Double) async -> Bool {
        if activeCount == 0 {
            return true
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = self.zeroSemaphore.wait(timeout: .now() + timeoutSeconds)
                continuation.resume(returning: status == .success)
            }
        }
    }
}

final class IndexingRunGateBox: @unchecked Sendable {
    private let run1Entered = DispatchSemaphore(value: 0)
    private let run1Release = DispatchSemaphore(value: 0)
    private let run2Entered = DispatchSemaphore(value: 0)
    private let run2Release = DispatchSemaphore(value: 0)

    func enterAndWait(callNumber: Int) {
        if callNumber == 1 {
            run1Entered.signal()
            _ = run1Release.wait(timeout: .now() + 2.0)
        } else if callNumber == 2 {
            run2Entered.signal()
            _ = run2Release.wait(timeout: .now() + 2.0)
        }
    }

    func waitRun1Entered(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = self.run1Entered.wait(timeout: .now() + timeoutSeconds)
                continuation.resume(returning: status == .success)
            }
        }
    }

    func waitRun2Entered(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = self.run2Entered.wait(timeout: .now() + timeoutSeconds)
                continuation.resume(returning: status == .success)
            }
        }
    }

    func releaseRun1() {
        run1Release.signal()
    }

    func releaseRun2() {
        run2Release.signal()
    }
}

final class NativeModelMutexSimulationGate: @unchecked Sendable {
    private let modelMutex = NSLock()
    private let indexingEnteredSemaphore = DispatchSemaphore(value: 0)
    private let indexingReleaseSemaphore = DispatchSemaphore(value: 0)
    private let searchWaitingSemaphore = DispatchSemaphore(value: 0)

    func indexingHoldMutex() {
        modelMutex.lock()
        indexingEnteredSemaphore.signal()
        _ = indexingReleaseSemaphore.wait(timeout: .now() + 2.0)
        modelMutex.unlock()
    }

    func searchAcquireMutex() {
        searchWaitingSemaphore.signal()
        modelMutex.lock()
        modelMutex.unlock()
    }

    func waitIndexingEnteredMutex(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = self.indexingEnteredSemaphore.wait(timeout: .now() + timeoutSeconds)
                continuation.resume(returning: status == .success)
            }
        }
    }

    func waitSearchWaitingOnMutex(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = self.searchWaitingSemaphore.wait(timeout: .now() + timeoutSeconds)
                continuation.resume(returning: status == .success)
            }
        }
    }

    func releaseIndexingMutex() {
        indexingReleaseSemaphore.signal()
    }
}

final class S2LifecycleUniFFIDouble: UniFFISemanticSearchEngineBindingProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let isModelInstalled: Bool
    private let onIndexingStarted: (@Sendable () -> Void)?
    private let onIndexingFinished: (@Sendable () -> Void)?
    private let onCancelIndexingCalled: (@Sendable () -> Void)?
    private let runGate: IndexingRunGateBox?
    private let mutexGate: NativeModelMutexSimulationGate?
    private let eventLog: OrderedLifecycleEventLog?
    private var scopeSegments: [String: UInt32] = [:]
    private var scopeEpochs: [String: UInt64] = [:]
    private var activeRunTokens: [String: UInt64] = [:]
    private var nextSequence: UInt64 = 1
    private var _directoryIndexingCallCount: Int = 0
    private var _cancelledSearchIds: Set<UInt64> = []

    var directoryIndexingCallCount: Int {
        lock.withLock { _directoryIndexingCallCount }
    }

    var cancelledSearchIds: Set<UInt64> {
        lock.withLock { _cancelledSearchIds }
    }

    init(
        isModelInstalled: Bool = true,
        onIndexingStarted: (@Sendable () -> Void)? = nil,
        onIndexingFinished: (@Sendable () -> Void)? = nil,
        runGate: IndexingRunGateBox? = nil,
        mutexGate: NativeModelMutexSimulationGate? = nil,
        eventLog: OrderedLifecycleEventLog? = nil,
        onCancelIndexingCalled: (@Sendable () -> Void)? = nil
    ) {
        self.isModelInstalled = isModelInstalled
        self.onIndexingStarted = onIndexingStarted
        self.onIndexingFinished = onIndexingFinished
        self.runGate = runGate
        self.mutexGate = mutexGate
        self.eventLog = eventLog
        self.onCancelIndexingCalled = onCancelIndexingCalled
    }

    func segmentsCount(for scopeId: String) -> UInt32 {
        lock.withLock { scopeSegments[scopeId] ?? 0 }
    }

    func isScopeRegistered(for scopeId: String) -> Bool {
        lock.withLock { scopeEpochs[scopeId] != nil }
    }

    func modelState() -> AppUniFFISemanticModelState {
        guard isModelInstalled else {
            return .notInstalled
        }
        return .ready(
            info: AppUniFFISemanticModelInfo(
                modelId: PinnedSemanticModelConstants.modelId,
                modelRevision: PinnedSemanticModelConstants.modelRevision,
                ggufFilename: PinnedSemanticModelConstants.ggufFilename,
                expectedBytes: PinnedSemanticModelConstants.ggufSizeBytes,
                expectedSha256: PinnedSemanticModelConstants.ggufSha256,
                llamaCppTag: PinnedSemanticModelConstants.llamaCppTag,
                llamaCppCommit: PinnedSemanticModelConstants.llamaCppCommit,
                modelFingerprint: PinnedSemanticModelConstants.testDoubleModelFingerprint,
                backend: .deterministicTestDouble
            )
        )
    }

    func registerScope(descriptor: AppUniFFISemanticScopeDescriptor) -> Bool {
        lock.withLock {
            nextSequence &+= 1
            scopeEpochs[descriptor.scopeId] = nextSequence
            activeRunTokens[descriptor.scopeId] = 0
            if scopeSegments[descriptor.scopeId] == nil {
                scopeSegments[descriptor.scopeId] = 0
            }
            return true
        }
    }

    func revokeScope(scopeId: String) -> Bool {
        eventLog?.record("bridge.revokeScope")
        return lock.withLock {
            activeRunTokens[scopeId] = 0
            scopeEpochs.removeValue(forKey: scopeId)
            return scopeSegments.removeValue(forKey: scopeId) != nil
        }
    }

    func startDirectoryIndexing(scopeId: String) -> AppUniFFISemanticIndexProgress {
        onIndexingStarted?()
        if !isModelInstalled {
            onIndexingFinished?()
            return AppUniFFISemanticIndexProgress(
                scopeId: scopeId,
                phase: .degradedLexicalOnly,
                processedFiles: 0,
                totalFiles: 0,
                indexedSegments: 0,
                indexGeneration: 0,
                errorMessage: nil
            )
        }
        let (callNum, runEpoch, runToken) = lock.withLock { () -> (Int, UInt64, UInt64) in
            _directoryIndexingCallCount += 1
            nextSequence &+= 1
            let tok = nextSequence
            activeRunTokens[scopeId] = tok
            return (_directoryIndexingCallCount, scopeEpochs[scopeId] ?? 0, tok)
        }
        eventLog?.record("run\(callNum).enteredNative")
        runGate?.enterAndWait(callNumber: callNum)
        mutexGate?.indexingHoldMutex()
        eventLog?.record("run\(callNum).exitedNative")
        let committed = lock.withLock { () -> Bool in
            guard scopeEpochs[scopeId] == runEpoch,
                  activeRunTokens[scopeId] == runToken
            else {
                return false
            }
            scopeSegments[scopeId] = 6
            return true
        }
        onIndexingFinished?()
        guard committed else {
            return AppUniFFISemanticIndexProgress(
                scopeId: scopeId,
                phase: .cancelled,
                processedFiles: 0,
                totalFiles: 2,
                indexedSegments: 0,
                indexGeneration: 0,
                errorMessage: nil
            )
        }
        return AppUniFFISemanticIndexProgress(
            scopeId: scopeId,
            phase: .completed,
            processedFiles: 2,
            totalFiles: 2,
            indexedSegments: 6,
            indexGeneration: 2,
            errorMessage: nil
        )
    }

    func cancelIndexing(scopeId: String) {
        eventLog?.record("cancelA.called")
        lock.withLock {
            activeRunTokens[scopeId] = 0
        }
        onCancelIndexingCalled?()
    }

    func scopeProgress(scopeId: String) -> AppUniFFISemanticIndexProgress? {
        let segsOpt: UInt32? = lock.withLock {
            guard scopeEpochs[scopeId] != nil else { return nil }
            return scopeSegments[scopeId] ?? 0
        }
        guard let segs = segsOpt else { return nil }
        return AppUniFFISemanticIndexProgress(
            scopeId: scopeId,
            phase: segs > 0 ? .completed : .idle,
            processedFiles: segs > 0 ? 2 : 0,
            totalFiles: segs > 0 ? 2 : 0,
            indexedSegments: segs,
            indexGeneration: segs > 0 ? 2 : 0,
            errorMessage: nil
        )
    }

    func upsertArchiveEntries(scopeId: String, entries: [AppUniFFISemanticArchiveEntryInput]) -> AppUniFFISemanticIndexProgress {
        lock.withLock {
            scopeSegments[scopeId] = UInt32(entries.count)
        }
        return AppUniFFISemanticIndexProgress(
            scopeId: scopeId,
            phase: .completed,
            processedFiles: UInt32(entries.count),
            totalFiles: UInt32(entries.count),
            indexedSegments: UInt32(entries.count),
            indexGeneration: 1,
            errorMessage: nil
        )
    }

    func removeIndexedFile(scopeId: String, relativePath: String) -> Bool {
        true
    }

    func search(request: AppUniFFISemanticSearchRequest) -> AppUniFFISemanticSearchResponse {
        mutexGate?.searchAcquireMutex()
        let (isCancelled, activeScopes) = lock.withLock {
            (_cancelledSearchIds.contains(request.requestId), scopeSegments.filter { $0.value > 0 })
        }
        if isCancelled {
            return AppUniFFISemanticSearchResponse(
                requestId: request.requestId,
                windowId: request.windowId,
                isCancelled: true,
                degradedLexicalOnly: false,
                hits: []
            )
        }
        if !isModelInstalled {
            return AppUniFFISemanticSearchResponse(
                requestId: request.requestId,
                windowId: request.windowId,
                isCancelled: false,
                degradedLexicalOnly: true,
                hits: []
            )
        }
        guard let firstScope = activeScopes.first else {
            return AppUniFFISemanticSearchResponse(
                requestId: request.requestId,
                windowId: request.windowId,
                isCancelled: false,
                degradedLexicalOnly: false,
                hits: []
            )
        }
        let rootPath = firstScope.key.replacingOccurrences(of: "dir:", with: "")
        let hit = AppUniFFISemanticSearchHit(
            scopeId: firstScope.key,
            sourceKind: .authorizedDirectory,
            containerOrRootPath: rootPath,
            displayPath: "opaque_notes.txt",
            archiveEntryPath: nil,
            snippet: "quantum_entanglement_body_only body match",
            lineStart: 8,
            lineEnd: 10,
            matchKind: .contentSemantic,
            lexicalScore: 0.0,
            semanticScore: 0.91,
            combinedScore: 0.91,
            indexGeneration: 2,
            modelFingerprint: PinnedSemanticModelConstants.testDoubleModelFingerprint
        )
        return AppUniFFISemanticSearchResponse(
            requestId: request.requestId,
            windowId: request.windowId,
            isCancelled: false,
            degradedLexicalOnly: false,
            hits: [hit]
        )
    }

    func cancelSearch(requestId: UInt64) {
        lock.withLock {
            _ = _cancelledSearchIds.insert(requestId)
        }
    }

    func buildOpenRequest(hit: AppUniFFISemanticSearchHit) -> AppUniFFISemanticOpenRequest {
        AppUniFFISemanticOpenRequest(
            scopeId: hit.scopeId,
            sourceKind: hit.sourceKind,
            outerPath: hit.containerOrRootPath,
            archiveEntryPath: hit.archiveEntryPath,
            lineNumber: hit.lineStart
        )
    }
}

final class SystemSecurityScopeObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let eventLog: OrderedLifecycleEventLog?
    private var _startCount: Int = 0
    private var _stopCount: Int = 0

    init(eventLog: OrderedLifecycleEventLog? = nil) {
        self.eventLog = eventLog
    }

    var startCount: Int {
        lock.withLock { _startCount }
    }

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    func recordStop(_: URL) {
        lock.withLock {
            _stopCount += 1
        }
        eventLog?.record("systemScope.stop")
    }

    func recordStart(_: URL) -> Bool {
        lock.withLock {
            _startCount += 1
        }
        eventLog?.record("systemScope.start")
        return true
    }
}

@MainActor
final class SystemSecurityScopeTestHarness {
    let observer: SystemSecurityScopeObserver
    let accessManager: RootFolderAccessManager
    private let savedBookmarks: Data?
    private let prevEnabled: Bool
    private let prevProvider: () -> SemanticSearchEngine
    private let prevStart: @MainActor (URL) -> Bool
    private let prevStop: @MainActor (URL) -> Void

    init(
        eventLog: OrderedLifecycleEventLog? = nil,
        autoIndexingEnabled: Bool = false,
        engine: SemanticSearchEngine? = nil
    ) {
        let obs = SystemSecurityScopeObserver(eventLog: eventLog)
        let mgr = RootFolderAccessManager.shared
        self.observer = obs
        self.accessManager = mgr
        self.savedBookmarks = UserDefaults.standard.data(forKey: "TTZipSecurityScopedBookmarksKey")
        self.prevEnabled = mgr.isAutoSemanticIndexingEnabled
        self.prevProvider = mgr.autoSemanticIndexingEngineProvider
        self.prevStart = mgr.startSecurityScopedAccess
        self.prevStop = mgr.stopSecurityScopedAccess
        mgr.isAutoSemanticIndexingEnabled = false
        mgr.revokeAllAccess()
        mgr.restoreBookmarks()
        mgr.isAutoSemanticIndexingEnabled = autoIndexingEnabled
        if let engine {
            mgr.autoSemanticIndexingEngineProvider = { engine }
        }
        mgr.startSecurityScopedAccess = { url in
            guard mgr.hasPersistedBookmark(for: url) else { return false }
            return obs.recordStart(url)
        }
        mgr.stopSecurityScopedAccess = { obs.recordStop($0) }
    }

    func restore(revoking urls: [URL], restoreSavedBookmarks: Bool = false) {
        accessManager.isAutoSemanticIndexingEnabled = prevEnabled
        accessManager.autoSemanticIndexingEngineProvider = prevProvider
        accessManager.startSecurityScopedAccess = prevStart
        accessManager.stopSecurityScopedAccess = prevStop
        for url in urls {
            accessManager.revokeAccess(for: url)
        }
        if restoreSavedBookmarks, let savedBookmarks {
            UserDefaults.standard.set(savedBookmarks, forKey: "TTZipSecurityScopedBookmarksKey")
            accessManager.restoreBookmarks()
        }
    }

    func persist(_ url: URL) -> Data? {
        accessManager.persistBookmark(for: url)
    }

    func acquire(_ url: URL) -> SecurityScopeLease? {
        accessManager.acquireLease(for: url)
    }

    func revoke(_ url: URL) {
        accessManager.revokeAccess(for: url)
    }

    func counts(_ url: URL) -> (active: Int, retiring: Int, stop: Int) {
        (
            accessManager.activeLeaseCount(for: url),
            accessManager.retiringLeaseCount(for: url),
            observer.stopCount
        )
    }
}

final class ControlledGenerationBindingTracker: @unchecked Sendable {
    private let lock = NSLock()
    let eventLog = OrderedLifecycleEventLog()
    let firstIndexEntered = BoundedSignalReceipt()
    private let firstIndexRelease = DispatchSemaphore(value: 0)
    private var nextID: Int = 0
    private(set) var liveCount: Int = 0
    private(set) var maxConcurrentLiveCount: Int = 0
    private(set) var prepareCount: Int = 0
    private(set) var registerCount: Int = 0
    private(set) var removeFileCount: Int = 0
    private(set) var upsertCount: Int = 0
    private(set) var searchCount: Int = 0
    private(set) var indexCount: Int = 0
    private(set) var heldIndexInstanceID: Int?
    private var holdFirstIndex: Bool = false

    func enableHoldFirstIndex() {
        lock.withLock { holdFirstIndex = true }
    }

    func releaseAll() {
        for _ in 0..<8 {
            firstIndexRelease.signal()
        }
    }

    func allocateInstance() -> Int {
        lock.withLock {
            nextID += 1
            liveCount += 1
            maxConcurrentLiveCount = max(maxConcurrentLiveCount, liveCount)
            eventLog.record("create#\(nextID)")
            return nextID
        }
    }

    func recordDestroy(_ id: Int) {
        lock.withLock {
            liveCount = max(0, liveCount - 1)
            eventLog.record("destroy#\(id)")
        }
    }

    func recordPrepare(_ id: Int) {
        lock.withLock {
            prepareCount += 1
            eventLog.record("prepare#\(id)")
        }
    }

    func recordRegister() {
        lock.withLock { registerCount += 1 }
    }

    func recordRemoveFile() {
        lock.withLock { removeFileCount += 1 }
    }

    func recordUpsert() {
        lock.withLock { upsertCount += 1 }
    }

    func recordSearch() {
        lock.withLock { searchCount += 1 }
    }

    func enterIndex(_ id: Int) {
        let shouldHold = lock.withLock { () -> Bool in
            indexCount += 1
            eventLog.record("native#\(id).entered")
            let h = holdFirstIndex
            if h {
                holdFirstIndex = false
                heldIndexInstanceID = id
            }
            return h
        }
        if shouldHold {
            firstIndexEntered.signal()
            _ = firstIndexRelease.wait(timeout: .now() + 5.0)
        }
        eventLog.record("native#\(id).exited")
    }
}
