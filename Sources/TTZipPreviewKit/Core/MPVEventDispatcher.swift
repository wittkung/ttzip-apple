// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import os.log

/// Swift 6 Actor-isolated event dispatcher providing AsyncStream multicast and high-frequency debouncing.
public actor MPVEventDispatcher {
    /// Shared singleton instance bound to the shared core engine.
    public static let shared = MPVEventDispatcher()

    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVEventDispatcher")
    private let engine: MPVCoreEngine

    private var currentState: MPVPlaybackStateSnapshot = MPVPlaybackStateSnapshot()
    private var currentMetadata: MPVMediaMetadataSnapshot = MPVMediaMetadataSnapshot()

    private var eventContinuations: [UUID: AsyncStream<MPVEvent>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<MPVPlaybackStateSnapshot>.Continuation] = [:]

    private var lastBroadcastInstant: ContinuousClock.Instant = .now
    private var throttleDuration: Duration = .milliseconds(16) // Default ~60 FPS
    private var debounceTask: Task<Void, Never>? = nil
    private var hasPendingStateFlush: Bool = false
    private var isStarted: Bool = false
    private var wakeupListenerID: UUID? = nil

    /// Initializes the event dispatcher with a dedicated or shared MPVCoreEngine.
    public init(engine: MPVCoreEngine = .shared) {
        self.engine = engine
    }

    deinit {
        debounceTask?.cancel()
        for cont in eventContinuations.values { cont.finish() }
        for cont in stateContinuations.values { cont.finish() }
    }

    /// Attaches the dispatcher to the core engine's wakeup notification pipeline.
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        let id = await engine.addWakeupListener { [weak self] in
            guard let self else { return }
            Task {
                await self.drainAndDispatch()
            }
        }
        self.wakeupListenerID = id
        await drainAndDispatch()
        logger.info("MPVEventDispatcher started and hooked to MPVCoreEngine")
    }

    /// Stops the event dispatcher, cancelling active timers and finishing broadcast streams.
    public func stop() async {
        isStarted = false
        if let id = wakeupListenerID {
            await engine.removeWakeupListener(id: id)
            wakeupListenerID = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
        for cont in eventContinuations.values { cont.finish() }
        for cont in stateContinuations.values { cont.finish() }
        eventContinuations.removeAll()
        stateContinuations.removeAll()
        logger.info("MPVEventDispatcher stopped")
    }

    /// Configures the target aggregation frame rate for high-frequency playback state updates.
    public func setTargetFPS(_ fps: Int) {
        let safeFPS = max(1, min(120, fps))
        self.throttleDuration = .milliseconds(1000 / safeFPS)
    }

    /// Returns the latest immutable playback state snapshot.
    public func getCurrentState() -> MPVPlaybackStateSnapshot {
        currentState
    }

    /// Returns the latest immutable media metadata snapshot.
    public func getCurrentMetadata() -> MPVMediaMetadataSnapshot {
        currentMetadata
    }

    /// Updates the cached media metadata and broadcasts notification if applicable.
    public func updateMetadata(_ metadata: MPVMediaMetadataSnapshot) {
        self.currentMetadata = metadata
    }

    /// Multicast asynchronous stream emitting discrete engine lifecycle and control events.
    public var eventStream: AsyncStream<MPVEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MPVEvent.self)
        let id = UUID()
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeEventContinuation(id: id)
            }
        }
        if !isStarted {
            Task { await self.start() }
        }
        return stream
    }

    /// Multicast asynchronous stream emitting debounced and throttled playback state snapshots.
    public var stateStream: AsyncStream<MPVPlaybackStateSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: MPVPlaybackStateSnapshot.self)
        let id = UUID()
        stateContinuations[id] = continuation
        continuation.yield(currentState)
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeStateContinuation(id: id)
            }
        }
        if !isStarted {
            Task { await self.start() }
        }
        return stream
    }

    /// Drains all pending events from the underlying core engine and dispatches them.
    public func drainAndDispatch() async {
        let events = await engine.drainEvents()
        guard !events.isEmpty else { return }
        handleBatchEvents(events)
    }

    /// Ingests and processes a batch of MPV events, updating internal state and broadcasting.
    public func handleBatchEvents(_ events: [MPVEvent]) {
        var needsImmediateStateFlush = false

        for event in events {
            for cont in eventContinuations.values {
                cont.yield(event)
            }

            switch event {
            case .fileLoaded:
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: 0.0,
                    duration: currentState.duration,
                    isPaused: currentState.isPaused,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: 0.0,
                    isEOF: false,
                    isBuffering: false
                )
                needsImmediateStateFlush = true

            case .playbackRestart:
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: false,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: false,
                    isBuffering: false
                )
                needsImmediateStateFlush = true

            case .seek(let position):
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: position,
                    duration: currentState.duration,
                    isPaused: currentState.isPaused,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: false,
                    isBuffering: currentState.isBuffering
                )
                needsImmediateStateFlush = true

            case .pause(let isPaused):
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: isPaused,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: currentState.isEOF,
                    isBuffering: currentState.isBuffering
                )
                needsImmediateStateFlush = true

            case .eof:
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.duration > 0 ? currentState.duration : currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: true,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: true,
                    isBuffering: false
                )
                needsImmediateStateFlush = true

            case .error:
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: true,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: false,
                    isBuffering: false
                )
                needsImmediateStateFlush = true

            case .propertyChange(let name, let value):
                applyPropertyChange(name: name, value: value)

            case .logMessage:
                break
            }
        }

        if needsImmediateStateFlush {
            flushState()
        } else if hasPendingStateFlush {
            scheduleThrottledFlush()
        }
    }

    private func applyPropertyChange(name: String, value: MPVPropertyValue) {
        hasPendingStateFlush = true
        switch name {
        case "time-pos":
            if case .double(let val) = value, val.isFinite, val >= 0 {
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: val,
                    duration: currentState.duration,
                    isPaused: currentState.isPaused,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: currentState.isEOF,
                    isBuffering: currentState.isBuffering
                )
            }
        case "duration":
            if case .double(let val) = value, val.isFinite, val > 0 {
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: val,
                    isPaused: currentState.isPaused,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: currentState.isEOF,
                    isBuffering: currentState.isBuffering
                )
            }
        case "pause":
            if case .flag(let val) = value {
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: val,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: currentState.isEOF,
                    isBuffering: currentState.isBuffering
                )
            }
        case "mute":
            if case .flag(let val) = value {
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: currentState.isPaused,
                    volume: currentState.volume,
                    isMuted: val,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: currentState.isEOF,
                    isBuffering: currentState.isBuffering
                )
            }
        case "volume":
            if case .double(let val) = value {
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: currentState.isPaused,
                    volume: max(0.0, min(1.0, val / 100.0)),
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: currentState.isEOF,
                    isBuffering: currentState.isBuffering
                )
            }
        case "cache-buffering-state":
            if case .int64(let val) = value {
                let fraction = max(0.0, min(1.0, Double(val) / 100.0))
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: currentState.isPaused,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: fraction,
                    isEOF: currentState.isEOF,
                    isBuffering: (val < 100 && !currentState.isPaused)
                )
            }
        case "core-idle":
            if case .flag(let val) = value {
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: currentState.isPaused,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: currentState.isEOF,
                    isBuffering: (val && !currentState.isPaused)
                )
            }
        case "eof-reached":
            if case .flag(let val) = value, val {
                currentState = MPVPlaybackStateSnapshot(
                    currentTime: currentState.currentTime,
                    duration: currentState.duration,
                    isPaused: true,
                    volume: currentState.volume,
                    isMuted: currentState.isMuted,
                    cacheProgress: currentState.cacheProgress,
                    isEOF: true,
                    isBuffering: false
                )
            }
        case "audio-codec-name":
            if case .string(let val) = value {
                currentMetadata = MPVMediaMetadataSnapshot(
                    videoCodec: currentMetadata.videoCodec,
                    audioCodec: val,
                    videoWidth: currentMetadata.videoWidth,
                    videoHeight: currentMetadata.videoHeight,
                    aspectRatio: currentMetadata.aspectRatio,
                    colorSpace: currentMetadata.colorSpace,
                    audioSampleRate: currentMetadata.audioSampleRate,
                    audioChannels: currentMetadata.audioChannels,
                    audioBitDepth: currentMetadata.audioBitDepth,
                    audioTracks: currentMetadata.audioTracks,
                    subtitleTracks: currentMetadata.subtitleTracks,
                    title: currentMetadata.title,
                    artist: currentMetadata.artist
                )
            }
        case "audio-params/samplerate":
            let sr: Int
            if case .int64(let val) = value {
                sr = Int(val)
            } else if case .double(let val) = value {
                sr = Int(val)
            } else {
                sr = currentMetadata.audioSampleRate
            }
            currentMetadata = MPVMediaMetadataSnapshot(
                videoCodec: currentMetadata.videoCodec,
                audioCodec: currentMetadata.audioCodec,
                videoWidth: currentMetadata.videoWidth,
                videoHeight: currentMetadata.videoHeight,
                aspectRatio: currentMetadata.aspectRatio,
                colorSpace: currentMetadata.colorSpace,
                audioSampleRate: sr,
                audioChannels: currentMetadata.audioChannels,
                audioBitDepth: currentMetadata.audioBitDepth,
                audioTracks: currentMetadata.audioTracks,
                subtitleTracks: currentMetadata.subtitleTracks,
                title: currentMetadata.title,
                artist: currentMetadata.artist
            )
        case "audio-params/channels":
            let chCount: Int
            if case .string(let val) = value {
                let lower = val.lowercased()
                if lower == "stereo" {
                    chCount = 2
                } else if lower == "mono" {
                    chCount = 1
                } else if lower.contains("5.1") {
                    chCount = 6
                } else if lower.contains("7.1") {
                    chCount = 8
                } else {
                    chCount = Int(val) ?? currentMetadata.audioChannels
                }
            } else if case .int64(let val) = value {
                chCount = Int(val)
            } else {
                chCount = currentMetadata.audioChannels
            }
            currentMetadata = MPVMediaMetadataSnapshot(
                videoCodec: currentMetadata.videoCodec,
                audioCodec: currentMetadata.audioCodec,
                videoWidth: currentMetadata.videoWidth,
                videoHeight: currentMetadata.videoHeight,
                aspectRatio: currentMetadata.aspectRatio,
                colorSpace: currentMetadata.colorSpace,
                audioSampleRate: currentMetadata.audioSampleRate,
                audioChannels: chCount,
                audioBitDepth: currentMetadata.audioBitDepth,
                audioTracks: currentMetadata.audioTracks,
                subtitleTracks: currentMetadata.subtitleTracks,
                title: currentMetadata.title,
                artist: currentMetadata.artist
            )
        case "video-params/w":
            let w: Int
            if case .int64(let val) = value {
                w = Int(val)
            } else if case .double(let val) = value {
                w = Int(val)
            } else {
                w = currentMetadata.videoWidth
            }
            currentMetadata = MPVMediaMetadataSnapshot(
                videoCodec: currentMetadata.videoCodec,
                audioCodec: currentMetadata.audioCodec,
                videoWidth: w,
                videoHeight: currentMetadata.videoHeight,
                aspectRatio: currentMetadata.aspectRatio,
                colorSpace: currentMetadata.colorSpace,
                audioSampleRate: currentMetadata.audioSampleRate,
                audioChannels: currentMetadata.audioChannels,
                audioBitDepth: currentMetadata.audioBitDepth,
                audioTracks: currentMetadata.audioTracks,
                subtitleTracks: currentMetadata.subtitleTracks,
                title: currentMetadata.title,
                artist: currentMetadata.artist
            )
        case "video-params/h":
            let h: Int
            if case .int64(let val) = value {
                h = Int(val)
            } else if case .double(let val) = value {
                h = Int(val)
            } else {
                h = currentMetadata.videoHeight
            }
            currentMetadata = MPVMediaMetadataSnapshot(
                videoCodec: currentMetadata.videoCodec,
                audioCodec: currentMetadata.audioCodec,
                videoWidth: currentMetadata.videoWidth,
                videoHeight: h,
                aspectRatio: currentMetadata.aspectRatio,
                colorSpace: currentMetadata.colorSpace,
                audioSampleRate: currentMetadata.audioSampleRate,
                audioChannels: currentMetadata.audioChannels,
                audioBitDepth: currentMetadata.audioBitDepth,
                audioTracks: currentMetadata.audioTracks,
                subtitleTracks: currentMetadata.subtitleTracks,
                title: currentMetadata.title,
                artist: currentMetadata.artist
            )
        default:
            break
        }
    }

    private func scheduleThrottledFlush() {
        let now = ContinuousClock.now
        let elapsed = now - lastBroadcastInstant
        if elapsed >= throttleDuration {
            flushState()
        } else if debounceTask == nil {
            let remaining = throttleDuration - elapsed
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled else { return }
                await self?.flushPendingState()
            }
        }
    }

    private func flushPendingState() {
        debounceTask = nil
        if hasPendingStateFlush {
            flushState()
        }
    }

    private func flushState() {
        hasPendingStateFlush = false
        debounceTask?.cancel()
        debounceTask = nil
        lastBroadcastInstant = .now
        for cont in stateContinuations.values {
            cont.yield(currentState)
        }
    }

    private func addEventContinuation(id: UUID, continuation: AsyncStream<MPVEvent>.Continuation) {
        eventContinuations[id] = continuation
        if !isStarted {
            Task { await self.start() }
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func addStateContinuation(id: UUID, continuation: AsyncStream<MPVPlaybackStateSnapshot>.Continuation) {
        stateContinuations[id] = continuation
        continuation.yield(currentState)
        if !isStarted {
            Task { await self.start() }
        }
    }

    private func removeStateContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }
}
