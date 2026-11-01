// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation

/// Manages local EmbeddingGemma 2 GGUF model installation, verification, download, and deletion.
@MainActor
@Observable
public final class LocalModelManager {
    public static let shared = LocalModelManager(
        pathResolver: .defaultResolver(),
        engine: .shared
    )

    private struct VerifiedFileMetadata: Equatable {
        let path: String
        let sizeBytes: Int64
        let modificationDate: Date?
        let systemFileNumber: UInt64?
    }

    public private(set) var installState: SemanticModelInstallState = .notInstalled
    public private(set) var isPluginEnabled: Bool
    public private(set) var isDisabling: Bool = false
    public private(set) var isModelInstalled = false
    private let userDefaults: UserDefaults
    public private(set) var diskUsageBytes: Int64 = 0
    public private(set) var isBusy: Bool = false
    public private(set) var lastFailureReason: String?
    public private(set) var isShuttingDown: Bool = false
    public private(set) var isShutDown: Bool = false

    public let pathResolver: LocalModelPathResolver
    public let engine: SemanticSearchEngine
    private let transport: any LocalModelDownloadTransport
    private let requireExactChecksum: Bool
    private let maxAutomaticRetries: Int
    @ObservationIgnored
    private var cachedVerifiedMetadata: VerifiedFileMetadata?
    @ObservationIgnored
    private var pluginEnableGeneration: UInt64 = 0
    @ObservationIgnored
    private var activeDownloadTask: Task<Void, Never>?
    @ObservationIgnored
    private var ownedDownloadTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var activeDownloadGeneration: UInt64 = 0
    @ObservationIgnored
    private var activeRefreshTasks: Int = 0
    @ObservationIgnored
    private var refreshCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored
    private var activeShutdownTask: Task<Bool, Never>?
    @ObservationIgnored
    private var activeBackfillTask: Task<[SemanticIndexProgress], Never>?

    public var hasAcceptedDownloadTasksInFlight: Bool {
        !ownedDownloadTasks.isEmpty
    }

    public var modelDisplayName: String { SemanticModelSpec.displayTitle }
    public var modelIdentifier: String { SemanticModelSpec.modelId }
    public var expectedDownloadBytes: Int64 { Int64(SemanticModelSpec.expectedGGUFSizeBytes) }

    /// True ONLY when download + file verification + runtime load have all succeeded (`.ready`).
    public var isSemanticSearchAvailable: Bool {
        guard isPluginEnabled, isModelInstalled else { return false }
        if case .ready = installState { return true }
        return false
    }

    /// Basic lexical search is always available even when the semantic model is not installed.
    public var isLexicalSearchAvailable: Bool { true }

    public var downloadProgressFraction: Double? {
        if case .downloading(let progress) = installState {
            return min(1.0, max(0.0, progress))
        }
        return nil
    }

    public init(
        pathResolver: LocalModelPathResolver = .defaultResolver(),
        engine: SemanticSearchEngine? = nil,
        transport: any LocalModelDownloadTransport = URLSessionLocalModelDownloadTransport(),
        requireExactChecksum: Bool = true,
        maxAutomaticRetries: Int = 0,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        self.isPluginEnabled = userDefaults.bool(forKey: LocalSemanticPluginPreferences.enabledKey)
        self.pathResolver = pathResolver
        self.engine = engine ?? SemanticSearchEngine(
            storageDirectory: pathResolver.semanticStorageDirectoryURL
        )
        self.transport = transport
        self.requireExactChecksum = requireExactChecksum
        self.maxAutomaticRetries = min(
            max(0, maxAutomaticRetries),
            SemanticModelSpec.maxRetryAttempts
        )
        reconcileInitialDiskStateSynchronously()
    }

    /// Installation alone never authorizes native model loading or indexing.
    public func setPluginEnabled(_ enabled: Bool) async {
        guard !isShuttingDown, !isShutDown else { return }
        if !enabled {
            await disablePluginRuntime()
            return
        }
        if !isModelInstalled { await refreshState() }
        guard isModelInstalled, let existingURL = resolvedInstalledModelFileURL() else { return }
        pluginEnableGeneration &+= 1
        let enableGen = pluginEnableGeneration
        activeDownloadGeneration &+= 1
        let generation = activeDownloadGeneration
        isPluginEnabled = true
        isDisabling = false
        isBusy = true
        installState = .verifying
        userDefaults.set(true, forKey: LocalSemanticPluginPreferences.enabledKey)
        await engine.setPluginEnabled(true)
        guard isCurrentEnableTransition(enableGen: enableGen, downloadGen: generation) else { return }
        let fileSize = fileSizeInBytes(at: existingURL)
        let runtimeState = await engine.reloadAndVerifyModelRuntime(
            at: existingURL,
            requireExactChecksum: requireExactChecksum
        )
        guard isCurrentEnableTransition(enableGen: enableGen, downloadGen: generation) else { return }
        if case .failed = runtimeState {
            cachedVerifiedMetadata = nil
            if !FileManager.default.fileExists(atPath: existingURL.path) { isModelInstalled = false }
        }
        applyRefreshedRuntimeState(runtimeState, fileSize: fileSize, allowDeferredNotInstalled: false)
        isBusy = false
    }

    private func disablePluginRuntime() async {
        pluginEnableGeneration &+= 1
        let disableGen = pluginEnableGeneration
        isPluginEnabled = false
        isDisabling = true
        userDefaults.set(false, forKey: LocalSemanticPluginPreferences.enabledKey)
        if activeDownloadTask == nil { activeDownloadGeneration &+= 1 }
        activeBackfillTask?.cancel()
        activeBackfillTask = nil
        installState = .notInstalled
        isBusy = true
        await engine.setPluginEnabled(false)
        if pluginEnableGeneration == disableGen {
            isDisabling = false
            if activeDownloadTask == nil { isBusy = false }
        }
    }

    private func isCurrentEnableTransition(enableGen: UInt64, downloadGen: UInt64) -> Bool {
        !isShuttingDown && !isShutDown && isPluginEnabled
            && pluginEnableGeneration == enableGen && activeDownloadGeneration == downloadGen
    }

    /// Synchronously removes leftover `.part` files and checks initial on-disk presence.
    private func reconcileInitialDiskStateSynchronously() {
        removeAllPartFilesIfPresent()
        guard let existingURL = resolvedInstalledModelFileURL() else {
            cachedVerifiedMetadata = nil
            isModelInstalled = false
            installState = .notInstalled
            diskUsageBytes = 0
            lastFailureReason = nil
            return
        }
        diskUsageBytes = fileSizeInBytes(at: existingURL)
    }

    /// Reconciles on-disk model state and reads non-loading runtime state without reloading the model.
    public func refreshState() async {
        guard !isShuttingDown, !isShutDown, activeDownloadTask == nil else { return }
        activeDownloadGeneration &+= 1
        let generation = activeDownloadGeneration
        activeRefreshTasks += 1
        defer {
            activeRefreshTasks = max(0, activeRefreshTasks - 1)
            if activeRefreshTasks == 0 {
                let waiters = refreshCompletionWaiters
                refreshCompletionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        await refreshInstalledModelState(generation: generation)
    }

    private func refreshInstalledModelState(generation: UInt64) async {
        if ownedDownloadTasks.isEmpty { removeAllPartFilesIfPresent() }
        guard let existingURL = resolvedInstalledModelFileURL() else {
            cachedVerifiedMetadata = nil
            await engine.unloadModelRuntime()
            if isCurrentActiveGeneration(generation) {
                isModelInstalled = false
                installState = .notInstalled
                diskUsageBytes = 0
                lastFailureReason = nil
            }
            isBusy = isDisabling
            return
        }

        let currentMetadata = fileMetadata(at: existingURL)
        let fileSize = currentMetadata.sizeBytes
        guard await verifyInstalledModelOnDiskIfNeeded(
            at: existingURL,
            metadata: currentMetadata,
            generation: generation
        ) else { return }

        isModelInstalled = true
        diskUsageBytes = fileSize
        guard isPluginEnabled, !isDisabling else {
            installState = .notInstalled
            lastFailureReason = nil
            isBusy = isDisabling
            return
        }
        await engine.setPluginEnabled(true)
        guard isCurrentActiveGeneration(generation), isPluginEnabled, !isDisabling else {
            isBusy = isDisabling
            return
        }
        let runtimeState = await engine.modelState()
        guard isCurrentActiveGeneration(generation), isPluginEnabled, !isDisabling else {
            isBusy = isDisabling
            return
        }
        applyRefreshedRuntimeState(runtimeState, fileSize: fileSize, allowDeferredNotInstalled: true)
        isBusy = false
    }

    private func verifyInstalledModelOnDiskIfNeeded(
        at existingURL: URL,
        metadata: VerifiedFileMetadata,
        generation: UInt64
    ) async -> Bool {
        if cachedVerifiedMetadata != metadata {
            isModelInstalled = false
            isBusy = true
            installState = .verifying
            do {
                _ = try await GGUFModelVerifier.verifyModelFileAsync(
                    at: existingURL,
                    requireExactChecksum: requireExactChecksum
                )
                cachedVerifiedMetadata = metadata
            } catch {
                cachedVerifiedMetadata = nil
                await engine.unloadModelRuntime()
                if isCurrentActiveGeneration(generation) {
                    let reason = error.localizedDescription
                    isModelInstalled = false
                    installState = .failed(reason: reason)
                    lastFailureReason = reason
                    diskUsageBytes = metadata.sizeBytes
                }
                isBusy = isDisabling
                return false
            }
        }
        guard isCurrentActiveGeneration(generation) else {
            isBusy = isDisabling
            return false
        }
        return true
    }

    private func applyRefreshedRuntimeState(
        _ runtimeState: SemanticModelInstallState,
        fileSize: Int64,
        allowDeferredNotInstalled: Bool
    ) {
        switch runtimeState {
        case let .ready(descriptor):
            installState = .ready(descriptor)
            diskUsageBytes = fileSize
            lastFailureReason = nil
            triggerAuthorizedScopeBackfill()
        case let .failed(reason), let .engineUnlinked(reason):
            installState = .failed(reason: reason)
            diskUsageBytes = fileSize
            lastFailureReason = reason
        case .notInstalled where allowDeferredNotInstalled:
            installState = .notInstalled
            diskUsageBytes = fileSize
            lastFailureReason = nil
        default:
            let reason = "Semantic model runtime failed to initialize."
            installState = .failed(reason: reason)
            diskUsageBytes = fileSize
            lastFailureReason = reason
        }
    }

    /// Triggers background indexing for any authorized directory scopes registered while the model was not yet ready.
    public func triggerAuthorizedScopeBackfill() {
        guard !isShuttingDown, !isShutDown, isSemanticSearchAvailable else { return }
        activeBackfillTask?.cancel()
        let engineRef = engine
        activeBackfillTask = Task {
            await engineRef.backfillAuthorizedScopesIfNeeded()
        }
    }

    /// Waits for any in-flight or newly triggered authorized scope backfill indexing to complete.
    @discardableResult
    public func backfillAuthorizedScopes() async -> [SemanticIndexProgress] {
        guard !isShuttingDown, !isShutDown, isSemanticSearchAvailable else { return [] }
        if let existing = activeBackfillTask {
            return await existing.value
        }
        triggerAuthorizedScopeBackfill()
        guard let task = activeBackfillTask else { return [] }
        return await task.value
    }

    /// Starts downloading the model if not already downloading/verifying/ready.
    public func startDownload() {
        guard !isShuttingDown, !isShutDown, !isDownloadOrVerifyInFlight, !isModelInstalled else {
            return
        }
        isPluginEnabled = false
        userDefaults.set(false, forKey: LocalSemanticPluginPreferences.enabledKey)
        activeDownloadGeneration &+= 1
        let generation = activeDownloadGeneration
        isBusy = true
        lastFailureReason = nil
        installState = .downloading(
            bytesDownloaded: 0,
            totalBytes: SemanticModelSpec.expectedGGUFSizeBytes
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeDownloadPipeline(generation: generation)
        }
        ownedDownloadTasks[generation] = task
        activeDownloadTask = task
    }

    /// Async entry point for awaiting a download lifecycle in tests or callers.
    public func performDownload() async {
        guard !isShuttingDown, !isShutDown else { return }
        if let existingTask = activeDownloadTask {
            await existingTask.value
            return
        }
        guard !isModelInstalled else { return }
        startDownload()
        if let task = activeDownloadTask {
            await task.value
        }
    }

    /// Cancels the current download UI intent, signals task cancellation, and transitions cleanly to `.notInstalled`.
    /// The accepted task remains in `ownedDownloadTasks` until its body exits so `shutdown()` / `deleteModel()` can drain it.
    public func cancelDownload() {
        guard !isShuttingDown, !isShutDown else { return }
        let cancelledGeneration = activeDownloadGeneration
        activeDownloadGeneration &+= 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        removeFileIfPresent(at: pathResolver.stagingPartFileURL(forGeneration: cancelledGeneration))
        isBusy = isDisabling
        lastFailureReason = nil
        if let existingURL = resolvedInstalledModelFileURL(), isModelInstalled {
            diskUsageBytes = fileSizeInBytes(at: existingURL)
        } else {
            cachedVerifiedMetadata = nil
            isModelInstalled = false
            installState = .notInstalled
            diskUsageBytes = 0
        }
    }

    /// Retries after a failure or cancellation.
    public func retryDownload() {
        guard !isShuttingDown, !isShutDown, !isDownloadOrVerifyInFlight else { return }
        if ownedDownloadTasks.isEmpty {
            removeAllPartFilesIfPresent()
        }
        if case .failed = installState {
            try? FileManager.default.removeItem(at: pathResolver.canonicalModelFileURL)
            cachedVerifiedMetadata = nil
            isModelInstalled = false
            installState = .notInstalled
            diskUsageBytes = 0
            lastFailureReason = nil
        }
        startDownload()
    }

    /// Safely drains any accepted download tasks, unloads the model from `SemanticSearchEngine` runtime first,
    /// then deletes only the explicitly registered model files and resets state to `.notInstalled`.
    public func deleteModel() async throws {
        guard !isShuttingDown, !isShutDown else { return }
        await setPluginEnabled(false)
        cachedVerifiedMetadata = nil
        isModelInstalled = false
        activeDownloadGeneration &+= 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeBackfillTask?.cancel()
        activeBackfillTask = nil
        for task in ownedDownloadTasks.values {
            task.cancel()
        }
        isBusy = true
        defer { isBusy = false }

        await drainOwnedDownloadTasks()
        await engine.unloadModelRuntime()

        let fm = FileManager.default
        removeAllPartFilesIfPresent()
        var urlsToRemove: [URL] = [
            pathResolver.canonicalModelFileURL
        ]
        if let legacy = pathResolver.legacyModelFileURL {
            urlsToRemove.append(legacy)
        }
        for fileURL in urlsToRemove where fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }

        await engine.unloadModelRuntime()
        installState = .notInstalled
        diskUsageBytes = 0
        lastFailureReason = nil
    }

    /// Idempotent terminal shutdown for normal app termination (`CmdQ`).
    /// Closes entry points to new work, invalidates and drains all accepted downloads/reloads (including tasks
    /// cancelled prior to shutdown), removes only transient `.part*` staging files (preserving installed GGUF
    /// models and indices), and awaits terminal shutdown of the owned `SemanticSearchEngine`.
    @discardableResult
    public func shutdown() async -> Bool {
        if isShutDown {
            return true
        }
        if let existingTask = activeShutdownTask {
            return await existingTask.value
        }
        isShuttingDown = true
        pluginEnableGeneration &+= 1
        activeDownloadGeneration &+= 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeBackfillTask?.cancel()
        activeBackfillTask = nil
        for task in ownedDownloadTasks.values {
            task.cancel()
        }

        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return true }
            let engineReleased = await self.engine.shutdown()
            await self.drainOwnedDownloadTasks()
            if self.activeRefreshTasks > 0 {
                await withCheckedContinuation { continuation in
                    self.refreshCompletionWaiters.append(continuation)
                }
            }
            self.removeAllPartFilesIfPresent()
            self.isDisabling = false
            self.isBusy = false
            switch self.installState {
            case .downloading, .verifying, .ready:
                self.installState = .notInstalled
            case .notInstalled, .engineUnlinked, .failed:
                break
            }
            if engineReleased {
                self.isShutDown = true
                self.activeShutdownTask = nil
                return true
            } else {
                self.isShuttingDown = false
                self.activeShutdownTask = nil
                self.lastFailureReason = "Failed to release native semantic model runtime during shutdown."
                return false
            }
        }
        activeShutdownTask = task
        return await task.value
    }

    private func drainOwnedDownloadTasks() async {
        while !ownedDownloadTasks.isEmpty {
            let currentTasks = Array(ownedDownloadTasks.values)
            for task in currentTasks {
                await task.value
            }
        }
    }

    // MARK: - Internal Download & Verification Pipeline

    private var isDownloadOrVerifyInFlight: Bool {
        if activeDownloadTask != nil { return true }
        switch installState {
        case .downloading, .verifying:
            return true
        default:
            return false
        }
    }

    private func executeDownloadPipeline(generation: UInt64) async {
        let partURL = pathResolver.stagingPartFileURL(forGeneration: generation)
        await engine.setPluginEnabled(false)
        defer {
            self.ownedDownloadTasks.removeValue(forKey: generation)
            self.removeFileIfPresent(at: partURL)
            if self.activeDownloadGeneration == generation {
                self.activeDownloadTask = nil
                self.isBusy = self.isDisabling
            }
        }

        guard let downloadURL = URL(string: SemanticModelSpec.pinnedDownloadURLString) else {
            failDownload(generation: generation, reason: "Invalid model download URL.")
            return
        }

        let canonicalURL = pathResolver.canonicalModelFileURL
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: pathResolver.modelsDirectoryURL, withIntermediateDirectories: true)
            try await runTransportWithBoundedRetry(
                from: downloadURL,
                to: partURL,
                generation: generation
            )
            guard isCurrentActiveGeneration(generation) else {
                return
            }

            installState = .verifying
            _ = try await GGUFModelVerifier.verifyModelFileAsync(
                at: partURL,
                requireExactChecksum: requireExactChecksum
            )
            guard isCurrentActiveGeneration(generation) else {
                return
            }

            if fm.fileExists(atPath: canonicalURL.path) {
                try fm.removeItem(at: canonicalURL)
            }
            try fm.moveItem(at: partURL, to: canonicalURL)

            recordVerifiedInstallation(at: canonicalURL, generation: generation)
        } catch is CancellationError {
            handleCancelledDownload(generation: generation, partURL: partURL)
        } catch {
            if Task.isCancelled || !isCurrentActiveGeneration(generation) {
                handleCancelledDownload(generation: generation, partURL: partURL)
            } else {
                removeFileIfPresent(at: partURL)
                failDownload(generation: generation, reason: error.localizedDescription)
            }
        }
    }

    private func runTransportWithBoundedRetry(
        from url: URL,
        to partURL: URL,
        generation: UInt64
    ) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                try await transport.downloadModel(from: url, to: partURL) { [weak self] progress in
                    await MainActor.run {
                        guard let self, self.isCurrentActiveGeneration(generation) else { return }
                        let total = progress.totalBytesExpected > 0
                            ? UInt64(progress.totalBytesExpected)
                            : SemanticModelSpec.expectedGGUFSizeBytes
                        let received = UInt64(max(0, progress.bytesReceived))
                        self.installState = .downloading(bytesDownloaded: received, totalBytes: total)
                    }
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                removeFileIfPresent(at: partURL)
                if Task.isCancelled || attempt >= maxAutomaticRetries {
                    throw error
                }
                attempt += 1
            }
        }
    }

    private func recordVerifiedInstallation(at canonicalURL: URL, generation: UInt64) {
        guard isCurrentActiveGeneration(generation) else { return }
        let meta = fileMetadata(at: canonicalURL)
        cachedVerifiedMetadata = meta
        isModelInstalled = true
        diskUsageBytes = meta.sizeBytes
        installState = .notInstalled
        lastFailureReason = nil
        // The user must explicitly enable the component after installation.
    }

    private func handleCancelledDownload(generation: UInt64, partURL: URL) {
        removeFileIfPresent(at: partURL)
        guard !isShuttingDown, !isShutDown, activeDownloadGeneration == generation else { return }
        installState = .notInstalled
        diskUsageBytes = 0
        lastFailureReason = nil
    }

    private func failDownload(generation: UInt64, reason: String) {
        guard !isShuttingDown, !isShutDown, activeDownloadGeneration == generation else { return }
        installState = .failed(reason: reason)
        diskUsageBytes = 0
        lastFailureReason = reason
    }

    private func isCurrentActiveGeneration(_ generation: UInt64) -> Bool {
        !isShuttingDown && !isShutDown && !Task.isCancelled && activeDownloadGeneration == generation
    }

    private func resolvedInstalledModelFileURL() -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: pathResolver.canonicalModelFileURL.path) {
            return pathResolver.canonicalModelFileURL
        }
        if let legacy = pathResolver.legacyModelFileURL, fm.fileExists(atPath: legacy.path) {
            return legacy
        }
        return nil
    }

    private func removeFileIfPresent(at fileURL: URL) {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func removeAllPartFilesIfPresent() {
        let fm = FileManager.default
        removeFileIfPresent(at: pathResolver.stagingPartFileURL)
        let prefix = "\(SemanticModelSpec.pinnedGGUFFilename).part."
        guard let entries = try? fm.contentsOfDirectory(
            at: pathResolver.modelsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: entry)
        }
    }

    private func fileSizeInBytes(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func fileMetadata(at url: URL) -> VerifiedFileMetadata {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return VerifiedFileMetadata(
            path: url.standardizedFileURL.path,
            sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: attrs?[.modificationDate] as? Date,
            systemFileNumber: (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
