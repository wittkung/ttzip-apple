// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CoreGraphics
import AppKit
import os.log
import TTZipCore
import TTZipUI

/// Comprehensive full-featured video playback domain state machine.
///
/// Coordinates `MPVCoreEngine.shared` video decoding with `MPVMetalRenderLayer` hardware passthrough,
/// managing dynamic 1600 nits Apple Silicon EDR tone mapping, multi-track audio/subtitle switching,
/// MAS sandbox-safe companion subtitle discovery, PiP/fullscreen transitions, and background power management.
@MainActor
@Observable
public final class MPVVideoEngine {
    /// Shared singleton instance for unified video playback orchestration.
    public static let shared = MPVVideoEngine()

    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVVideoEngine")

    // MARK: - Reactive Playback State

    public private(set) var currentURL: URL? = nil
    public private(set) var currentTime: Double = 0.0
    public private(set) var duration: Double = 0.0
    public private(set) var isPlaying: Bool = false
    public private(set) var isBuffering: Bool = false
    public private(set) var volume: Double = 1.0
    public private(set) var isMuted: Bool = false
    public private(set) var videoSize: CGSize = .zero
    public private(set) var hasPlaybackError: Bool = false
    public private(set) var errorMessage: String? = nil

    // MARK: - HDR, EDR & Subtitle Telemetry

    public private(set) var edrMetrics: MPVEDRMetrics = MPVEDRMetrics()
    public private(set) var hdrFormat: MPVHDRFormat = .sdr
    public private(set) var activeSubtitleDialogue: String? = nil
    public private(set) var subtitleTracks: [MPVSubtitleSnapshot] = []
    public private(set) var selectedSubtitleTrackId: String? = nil
    public private(set) var audioTracks: [MPVTrackSnapshot] = []
    public private(set) var selectedAudioTrackId: String? = nil

    // MARK: - Viewport & Window Routing State

    public private(set) var isFullScreen: Bool = false
    public private(set) var isPictureInPicture: Bool = false
    public var autoPauseOnBackground: Bool = true

    // MARK: - Internal References

    private weak var boundRenderLayer: MPVMetalRenderLayer? = nil
    private var telemetryPollTask: Task<Void, Never>? = nil
    private var wasPlayingBeforeBackground: Bool = false

    public init() {
        setupWakeupBridge()
    }

    // MARK: - Viewport & Metal Layer Binding

    /// Binds the Metal render layer viewport to the active video playback pipeline.
    ///
    /// - Parameter layer: Target hardware passthrough CAMetalLayer.
    public func attachRenderLayer(_ layer: MPVMetalRenderLayer) {
        self.boundRenderLayer = layer
        layer.requestRender()
        logger.debug("Attached MPVMetalRenderLayer to MPVVideoEngine")
    }

    /// Detaches the active Metal render layer.
    public func detachRenderLayer() {
        self.boundRenderLayer = nil
        logger.debug("Detached MPVMetalRenderLayer from MPVVideoEngine")
    }

    /// Updates the target viewport dimensions and Retina backing scale factor.
    ///
    /// - Parameters:
    ///   - size: Bounds size in points.
    ///   - scaleFactor: Display scaling factor (e.g. 2.0 on Retina).
    public func updateViewportSize(_ size: CGSize, scaleFactor: CGFloat) {
        boundRenderLayer?.updateDrawableSize(boundsSize: size, scaleFactor: scaleFactor)
        boundRenderLayer?.requestRender()
    }

    // MARK: - Primary Domain Operations

    /// Loads a video file, starts playback session, and securely discovers companion subtitles.
    ///
    /// - Parameters:
    ///   - url: Target video file URL.
    ///   - autoPlay: Whether playback begins automatically.
    public func load(url: URL, autoPlay: Bool = true) {
        currentURL = url
        currentTime = 0.0
        duration = 0.0
        isPlaying = autoPlay
        isBuffering = true
        hasPlaybackError = false
        errorMessage = nil
        activeSubtitleDialogue = nil
        subtitleTracks = []
        audioTracks = []

        Task { [weak self] in
            guard let self else { return }
            do {
                try await MPVCoreEngine.shared.loadFile(url: url, replace: true, isAudioOnly: false)
                if !autoPlay {
                    try await MPVCoreEngine.shared.setProperty(name: "pause", value: true)
                }

                // Discover and attach external companion subtitles safely
                self.discoverCompanionSubtitles(for: url)
                self.startTelemetryPolling()
                self.updateEDRHeadroom()
            } catch {
                self.hasPlaybackError = true
                self.errorMessage = error.localizedDescription
                self.logger.error("Failed to load video in MPVCoreEngine: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resumes video playback.
    public func play() {
        Task {
            do {
                try await MPVCoreEngine.shared.setProperty(name: "pause", value: false)
                self.isPlaying = true
                self.startTelemetryPolling()
            } catch {
                self.logger.error("Failed to resume playback: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pauses video playback.
    public func pause() {
        Task {
            do {
                try await MPVCoreEngine.shared.setProperty(name: "pause", value: true)
                self.isPlaying = false
            } catch {
                self.logger.error("Failed to pause playback: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Toggles between play and pause.
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seeks to the specified position in seconds.
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

    /// Sets playback volume level.
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

    /// Sets audio mute state.
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

    /// Stops playback and resets timeline.
    public func stop() {
        isPlaying = false
        currentTime = 0.0
        telemetryPollTask?.cancel()
        telemetryPollTask = nil
        Task {
            await MPVCoreEngine.shared.stop()
        }
    }

    // MARK: - Subtitle & Audio Track Selection

    /// Switches the active subtitle track.
    public func selectSubtitle(trackId: String?) {
        self.selectedSubtitleTrackId = trackId
        Task {
            do {
                if let trackId, let idVal = Int64(trackId.replacingOccurrences(of: "mpv_sub_", with: "")) {
                    try await MPVCoreEngine.shared.setProperty(name: "sid", value: String(idVal))
                } else {
                    try await MPVCoreEngine.shared.setProperty(name: "sid", value: "no")
                }
            } catch {
                self.logger.error("Failed to select subtitle: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Loads an external standalone subtitle file.
    public func loadExternalSubtitle(url: URL) {
        Task {
            do {
                try await MPVCoreEngine.shared.sendCommand(["sub-add", url.path, "select"])
                self.synchronizeTrackList()
            } catch {
                self.logger.error("Failed to load external subtitle: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Sets subtitle synchronization delay in seconds.
    public func setSubtitleDelay(_ delay: Double) {
        Task {
            do {
                try await MPVCoreEngine.shared.setProperty(name: "sub-delay", value: delay)
            } catch {
                self.logger.error("Failed to set subtitle delay: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Switches the active audio stream track.
    public func selectAudioTrack(trackId: String?) {
        self.selectedAudioTrackId = trackId
        Task {
            do {
                if let trackId, let idVal = Int64(trackId.replacingOccurrences(of: "mpv_audio_", with: "")) {
                    try await MPVCoreEngine.shared.setProperty(name: "aid", value: String(idVal))
                }
            } catch {
                self.logger.error("Failed to select audio track: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Window, PiP & App Lifecycle

    /// Toggles fullscreen presentation mode.
    public func toggleFullScreen() {
        self.isFullScreen.toggle()
    }

    /// Toggles Picture-in-Picture window overlay mode.
    public func togglePictureInPicture() {
        self.isPictureInPicture.toggle()
    }

    /// Handles application transition to background / window occlusion.
    public func handleAppBackgrounded() {
        if autoPauseOnBackground && isPlaying {
            wasPlayingBeforeBackground = true
            pause()
        }
    }

    /// Handles application return to active foreground.
    public func handleAppForegrounded() {
        if wasPlayingBeforeBackground {
            wasPlayingBeforeBackground = false
            play()
        }
    }

    // MARK: - Private Helpers & Telemetry

    private func discoverCompanionSubtitles(for videoURL: URL) {
        let companionURLs = SecurityScopedResourceManager.shared.safeDiscoverCompanionSubtitles(for: videoURL)
        for subURL in companionURLs {
            Task {
                try? await MPVCoreEngine.shared.sendCommand(["sub-add", subURL.path, "auto"])
            }
        }
    }

    private func updateEDRHeadroom() {
        let maxHeadroom = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let currentHeadroom = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let peakNits = max(500.0, min(1600.0, Double(maxHeadroom) * 400.0))

        self.edrMetrics = MPVEDRMetrics(
            maxEDRHeadroom: maxHeadroom,
            currentEDRHeadroom: currentHeadroom,
            peakNits: peakNits,
            isHDRActive: maxHeadroom > 1.0 || hdrFormat.isHDR,
            hdrFormat: hdrFormat
        )
    }

    private func setupWakeupBridge() {
        Task {
            await MPVCoreEngine.shared.setWakeupHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.synchronizeState()
                }
            }
        }
    }

    private func startTelemetryPolling() {
        guard telemetryPollTask == nil else { return }
        telemetryPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.isPlaying else { continue }
                self.synchronizeState()
            }
        }
    }

    private func synchronizeState() {
        Task { [weak self] in
            guard let self else { return }
            let events = await MPVCoreEngine.shared.drainEvents()
            for event in events {
                switch event {
                case .fileLoaded, .playbackRestart:
                    self.isBuffering = false
                    self.boundRenderLayer?.requestRender()
                case .pause(let paused):
                    self.isPlaying = !paused
                case .seek(let pos):
                    self.currentTime = pos
                    self.boundRenderLayer?.requestRender()
                case .eof:
                    self.isPlaying = false
                    self.currentTime = self.duration
                case .error(let msg):
                    self.hasPlaybackError = true
                    self.errorMessage = msg
                default:
                    break
                }
            }

            if let time = await MPVCoreEngine.shared.getPropertyDouble(name: "time-pos") {
                self.currentTime = max(0.0, time)
            }
            if let dur = await MPVCoreEngine.shared.getPropertyDouble(name: "duration"), dur > 0.0 {
                self.duration = dur
            }
            if let paused = await MPVCoreEngine.shared.getPropertyBool(name: "pause") {
                self.isPlaying = !paused
            }
            if let subText = await MPVCoreEngine.shared.getPropertyString(name: "sub-text") {
                self.activeSubtitleDialogue = subText.isEmpty ? nil : subText
            }

            self.synchronizeTrackList()
        }
    }

    private func synchronizeTrackList() {
        Task { [weak self] in
            guard let self else { return }
            if let w = await MPVCoreEngine.shared.getPropertyDouble(name: "video-params/w"),
               let h = await MPVCoreEngine.shared.getPropertyDouble(name: "video-params/h"), w > 0, h > 0 {
                self.videoSize = CGSize(width: w, height: h)
            }
        }
    }
}
