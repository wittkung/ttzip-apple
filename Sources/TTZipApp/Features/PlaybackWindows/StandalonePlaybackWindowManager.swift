// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import Observation
import SwiftUI
import TTMediaKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI

/// Coordinates the standalone video playback `NSWindow`, F4 archive/ephemeral cache leases,
/// and the 5-state lifecycle transitions between browser windows and the standalone player (W1 — Feedback ②).
@MainActor
@Observable
public final class StandalonePlaybackWindowManager: NSObject, NSWindowDelegate {
    public static let shared = StandalonePlaybackWindowManager()

    public internal(set) var activeSession: StandalonePlaybackSessionState?
    public internal(set) var lastLifecycleEvent: StandalonePlaybackLifecycleEvent?
    public internal(set) var createdWindowCount: Int = 0
    public internal(set) var windowPresentationRequestCount: Int = 0
    public var windowFactory: (@MainActor (StandalonePlaybackSessionState) -> StandalonePlaybackNSWindow)?
    public var windowPresentationHandler: (@MainActor (StandalonePlaybackNSWindow, StandalonePlaybackSessionState) -> Void)?

    public var standaloneCacheLease: PreviewCacheLease? {
        activeSessionResources?.cacheLease
    }

    public var pendingHandoffCount: Int {
        pendingHandoffs.count
    }

    var activeSessionResources: StandalonePlaybackSessionResources?
    var pendingHandoffs: [UUID: StandalonePlaybackHandoffRecord] = [:]
    var originWindowRestoredLeases: [UUID: OriginWindowRestoredLeaseRecord] = [:]
    var openRequestGeneration: UInt64 = 0
    var inFlightOpenTask: Task<StandalonePlaybackSessionState?, Never>?

    public internal(set) var playerWindow: StandalonePlaybackNSWindow?
    var isReturningToOriginPreview = false

    /// Optional test hook invoked after cache lease acquisition completes and before committing window state.
    public var onWillCommitAcquiredLeaseHook: (@MainActor () async -> Void)?

    /// Optional test hook invoked after an origin bridge lease is acquired and before revalidating target window/handoff state.
    public var onWillCommitOriginBridgeLeaseHook: (@MainActor (_ targetWindowID: UUID, _ handoffID: UUID) async -> Void)?

    /// Optional test hook invoked immediately after releasing a replaced origin bridge lease and before the final synchronous commit.
    public var onDidReleasePreviousOriginBridgeLeaseHook: (@MainActor (_ targetWindowID: UUID, _ handoffID: UUID) async -> Void)?

    /// Optional override allowing tests to simulate origin takeover failure during `returnToOriginPreview`.
    public var shouldSimulateOriginTakeoverFailure = false

    /// Callback invoked when the user clicks "Return to Preview" so the browser window
    /// can restore selection and reclaim the active `VideoPlaybackSession` without restarting from 0s.
    public var onReturnToOriginPreview: (@MainActor (StandalonePlaybackSessionState) -> Void)?

    package static var isOriginBrowserWindowRegistered: (@MainActor (UUID) -> Bool)?
    package static var activateAndRestoreOriginBrowserWindow: (
        @MainActor (UUID, StandalonePlaybackSessionState) -> Bool
    )?

    public override init() {
        super.init()
    }

    // MARK: - Video Classification & Identity

    /// Returns `true` strictly when `item` represents a video file that should open in a standalone playback window.
    /// Distinguishes MPEG-TS video from TypeScript `.ts` source files via `TTMediaDetector`.
    public static func isVideoItem(_ item: ImmersiveMediaItem) -> Bool {
        let fast = TTMediaDetector.fastTypeByExtension(url: item.url)
        if fast.isVideoPreview {
            return true
        }
        let nameExt = (item.name as NSString).pathExtension
        let rawExt = nameExt.isEmpty ? item.url.pathExtension : nameExt
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: rawExt)
        guard TTMediaCapabilityMatrix.videoExtensions.contains(ext) else {
            return false
        }
        return TTMediaDetector.inferHostLayoutClass(url: item.url, fileName: item.name) == .canvasMedia
    }

    /// Resolves the deterministic F4 cache key for `item` when backed by an archive entry or explicit cache key.
    public static func resolvedCacheKey(for item: ImmersiveMediaItem) -> String? {
        if let cacheKey = item.resourceCacheKey, !cacheKey.isEmpty {
            return cacheKey
        }
        if let arch = item.sourceArchivePath, let sub = item.archiveSubpath {
            return PreviewLRUCacheManager.deterministicCacheKey(archivePath: arch, subpath: sub)
        }
        return nil
    }

    /// Computes a canonical identity key for deduplicating standalone window open requests.
    public static func canonicalIdentityKey(for item: ImmersiveMediaItem) -> String {
        if let key = resolvedCacheKey(for: item) {
            return "cache:\(key)"
        }
        return "url:\(item.url.standardizedFileURL.resolvingSymlinksInPath().path)"
    }

    public var hasActivePlaybackSession: Bool {
        activeSession != nil
    }

    public func hasPendingHandoff(id: UUID) -> Bool {
        pendingHandoffs[id] != nil
    }

    public func hasOriginRestoredLease(forWindowID windowID: UUID, key: String? = nil) -> Bool {
        guard let record = originWindowRestoredLeases[windowID] else { return false }
        if let key {
            return record.lease.key == key
        }
        return true
    }

    public func isPresenting(item: ImmersiveMediaItem) -> Bool {
        guard let activeSession else { return false }
        return activeSession.canonicalIdentityKey == Self.canonicalIdentityKey(for: item)
    }

    public func isPresenting(url: URL, resourceCacheKey: String? = nil) -> Bool {
        guard let activeSession else { return false }
        if let resourceCacheKey, !resourceCacheKey.isEmpty {
            return activeSession.canonicalIdentityKey == "cache:\(resourceCacheKey)"
        }
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return activeSession.canonicalIdentityKey == "url:\(canonicalPath)"
            || activeSession.item.url.standardizedFileURL.resolvingSymlinksInPath().path == canonicalPath
    }

    // MARK: - Open, Deduplicate & Focus Standalone Window (Requirement ①)

    /// Synchronous UI entry point that schedules an async `openOrFocus` transition while cancelling any superseded open task.
    @discardableResult
    public func requestOpenOrFocus(
        item: ImmersiveMediaItem,
        originBrowserWindowID: UUID?,
        originSelectedItem: DiskItemInfo? = nil,
        originDirectoryURL: URL? = nil,
        originArchivePath: String? = nil,
        createAppKitWindow: Bool = true,
        cacheManager: PreviewLRUCacheManager = .shared
    ) -> Task<StandalonePlaybackSessionState?, Never> {
        inFlightOpenTask?.cancel()
        let task = Task { @MainActor [weak self] () -> StandalonePlaybackSessionState? in
            guard let self else { return nil }
            return await self.openOrFocus(
                item: item,
                originBrowserWindowID: originBrowserWindowID,
                originSelectedItem: originSelectedItem,
                originDirectoryURL: originDirectoryURL,
                originArchivePath: originArchivePath,
                createAppKitWindow: createAppKitWindow,
                cacheManager: cacheManager
            )
        }
        inFlightOpenTask = task
        return task
    }

    /// Opens a standard resizable `NSWindow` for `item`, or focuses the existing standalone window if already open.
    @discardableResult
    public func openOrFocus(
        item: ImmersiveMediaItem,
        originBrowserWindowID: UUID?,
        originSelectedItem: DiskItemInfo? = nil,
        originDirectoryURL: URL? = nil,
        originArchivePath: String? = nil,
        createAppKitWindow: Bool = true,
        cacheManager: PreviewLRUCacheManager = .shared
    ) async -> StandalonePlaybackSessionState? {
        openRequestGeneration &+= 1
        let requestGen = openRequestGeneration
        isReturningToOriginPreview = false
        let identityKey = Self.canonicalIdentityKey(for: item)
        let requiredCacheKey = Self.resolvedCacheKey(for: item)

        if let focused = await tryFocusExistingSameSession(
            item: item,
            identityKey: identityKey,
            requiredCacheKey: requiredCacheKey,
            originBrowserWindowID: originBrowserWindowID,
            originSelectedItem: originSelectedItem,
            createAppKitWindow: createAppKitWindow,
            requestGeneration: requestGen,
            cacheManager: cacheManager
        ) {
            return focused
        }

        let sessionConsumerID = UUID()
        let sessionEphemeralBox = TTMediaEphemeralLeaseBox()
        TTMediaDetector.beginFullscreenEphemeralHandoff(for: item.url)
        sessionEphemeralBox.bind(url: item.url, consumeFullscreenHandoff: false)

        let acquisition = await acquireValidatedCacheLease(
            for: item,
            requiredCacheKey: requiredCacheKey,
            consumerID: sessionConsumerID,
            cacheManager: cacheManager
        )
        guard acquisition.succeeded else {
            TTMediaDetector.endFullscreenEphemeralHandoff(for: item.url)
            sessionEphemeralBox.release()
            lastLifecycleEvent = .leaseAcquisitionFailed
            return nil
        }

        if let hook = onWillCommitAcquiredLeaseHook {
            await hook()
        }

        guard !Task.isCancelled, requestGen == openRequestGeneration else {
            if let lease = acquisition.lease {
                await cacheManager.releaseLease(lease)
            }
            TTMediaDetector.endFullscreenEphemeralHandoff(for: acquisition.resolvedURL)
            sessionEphemeralBox.release()
            return nil
        }

        return await commitOpenedSession(
            item: item,
            resolvedURL: acquisition.resolvedURL,
            identityKey: identityKey,
            consumerID: sessionConsumerID,
            acquiredLease: acquisition.lease,
            ephemeralBox: sessionEphemeralBox,
            originBrowserWindowID: originBrowserWindowID,
            originSelectedItem: originSelectedItem,
            originDirectoryURL: originDirectoryURL,
            originArchivePath: originArchivePath,
            createAppKitWindow: createAppKitWindow,
            cacheManager: cacheManager
        )
    }

    private func tryFocusExistingSameSession(
        item: ImmersiveMediaItem,
        identityKey: String,
        requiredCacheKey: String?,
        originBrowserWindowID: UUID?,
        originSelectedItem: DiskItemInfo?,
        createAppKitWindow: Bool,
        requestGeneration: UInt64,
        cacheManager: PreviewLRUCacheManager
    ) async -> StandalonePlaybackSessionState? {
        guard var existing = activeSession,
              existing.canonicalIdentityKey == identityKey,
              let existingResources = activeSessionResources else {
            return nil
        }
        if let requiredCacheKey {
            guard existingResources.cacheLease != nil,
                  await cacheManager.cachedURL(forKey: requiredCacheKey) != nil,
                  await cacheManager.activeLeaseCount(forKey: requiredCacheKey) > 0 else {
                return nil
            }
        }
        guard !Task.isCancelled, requestGeneration == openRequestGeneration else {
            return nil
        }
        existing.item = item
        if let originBrowserWindowID {
            existing.originBrowserWindowID = originBrowserWindowID
            existing.isOriginWindowClosed = false
        }
        if let originSelectedItem {
            existing.originSelectedItem = originSelectedItem
            existing.hasOriginSelectionChanged = false
        }
        existing.focusRequestCount += 1
        activeSession = existing
        lastLifecycleEvent = .focusedExistingWindow
        if createAppKitWindow {
            ensureAndFocusNSWindow(for: existing)
        }
        return existing
    }

    private func commitOpenedSession(
        item: ImmersiveMediaItem,
        resolvedURL: URL,
        identityKey: String,
        consumerID: UUID,
        acquiredLease: PreviewCacheLease?,
        ephemeralBox: TTMediaEphemeralLeaseBox,
        originBrowserWindowID: UUID?,
        originSelectedItem: DiskItemInfo?,
        originDirectoryURL: URL?,
        originArchivePath: String?,
        createAppKitWindow: Bool,
        cacheManager: PreviewLRUCacheManager
    ) async -> StandalonePlaybackSessionState {
        let previousResources = activeSessionResources
        let resolvedItem = ImmersiveMediaItem(
            url: resolvedURL,
            name: item.name,
            fileSizeBytes: item.fileSizeBytes,
            sourceArchivePath: item.sourceArchivePath,
            archiveSubpath: item.archiveSubpath,
            resourceCacheKey: item.resourceCacheKey,
            isEditable: item.isEditable,
            resourceContext: item.resourceContext
        )
        let newSession = StandalonePlaybackSessionState(
            item: resolvedItem,
            canonicalIdentityKey: identityKey,
            originBrowserWindowID: originBrowserWindowID,
            originSelectedItem: originSelectedItem,
            originDirectoryURL: originDirectoryURL,
            originArchivePath: originArchivePath
        )
        let securityScope = resolvedURL.isFileURL
            ? RootFolderAccessManager.shared.acquireLease(for: resolvedURL)
            : nil
        if let acquiredLease,
           let arch = item.sourceArchivePath ?? originArchivePath,
           !arch.isEmpty {
            ArchivePreviewKeyRegistry.shared.record(archivePath: arch, cacheKey: acquiredLease.key)
        }
        activeSessionResources = StandalonePlaybackSessionResources(
            sessionID: newSession.sessionID,
            consumerID: consumerID,
            canonicalIdentityKey: identityKey,
            mediaURL: resolvedURL,
            cacheLease: acquiredLease,
            cacheManager: cacheManager,
            ephemeralLeaseBox: ephemeralBox,
            securityScope: securityScope
        )
        activeSession = newSession
        lastLifecycleEvent = (previousResources != nil) ? .replacedMediaInPlace : .openedNewWindow
        if createAppKitWindow {
            ensureAndFocusNSWindow(for: newSession)
        }
        if let previousResources {
            await previousResources.release()
        }
        return newSession
    }

    public func focusExistingWindowIfPresent() {
        guard let activeSession else { return }
        self.activeSession?.focusRequestCount += 1
        lastLifecycleEvent = .focusedExistingWindow
        if let playerWindow {
            if playerWindow.isMiniaturized {
                playerWindow.deminiaturize(nil)
            }
            playerWindow.makeKeyAndOrderFront(nil)
            NSApp?.activate(ignoringOtherApps: true)
        } else {
            ensureAndFocusNSWindow(for: activeSession)
        }
    }

    // MARK: - 5-State Lifecycle Transitions & Explicit Handoff Confirmation (Requirement ②)

    /// Lifecycle 1: Explicitly closes the standalone player window, completing origin handoff if active, or invalidates in-flight opens.
    public func closeStandaloneWindow(stopPlayback: Bool = true) {
        if activeSession != nil && !isReturningToOriginPreview {
            _ = requestReturnToOriginPreview()
            return
        }
        openRequestGeneration &+= 1
        inFlightOpenTask?.cancel()
        inFlightOpenTask = nil
        isReturningToOriginPreview = !stopPlayback
        if let window = playerWindow {
            playerWindow = nil
            window.delegate = nil
            window.close()
        }
        finalizeSessionTeardown(stopPlayback: stopPlayback)
    }

    /// Synchronous UI wrapper for `returnToOriginPreview()` that never cancels prior handoff records.
    @discardableResult
    public func requestReturnToOriginPreview(
        cacheManager: PreviewLRUCacheManager = .shared
    ) -> Task<Bool, Never> {
        Task { @MainActor in
            await self.returnToOriginPreview(cacheManager: cacheManager)
        }
    }

    /// Initiates a return-to-origin handoff by detaching the current session into an independent `StandalonePlaybackHandoffRecord`.
    /// Callers can subsequently invoke `completeOriginPreviewHandoff(handoffID:)` or `failOriginPreviewHandoff(handoffID:)`.
    public func beginOriginPreviewHandoff(
        cacheManager: PreviewLRUCacheManager = .shared
    ) -> StandalonePlaybackSessionState? {
        guard var session = activeSession else { return nil }
        openRequestGeneration &+= 1
        inFlightOpenTask?.cancel()
        inFlightOpenTask = nil

        let handoffID = UUID()
        session.handoffID = handoffID
        let currentResources = activeSessionResources
        activeSessionResources = nil
        activeSession = nil
        isReturningToOriginPreview = true
        lastLifecycleEvent = .returnedToOriginPreview

        if let window = playerWindow {
            playerWindow = nil
            window.delegate = nil
            window.close()
        }
        isReturningToOriginPreview = false

        let recordCacheManager = currentResources?.cacheManager ?? cacheManager
        let recordEphemeralBox = currentResources?.ephemeralLeaseBox ?? TTMediaEphemeralLeaseBox()
        let recordURL = currentResources?.mediaURL ?? session.item.url
        TTMediaDetector.beginFullscreenEphemeralHandoff(for: recordURL)
        pendingHandoffs[handoffID] = StandalonePlaybackHandoffRecord(
            handoffID: handoffID,
            session: session,
            mediaURL: recordURL,
            cacheLease: currentResources?.cacheLease,
            cacheManager: recordCacheManager,
            ephemeralLeaseBox: recordEphemeralBox,
            securityScope: currentResources?.securityScope
        )
        return session
    }

    /// Lifecycle 2: Returns playback to the origin browser window's inspector without resetting playback time.
    /// Uses explicit takeover confirmation (`completeOriginPreviewHandoff` / `failOriginPreviewHandoff`) with zero fixed sleep.
    @discardableResult
    public func returnToOriginPreview(
        cacheManager: PreviewLRUCacheManager = .shared
    ) async -> Bool {
        guard let session = beginOriginPreviewHandoff(cacheManager: cacheManager),
              let handoffID = session.handoffID,
              let record = pendingHandoffs[handoffID] else {
            return false
        }

        if shouldSimulateOriginTakeoverFailure {
            onReturnToOriginPreview?(session)
            await failOriginPreviewHandoff(handoffID: handoffID)
            return false
        }

        guard let targetWindowID = resolveTargetBrowserWindowID(for: session) else {
            onReturnToOriginPreview?(session)
            await failOriginPreviewHandoff(handoffID: handoffID)
            return false
        }

        let acquiredOriginLease = await acquireOriginRestoredLeaseIfNeeded(
            for: session,
            targetWindowID: targetWindowID,
            record: record
        )
        guard acquiredOriginLease,
              pendingHandoffs[handoffID] != nil,
              Self.activateAndRestoreOriginBrowserWindow?(targetWindowID, session) == true else {
            onReturnToOriginPreview?(session)
            await failOriginPreviewHandoff(handoffID: handoffID)
            return false
        }

        onReturnToOriginPreview?(session)

        await completeOriginPreviewHandoff(handoffID: handoffID)
        return true
    }

    /// Explicitly confirms that the origin preview has taken over the session and acquired its own lease,
    /// releasing ONLY the standalone player resources associated with `handoffID`.
    public func completeOriginPreviewHandoff(handoffID: UUID) async {
        guard let record = pendingHandoffs.removeValue(forKey: handoffID) else { return }
        await record.release()
    }

    /// Explicitly aborts an in-flight origin preview handoff when the target browser window or cache entry is unavailable,
    /// releasing all standalone player resources associated with `handoffID` so nothing leaks.
    public func failOriginPreviewHandoff(handoffID: UUID) async {
        guard let record = pendingHandoffs.removeValue(forKey: handoffID) else { return }
        lastLifecycleEvent = .handoffFailed
        TTPreviewPlaybackManager.stopAll()
        await record.release()
    }

    /// Called by `ExplorerItemInspectorView` once the inspector's `.task` has acquired its own `activePreviewLease`
    /// for `(windowID, key)`. Strictly isolates consumption to `windowID` (and optional `handoffID`), never releasing
    /// other browser windows' bridge leases for the same `key`.
    @discardableResult
    public func consumeOriginRestoredLease(
        forWindowID windowID: UUID,
        key: String,
        handoffID: UUID? = nil,
        reclaimImmediatelyIfIdle: Bool = false
    ) async -> Bool {
        guard let existing = originWindowRestoredLeases[windowID],
              existing.lease.key == key,
              handoffID == nil || existing.handoffID == handoffID else {
            return false
        }
        originWindowRestoredLeases.removeValue(forKey: windowID)
        await existing.cacheManager.releaseLease(existing.lease, reclaimImmediatelyIfIdle: reclaimImmediatelyIfIdle)
        return true
    }

    /// Lifecycle 3: Notifies that the origin browser window was closed. Standalone playback continues uninterrupted.
    public func notifyOriginBrowserWindowClosed(windowID: UUID) {
        if let restored = originWindowRestoredLeases.removeValue(forKey: windowID) {
            Task { await restored.cacheManager.releaseLease(restored.lease, reclaimImmediatelyIfIdle: true) }
        }
        markOriginWindowClosedIfMatching(windowID: windowID)
    }

    /// Async variant of `notifyOriginBrowserWindowClosed` that deterministically awaits bridge lease release.
    public func notifyOriginBrowserWindowClosedAsync(windowID: UUID) async {
        if let restored = originWindowRestoredLeases.removeValue(forKey: windowID) {
            await restored.cacheManager.releaseLease(restored.lease, reclaimImmediatelyIfIdle: true)
        }
        markOriginWindowClosedIfMatching(windowID: windowID)
    }

    private func markOriginWindowClosedIfMatching(windowID: UUID) {
        guard var session = activeSession, session.originBrowserWindowID == windowID else { return }
        session.isOriginWindowClosed = true
        activeSession = session
        lastLifecycleEvent = .originBrowserWindowClosed
    }

    /// Lifecycle 4: Notifies that the origin browser window changed its file selection. Standalone playback continues uninterrupted.
    public func notifyOriginSelectionChanged(windowID: UUID, newSelectedItem: DiskItemInfo?) {
        if let restored = originWindowRestoredLeases[windowID],
           newSelectedItem?.path != restored.selectedPath {
            originWindowRestoredLeases.removeValue(forKey: windowID)
            Task { await restored.cacheManager.releaseLease(restored.lease, reclaimImmediatelyIfIdle: true) }
        }
        guard var session = activeSession, session.originBrowserWindowID == windowID else { return }
        let originPath = session.originSelectedItem?.path ?? session.item.url.path
        if newSelectedItem?.path != originPath {
            session.hasOriginSelectionChanged = true
            activeSession = session
            lastLifecycleEvent = .originSelectionChanged
        } else {
            session.hasOriginSelectionChanged = false
            activeSession = session
        }
    }

    /// Lifecycle 5: Enters or exits macOS system fullscreen on the standalone `NSWindow` without affecting browser windows.
    public func toggleSystemFullScreen() {
        guard activeSession != nil else { return }
        if let playerWindow {
            playerWindow.toggleFullScreen(nil)
        } else {
            let currentlyFull = activeSession?.isInSystemFullScreen ?? false
            activeSession?.isInSystemFullScreen = !currentlyFull
            lastLifecycleEvent = (!currentlyFull) ? .enteredSystemFullScreen : .exitedSystemFullScreen
        }
    }
}
