// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipCore
import TTZipPreviewKit

extension StandalonePlaybackWindowManager {
    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === playerWindow else {
            return
        }
        playerWindow = nil
        if !isReturningToOriginPreview && activeSession != nil {
            _ = requestReturnToOriginPreview()
            return
        }
        finalizeSessionTeardown(stopPlayback: true)
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        guard let win = notification.object as? NSWindow,
              win === playerWindow else {
            return
        }
        activeSession?.isInSystemFullScreen = true
        lastLifecycleEvent = .enteredSystemFullScreen
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        guard let win = notification.object as? NSWindow,
              win === playerWindow else {
            return
        }
        activeSession?.isInSystemFullScreen = false
        lastLifecycleEvent = .exitedSystemFullScreen
    }

    // MARK: - Origin Bridge Lease & Teardown

    func resolveTargetBrowserWindowID(
        for session: StandalonePlaybackSessionState
    ) -> UUID? {
        guard !session.isOriginWindowClosed,
              let originID = session.originBrowserWindowID,
              Self.isOriginBrowserWindowRegistered?(originID) == true else {
            return nil
        }
        return originID
    }

    func isOriginHandoffValid(
        targetWindowID: UUID,
        handoffID: UUID
    ) -> Bool {
        guard !Task.isCancelled,
              !shouldSimulateOriginTakeoverFailure,
              pendingHandoffs[handoffID] != nil else {
            return false
        }
        return Self.isOriginBrowserWindowRegistered?(targetWindowID) == true
    }

    func fetchOriginBridgeLease(
        key: String,
        record: StandalonePlaybackHandoffRecord,
        consumerID: UUID
    ) async -> PreviewCacheLease? {
        if let hit = await record.cacheManager.acquireCachedURL(
            forKey: key,
            consumerID: consumerID
        ) {
            return hit.lease
        }
        return await record.cacheManager.acquireIndependentPlayerLease(
            forFileURL: record.mediaURL,
            consumerID: consumerID
        )
    }

    func commitOriginBridgeLeaseIfValid(
        _ originLease: PreviewCacheLease,
        for session: StandalonePlaybackSessionState,
        targetWindowID: UUID,
        record: StandalonePlaybackHandoffRecord
    ) -> Bool {
        guard isOriginHandoffValid(targetWindowID: targetWindowID, handoffID: record.handoffID),
              originWindowRestoredLeases[targetWindowID] == nil else {
            return false
        }
        let selectedPath = session.originSelectedItem?.path ?? session.item.url.path
        originWindowRestoredLeases[targetWindowID] = OriginWindowRestoredLeaseRecord(
            windowID: targetWindowID,
            handoffID: record.handoffID,
            selectedPath: selectedPath,
            lease: originLease,
            cacheManager: record.cacheManager
        )
        return true
    }

    func acquireOriginRestoredLeaseIfNeeded(
        for session: StandalonePlaybackSessionState,
        targetWindowID: UUID,
        record: StandalonePlaybackHandoffRecord
    ) async -> Bool {
        let expectedReplacedHandoffID = originWindowRestoredLeases[targetWindowID]?.handoffID
        let requiredKey = Self.resolvedCacheKey(for: session.item) ?? record.cacheLease?.key
        guard let key = requiredKey else {
            if let hook = onWillCommitOriginBridgeLeaseHook {
                await hook(targetWindowID, record.handoffID)
            }
            return isOriginHandoffValid(targetWindowID: targetWindowID, handoffID: record.handoffID)
        }
        guard let originLease = await fetchOriginBridgeLease(
            key: key,
            record: record,
            consumerID: UUID()
        ) else {
            return false
        }
        if let hook = onWillCommitOriginBridgeLeaseHook {
            await hook(targetWindowID, record.handoffID)
        }
        if isOriginHandoffValid(targetWindowID: targetWindowID, handoffID: record.handoffID),
           let existing = originWindowRestoredLeases[targetWindowID],
           existing.handoffID == expectedReplacedHandoffID {
            originWindowRestoredLeases.removeValue(forKey: targetWindowID)
            await existing.cacheManager.releaseLease(existing.lease, reclaimImmediatelyIfIdle: true)
            if let releaseHook = onDidReleasePreviousOriginBridgeLeaseHook {
                await releaseHook(targetWindowID, record.handoffID)
            }
        }
        guard commitOriginBridgeLeaseIfValid(
            originLease,
            for: session,
            targetWindowID: targetWindowID,
            record: record
        ) else {
            await record.cacheManager.releaseLease(originLease, reclaimImmediatelyIfIdle: true)
            return false
        }
        return true
    }

    func finalizeSessionTeardown(stopPlayback: Bool) {
        let oldResources = activeSessionResources
        activeSessionResources = nil
        activeSession = nil
        isReturningToOriginPreview = false
        if stopPlayback {
            lastLifecycleEvent = .closedStandalonePlayer
            TTPreviewPlaybackManager.stopAll()
        }
        if let oldResources {
            Task { @MainActor in
                await oldResources.release()
            }
        }
    }

    /// Async teardown entry point that awaits deterministic F4 lease release before returning.
    public func closeStandaloneWindowAsync(stopPlayback: Bool = true) async {
        openRequestGeneration &+= 1
        inFlightOpenTask?.cancel()
        inFlightOpenTask = nil
        isReturningToOriginPreview = !stopPlayback
        if let window = playerWindow {
            playerWindow = nil
            window.delegate = nil
            window.close()
        }
        let oldResources = activeSessionResources
        activeSessionResources = nil
        activeSession = nil
        isReturningToOriginPreview = false
        if stopPlayback {
            lastLifecycleEvent = .closedStandalonePlayer
            TTPreviewPlaybackManager.stopAll()
        }
        if let oldResources {
            await oldResources.release()
        }
    }

    /// Resets active sessions, pending handoffs, restored origin leases, and test hooks deterministically.
    public func resetForTesting() async {
        onWillCommitAcquiredLeaseHook = nil
        onWillCommitOriginBridgeLeaseHook = nil
        onDidReleasePreviousOriginBridgeLeaseHook = nil
        shouldSimulateOriginTakeoverFailure = false
        windowFactory = nil
        windowPresentationHandler = nil
        await closeStandaloneWindowAsync(stopPlayback: false)
        let handoffIDs = Array(pendingHandoffs.keys)
        for id in handoffIDs {
            await failOriginPreviewHandoff(handoffID: id)
        }
        let restoredEntries = Array(originWindowRestoredLeases.values)
        originWindowRestoredLeases.removeAll()
        for entry in restoredEntries {
            await entry.cacheManager.releaseLease(entry.lease, reclaimImmediatelyIfIdle: true)
        }
        createdWindowCount = 0
        windowPresentationRequestCount = 0
        lastLifecycleEvent = nil
    }

    // MARK: - Standard NSWindow Construction

    func ensureAndFocusNSWindow(for session: StandalonePlaybackSessionState) {
        windowPresentationRequestCount += 1
        let window: StandalonePlaybackNSWindow
        if let existing = playerWindow {
            window = existing
        } else {
            let created = windowFactory?(session) ?? Self.makeStandardPlayerWindow(title: session.item.name)
            created.delegate = self
            playerWindow = created
            createdWindowCount += 1
            window = created
        }
        if let windowPresentationHandler {
            window.configureAndFocus(for: session, manager: self, activateInForeground: false)
            windowPresentationHandler(window, session)
        } else {
            window.configureAndFocus(for: session, manager: self)
        }
    }

    public static func makeStandardPlayerWindow(title: String) -> StandalonePlaybackNSWindow {
        StandalonePlaybackNSWindow.makeStandardPlayerWindow(title: title)
    }
}
