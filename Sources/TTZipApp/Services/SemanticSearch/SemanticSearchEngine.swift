// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Thin Swift adapter over the Rust `ttzip-semantic` UniFFI engine (`RustSemanticCoreBridging`).
///
/// Architectural Contract (Spec 232):
/// - Production `SemanticSearchEngine(storageDirectory:)` binds exclusively to `UniFFIRustSemanticCoreBridge`
///   and NEVER instantiates `DeterministicConceptSemanticEncoder` or a duplicate Swift indexing engine.
/// - Swift responsibilities are limited to scope authorization state, request-ID superseding per window,
///   cancellation forwarding, and constructing `SemanticOpenRequest` payloads for `BrowserWindowRouter`.
public actor SemanticSearchEngine: SemanticSearchEngineProtocol {
    /// Process-wide production instance backed by `UniFFIRustSemanticCoreBridge` at `defaultStorageDirectory()`.
    public static let shared = SemanticSearchEngine(
        storageDirectory: defaultStorageDirectory(),
        pluginEnabled: LocalSemanticPluginPreferences.isEnabled
    )

    /// Canonical persistent index directory (`~/Library/Application Support/com.metastudyline.ttzip/SemanticIndex`).
    public nonisolated static func defaultStorageDirectory() -> URL {
        let dir = LocalModelPathResolver.defaultResolver().semanticStorageDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deterministic scope ID for an authorized filesystem directory URL.
    public nonisolated static func scopeId(forDirectoryURL url: URL) -> String {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        return "dir:\(canonical)"
    }

    /// Deterministic scope ID for an open archive file path.
    public nonisolated static func scopeId(forArchivePath archivePath: String) -> String {
        let canonical = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
        return "archive:\(canonical)"
    }

    private var isPluginEnabled: Bool
    private let storageDirectory: URL
    let bridge: any RustSemanticCoreBridging
    private let usesCustomBridge: Bool
    private let directoryLeaseProvider: @Sendable (URL) async -> SecurityScopeLease?
    var scopeRecords: [String: SemanticScopeDescriptor] = [:]
    private var scopeGenerations: [String: UInt64] = [:]
    private var inFlightIndexingRuns: [String: SemanticTrackedIndexingRun] = [:]
    private var retiringIndexingRuns: [UUID: SemanticTrackedIndexingRun] = [:]
    private var activeSearchIds: Set<UInt64> = []
    private var latestWindowRequest: [String: UInt64] = [:]
    private var cancelledRequestIds: Set<UInt64> = []
    private var modelInstallStateOverride: SemanticModelInstallState?
    var isRuntimeDraining: Bool = false
    var hasDirtyBridgeSession: Bool = false
    private var pluginTransitionTicket: UInt64 = 0
    private var isShuttingDown: Bool = false
    private var isShutDown: Bool = false
    private var isExecutingShutdown: Bool = false
    private var operationDrainTracker = SemanticOperationDrainTracker()
    private var shutdownCompletionWaiters: [CheckedContinuation<Bool, Never>] = []
    var predecessorWaitObserver: (@Sendable (SemanticRetiringPredecessorWaitReceipt) -> Void)?

    public var isTerminated: Bool {
        isShutDown
    }

    public var isDrainingRuntime: Bool {
        isRuntimeDraining
    }

    var isAcceptingOperations: Bool {
        !isShuttingDown && !isShutDown
    }

    var isPluginAdmittingWork: Bool {
        isAcceptingOperations && isPluginEnabled && !isRuntimeDraining
    }

    /// Production initializer: binds exclusively to `UniFFIRustSemanticCoreBridge`.
    /// Never uses a test double or duplicate Swift indexer.
    public init(
        storageDirectory: URL = SemanticSearchEngine.defaultStorageDirectory(),
        directoryLeaseProvider: (@Sendable (URL) async -> SecurityScopeLease?)? = nil,
        pluginEnabled: Bool = false
    ) {
        self.isPluginEnabled = pluginEnabled
        self.storageDirectory = storageDirectory
        self.bridge = UniFFIRustSemanticCoreBridge(storageDirectory: storageDirectory)
        self.usesCustomBridge = false
        self.directoryLeaseProvider = directoryLeaseProvider ?? { url in
            await MainActor.run { RootFolderAccessManager.shared.acquireLease(for: url) }
        }
    }

    /// Explicit dependency-injection initializer for testing the thin Swift adapter layer.
    public init(
        storageDirectory: URL,
        bridge: any RustSemanticCoreBridging,
        directoryLeaseProvider: (@Sendable (URL) async -> SecurityScopeLease?)? = nil,
        pluginEnabled: Bool = true
    ) {
        self.isPluginEnabled = pluginEnabled
        self.storageDirectory = storageDirectory
        self.bridge = bridge
        self.usesCustomBridge = true
        self.directoryLeaseProvider = directoryLeaseProvider ?? { url in
            if let lease = await MainActor.run(body: { RootFolderAccessManager.shared.acquireLease(for: url) }) {
                return lease
            }
            let existsOnDisk = FileManager.default.fileExists(atPath: url.path)
            return existsOnDisk ? nil : SecurityScopeLease(url: url, onRelease: { _ in })
        }
    }

    /// Explicit test-only factory method for adapter unit tests.
    public static func forTesting(
        storageDirectory: URL,
        bridge: any RustSemanticCoreBridging,
        directoryLeaseProvider: (@Sendable (URL) async -> SecurityScopeLease?)? = nil
    ) -> SemanticSearchEngine {
        SemanticSearchEngine(
            storageDirectory: storageDirectory,
            bridge: bridge,
            directoryLeaseProvider: directoryLeaseProvider
        )
    }

    /// Revokes admission immediately; native work retains ownership until it really returns.
    public func setPluginEnabled(_ enabled: Bool) async {
        guard isAcceptingOperations else { return }
        if isPluginEnabled == enabled && !isRuntimeDraining { return }
        if enabled && !isRuntimeDraining && !hasDirtyBridgeSession {
            isPluginEnabled = true
            pluginTransitionTicket &+= 1
            let myTicket = pluginTransitionTicket
            guard let seq = beginInFlightOperation() else { return }
            defer { endInFlightOperation(seq) }
            _ = await rebindAuthorizedScopes(expectedTicket: myTicket)
            return
        }
        isPluginEnabled = enabled
        await runSessionTransition(rebindScopesIfEnabled: enabled)
    }

    public func modelState() async -> SemanticModelInstallState {
        if isShutDown { return await bridge.modelState() }
        guard isPluginAdmittingWork, let seq = beginInFlightOperation() else { return .notInstalled }
        defer { endInFlightOperation(seq) }
        if let override = modelInstallStateOverride { return override }
        let state = await bridge.modelState()
        return isPluginAdmittingWork ? state : .notInstalled
    }

    /// Cancels active searches/indexing, resets the underlying bridge runtime, and verifies whether
    /// the model at `modelURL` loads into the runtime.
    public func reloadModelRuntime(
        at modelURL: URL? = nil,
        requireExactChecksum: Bool = true
    ) async -> SemanticModelInstallState {
        guard isPluginAdmittingWork else { return .notInstalled }
        isRuntimeDraining = true
        pluginTransitionTicket &+= 1
        let myTicket = pluginTransitionTicket
        guard let seq = beginInFlightOperation() else {
            if pluginTransitionTicket == myTicket { isRuntimeDraining = false }
            return .notInstalled
        }
        defer { endInFlightOperation(seq) }

        await cancelActiveOperations()
        guard isAcceptingOperations, isPluginEnabled, pluginTransitionTicket == myTicket else {
            if pluginTransitionTicket == myTicket { isRuntimeDraining = false }
            return .notInstalled
        }
        if let verificationFailure = await verifyModelFileForReload(
            at: modelURL,
            requireExactChecksum: requireExactChecksum,
            expectedTicket: myTicket
        ) {
            if pluginTransitionTicket == myTicket { isRuntimeDraining = false }
            return verificationFailure
        }
        guard await drainAndResetRuntimeSession(
            cutoffSequence: seq,
            ticket: myTicket,
            rebindScopesIfEnabled: true
        ) else { return .notInstalled }
        hasDirtyBridgeSession = true
        let bridgeState = await bridge.prepareModelRuntime()
        guard isPluginAdmittingWork, pluginTransitionTicket == myTicket else { return .notInstalled }
        let resolved = SemanticModelReloadStateResolver.resolve(
            from: bridgeState,
            modelURL: modelURL,
            requireExactChecksum: requireExactChecksum,
            usesCustomBridge: usesCustomBridge
        )
        modelInstallStateOverride = resolved.overrideState
        return resolved.resolved
    }

    private func verifyModelFileForReload(
        at modelURL: URL?,
        requireExactChecksum: Bool,
        expectedTicket: UInt64
    ) async -> SemanticModelInstallState? {
        guard let modelURL else { return nil }
        do {
            _ = try await GGUFModelVerifier.verifyModelFileAsync(
                at: modelURL,
                requireExactChecksum: requireExactChecksum
            )
            return (isAcceptingOperations && isPluginEnabled && pluginTransitionTicket == expectedTicket)
                ? nil : .notInstalled
        } catch {
            guard isAcceptingOperations, isPluginEnabled, pluginTransitionTicket == expectedTicket else {
                return .notInstalled
            }
            let state = SemanticModelInstallState.failed(reason: error.localizedDescription)
            modelInstallStateOverride = state
            return state
        }
    }

    private func runSessionTransition(rebindScopesIfEnabled: Bool) async {
        guard isAcceptingOperations else { return }
        isRuntimeDraining = true
        modelInstallStateOverride = nil
        pluginTransitionTicket &+= 1
        let myTicket = pluginTransitionTicket
        guard let seq = beginInFlightOperation() else {
            if pluginTransitionTicket == myTicket { isRuntimeDraining = false }
            return
        }
        defer { endInFlightOperation(seq) }
        _ = await drainAndResetRuntimeSession(
            cutoffSequence: seq,
            ticket: myTicket,
            rebindScopesIfEnabled: rebindScopesIfEnabled
        )
    }

    private func drainAndResetRuntimeSession(
        cutoffSequence: UInt64,
        ticket: UInt64,
        rebindScopesIfEnabled: Bool
    ) async -> Bool {
        await cancelActiveOperations()
        try? await bridge.resetEngine()
        await drainRetiringIndexingRuns(beforeSequence: cutoffSequence)
        await waitForPriorOperationsToDrain(beforeSequence: cutoffSequence)
        guard isAcceptingOperations, pluginTransitionTicket == ticket else { return false }
        hasDirtyBridgeSession = false
        isRuntimeDraining = false
        if rebindScopesIfEnabled && isPluginEnabled {
            return await rebindAuthorizedScopes(expectedTicket: ticket)
        }
        return isAcceptingOperations && pluginTransitionTicket == ticket
    }

    private func rebindAuthorizedScopes(expectedTicket: UInt64) async -> Bool {
        guard isPluginAdmittingWork, pluginTransitionTicket == expectedTicket else { return false }
        for scope in scopeRecords.values where scope.isAuthorized && isPluginAdmittingWork {
            guard pluginTransitionTicket == expectedTicket else { return false }
            hasDirtyBridgeSession = true
            _ = await bridge.registerScope(scope)
        }
        return isPluginAdmittingWork && pluginTransitionTicket == expectedTicket
    }

    /// Alias for `reloadModelRuntime(at:requireExactChecksum:)`.
    public func reloadAndVerifyModelRuntime(
        at modelURL: URL? = nil,
        requireExactChecksum: Bool = true
    ) async -> SemanticModelInstallState {
        await reloadModelRuntime(at: modelURL, requireExactChecksum: requireExactChecksum)
    }

    /// Cancels all active semantic operations and resets the runtime session to release open model file handles
    /// for non-terminal scenarios (such as model deletion or replacement).
    public func unloadModelRuntime() async {
        await runSessionTransition(rebindScopesIfEnabled: isPluginEnabled)
    }

    /// Idempotent terminal shutdown: closes entry points to new work, cancels and drains all accepted
    /// in-flight operations, and permanently releases the underlying bridge runtime without recreating it.
    @discardableResult
    public func shutdown() async -> Bool {
        if isShutDown { return true }
        if isExecutingShutdown {
            return await withCheckedContinuation { shutdownCompletionWaiters.append($0) }
        }
        isShuttingDown = true
        isExecutingShutdown = true
        isRuntimeDraining = true
        pluginTransitionTicket &+= 1

        let cutoff = operationDrainTracker.allocateCutoffSequence()
        await cancelActiveOperations()
        await drainRetiringIndexingRuns(beforeSequence: cutoff)
        await waitForPriorOperationsToDrain(beforeSequence: cutoff)

        let bridgeReleased = await bridge.shutdown()
        scopeRecords.removeAll()
        scopeGenerations.removeAll()
        activeSearchIds.removeAll()
        modelInstallStateOverride = nil
        hasDirtyBridgeSession = false
        isRuntimeDraining = false

        if bridgeReleased {
            isShutDown = true
        } else {
            isShuttingDown = false
        }
        isExecutingShutdown = false

        let waiters = shutdownCompletionWaiters
        shutdownCompletionWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: bridgeReleased) }
        return bridgeReleased
    }

    func beginInFlightOperation() -> UInt64? {
        guard !isShuttingDown && !isShutDown else { return nil }
        return operationDrainTracker.beginOperation()
    }

    func endInFlightOperation(_ sequence: UInt64) {
        for waiter in operationDrainTracker.endOperation(sequence) {
            waiter.resume()
        }
    }

    private func waitForPriorOperationsToDrain(beforeSequence cutoff: UInt64) async {
        guard operationDrainTracker.hasActiveOperations(beforeSequence: cutoff) else { return }
        await withCheckedContinuation { continuation in
            if operationDrainTracker.registerWaiter(beforeSequence: cutoff, continuation: continuation) {
                continuation.resume()
            }
        }
    }

    private func drainRetiringIndexingRuns(beforeSequence cutoff: UInt64) async {
        while true {
            let snapshot = retiringIndexingRuns.values
                .filter { $0.admissionSequence < cutoff }
                .sorted { $0.admissionSequence < $1.admissionSequence }
            guard !snapshot.isEmpty else { break }
            for retiring in snapshot {
                retiring.task.cancel()
                _ = await retiring.task.value
                retiringIndexingRuns.removeValue(forKey: retiring.runID)
            }
        }
    }

    private func cancelActiveOperations() async {
        let searchIds = activeSearchIds
        activeSearchIds.removeAll()
        for reqId in searchIds {
            cancelledRequestIds.insert(reqId)
            await bridge.cancelSearch(requestId: reqId)
        }
        let activeRuns = inFlightIndexingRuns
        inFlightIndexingRuns.removeAll()
        for (_, run) in activeRuns {
            retiringIndexingRuns[run.runID] = run
            run.task.cancel()
        }
        for (_, retiring) in retiringIndexingRuns {
            retiring.task.cancel()
        }
        for scopeId in scopeRecords.keys {
            await bridge.cancelIndexing(scopeId: scopeId)
        }
    }

    @discardableResult
    private func cancelAndRetireIndexingRun(
        forScopeId scopeId: String,
        maxGeneration: UInt64? = nil
    ) -> Task<SemanticIndexProgress, Never>? {
        guard let run = inFlightIndexingRuns[scopeId] else {
            return nil
        }
        if let maxGeneration, run.scopeGeneration > maxGeneration {
            return nil
        }
        inFlightIndexingRuns.removeValue(forKey: scopeId)
        retiringIndexingRuns[run.runID] = run
        run.task.cancel()
        return run.task
    }

    private func drainIndexingRuns(
        forScopeId scopeId: String,
        maxGeneration: UInt64,
        beforeAdmissionSequence: UInt64
    ) async {
        _ = cancelAndRetireIndexingRun(forScopeId: scopeId, maxGeneration: maxGeneration)
        if scopeGenerations[scopeId] == maxGeneration {
            await bridge.cancelIndexing(scopeId: scopeId)
        }
        while true {
            if let active = inFlightIndexingRuns[scopeId],
               active.scopeGeneration <= maxGeneration,
               active.admissionSequence < beforeAdmissionSequence {
                _ = cancelAndRetireIndexingRun(forScopeId: scopeId, maxGeneration: maxGeneration)
                if scopeGenerations[scopeId] == maxGeneration {
                    await bridge.cancelIndexing(scopeId: scopeId)
                }
            }
            let matching = retiringIndexingRuns.values
                .filter {
                    $0.scopeId == scopeId
                        && $0.admissionSequence < beforeAdmissionSequence
                        && $0.scopeGeneration <= maxGeneration
                }
                .sorted { $0.admissionSequence < $1.admissionSequence }
            guard !matching.isEmpty else { break }
            for retiring in matching {
                retiring.task.cancel()
                _ = await retiring.task.value
                retiringIndexingRuns.removeValue(forKey: retiring.runID)
            }
        }
    }

    private func awaitPriorRetiringRuns(
        forScopeId scopeId: String,
        excludingRunID: UUID,
        beforeAdmissionSequence: UInt64,
        maxGeneration: UInt64
    ) async {
        while true {
            let priorRuns = retiringIndexingRuns.values
                .filter {
                    $0.scopeId == scopeId
                        && $0.runID != excludingRunID
                        && $0.admissionSequence < beforeAdmissionSequence
                        && $0.scopeGeneration <= maxGeneration
                }
                .sorted { $0.admissionSequence < $1.admissionSequence }
            guard !priorRuns.isEmpty else { break }
            predecessorWaitObserver?(
                .make(scopeId: scopeId, waiterRunID: excludingRunID, waiterSequence: beforeAdmissionSequence, priorRuns: priorRuns)
            )
            for prior in priorRuns {
                _ = await prior.task.value
                retiringIndexingRuns.removeValue(forKey: prior.runID)
            }
        }
    }

    private func isScopeRevocationAdmitted(scopeId: String, expectedGeneration: UInt64) -> Bool {
        isAcceptingOperations && scopeGenerations[scopeId] == expectedGeneration && scopeRecords[scopeId] == nil
    }

    private func isIndexingRunAdmitted(
        scopeId: String,
        runID: UUID,
        expectedGeneration: UInt64
    ) -> Bool {
        guard isPluginAdmittingWork,
              let descriptor = scopeRecords[scopeId],
              descriptor.isAuthorized,
              scopeGenerations[scopeId] == expectedGeneration,
              let currentRun = inFlightIndexingRuns[scopeId]
        else { return false }
        return currentRun.runID == runID && !currentRun.task.isCancelled
    }

    @discardableResult
    private func advanceScopeGenerationAndRetireActiveRun(for scopeId: String) -> (generation: UInt64, didRetireRun: Bool) {
        let didRetire = cancelAndRetireIndexingRun(forScopeId: scopeId) != nil
        let next = (scopeGenerations[scopeId] ?? 0) &+ 1
        scopeGenerations[scopeId] = next
        return (next, didRetire)
    }

    private func commitScopeRegistration(
        _ descriptor: SemanticScopeDescriptor
    ) async -> (loaded: Bool, generation: UInt64) {
        let scopeId = descriptor.scopeId
        let (targetGeneration, didRetire) = advanceScopeGenerationAndRetireActiveRun(for: scopeId)
        scopeRecords[scopeId] = descriptor
        if didRetire {
            await bridge.cancelIndexing(scopeId: scopeId)
        }
        guard isPluginAdmittingWork,
              scopeGenerations[scopeId] == targetGeneration,
              scopeRecords[scopeId] != nil else {
            return (false, targetGeneration)
        }
        hasDirtyBridgeSession = true
        let loaded = await bridge.registerScope(descriptor)
        guard isPluginAdmittingWork,
              scopeGenerations[scopeId] == targetGeneration,
              scopeRecords[scopeId] != nil else {
            return (false, targetGeneration)
        }
        return (loaded, targetGeneration)
    }

    public func registerScope(_ descriptor: SemanticScopeDescriptor) async -> Bool {
        guard !isRuntimeDraining, let seq = beginInFlightOperation() else { return false }
        defer { endInFlightOperation(seq) }
        return await commitScopeRegistration(descriptor).loaded
    }

    public func revokeScope(scopeId: String) async -> Bool {
        guard let seq = beginInFlightOperation() else { return false }
        defer { endInFlightOperation(seq) }
        let (revokeGeneration, _) = advanceScopeGenerationAndRetireActiveRun(for: scopeId)
        let drainCutoff = operationDrainTracker.allocateCutoffSequence()
        scopeRecords.removeValue(forKey: scopeId)
        await drainIndexingRuns(
            forScopeId: scopeId,
            maxGeneration: revokeGeneration,
            beforeAdmissionSequence: drainCutoff
        )
        guard isScopeRevocationAdmitted(scopeId: scopeId, expectedGeneration: revokeGeneration),
              !isRuntimeDraining else { return false }
        let revoked = await bridge.revokeScope(scopeId: scopeId)
        guard isScopeRevocationAdmitted(scopeId: scopeId, expectedGeneration: revokeGeneration) else {
            if let currentDescriptor = scopeRecords[scopeId],
               currentDescriptor.isAuthorized,
               isPluginAdmittingWork {
                hasDirtyBridgeSession = true
                _ = await bridge.registerScope(currentDescriptor)
            }
            return false
        }
        return revoked
    }

    /// Registers an authorized directory URL and optionally triggers deduplicated directory indexing.
    /// Contract: `progress` is `nil` when `startIndexingImmediately == false` or when registration is
    /// superseded/revoked before indexing admission; `progress?.phase == .cancelled` is returned only
    /// when an indexing run was actually admitted and subsequently cancelled.
    public func registerAuthorizedDirectory(
        url: URL,
        isAuthorized: Bool = true,
        startIndexingImmediately: Bool = false
    ) async -> (loadedExistingIndex: Bool, progress: SemanticIndexProgress?) {
        guard !isRuntimeDraining, let seq = beginInFlightOperation() else { return (false, nil) }
        defer { endInFlightOperation(seq) }

        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let scopeId = Self.scopeId(forDirectoryURL: canonical)
        let descriptor = SemanticScopeDescriptor(
            scopeId: scopeId,
            kind: .authorizedDirectory,
            rootPath: canonical.path,
            displayName: canonical.lastPathComponent.isEmpty ? canonical.path : canonical.lastPathComponent,
            isAuthorized: isAuthorized
        )
        let (loaded, targetGeneration) = await commitScopeRegistration(descriptor)
        guard isPluginAdmittingWork,
              scopeGenerations[scopeId] == targetGeneration,
              scopeRecords[scopeId]?.isAuthorized == true,
              isAuthorized && startIndexingImmediately else {
            return (loaded, nil)
        }
        let progress = await performDeduplicatedDirectoryIndexing(scopeId: scopeId)
        return (loaded, progress)
    }

    /// Cancels any active or retiring indexing for `url`, waits for all in-flight indexing workers
    /// (and their security-scoped leases) from the revoked generation to drain, and revokes its scope
    /// from the semantic coordinator if not superseded by a newer authorization generation.
    public func revokeAuthorizedDirectory(url: URL) async -> Bool {
        await revokeScope(scopeId: Self.scopeId(forDirectoryURL: url))
    }

    public func cancelIndexing(scopeId: String) async {
        guard !isShutDown else { return }
        _ = cancelAndRetireIndexingRun(forScopeId: scopeId)
        await bridge.cancelIndexing(scopeId: scopeId)
    }

    public func indexProgress(scopeId: String) async -> SemanticIndexProgress? {
        guard !isRuntimeDraining, let seq = beginInFlightOperation() else { return nil }
        defer { endInFlightOperation(seq) }
        return await bridge.scopeProgress(scopeId: scopeId)
    }

    public func startIndexing(scopeId: String) async -> SemanticIndexProgress {
        guard isPluginAdmittingWork, let seq = beginInFlightOperation() else {
            return Self.cancelledProgress(scopeId: scopeId)
        }
        defer { endInFlightOperation(seq) }
        return await performDeduplicatedDirectoryIndexing(scopeId: scopeId)
    }

    /// Coalesces concurrent indexing requests for the same `scopeId` so duplicate triggers
    /// share a single underlying FFI indexing run while holding a security-scoped lease.
    func performDeduplicatedDirectoryIndexing(scopeId: String) async -> SemanticIndexProgress {
        guard isPluginAdmittingWork else { return Self.cancelledProgress(scopeId: scopeId) }
        let currentGen = scopeGenerations[scopeId] ?? 0
        if let existingRun = inFlightIndexingRuns[scopeId],
           existingRun.scopeGeneration == currentGen,
           !existingRun.task.isCancelled {
            return await existingRun.task.value
        }
        _ = cancelAndRetireIndexingRun(forScopeId: scopeId)
        guard let descriptor = scopeRecords[scopeId], descriptor.isAuthorized else {
            return Self.cancelledProgress(scopeId: scopeId)
        }

        let runID = UUID()
        let runSeq = operationDrainTracker.allocateCutoffSequence()
        let isDirectoryScope = (descriptor.kind == .authorizedDirectory)
        let rootURL = URL(fileURLWithPath: descriptor.rootPath)
        let task = Task<SemanticIndexProgress, Never> {
            await self.executeAdmittedDirectoryIndexingRun(
                scopeId: scopeId,
                runID: runID,
                admissionSequence: runSeq,
                expectedGeneration: currentGen,
                isDirectoryScope: isDirectoryScope,
                rootURL: rootURL
            )
        }
        inFlightIndexingRuns[scopeId] = SemanticTrackedIndexingRun(
            runID: runID,
            scopeId: scopeId,
            scopeGeneration: currentGen,
            admissionSequence: runSeq,
            task: task
        )
        let progress = await task.value
        if inFlightIndexingRuns[scopeId]?.runID == runID {
            inFlightIndexingRuns.removeValue(forKey: scopeId)
        }
        retiringIndexingRuns.removeValue(forKey: runID)
        if task.isCancelled || !isPluginAdmittingWork || scopeGenerations[scopeId] != currentGen || scopeRecords[scopeId] == nil {
            return Self.cancelledProgress(
                scopeId: scopeId,
                processedFiles: progress.processedFiles,
                totalFiles: progress.totalFiles,
                indexGeneration: progress.indexGeneration
            )
        }
        return progress
    }

    private func executeAdmittedDirectoryIndexingRun(
        scopeId: String,
        runID: UUID,
        admissionSequence: UInt64,
        expectedGeneration: UInt64,
        isDirectoryScope: Bool,
        rootURL: URL
    ) async -> SemanticIndexProgress {
        defer { retiringIndexingRuns.removeValue(forKey: runID) }
        let bridgeRef = bridge
        let leaseProviderRef = directoryLeaseProvider
        guard !Task.isCancelled,
              isIndexingRunAdmitted(scopeId: scopeId, runID: runID, expectedGeneration: expectedGeneration)
        else { return Self.cancelledProgress(scopeId: scopeId) }

        await awaitPriorRetiringRuns(
            forScopeId: scopeId,
            excludingRunID: runID,
            beforeAdmissionSequence: admissionSequence,
            maxGeneration: expectedGeneration
        )
        guard !Task.isCancelled,
              isIndexingRunAdmitted(scopeId: scopeId, runID: runID, expectedGeneration: expectedGeneration)
        else { return Self.cancelledProgress(scopeId: scopeId) }

        let acquiredLease: SecurityScopeLease? = isDirectoryScope ? await leaseProviderRef(rootURL) : nil
        defer { acquiredLease?.release() }
        if isDirectoryScope && acquiredLease == nil {
            return SemanticIndexProgress(
                scopeId: scopeId,
                phase: .failed,
                processedFiles: 0,
                totalFiles: 0,
                indexedSegments: 0,
                indexGeneration: 0,
                errorMessage: "Failed to acquire security-scoped lease for \(rootURL.path)"
            )
        }
        guard !Task.isCancelled,
              isIndexingRunAdmitted(scopeId: scopeId, runID: runID, expectedGeneration: expectedGeneration)
        else {
            if let acquiredLease {
                await MainActor.run { acquiredLease.release() }
            }
            return Self.cancelledProgress(scopeId: scopeId)
        }
        hasDirtyBridgeSession = true
        let result = await bridgeRef.startDirectoryIndexing(scopeId: scopeId)
        if let acquiredLease {
            await MainActor.run { acquiredLease.release() }
        }
        return result
    }

    public func cancelSearch(requestId: UInt64) async {
        activeSearchIds.remove(requestId)
        cancelledRequestIds.insert(requestId)
        guard !isShutDown else { return }
        await bridge.cancelSearch(requestId: requestId)
    }

    public func search(_ request: SemanticSearchRequest) async -> SemanticSearchResponse {
        if isRuntimeDraining || !isAcceptingOperations {
            return Self.emptySearchResponse(request, isCancelled: true)
        }
        guard isPluginEnabled else {
            return Self.emptySearchResponse(request, isCancelled: false, degradedLexicalOnly: true)
        }
        guard let seq = beginInFlightOperation() else {
            return Self.emptySearchResponse(request, isCancelled: true)
        }
        defer { endInFlightOperation(seq) }

        let previousLatest = latestWindowRequest[request.windowId] ?? 0
        if request.requestId > previousLatest {
            latestWindowRequest[request.windowId] = request.requestId
        }
        if isSearchCancelled(windowId: request.windowId, requestId: request.requestId) {
            await bridge.cancelSearch(requestId: request.requestId)
            return Self.emptySearchResponse(request, isCancelled: true)
        }

        let (_, cleanQuery) = SemanticPromptFormatter.stripCodeQueryPrefix(request.query)
        guard !cleanQuery.isEmpty else {
            return Self.emptySearchResponse(request, isCancelled: false)
        }

        activeSearchIds.insert(request.requestId)
        defer { activeSearchIds.remove(request.requestId) }
        hasDirtyBridgeSession = true

        let response = await bridge.search(request)
        if !isPluginAdmittingWork || isSearchCancelled(windowId: request.windowId, requestId: request.requestId) {
            return Self.emptySearchResponse(
                request,
                isCancelled: true,
                degradedLexicalOnly: response.degradedLexicalOnly,
                isEngineLinked: response.isEngineLinked,
                engineUnlinkedReason: response.engineUnlinkedReason
            )
        }
        return response
    }

    public nonisolated func buildOpenRequest(for hit: SemanticSearchHit) -> SemanticOpenRequest {
        bridge.buildOpenRequest(for: hit)
    }

    private func isSearchCancelled(windowId: String, requestId: UInt64) -> Bool {
        cancelledRequestIds.contains(requestId) || (latestWindowRequest[windowId] ?? 0) > requestId
    }
}
