// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import Observation
import CTTMpvBridge
import TTMPVKit
import TTZipCore
import TTZipUI

/// Backward-compatible alias for previous store naming.
public typealias SharedVideoPlayerStore = MPVMetalPlayerStore

/// High-performance Observable playback facade proxying and synchronizing the resident libmpv microkernel.
///
/// Bridges Layer 1 `MPVCoreEngine` and `MPVEventDispatcher` with Layer 3 `MPVVideoEngine` and `MPVAudioEngine`,
/// maintaining 100% backward compatibility for Combine/ObservableObject views, controls, and tests.
@Observable
@MainActor
public final class MPVMetalPlayerStore {
    /// Shared persistent playback store instance ensuring libmpv engine continuity.
    public static let shared = MPVMetalPlayerStore()
    
    private let logger = PreviewKitLogger(category: "MPVMetalPlayerStore")
    @ObservationIgnored
    private nonisolated(unsafe) var securityScopedURL: URL? = nil
    private var isAccessingSecurityScopedResource: Bool = false
    
    @ObservationIgnored
    public nonisolated(unsafe) weak var activeLayer: MPVMetalRenderLayer? = nil
    
    /// Registers the active Metal render layer for dynamic EDR colorspace synchronization.
    nonisolated public func registerRenderLayer(_ layer: MPVMetalRenderLayer) {
        self.activeLayer = layer
    }
    
    /// Unregisters the active Metal render layer when detaching.
    nonisolated public func unregisterRenderLayer(_ layer: MPVMetalRenderLayer) {
        if self.activeLayer === layer {
            self.activeLayer = nil
        }
    }
    
    /// Flag indicating whether the store is operating in pure audio mode without video rendering pipeline.
    public private(set) var isAudioOnly: Bool = false
    
    public var currentURL: URL?
    public var isPlaying: Bool = false
    private var pendingDesiredPauseState: Bool? = nil
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var volume: Double = 1.0
    public var isMuted: Bool = false
    public var isBuffering: Bool = false
    public var hasPlaybackError: Bool = false
    public var hasDecoderLimitation: Bool = false
    public var errorMessage: String? = nil
    
    public var demuxSummary: UniFfiMediaDemuxSummary? = nil
    public var audioTracks: [MPVTrackItem] = []
    public var selectedAudioTrackId: String? = nil
    public var subtitleTracks: [MPVSubtitleItem] = []
    public var selectedSubtitleTrackId: String? = nil
    public var selectedSecondarySubtitleTrackId: String? = nil
    public var subtitleDelay: Double = 0.0
    public var edrMetrics: MPVEDRMetrics = MPVEDRMetrics()
    public var activeSubtitleDialogue: String? = nil
    public var videoWidth: Int = 0
    public var videoHeight: Int = 0
    public var videoSize: CGSize = .zero
    public var isFullScreen: Bool = false
    public var playbackSpeed: Double = 1.0
    
    public var audioSampleRate: String = "--"
    public var audioChannels: String = "--"
    public var audioCodecFormatted: String = ""
    public var audioBitrateFormatted: String = ""
    public var videoCodec: String = ""
    public var hwdecCurrent: String = ""
    
    /// Callback invoked on the MainActor when file playback reaches the end (MPV_EVENT_END_FILE), enabling playlist auto-advance.
    public var onFilePlaybackEnded: (@MainActor (URL?) -> Void)?
    
    /// Native libmpv client handle pointer proxied directly from MPVCoreEngine.shared.
    nonisolated public var mpv: OpaquePointer? { MPVCoreEngine.shared.rawHandle }
    
    /// Backward-compatible handle accessor.
    nonisolated public var player: OpaquePointer? { mpv }
    
    /// Dedicated render context manager for vo=libmpv OpenGL pipeline.
    public let renderContextManager = MPVRenderContextManager()
    
    @ObservationIgnored
    private nonisolated(unsafe) var pendingParamsRefreshTask: Task<Void, Never>? = nil
    @ObservationIgnored
    private nonisolated(unsafe) var stateObservationTask: Task<Void, Never>? = nil
    @ObservationIgnored
    private nonisolated(unsafe) var eventObservationTask: Task<Void, Never>? = nil
    private var hasAttemptedSoftwareFallback = false
    var discoveredCompanionSubtitles: [MPVSubtitleItem] = []
    
    public init() {
        startObservingDispatcher()
    }
    
    deinit {
        stateObservationTask?.cancel()
        eventObservationTask?.cancel()
        pendingParamsRefreshTask?.cancel()
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
    
    // MARK: - Reactive Microkernel State Observation
    
    private func startObservingDispatcher() {
        stateObservationTask?.cancel()
        stateObservationTask = Task { @MainActor [weak self] in
            for await state in await MPVEventDispatcher.shared.stateStream {
                guard let self else { break }
                self.applyStateSnapshot(state)
            }
        }
        
        eventObservationTask?.cancel()
        eventObservationTask = Task { @MainActor [weak self] in
            for await event in await MPVEventDispatcher.shared.eventStream {
                guard let self else { break }
                self.applyEvent(event)
            }
        }
    }
    
    private func applyStateSnapshot(_ state: MPVPlaybackStateSnapshot) {
        self.currentTime = state.currentTime
        if state.duration > 0 {
            self.duration = state.duration
        }
        if let targetPaused = pendingDesiredPauseState {
            if state.isPaused == targetPaused {
                pendingDesiredPauseState = nil
                self.isPlaying = !state.isPaused
            }
        } else {
            self.isPlaying = !state.isPaused
        }
        self.volume = state.volume
        self.isMuted = state.isMuted
        self.isBuffering = state.isBuffering
        if state.isEOF {
            self.isPlaying = false
        }
    }
    
    private func applyEvent(_ event: MPVEvent) {
        switch event {
        case .fileLoaded:
            self.hasPlaybackError = false
            self.errorMessage = nil
            self.activeLayer?.forceRedraw()
            self.scheduleAsyncParamsRefresh()
        case .playbackRestart:
            self.hasPlaybackError = false
            self.isPlaying = true
            self.activeLayer?.forceRedraw()
        case .seek(let pos):
            self.currentTime = pos
            self.activeLayer?.forceRedraw()
        case .pause(let isPaused):
            self.isPlaying = !isPaused
        case .eof:
            self.isPlaying = false
            let finishedURL = self.currentURL
            self.onFilePlaybackEnded?(finishedURL)
        case .error(let msg):
            self.handlePlaybackFailure(reason: msg)
        case .playbackAbort:
            self.handlePlaybackFailure(reason: "Playback aborted by decoder")
        case .propertyChange(let name, let value):
            self.handlePropertyChange(name: name, value: value)
        case .logMessage(let level, let text):
            logger.debug("[\(level)] \(text)")
        }
    }
    
    private func handlePlaybackFailure(reason: String) {
        if !hasAttemptedSoftwareFallback, let url = currentURL {
            hasAttemptedSoftwareFallback = true
            logger.warning("Playback failure encountered (\(reason)); automatically attempting software decoding fallback for \(url.lastPathComponent)...")
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await MPVCoreEngine.shared.fallbackToSoftwareDecodingAndReload(url: url)
                    self.hasPlaybackError = false
                    self.errorMessage = nil
                } catch {
                    self.hasPlaybackError = true
                    self.errorMessage = reason
                    self.isPlaying = false
                    self.logger.error("Software decoding fallback failed: \(error.localizedDescription)")
                }
            }
        } else {
            self.hasPlaybackError = true
            self.errorMessage = reason
            self.isPlaying = false
        }
    }
    
    private func handlePropertyChange(name: String, value: MPVPropertyValue) {
        switch name {
        case "sub-text":
            if case .string(let text) = value {
                self.activeSubtitleDialogue = text.isEmpty ? nil : text
            } else {
                self.activeSubtitleDialogue = nil
            }
        case "sub-delay":
            if case .double(let delay) = value {
                self.subtitleDelay = delay
            }
        case "audio-codec-name", "audio-codec":
            if case .string(let codec) = value {
                self.audioCodecFormatted = Self.formatAudioCodecName(codec)
            }
            self.scheduleAsyncParamsRefresh()
        case "audio-bitrate":
            if case .double(let bitrate) = value, bitrate > 0 {
                self.audioBitrateFormatted = String(format: "%.0f kbps", bitrate / 1000.0)
            }
        case "video-codec":
            if case .string(let codec) = value {
                self.videoCodec = codec
            }
            self.scheduleAsyncParamsRefresh()
        case "hwdec-current":
            if case .string(let hwdec) = value {
                self.hwdecCurrent = hwdec
            }
            self.scheduleAsyncParamsRefresh()
        case "track-list", "aid", "sid", "video-params", "audio-params", "video-params/pixelformat":
            self.scheduleAsyncParamsRefresh()
        default:
            if name.hasPrefix("track-list") || name.hasPrefix("audio-params") || name.hasPrefix("video-params") {
                self.scheduleAsyncParamsRefresh()
            }
        }
    }
    
    /// Dynamically applies a hardware decoding policy (e.g. zero-copy auto vs software decoding).
    public func setHardwareDecodingPolicy(_ policy: MPVHardwareDecodingPolicy) {
        Task {
            try? await MPVCoreEngine.shared.setHardwareDecodingPolicy(policy)
        }
    }
    
    // MARK: - Media Loading API
    
    public func load(url: URL) {
        setup(url: url, isAudioOnly: false)
    }
    
    public func loadMedia(url: URL, isAudioOnly: Bool = false) {
        if currentURL == url, mpv != nil {
            if !isPlaying { play() }
            return
        }
        
        self.isAudioOnly = isAudioOnly
        
        if isAccessingSecurityScopedResource, let prevURL = securityScopedURL {
            prevURL.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
            isAccessingSecurityScopedResource = false
        }
        
        if url.startAccessingSecurityScopedResource() {
            self.securityScopedURL = url
            self.isAccessingSecurityScopedResource = true
            logger.info("Acquired security-scoped access for: \(url.path)")
        }
        
        self.currentURL = url
        self.isPlaying = false
        self.currentTime = 0
        self.duration = 0
        self.hasPlaybackError = false
        self.hasDecoderLimitation = false
        self.errorMessage = nil
        self.audioTracks.removeAll()
        self.subtitleTracks.removeAll()
        self.discoveredCompanionSubtitles.removeAll()
        self.selectedAudioTrackId = nil
        self.selectedSubtitleTrackId = nil
        self.selectedSecondarySubtitleTrackId = nil
        self.activeSubtitleDialogue = nil
        self.subtitleDelay = 0.0
        self.hasAttemptedSoftwareFallback = false
        self.videoCodec = ""
        self.hwdecCurrent = ""
        self.audioSampleRate = "--"
        self.audioChannels = "--"
        self.audioCodecFormatted = ""
        self.audioBitrateFormatted = ""
        
        self.updateEDRMetrics()
        if !isAudioOnly {
            self.discoverCompanionSubtitles(for: url)
        }
        
        self.ensureMpvInitialized(isAudioOnly: isAudioOnly)
        if !isAudioOnly, let handle = self.mpv {
            renderContextManager.createRenderContext(mpvHandle: handle)
        }
        
        logger.info("Executing loadfile asynchronously via MPVCoreEngine for: \(url.path)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await MPVCoreEngine.shared.loadFile(url: url, replace: true, isAudioOnly: isAudioOnly)
                await MPVEventDispatcher.shared.start()
                let targetVol = (self.volume > 0.0 ? self.volume : 1.0) * 100.0
                try? await MPVCoreEngine.shared.setProperty(name: "volume", value: targetVol)
                try? await MPVCoreEngine.shared.setProperty(name: "mute", value: self.isMuted)
                try? await MPVCoreEngine.shared.setProperty(name: "aid", value: "auto")
                // Explicitly unpause mpv upon load to ensure auto-start without requiring manual pause-then-play
                try? await MPVCoreEngine.shared.setProperty(name: "pause", value: false)
                self.isPlaying = true
            } catch {
                self.hasPlaybackError = true
                self.errorMessage = error.localizedDescription
                self.logger.error("Failed to load file in MPVCoreEngine: \(error.localizedDescription)")
            }
        }
    }
    
    public func setup(url: URL, isAudioOnly: Bool = false) {
        loadMedia(url: url, isAudioOnly: isAudioOnly)
    }
    
    /// Ensures the shared resident libmpv microkernel is initialized without allocating an unattached dummy render context.
    private func ensureMpvInitialized(isAudioOnly: Bool = false) {
        do {
            _ = try MPVCoreEngine.shared.ensureInitialized(mode: isAudioOnly ? .audioOnly : .video(renderBackend: "libmpv"))
        } catch {
            self.hasPlaybackError = true
            self.errorMessage = "Failed to initialize MPVCoreEngine: \(error.localizedDescription)"
            logger.error("Failed to initialize MPVCoreEngine: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Playback Control API
    
    public func togglePlayPause() { isPlaying ? pause() : play() }
    
    public func play() {
        isPlaying = true
        pendingDesiredPauseState = false
        logger.info("Playback resumed")
        Task(priority: .high) {
            try? await MPVCoreEngine.shared.setProperty(name: "pause", value: false)
        }
    }
    
    public func pause() {
        isPlaying = false
        pendingDesiredPauseState = true
        logger.info("Playback paused")
        Task(priority: .high) {
            try? await MPVCoreEngine.shared.setProperty(name: "pause", value: true)
        }
    }
    
    public func seek(to seconds: Double) {
        let maxDur = duration > 0 ? duration : 86400
        let clamped = max(0, min(seconds, maxDur))
        currentTime = clamped
        logger.info("Seeking to absolute position: \(clamped)s")
        Task {
            try? await MPVCoreEngine.shared.sendCommand(["seek", "\(clamped)", "absolute"])
        }
    }
    
    public func seekRelative(seconds: Double) { seekBy(seconds) }
    
    public func seekBy(_ delta: Double) {
        let maxDur = duration > 0 ? duration : 36000
        let target = max(0, min(currentTime + delta, maxDur))
        currentTime = target
        logger.info("Seeking relative position by: \(delta)s (target: \(target)s)")
        Task {
            try? await MPVCoreEngine.shared.sendCommand(["seek", "\(delta)", "relative"])
        }
    }
    
    public func setVolume(_ newVolume: Double) {
        let clamped = max(0.0, min(1.0, newVolume))
        self.volume = clamped
        Task {
            try? await MPVCoreEngine.shared.setProperty(name: "volume", value: clamped * 100.0)
        }
        if clamped > 0 && isMuted {
            isMuted = false
            Task {
                try? await MPVCoreEngine.shared.setProperty(name: "mute", value: false)
            }
        }
    }
    
    public func toggleMute() {
        isMuted.toggle()
        Task {
            try? await MPVCoreEngine.shared.setProperty(name: "mute", value: isMuted)
        }
    }
    
    /// Adjusts active video playback rate (e.g. 0.5x, 1.0x, 1.5x, 2.0x).
    public func setPlaybackSpeed(_ newSpeed: Double) {
        let clamped = max(0.25, min(4.0, newSpeed))
        self.playbackSpeed = clamped
        Task {
            try? await MPVCoreEngine.shared.setProperty(name: "speed", value: clamped)
        }
    }
    
    /// Coordinates full screen routing state across inline and presentation viewports.
    public func setFullScreen(_ fullScreen: Bool) {
        self.isFullScreen = fullScreen
    }
    
    // MARK: - Audio & Subtitle Track Scheduling
    
    public func selectAudioTrack(_ track: MPVTrackItem) { selectAudioTrack(id: track.id) }
    
    public func selectAudioTrack(id: String) {
        self.selectedAudioTrackId = id
        guard let track = audioTracks.first(where: { $0.id == id }) else { return }
        Task {
            try? await MPVCoreEngine.shared.setProperty(name: "aid", value: "\(track.trackId)")
        }
    }
    
    public func selectSubtitleTrack(_ sub: MPVSubtitleItem?) { selectSubtitleTrack(id: sub?.id) }
    
    public func selectSubtitleTrack(id: String?) {
        guard let id = id, let sub = subtitleTracks.first(where: { $0.id == id }) else {
            self.selectedSubtitleTrackId = nil
            Task {
                try? await MPVCoreEngine.shared.setProperty(name: "sid", value: "no")
            }
            return
        }
        self.selectedSubtitleTrackId = id
        Task {
            if sub.isExternal, let url = sub.fileURL {
                try? await MPVCoreEngine.shared.sendCommand(["sub-add", url.path, "select"])
            } else {
                try? await MPVCoreEngine.shared.setProperty(name: "sid", value: "\(sub.subtitleId)")
            }
        }
    }
    
    public func selectSecondarySubtitleTrack(_ sub: MPVSubtitleItem?) { selectSecondarySubtitleTrack(id: sub?.id) }
    
    public func selectSecondarySubtitleTrack(id: String?) {
        guard let id = id, let sub = subtitleTracks.first(where: { $0.id == id }) else {
            self.selectedSecondarySubtitleTrackId = nil
            Task {
                try? await MPVCoreEngine.shared.setProperty(name: "secondary-sid", value: "no")
            }
            return
        }
        self.selectedSecondarySubtitleTrackId = id
        Task {
            if sub.isExternal, let url = sub.fileURL {
                try? await MPVCoreEngine.shared.sendCommand(["sub-add", url.path, "auto"])
            }
            try? await MPVCoreEngine.shared.setProperty(name: "secondary-sid", value: "\(sub.subtitleId)")
        }
    }
    
    public func setSubtitleDelay(seconds: Double) {
        self.subtitleDelay = seconds
        Task {
            try? await MPVCoreEngine.shared.setProperty(name: "sub-delay", value: seconds)
        }
    }
    
    /// Loads an external subtitle file using libmpv `sub-add` command and registers it in the track list.
    public func loadSubtitle(url: URL, select: Bool = true) {
        let ext = url.pathExtension.lowercased()
        let sub = MPVSubtitleItem(
            id: "ext_sub_\(url.lastPathComponent)_\(UUID().uuidString.prefix(6))",
            subtitleId: Int32(subtitleTracks.count + 1),
            title: url.lastPathComponent,
            language: "Ext",
            format: ext.uppercased(),
            isExternal: true,
            fileURL: url,
            isSelected: select
        )
        if !subtitleTracks.contains(where: { $0.fileURL?.path == url.path }) {
            self.subtitleTracks.append(sub)
        }
        if select {
            self.selectedSubtitleTrackId = sub.id
        }
        Task {
            try? await MPVCoreEngine.shared.sendCommand(["sub-add", url.path, select ? "select" : "auto"])
        }
        logger.info("Loaded subtitle via sub-add: \(url.path) (select: \(select))")
    }
    
    /// Backward-compatible alias for loading external subtitle.
    public func addExternalSubtitle(url: URL) {
        loadSubtitle(url: url, select: true)
    }
    
    /// Removes a subtitle track from libmpv and clears its selection.
    public func removeSubtitleTrack(id: String) {
        guard let index = subtitleTracks.firstIndex(where: { $0.id == id }) else { return }
        let sub = subtitleTracks[index]
        subtitleTracks.remove(at: index)
        discoveredCompanionSubtitles.removeAll(where: { $0.id == id || $0.fileURL?.path == sub.fileURL?.path })
        
        if selectedSubtitleTrackId == id {
            selectedSubtitleTrackId = nil
            Task {
                try? await MPVCoreEngine.shared.setProperty(name: "sid", value: "no")
            }
        }
        if selectedSecondarySubtitleTrackId == id {
            selectedSecondarySubtitleTrackId = nil
            Task {
                try? await MPVCoreEngine.shared.setProperty(name: "secondary-sid", value: "no")
            }
        }
        
        Task {
            try? await MPVCoreEngine.shared.sendCommand(["sub-remove", "\(sub.subtitleId)"])
        }
        logger.info("Removed subtitle track: \(sub.title)")
    }
    
    public func removeSubtitleTrack(_ sub: MPVSubtitleItem) {
        removeSubtitleTrack(id: sub.id)
    }
    
    // MARK: - Media Track & HDR Introspection
    
    private func scheduleAsyncParamsRefresh() {
        guard self.mpv != nil else { return }
        pendingParamsRefreshTask?.cancel()
        pendingParamsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            
            let snapshot = await Task.detached(priority: .utility) { () -> MPVMediaParamsSnapshot? in
                guard !Task.isCancelled, let handle = MPVCoreEngine.shared.rawHandle else { return nil }
                return Self.extractMediaParamsSnapshot(handle: handle)
            }.value
            
            guard !Task.isCancelled, let validSnapshot = snapshot else { return }
            guard let self = self else { return }
            self.applyMediaParamsSnapshot(validSnapshot)
            self.pendingParamsRefreshTask = nil
        }
    }
    
    @MainActor
    private func applyMediaParamsSnapshot(_ snapshot: MPVMediaParamsSnapshot) {
        self.videoWidth = snapshot.width
        self.videoHeight = snapshot.height
        self.videoSize = CGSize(width: snapshot.width, height: snapshot.height)
        if !snapshot.sampleRate.isEmpty && snapshot.sampleRate != "--" { self.audioSampleRate = snapshot.sampleRate }
        if !snapshot.channels.isEmpty && snapshot.channels != "--" { self.audioChannels = snapshot.channels }
        if !snapshot.audioCodec.isEmpty { self.audioCodecFormatted = snapshot.audioCodec }
        if !snapshot.videoCodec.isEmpty { self.videoCodec = snapshot.videoCodec }
        if !snapshot.hwdecCurrent.isEmpty { self.hwdecCurrent = snapshot.hwdecCurrent }
        if !snapshot.bitrate.isEmpty { self.audioBitrateFormatted = snapshot.bitrate }
        if !snapshot.audioTracks.isEmpty { self.audioTracks = snapshot.audioTracks }
        
        var mergedSubs = snapshot.subtitleTracks
        for companion in self.discoveredCompanionSubtitles {
            if !mergedSubs.contains(where: { $0.fileURL?.path == companion.fileURL?.path || $0.title == companion.title }) {
                mergedSubs.append(companion)
            }
        }
        self.subtitleTracks = mergedSubs
        
        if let selAudio = snapshot.selectedAudioTrackId {
            self.selectedAudioTrackId = selAudio
        } else if self.selectedAudioTrackId == nil, let defTrack = snapshot.audioTracks.first(where: { $0.isDefault }) ?? snapshot.audioTracks.first {
            self.selectedAudioTrackId = defTrack.id
        }
        if let selSub = snapshot.selectedSubtitleTrackId { self.selectedSubtitleTrackId = selSub }
        self.updateEDRMetrics(detectedHDR: snapshot.hdrFormat)
    }
    
    // MARK: - Compatibility Event Draining
    
    /// Manually drains and dispatches events from the libmpv client event queue into the event dispatcher.
    public func drainMpvEvents() {
        Task {
            await MPVEventDispatcher.shared.drainAndDispatch()
        }
    }
    
    // MARK: - Teardown & Reset
    
    /// Stops playback and resets state without destroying the resident libmpv engine.
    public func cleanUp() {
        pendingParamsRefreshTask?.cancel()
        pendingParamsRefreshTask = nil
        pause()
        Task {
            await MPVCoreEngine.shared.stop()
        }
        
        if isAccessingSecurityScopedResource, let url = securityScopedURL ?? currentURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
            isAccessingSecurityScopedResource = false
            logger.info("Released security-scoped access for: \(url.path)")
        }
        
        currentURL = nil
        isPlaying = false
        isFullScreen = false
        hasAttemptedSoftwareFallback = false
        videoCodec = ""
        hwdecCurrent = ""
        renderContextManager.detachAndFree()
        currentTime = 0
        duration = 0
        hasPlaybackError = false
        hasDecoderLimitation = false
        errorMessage = nil
        demuxSummary = nil
        audioTracks.removeAll()
        subtitleTracks.removeAll()
        discoveredCompanionSubtitles.removeAll()
        selectedAudioTrackId = nil
        selectedSubtitleTrackId = nil
        selectedSecondarySubtitleTrackId = nil
        activeSubtitleDialogue = nil
        subtitleDelay = 0.0
        audioSampleRate = "--"
        audioChannels = "--"
        audioCodecFormatted = ""
        audioBitrateFormatted = ""
    }
    
    /// Explicit termination of the native libmpv engine during application teardown.
    public func terminate() {
        cleanUp()
        renderContextManager.detachAndFree()
        Task {
            await MPVCoreEngine.shared.terminate()
            await MPVEventDispatcher.shared.stop()
        }
    }
}
