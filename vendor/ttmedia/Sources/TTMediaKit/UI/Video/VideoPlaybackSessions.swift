// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Foundation
import Observation
import os

@MainActor
@Observable
internal final class VideoPlaybackSessions {
    static let shared = VideoPlaybackSessions()
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "VideoPlaybackSessions")
    private(set) var current: VideoPlaybackSession?
    private var releaseTask: Task<Void, Never>?
    private struct ViewportBinding {
        var sessionID: UUID
        var generation: UInt64
        let onSessionReplaced: @MainActor (VideoPlaybackSession) -> Void
    }

    private var nextBindingGeneration: UInt64 = 0
    private var viewportBindings: [UUID: ViewportBinding] = [:]
    var workerClientProvider: @MainActor () -> MediaWorkerXPCClient = { MediaWorkerXPCClient.makeDefault() }

    var activeBoundViewportIDs: Set<UUID> {
        Set(viewportBindings.keys)
    }

    func boundSessionID(for viewportID: UUID) -> UUID? {
        viewportBindings[viewportID]?.sessionID
    }

    func bindingGeneration(for viewportID: UUID) -> UInt64? {
        viewportBindings[viewportID]?.generation
    }

    @discardableResult
    func bindViewport(
        viewportID: UUID,
        sessionID: UUID? = nil,
        onSessionReplaced: @escaping @MainActor (VideoPlaybackSession) -> Void
    ) -> UInt64 {
        nextBindingGeneration &+= 1
        let generation = nextBindingGeneration
        let resolvedSessionID = sessionID ?? current?.sessionID ?? UUID()
        viewportBindings[viewportID] = ViewportBinding(
            sessionID: resolvedSessionID,
            generation: generation,
            onSessionReplaced: onSessionReplaced
        )
        return generation
    }

    @discardableResult
    func unbindViewport(
        viewportID: UUID,
        sessionID: UUID? = nil,
        generation: UInt64? = nil
    ) -> Bool {
        guard let existing = viewportBindings[viewportID] else { return false }
        if let sessionID, existing.sessionID != sessionID {
            return false
        }
        if let generation, existing.generation != generation {
            return false
        }
        viewportBindings.removeValue(forKey: viewportID)
        return true
    }

    private func alignCallerViewportBinding(viewportID: UUID, sessionID: UUID) {
        guard var binding = viewportBindings[viewportID], binding.sessionID != sessionID else { return }
        nextBindingGeneration &+= 1
        binding.sessionID = sessionID
        binding.generation = nextBindingGeneration
        viewportBindings[viewportID] = binding
    }

    private func purgeBindings(forSessionID sessionID: UUID) {
        let staleKeys = viewportBindings.compactMap { key, value in
            value.sessionID == sessionID ? key : nil
        }
        for key in staleKeys {
            viewportBindings.removeValue(forKey: key)
        }
    }

    func claim(
        url: URL,
        viewportID: UUID,
        isFullScreen: Bool = false,
        promoteToPresenter: Bool = true,
        restart: Bool = false,
        caller: String = "claim"
    ) -> VideoPlaybackSession {
        releaseTask?.cancel()
        releaseTask = nil
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if !restart, let current, !current.isStopped, current.canonicalURL == canonical {
            current.acquireViewport(
                viewportID,
                isFullScreen: isFullScreen,
                promoteToPresenter: promoteToPresenter,
                caller: caller
            )
            alignCallerViewportBinding(viewportID: viewportID, sessionID: current.sessionID)
            logger.info(
                "[PlaybackLifecycle] CLAIM_REUSE session=\(current.sessionID.uuidString, privacy: .public) viewport=\(viewportID.uuidString, privacy: .public) url=\(url.lastPathComponent, privacy: .public) isFullScreen=\(isFullScreen) activeViewports=\(current.activeViewports.count) presenter=\(current.activePresenterViewportID?.uuidString ?? "none", privacy: .public) caller=\(caller, privacy: .public)"
            )
            return current
        }

        let session = VideoPlaybackSession(url: url)
        session.workerClientProvider = workerClientProvider
        if let previous = current {
            if restart, previous.canonicalURL == canonical {
                migrateContextOnRestart(from: previous, to: session, primaryViewportID: viewportID)
            }
            if !previous.isStopped {
                previous.stop(reason: restart ? "claim_restart:\(caller)" : "claim_replaced_url:\(caller)")
            }
        }
        session.acquireViewport(
            viewportID,
            isFullScreen: isFullScreen,
            promoteToPresenter: promoteToPresenter,
            caller: caller
        )
        alignCallerViewportBinding(viewportID: viewportID, sessionID: session.sessionID)
        current = session
        if restart {
            notifyBoundViewportsOfRestart(newSession: session, initiatorViewportID: viewportID)
        }
        logger.info(
            "[PlaybackLifecycle] CLAIM_NEW session=\(session.sessionID.uuidString, privacy: .public) viewport=\(viewportID.uuidString, privacy: .public) url=\(url.lastPathComponent, privacy: .public) isFullScreen=\(isFullScreen) restart=\(restart) activeViewports=\(session.activeViewports.count) presenter=\(session.activePresenterViewportID?.uuidString ?? "none", privacy: .public) caller=\(caller, privacy: .public)"
        )
        return session
    }

    private func migrateContextOnRestart(
        from previous: VideoPlaybackSession,
        to next: VideoPlaybackSession,
        primaryViewportID: UUID
    ) {
        next.restorePreservedContext(from: previous)
        for existingViewport in previous.orderedActiveViewports where existingViewport != primaryViewportID {
            let wasFullScreen = previous.isViewportFullScreen(existingViewport)
            next.acquireViewport(
                existingViewport,
                isFullScreen: wasFullScreen,
                promoteToPresenter: wasFullScreen,
                caller: "restart_preserve"
            )
        }
    }

    private func notifyBoundViewportsOfRestart(newSession: VideoPlaybackSession, initiatorViewportID: UUID) {
        for activeViewport in newSession.orderedActiveViewports {
            guard var binding = viewportBindings[activeViewport] else { continue }
            nextBindingGeneration &+= 1
            binding.sessionID = newSession.sessionID
            binding.generation = nextBindingGeneration
            viewportBindings[activeViewport] = binding
            binding.onSessionReplaced(newSession)
            if activeViewport != initiatorViewportID {
                logger.info(
                    "[PlaybackLifecycle] REBIND_VIEWPORT session=\(newSession.sessionID.uuidString, privacy: .public) viewport=\(activeViewport.uuidString, privacy: .public) generation=\(binding.generation) initiator=\(initiatorViewportID.uuidString, privacy: .public)"
                )
            }
        }
    }

    func claim(url: URL, owner: UUID, restart: Bool = false) -> VideoPlaybackSession {
        claim(url: url, viewportID: owner, isFullScreen: false, promoteToPresenter: true, restart: restart, caller: "legacy_claim")
    }

    func release(sessionID: UUID, viewportID: UUID, caller: String = "release") {
        guard let current, current.sessionID == sessionID else {
            let removedStaleBinding = unbindViewport(viewportID: viewportID, sessionID: sessionID)
            logger.info(
                "[PlaybackLifecycle] RELEASE_IGNORED_STALE_SESSION targetSession=\(sessionID.uuidString, privacy: .public) currentSession=\(self.current?.sessionID.uuidString ?? "none", privacy: .public) viewport=\(viewportID.uuidString, privacy: .public) removedStaleBinding=\(removedStaleBinding) caller=\(caller, privacy: .public)"
            )
            return
        }
        unbindViewport(viewportID: viewportID, sessionID: sessionID)
        let becameEmpty = current.releaseViewport(viewportID, caller: caller)
        guard becameEmpty else {
            logger.info(
                "[PlaybackLifecycle] RELEASE_KEPT_ALIVE session=\(current.sessionID.uuidString, privacy: .public) departedViewport=\(viewportID.uuidString, privacy: .public) remainingViewports=\(current.activeViewports.count) presenter=\(current.activePresenterViewportID?.uuidString ?? "none", privacy: .public) caller=\(caller, privacy: .public)"
            )
            return
        }

        let targetSessionID = current.sessionID
        releaseTask?.cancel()
        logger.info(
            "[PlaybackLifecycle] RELEASE_SCHEDULE_GRACE session=\(targetSessionID.uuidString, privacy: .public) lastViewport=\(viewportID.uuidString, privacy: .public) caller=\(caller, privacy: .public)"
        )
        releaseTask = Task { @MainActor [weak self] in
            // Bridge the bounded SwiftUI transition without tying resource life to onDisappear order.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self,
                  let active = self.current,
                  active.sessionID == targetSessionID,
                  active.activeViewports.isEmpty else {
                return
            }
            active.stop(reason: "grace_period_expired_no_active_viewports:last=\(viewportID.uuidString)")
            self.purgeBindings(forSessionID: targetSessionID)
            self.current = nil
            self.releaseTask = nil
        }
    }

    func release(owner: UUID) {
        guard let current else { return }
        release(sessionID: current.sessionID, viewportID: owner, caller: "legacy_release")
    }
}

// MARK: - W1 Cross-Window Session Handle & Continuation Bridge (Contract v1)

/// Opaque, Sendable handle representing an active `VideoPlaybackSession` that can be handed off
/// across Inspector, Full-Window Immersive Browser, and Detached Window viewports without recreating the player.
public struct VideoPlaybackSessionHandle: Sendable, Equatable, Hashable, Identifiable {
    public static let contractVersion = "v1"

    public let sessionID: UUID
    public let canonicalURL: URL
    public let sourceURL: URL

    public var id: UUID { sessionID }

    public init(sessionID: UUID, canonicalURL: URL, sourceURL: URL) {
        self.sessionID = sessionID
        self.canonicalURL = canonicalURL
        self.sourceURL = sourceURL
    }
}

/// Verified outcome of a W1 cross-window session handoff, proving exact `sessionID` continuity without URL-only matching or fixed sleep delays.
public struct VideoPlaybackSessionHandoffResult: Sendable, Equatable {
    public let didHandoff: Bool
    public let sessionID: UUID
    public let targetViewportID: UUID
    public let activePresenterViewportID: UUID?
    public let currentTimeSeconds: Double
    public let userPlaybackIntent: Bool
    public let playbackRate: Float

    public init(
        didHandoff: Bool,
        sessionID: UUID,
        targetViewportID: UUID,
        activePresenterViewportID: UUID?,
        currentTimeSeconds: Double,
        userPlaybackIntent: Bool,
        playbackRate: Float
    ) {
        self.didHandoff = didHandoff
        self.sessionID = sessionID
        self.targetViewportID = targetViewportID
        self.activePresenterViewportID = activePresenterViewportID
        self.currentTimeSeconds = currentTimeSeconds
        self.userPlaybackIntent = userPlaybackIntent
        self.playbackRate = playbackRate
    }
}

/// Public façade for W1 window hosts to acquire, hand off, and release video playback sessions
/// without re-initializing decoders or losing playback progress, rate, audio track, or subtitles.
@MainActor
public enum VideoPlaybackSessionBridge {
    public static let contractVersion = "v1"

    /// Acquires or continues an existing active session for the given URL and binds the viewport.
    public static func acquireSessionHandle(
        for url: URL,
        viewportID: UUID,
        isFullScreen: Bool = false,
        promoteToPresenter: Bool = true,
        caller: String = "w1_acquire"
    ) -> VideoPlaybackSessionHandle {
        let session = VideoPlaybackSessions.shared.claim(
            url: url,
            viewportID: viewportID,
            isFullScreen: isFullScreen,
            promoteToPresenter: promoteToPresenter,
            restart: false,
            caller: caller
        )
        return session.handle
    }

    /// Returns the active session handle if one is currently alive for the given URL.
    public static func activeSessionHandle(for url: URL) -> VideoPlaybackSessionHandle? {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let current = VideoPlaybackSessions.shared.current,
              !current.isStopped,
              current.canonicalURL == canonical else {
            return nil
        }
        return current.handle
    }

    /// Performs a synchronous, deterministic handoff of the exact session identified by `handle.sessionID`
    /// to `viewportID` without recreating the player or relying on URL-only matching.
    public static func performHandoff(
        _ handle: VideoPlaybackSessionHandle,
        toViewportID viewportID: UUID,
        isFullScreen: Bool,
        promoteToPresenter: Bool = true,
        caller: String = "w1_handoff"
    ) -> VideoPlaybackSessionHandoffResult? {
        guard let current = VideoPlaybackSessions.shared.current,
              !current.isStopped,
              current.sessionID == handle.sessionID else {
            return nil
        }
        current.acquireViewport(
            viewportID,
            isFullScreen: isFullScreen,
            promoteToPresenter: promoteToPresenter,
            caller: caller
        )
        let currentSec = CMTimeGetSeconds(current.currentTime)
        return VideoPlaybackSessionHandoffResult(
            didHandoff: true,
            sessionID: current.sessionID,
            targetViewportID: viewportID,
            activePresenterViewportID: current.activePresenterViewportID,
            currentTimeSeconds: currentSec.isFinite ? max(0.0, currentSec) : 0.0,
            userPlaybackIntent: current.userPlaybackIntent,
            playbackRate: current.playbackRate
        )
    }

    /// Hands off an existing session identified by `handle.sessionID` to a target window/viewport without recreating the player.
    /// Returns `true` only if the underlying session with the exact `sessionID` was alive and attached to `viewportID`.
    @discardableResult
    public static func handoffSession(
        _ handle: VideoPlaybackSessionHandle,
        toViewportID viewportID: UUID,
        isFullScreen: Bool,
        promoteToPresenter: Bool = true,
        caller: String = "w1_handoff"
    ) -> Bool {
        performHandoff(
            handle,
            toViewportID: viewportID,
            isFullScreen: isFullScreen,
            promoteToPresenter: promoteToPresenter,
            caller: caller
        )?.didHandoff ?? false
    }

    /// Releases a viewport's claim on the session handle.
    public static func releaseViewport(
        handle: VideoPlaybackSessionHandle,
        viewportID: UUID,
        caller: String = "w1_release"
    ) {
        VideoPlaybackSessions.shared.release(
            sessionID: handle.sessionID,
            viewportID: viewportID,
            caller: caller
        )
    }
}
