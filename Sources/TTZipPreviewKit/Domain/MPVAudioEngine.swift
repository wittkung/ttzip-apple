// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CoreGraphics
import os.log
import TTZipCore
import TTZipUI

/// High-performance headless audio playback domain state machine.
///
/// Designed with strict physical insulation from any Viewport or CALayer concepts,
/// providing pure reactive state distribution (`@Observable`) and telemetry synchronization
/// directly backed by `MPVCoreEngine.shared` and `AudioWaveformExtractor.shared`.
@MainActor
@Observable
public final class MPVAudioEngine {
    /// Shared singleton instance for unified headless audio playback orchestration.
    public static let shared = MPVAudioEngine()

    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVAudioEngine")

    // MARK: - Reactive Playback State

    public private(set) var currentURL: URL? = nil
    public private(set) var currentTime: Double = 0.0
    public private(set) var duration: Double = 0.0
    public private(set) var isPlaying: Bool = false
    public private(set) var isBuffering: Bool = false
    public private(set) var volume: Double = 1.0
    public private(set) var isMuted: Bool = false
    public private(set) var hasPlaybackError: Bool = false
    public private(set) var errorMessage: String? = nil

    // MARK: - DAW Acoustic & Waveform Telemetry

    public private(set) var waveformSamples: [CGFloat] = []
    public private(set) var isExtractingWaveform: Bool = false
    public private(set) var sampleRateFormatted: String = "--"
    public private(set) var channelsFormatted: String = "--"
    public private(set) var codecFormatted: String = "--"
    public private(set) var bitrateFormatted: String = "--"
    public private(set) var peakAmplitude: Float = 0.0
    public private(set) var metadata: MPVMediaMetadataSnapshot? = nil

    // MARK: - Internal Tasks & Streams

    private var activeWaveformTask: Task<Void, Never>? = nil
    private var stateObservationTask: Task<Void, Never>? = nil
    private var eventObservationTask: Task<Void, Never>? = nil

    public init() {
        startObservingDispatcher()
    }

    // MARK: - Primary Domain Operations

    /// Loads an audio file with instant UI state reset and non-blocking waveform extraction.
    ///
    /// - Parameters:
    ///   - url: Target audio file URL.
    ///   - autoPlay: Whether playback should start automatically upon demux completion.
    public func load(url: URL, autoPlay: Bool = true) {
        // Immediate UI reset for zero-flicker song transition
        activeWaveformTask?.cancel()
        currentURL = url
        currentTime = 0.0
        duration = 0.0
        isPlaying = autoPlay
        isBuffering = true
        hasPlaybackError = false
        errorMessage = nil
        waveformSamples = []
        isExtractingWaveform = true
        sampleRateFormatted = "--"
        channelsFormatted = "--"
        codecFormatted = "--"
        bitrateFormatted = "--"
        peakAmplitude = 0.0

        // 1. Asynchronous non-blocking acoustic waveform extraction
        activeWaveformTask = Task { [weak self, url] in
            let samples = await AudioWaveformExtractor.shared.extractWaveform(from: url, targetSampleCount: 1600)
            guard !Task.isCancelled else { return }
            self?.waveformSamples = samples
            self?.isExtractingWaveform = false
        }

        // 2. Headless engine file load request
        Task { [weak self] in
            guard let self else { return }
            do {
                try await MPVCoreEngine.shared.loadFile(url: url, replace: true, isAudioOnly: true)
                if !autoPlay {
                    try await MPVCoreEngine.shared.setProperty(name: "pause", value: true)
                }
            } catch {
                self.hasPlaybackError = true
                self.errorMessage = error.localizedDescription
                self.logger.error("Failed to load audio file in MPVCoreEngine: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resumes audio playback.
    public func play() {
        Task {
            do {
                try await MPVCoreEngine.shared.setProperty(name: "pause", value: false)
                self.isPlaying = true
            } catch {
                self.logger.error("Failed to play: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pauses audio playback.
    public func pause() {
        Task {
            do {
                try await MPVCoreEngine.shared.setProperty(name: "pause", value: true)
                self.isPlaying = false
            } catch {
                self.logger.error("Failed to pause: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Toggles between play and pause states.
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seeks to the specified timeline position in seconds.
    ///
    /// - Parameter seconds: Absolute destination position.
    public func seek(to seconds: Double) {
        currentTime = max(0.0, min(duration, seconds))
        Task {
            do {
                try await MPVCoreEngine.shared.sendCommand(["seek", String(format: "%.3f", seconds), "absolute"])
            } catch {
                self.logger.error("Failed to seek: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Relative seek forward or backward by delta seconds.
    ///
    /// - Parameter delta: Relative time offset in seconds.
    public func seekBy(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    /// Updates playback volume level.
    ///
    /// - Parameter value: Normalized volume level [0.0 ... 1.0].
    public func setVolume(_ value: Double) {
        let clamped = max(0.0, min(1.0, value))
        self.volume = clamped
        Task {
            do {
                try await MPVCoreEngine.shared.setProperty(name: "volume", value: clamped * 100.0)
            } catch {
                self.logger.error("Failed to set volume: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Sets or clears audio mute state.
    ///
    /// - Parameter muted: Boolean indicating mute state.
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
        Task {
            do {
                try await MPVCoreEngine.shared.setProperty(name: "mute", value: muted)
            } catch {
                self.logger.error("Failed to set mute: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Toggles between audio mute and unmute states.
    public func toggleMute() {
        setMuted(!isMuted)
    }

    /// Stops audio playback and resets engine timeline.
    public func stop() {
        isPlaying = false
        currentTime = 0.0
        Task {
            await MPVCoreEngine.shared.stop()
        }
    }

    // MARK: - Telemetry & Event Synchronization via MPVEventDispatcher

    private func startObservingDispatcher() {
        stateObservationTask?.cancel()
        stateObservationTask = Task { @MainActor [weak self] in
            let stream = await MPVEventDispatcher.shared.stateStream
            for await state in stream {
                guard let self, !Task.isCancelled else { break }
                self.applyStateSnapshot(state)
            }
        }

        eventObservationTask?.cancel()
        eventObservationTask = Task { @MainActor [weak self] in
            let stream = await MPVEventDispatcher.shared.eventStream
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.applyEvent(event)
            }
        }
    }

    private func applyStateSnapshot(_ state: MPVPlaybackStateSnapshot) {
        self.currentTime = state.currentTime
        if state.duration > 0.0 {
            self.duration = state.duration
        }
        self.isPlaying = !state.isPaused
        self.volume = state.volume
        self.isMuted = state.isMuted
        self.isBuffering = state.isBuffering
        if state.isEOF {
            self.isPlaying = false
            self.currentTime = self.duration > 0 ? self.duration : self.currentTime
        }
    }

    private func applyEvent(_ event: MPVEvent) {
        switch event {
        case .fileLoaded, .playbackRestart:
            self.isBuffering = false
            self.hasPlaybackError = false
            self.errorMessage = nil
        case .pause(let paused):
            self.isPlaying = !paused
        case .seek(let pos):
            self.currentTime = pos
        case .eof:
            self.isPlaying = false
            self.currentTime = self.duration
        case .error(let msg):
            self.hasPlaybackError = true
            self.errorMessage = msg
        case .propertyChange(let name, let value):
            applyTelemetryPropertyChange(name: name, value: value)
        case .logMessage:
            break
        }
    }

    private func applyTelemetryPropertyChange(name: String, value: MPVPropertyValue) {
        switch name {
        case "audio-codec-name":
            if case .string(let rawCodec) = value, !rawCodec.isEmpty {
                self.codecFormatted = MPVMetalPlayerStore.formatAudioCodecName(rawCodec)
            }
        case "audio-params/samplerate":
            let sr: Double?
            if case .double(let val) = value, val > 0 {
                sr = val
            } else if case .int64(let val) = value, val > 0 {
                sr = Double(val)
            } else {
                sr = nil
            }
            if let sr {
                self.sampleRateFormatted = sr >= 1_000_000 ? String(format: "%.4f MHz", sr / 1_000_000.0) : String(format: "%.1f kHz", sr / 1000.0)
            }
        case "audio-params/channels":
            if case .string(let channels) = value, !channels.isEmpty {
                self.channelsFormatted = channels.capitalized
            }
        case "audio-bitrate":
            let br: Double?
            if case .double(let val) = value, val > 0 {
                br = val
            } else if case .int64(let val) = value, val > 0 {
                br = Double(val)
            } else {
                br = nil
            }
            if let br {
                self.bitrateFormatted = String(format: "%.0f kbps", br / 1000.0)
            }
        default:
            break
        }
    }
}
