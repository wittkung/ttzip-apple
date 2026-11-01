// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import CryptoKit
import Observation
@preconcurrency import PDFKit

/// Explicit terminal and transitional states for PDF preview loading.
public enum PDFPreviewPhase: Equatable, Sendable {
    case loading
    case ready
    case locked
    case failed(String)
}

/// Authoritative load state projection for `PDFPreviewLoader` (`U1-004` digital twin).
public enum PDFPreviewLoadState {
    case idle
    case loading
    case loaded(PDFDocument)
    case failed(String)
}

/// Observable state coordinator managing PDF loading lifecycle, input identity,
/// stale-request generation fencing, retry, password unlock transitions,
/// and cross-document / cross-mode page & zoom state isolation.
@Observable
@MainActor
public final class PDFPreviewLoader {
    public typealias DocumentBuilder = @Sendable (URL?, Data?) async -> PDFDocument?

    public private(set) var phase: PDFPreviewPhase = .loading
    public private(set) var document: PDFDocument? = nil
    public private(set) var currentIdentity: PDFPreviewInputIdentity? = nil
    public var loadedIdentity: PDFPreviewInputIdentity? { currentIdentity }
    public private(set) var activeGeneration: UInt64 = 0
    public private(set) var unlockError: String? = nil
    public private(set) var unlockedPassword: String? = nil
    public var currentPageIndex: Int = 0
    public private(set) var totalPages: Int = 0
    public private(set) var zoomScale: CGFloat? = nil
    public private(set) var zoomCommandToken: UInt64 = 0
    public private(set) var latestStageMetrics: PDFPreviewStageMetrics? = nil

    public var loadState: PDFPreviewLoadState {
        switch phase {
        case .loading:
            return currentIdentity == nil ? .idle : .loading
        case .ready, .locked:
            return document.map { .loaded($0) } ?? .loading
        case .failed(let message):
            return .failed(message)
        }
    }

    public let maxReadBudgetBytes: Int
    public var onBeforeStreamReadChunk: (@Sendable () -> Void)?
    private var currentURL: URL?
    private var currentData: Data?
    private let documentBuilder: DocumentBuilder?
    private var activeTask: Task<Void, Never>?
    private var generationStartNs: UInt64 = 0

    nonisolated public static let maxReadBudgetBytes: Int = 64 * 1024 * 1024

    nonisolated public static let defaultDocumentBuilder: DocumentBuilder = { url, data in
        await runDetachedBudgetedLoad(url: url, data: data, maxBytes: maxReadBudgetBytes)
    }

    public init(
        maxReadBudgetBytes: Int = PDFPreviewLoader.maxReadBudgetBytes,
        documentBuilder: DocumentBuilder? = nil
    ) {
        self.maxReadBudgetBytes = maxReadBudgetBytes
        self.documentBuilder = documentBuilder
    }

    public func startLoad(
        url: URL?,
        data: Data?,
        identity: PDFPreviewInputIdentity? = nil,
        forceReload: Bool = false
    ) {
        let resolvedIdentity = resolveEffectiveIdentity(url: url, data: data, explicitIdentity: identity)
        if !forceReload, resolvedIdentity == currentIdentity {
            if phase != .loading {
                recordWarmIdentityReuseIfNeeded(identity: resolvedIdentity)
                return
            }
            if let inFlight = activeTask, !inFlight.isCancelled { return }
        }
        activeTask?.cancel()
        let generation = prepareGeneration(url: url, data: data, identity: resolvedIdentity)
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(url: url, data: data, identity: resolvedIdentity, generation: generation)
        }
    }

    public func loadAsync(
        url: URL?,
        data: Data?,
        identity: PDFPreviewInputIdentity? = nil,
        forceReload: Bool = false
    ) async {
        let resolvedIdentity = resolveEffectiveIdentity(url: url, data: data, explicitIdentity: identity)
        if !forceReload, resolvedIdentity == currentIdentity {
            if phase != .loading {
                recordWarmIdentityReuseIfNeeded(identity: resolvedIdentity)
                return
            }
            if let inFlight = activeTask, !inFlight.isCancelled {
                await inFlight.value
                return
            }
        }
        activeTask?.cancel()
        let generation = prepareGeneration(url: url, data: data, identity: resolvedIdentity)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(url: url, data: data, identity: resolvedIdentity, generation: generation)
        }
        activeTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func resolveEffectiveIdentity(
        url: URL?,
        data: Data?,
        explicitIdentity: PDFPreviewInputIdentity?
    ) -> PDFPreviewInputIdentity {
        if let explicitIdentity {
            if data == nil, let url, url.isFileURL {
                return PDFPreviewInputIdentity(url: url, data: nil, maxDigestBytes: maxReadBudgetBytes)
            }
            return explicitIdentity
        }
        return PDFPreviewInputIdentity(url: url, data: data, maxDigestBytes: maxReadBudgetBytes)
    }

    /// Retries loading the most recent input from scratch.
    public func retry() {
        startLoad(url: currentURL, data: currentData, identity: nil, forceReload: true)
    }

    /// Retries loading the most recent input and awaits completion.
    public func retryAsync() async {
        await loadAsync(url: currentURL, data: currentData, identity: nil, forceReload: true)
    }

    /// Attempts to unlock a password-protected PDF document, propagates the password to the
    /// background thumbnail coordinator, and transitions state on success.
    @discardableResult
    public func unlock(withPassword password: String) -> Bool {
        guard let doc = document, !password.isEmpty else {
            unlockError = PDFPreviewLocalization.text(.incorrectPassword)
            return false
        }
        if doc.unlock(withPassword: password) {
            unlockedPassword = password
            if let id = currentIdentity {
                let url = currentURL
                let data = currentData
                Task {
                    await PDFThumbnailRenderCoordinator.shared.registerUnlockPassword(
                        password,
                        for: id,
                        url: url,
                        data: data
                    )
                }
            }
            syncLockState()
            return phase == .ready
        }
        unlockError = PDFPreviewLocalization.text(.incorrectPassword)
        return false
    }

    /// Synchronizes phase after PDFKit unlocks a document (either via native `PDFView` or custom prompt).
    public func syncLockState(withPassword password: String? = nil) {
        if let password, !password.isEmpty {
            unlockedPassword = password
        }
        guard let doc = document else { return }
        if doc.isLocked {
            totalPages = 0
            phase = .locked
        } else if doc.pageCount > 0 {
            unlockError = nil
            totalPages = doc.pageCount
            currentPageIndex = min(max(0, currentPageIndex), max(0, doc.pageCount - 1))
            phase = .ready
        } else {
            document = nil
            totalPages = 0
            phase = .failed(PDFPreviewLocalization.text(.loadFailedCorruptOrEmpty))
        }
    }

    /// Updates `currentPageIndex` clamped to `0 ..< max(totalPages, 1)`.
    public func selectPage(index: Int) {
        let upper = max(0, totalPages - 1)
        currentPageIndex = min(max(0, index), upper)
    }

    /// Applies an explicit zoom scale (`nil` resets to auto-fit).
    public func setExplicitZoom(_ scale: CGFloat?) {
        if let scale {
            zoomScale = min(max(scale, 0.25), 10.0)
        } else {
            zoomScale = nil
        }
        zoomCommandToken &+= 1
    }

    /// Records the first-frame display timestamp when explicitly invoked by a verified on-screen display observer.
    public func recordFirstFrameRendered() {
        guard var metrics = latestStageMetrics, metrics.firstFrameStageMs == nil else { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = generationStartNs > 0 ? Double(nowNs &- generationStartNs) / 1_000_000.0 : metrics.loadReadyStageMs
        metrics.firstFrameStageMs = max(metrics.loadReadyStageMs, elapsedMs)
        latestStageMetrics = metrics
    }

    /// Records the first thumbnail completion latency for three-page grid mode.
    public func recordThumbnailRendered(elapsedMs: Double) {
        guard var metrics = latestStageMetrics, metrics.thumbnailStageMs == nil else { return }
        metrics.thumbnailStageMs = max(0, elapsedMs)
        latestStageMetrics = metrics
    }

    private func recordWarmIdentityReuseIfNeeded(identity: PDFPreviewInputIdentity) {
        latestStageMetrics = PDFPreviewStageMetrics(
            generation: activeGeneration,
            identityKey: identity.cacheKey,
            loadStageMs: 0,
            parseStageMs: 0,
            loadReadyStageMs: 0,
            firstFrameStageMs: latestStageMetrics?.firstFrameStageMs,
            thumbnailStageMs: latestStageMetrics?.thumbnailStageMs,
            wasCacheHit: true
        )
    }

    private func prepareGeneration(url: URL?, data: Data?, identity: PDFPreviewInputIdentity) -> UInt64 {
        currentURL = url
        currentData = data
        currentIdentity = identity
        unlockError = nil
        unlockedPassword = nil
        currentPageIndex = 0
        totalPages = 0
        zoomScale = nil
        zoomCommandToken &+= 1
        activeGeneration &+= 1
        generationStartNs = DispatchTime.now().uptimeNanoseconds
        latestStageMetrics = nil
        phase = .loading
        document = nil
        return activeGeneration
    }

    private func performLoad(
        url: URL?,
        data: Data?,
        identity: PDFPreviewInputIdentity,
        generation: UInt64
    ) async {
        let hook = onBeforeStreamReadChunk
        let loadedDoc: PDFDocument?
        let loadMs: Double
        let parseMs: Double
        if let customBuilder = documentBuilder {
            let t0 = DispatchTime.now().uptimeNanoseconds
            if let raw = data, raw.count > maxReadBudgetBytes {
                loadedDoc = nil
            } else {
                loadedDoc = await customBuilder(url, data)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000.0
            loadMs = elapsed * 0.4
            parseMs = elapsed * 0.6
        } else {
            let box = await Self.runDetachedBudgetedLoadTimed(
                url: url,
                data: data,
                maxBytes: maxReadBudgetBytes,
                onBeforeStreamReadChunk: hook
            )
            loadedDoc = box.document
            loadMs = box.loadMs
            parseMs = box.parseMs
        }
        guard !Task.isCancelled,
              generation == activeGeneration,
              identity == currentIdentity else {
            return
        }
        let loadReadyElapsed = generationStartNs > 0
            ? Double(DispatchTime.now().uptimeNanoseconds &- generationStartNs) / 1_000_000.0
            : (loadMs + parseMs)
        latestStageMetrics = PDFPreviewStageMetrics(
            generation: generation,
            identityKey: identity.cacheKey,
            loadStageMs: loadMs,
            parseStageMs: parseMs,
            loadReadyStageMs: max(loadMs + parseMs, loadReadyElapsed),
            firstFrameStageMs: nil,
            thumbnailStageMs: nil,
            wasCacheHit: false
        )
        applyLoadedDocument(loadedDoc)
    }

    private func applyLoadedDocument(_ loadedDoc: PDFDocument?) {
        guard let doc = loadedDoc else {
            document = nil
            totalPages = 0
            phase = .failed(PDFPreviewLocalization.text(.loadFailedCorruptOrEmpty))
            return
        }
        if doc.isLocked {
            document = doc
            totalPages = 0
            currentPageIndex = 0
            phase = .locked
            return
        }
        guard doc.pageCount > 0 else {
            document = nil
            totalPages = 0
            phase = .failed(PDFPreviewLocalization.text(.loadFailedCorruptOrEmpty))
            return
        }
        document = doc
        totalPages = doc.pageCount
        currentPageIndex = 0
        phase = .ready
    }
}

// MARK: - Thread-Safe Background Thumbnail Coordinator

/// Coordinates off-main-thread PDF thumbnail rasterization with strict pixel budgets,
/// bounded concurrency (max 2 workers), isolated worker `PDFDocument` instances, and
/// honest accounting of synchronous CoreGraphics/PDFKit `PDFPage.thumbnail(of:for:)` calls.
///
/// Note on PDFKit cancellation: `PDFPage.thumbnail(of:for:)` is a synchronous CoreGraphics
/// call that cannot be preempted once entered. Cooperative cancellation therefore operates at
/// two honest boundaries:
/// 1. `abortedInQueueCount`: cancelled while waiting in the concurrency queue or before entering
///    `page.thumbnail(of:for:)` (stop queued work).
/// 2. `suppressedWritebackCount`: cancelled while synchronous `page.thumbnail(of:for:)` was
///    executing; once the underlying call returns, cache and caller writeback are suppressed (suppress writeback).
/// 3. `completedRenderCount`: completed normally (underlying render completed).
public actor PDFThumbnailRenderCoordinator {
    public static let shared = PDFThumbnailRenderCoordinator()

    public static let maxPixelWidth: CGFloat = 420
    public static let maxPixelHeight: CGFloat = 560
    public static let maxPixelArea: CGFloat = 235_200
    public static let defaultCardPointSize = CGSize(width: 220, height: 290)
    public static let maxConcurrentRenders: Int = 2

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    public private(set) var abortedInQueueCount: Int = 0
    public private(set) var suppressedWritebackCount: Int = 0
    public private(set) var completedRenderCount: Int = 0
    public var cancelledRenderCount: Int { abortedInQueueCount + suppressedWritebackCount }

    private let imageCache: NSCache<NSString, NSImage>
    private let maxReadBudgetBytes: Int
    private var activeRenderCount: Int = 0
    private var waiters: [Waiter] = []
    private var workerPools: [String: [PDFDocument]] = [:]
    private var unlockPasswords: [String: String] = [:]
    private var serializedFallbackData: [String: Data] = [:]
    private var poolOrder: [String] = []
    private let maxTrackedIdentities: Int = 8

    public init(
        countLimit: Int = 120,
        totalCostLimit: Int = 64 * 1024 * 1024,
        maxReadBudgetBytes: Int = PDFPreviewLoader.maxReadBudgetBytes
    ) {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        self.imageCache = cache
        self.maxReadBudgetBytes = maxReadBudgetBytes
    }

    /// Registers a validated unlock password for `identity` (and optional URL/Data alias keys)
    /// so isolated background worker `PDFDocument` instances unlock automatically.
    public func registerUnlockPassword(
        _ password: String,
        for identity: PDFPreviewInputIdentity?,
        url: URL? = nil,
        data: Data? = nil
    ) {
        guard !password.isEmpty else { return }
        var keys: Set<String> = []
        if let identity { keys.insert(identity.cacheKey) }
        if url != nil || data != nil {
            keys.insert(PDFPreviewInputIdentity(url: url, data: data, maxDigestBytes: maxReadBudgetBytes).cacheKey)
        }
        if let url {
            keys.insert(url.standardizedFileURL.absoluteString)
        }
        for key in keys {
            unlockPasswords[key] = password
            if let docs = workerPools[key] {
                for doc in docs where doc.isLocked {
                    _ = doc.unlock(withPassword: password)
                }
            }
        }
    }

    public func cachedThumbnail(
        identityKey: String,
        zeroBasedPageIndex: Int,
        pixelSize: CGSize
    ) -> NSImage? {
        let key = Self.thumbnailCacheKey(
            identityKey: identityKey,
            zeroBasedPageIndex: zeroBasedPageIndex,
            pixelSize: pixelSize
        ) as NSString
        return imageCache.object(forKey: key)
    }

    /// Clears all cached thumbnails, worker document pools, and counters.
    public func clearCache() {
        imageCache.removeAllObjects()
        workerPools.removeAll()
        unlockPasswords.removeAll()
        serializedFallbackData.removeAll()
        poolOrder.removeAll()
    }

    /// Renders or retrieves a cached thumbnail off `@MainActor` with isolated `PDFDocument` ownership.
    public func renderThumbnail(
        zeroBasedPageIndex: Int,
        displayPointSize: CGSize = PDFThumbnailRenderCoordinator.defaultCardPointSize,
        scaleFactor: CGFloat = 2.0,
        pageAspectRatio: CGFloat = 0.75,
        url: URL? = nil,
        data: Data? = nil,
        identity: PDFPreviewInputIdentity? = nil,
        unlockPassword: String? = nil,
        fallbackDocumentDataProvider: (@MainActor @Sendable () -> Data?)? = nil
    ) async -> NSImage? {
        guard zeroBasedPageIndex >= 0 else { return nil }
        if Task.isCancelled {
            abortedInQueueCount += 1
            return nil
        }
        if let unlockPassword, !unlockPassword.isEmpty {
            registerUnlockPassword(unlockPassword, for: identity, url: url, data: data)
        }
        let pixelSize = Self.budgetedPixelSize(
            for: displayPointSize,
            scaleFactor: scaleFactor,
            pageAspectRatio: pageAspectRatio
        )
        let resolvedKey = resolveIdentityKey(url: url, data: data, identity: identity)
        let cacheKey = Self.thumbnailCacheKey(
            identityKey: resolvedKey,
            zeroBasedPageIndex: zeroBasedPageIndex,
            pixelSize: pixelSize
        ) as NSString

        if let hit = imageCache.object(forKey: cacheKey) { return hit }
        guard await acquirePermit() else {
            abortedInQueueCount += 1
            return nil
        }
        if Task.isCancelled {
            abortedInQueueCount += 1
            releasePermit()
            return nil
        }
        if let hit = imageCache.object(forKey: cacheKey) {
            releasePermit()
            return hit
        }

        let outcome = await executeWorkerThumbnailRender(
            poolKey: resolvedKey,
            zeroBasedPageIndex: zeroBasedPageIndex,
            pixelSize: pixelSize,
            url: url,
            data: data,
            fallbackDocumentDataProvider: fallbackDocumentDataProvider
        )
        releasePermit()
        return recordRenderOutcome(outcome, cacheKey: cacheKey, pixelSize: pixelSize)
    }

    private func recordRenderOutcome(
        _ outcome: WorkerRenderOutcome,
        cacheKey: NSString,
        pixelSize: CGSize
    ) -> NSImage? {
        switch outcome {
        case .abortedBeforeRender:
            abortedInQueueCount += 1
            return nil
        case .suppressedWriteback:
            suppressedWritebackCount += 1
            return nil
        case .failed:
            return nil
        case .rendered(let image):
            if Task.isCancelled {
                suppressedWritebackCount += 1
                return nil
            }
            let cost = Int(pixelSize.width * pixelSize.height * 4)
            imageCache.setObject(image, forKey: cacheKey, cost: max(cost, 1))
            completedRenderCount += 1
            return image
        }
    }

    private enum WorkerRenderOutcome: Sendable {
        case abortedBeforeRender
        case suppressedWriteback
        case failed
        case rendered(NSImage)
    }

    private func executeWorkerThumbnailRender(
        poolKey: String,
        zeroBasedPageIndex: Int,
        pixelSize: CGSize,
        url: URL?,
        data: Data?,
        fallbackDocumentDataProvider: (@MainActor @Sendable () -> Data?)?
    ) async -> WorkerRenderOutcome {
        guard let workerDoc = await checkoutWorkerDocument(
            poolKey: poolKey,
            url: url,
            data: data,
            fallbackDocumentDataProvider: fallbackDocumentDataProvider
        ) else {
            return Task.isCancelled ? .abortedBeforeRender : .failed
        }
        defer { checkinWorkerDocument(workerDoc, poolKey: poolKey) }
        guard !Task.isCancelled else { return .abortedBeforeRender }

        let renderTask = Task.detached(priority: .utility) { () -> WorkerRenderOutcome in
            guard !Task.isCancelled else { return .abortedBeforeRender }
            guard !workerDoc.isLocked,
                  zeroBasedPageIndex < workerDoc.pageCount,
                  let workerPage = workerDoc.page(at: zeroBasedPageIndex) else {
                return .failed
            }
            guard !Task.isCancelled else { return .abortedBeforeRender }
            // Synchronous CoreGraphics/PDFKit rasterization; cannot be preempted mid-call.
            let image = workerPage.thumbnail(of: pixelSize, for: .cropBox)
            if Task.isCancelled {
                return .suppressedWriteback
            }
            return .rendered(image)
        }
        return await withTaskCancellationHandler {
            await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    private func resolveIdentityKey(
        url: URL?,
        data: Data?,
        identity: PDFPreviewInputIdentity?
    ) -> String {
        if let identity {
            return identity.cacheKey
        }
        if url != nil || data != nil {
            return PDFPreviewInputIdentity(url: url, data: data, maxDigestBytes: maxReadBudgetBytes).cacheKey
        }
        return "fallback-doc"
    }

    private func acquirePermit() async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeRenderCount < Self.maxConcurrentRenders {
            activeRenderCount += 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let removed = waiters.remove(at: idx)
            removed.continuation.resume(returning: false)
        }
    }

    private func releasePermit() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
            return
        }
        activeRenderCount = max(0, activeRenderCount - 1)
    }

    private func checkoutWorkerDocument(
        poolKey: String,
        url: URL?,
        data: Data?,
        fallbackDocumentDataProvider: (@MainActor @Sendable () -> Data?)?
    ) async -> PDFDocument? {
        if var existingPool = workerPools[poolKey], let doc = existingPool.popLast() {
            workerPools[poolKey] = existingPool
            applyRegisteredPasswordIfNeeded(to: doc, poolKey: poolKey, url: url)
            return doc
        }
        let createdDoc = await loadIsolatedWorkerDocument(
            poolKey: poolKey,
            url: url,
            data: data,
            fallbackDocumentDataProvider: fallbackDocumentDataProvider
        )
        if let createdDoc {
            applyRegisteredPasswordIfNeeded(to: createdDoc, poolKey: poolKey, url: url)
        }
        return createdDoc
    }

    private func loadIsolatedWorkerDocument(
        poolKey: String,
        url: URL?,
        data: Data?,
        fallbackDocumentDataProvider: (@MainActor @Sendable () -> Data?)?
    ) async -> PDFDocument? {
        if let explicitData = data {
            guard explicitData.count <= maxReadBudgetBytes else { return nil }
            return await PDFPreviewLoader.runDetachedBudgetedLoad(
                url: nil,
                data: explicitData,
                maxBytes: maxReadBudgetBytes,
                priority: .utility
            )
        }
        if let explicitURL = url {
            return await PDFPreviewLoader.runDetachedBudgetedLoad(
                url: explicitURL,
                data: nil,
                maxBytes: maxReadBudgetBytes,
                priority: .utility
            )
        }
        var fallbackData = serializedFallbackData[poolKey]
        if fallbackData == nil, let provider = fallbackDocumentDataProvider {
            if let extracted = await provider(), extracted.count <= maxReadBudgetBytes {
                serializedFallbackData[poolKey] = extracted
                fallbackData = extracted
            }
        }
        guard let fallbackData else { return nil }
        return await PDFPreviewLoader.runDetachedBudgetedLoad(
            url: nil,
            data: fallbackData,
            maxBytes: maxReadBudgetBytes,
            priority: .utility
        )
    }

    private func applyRegisteredPasswordIfNeeded(to doc: PDFDocument, poolKey: String, url: URL?) {
        guard doc.isLocked else { return }
        if let password = unlockPasswords[poolKey] {
            _ = doc.unlock(withPassword: password)
            return
        }
        if let urlKey = url?.standardizedFileURL.absoluteString, let password = unlockPasswords[urlKey] {
            _ = doc.unlock(withPassword: password)
        }
    }

    private func checkinWorkerDocument(_ doc: PDFDocument, poolKey: String) {
        if !poolOrder.contains(poolKey) {
            poolOrder.append(poolKey)
            if poolOrder.count > maxTrackedIdentities, let oldest = poolOrder.first {
                poolOrder.removeFirst()
                workerPools.removeValue(forKey: oldest)
                unlockPasswords.removeValue(forKey: oldest)
                serializedFallbackData.removeValue(forKey: oldest)
            }
        }
        var pool = workerPools[poolKey] ?? []
        if pool.count < Self.maxConcurrentRenders {
            pool.append(doc)
            workerPools[poolKey] = pool
        }
    }
}

