// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import os.log
import CMPVBridge
import TTZipCore

private func mpvWakeupHandler(context: UnsafeMutableRawPointer?) {
    guard let context = context else { return }
    let unmanaged = Unmanaged<MPVMetalPlayerStore>.fromOpaque(context)
    let store = unmanaged.takeUnretainedValue()
    DispatchQueue.main.async { [weak store] in
        store?.drainMpvEvents()
    }
}

/// Backward-compatible alias for previous store naming.
public typealias SharedVideoPlayerStore = MPVMetalPlayerStore

/// High-performance Observable playback store driving the native libmpv Metal/EDR video engine.
@MainActor
public final class MPVMetalPlayerStore: ObservableObject {
    /// Shared persistent playback store instance ensuring libmpv engine continuity.
    public static let shared = MPVMetalPlayerStore()
    
    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPV")
    private nonisolated(unsafe) var securityScopedURL: URL? = nil
    private var isAccessingSecurityScopedResource: Bool = false
    
    @Published public var currentURL: URL?
    @Published public var isPlaying: Bool = false
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var volume: Double = 1.0
    @Published public var isMuted: Bool = false
    @Published public var isBuffering: Bool = false
    @Published public var hasPlaybackError: Bool = false
    @Published public var hasDecoderLimitation: Bool = false
    @Published public var errorMessage: String? = nil
    
    @Published public var demuxSummary: UniFfiMediaDemuxSummary? = nil
    @Published public var audioTracks: [MPVTrackItem] = []
    @Published public var selectedAudioTrackId: String? = nil
    @Published public var subtitleTracks: [MPVSubtitleItem] = []
    @Published public var selectedSubtitleTrackId: String? = nil
    @Published public var selectedSecondarySubtitleTrackId: String? = nil
    @Published public var subtitleDelay: Double = 0.0
    @Published public var edrMetrics: MPVEDRMetrics = MPVEDRMetrics()
    @Published public var activeSubtitleDialogue: String? = nil
    @Published public var videoWidth: Int = 0
    @Published public var videoHeight: Int = 0
    
    @Published public var audioSampleRate: String = "--"
    @Published public var audioChannels: String = "--"
    @Published public var audioCodecFormatted: String = ""
    @Published public var audioBitrateFormatted: String = ""
    
    /// Callback invoked on the MainActor when file playback reaches the end (MPV_EVENT_END_FILE), enabling playlist auto-advance.
    public var onFilePlaybackEnded: (@MainActor (URL?) -> Void)?
    
    /// Native libmpv client handle pointer.
    nonisolated public var mpv: OpaquePointer? { handleHolder?.rawHandle }
    
    /// Backward-compatible handle accessor.
    nonisolated public var player: OpaquePointer? { mpv }
    
    private struct UncheckedHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }
    
    private final class MPVHandleHolder: @unchecked Sendable {
        var rawHandle: OpaquePointer?
        init(rawHandle: OpaquePointer?) { self.rawHandle = rawHandle }
        func terminateAndClear() {
            guard let handle = rawHandle else { return }
            rawHandle = nil
            mpv_set_wakeup_callback(handle, nil, nil)
            let wrapper = UncheckedHandle(pointer: handle)
            DispatchQueue.global(qos: .utility).async {
                mpv_terminate_destroy(wrapper.pointer)
            }
        }
    }
    
    /// Dedicated render context manager for vo=libmpv OpenGL pipeline.
    public let renderContextManager = MPVRenderContextManager()
    
    private nonisolated(unsafe) var handleHolder: MPVHandleHolder?
    var discoveredCompanionSubtitles: [MPVSubtitleItem] = []
    
    public init() {}
    
    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        handleHolder?.terminateAndClear()
    }
    
    // MARK: - Native Non-Blocking Async Command & Property Dispatchers
    
    @discardableResult
    private func executeCommandAsync(_ args: [String], replyUserdata: UInt64 = 0) -> Int32 {
        guard let handle = self.mpv else { return -1 }
        var cStrings: [UnsafePointer<CChar>?] = args.map { strdup($0).map { UnsafePointer($0) } }
        defer {
            for ptr in cStrings {
                if let ptr = ptr { free(UnsafeMutablePointer(mutating: ptr)) }
            }
        }
        cStrings.append(nil)
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return mpv_command_async(handle, replyUserdata, baseAddress)
        }
    }
    
    private func setPropertyStringAsync(_ name: String, _ value: String, replyUserdata: UInt64 = 0) {
        guard let handle = self.mpv else { return }
        var cVal = strdup(value).map { UnsafePointer($0) }
        defer {
            if let cVal = cVal { free(UnsafeMutablePointer(mutating: cVal)) }
        }
        _ = mpv_set_property_async(handle, replyUserdata, name, MPV_FORMAT_STRING, &cVal)
    }
    
    private func setPropertyDoubleAsync(_ name: String, _ value: Double, replyUserdata: UInt64 = 0) {
        guard let handle = self.mpv else { return }
        var val: Double = value
        _ = mpv_set_property_async(handle, replyUserdata, name, MPV_FORMAT_DOUBLE, &val)
    }
    
    private func setPropertyFlagAsync(_ name: String, _ flag: Bool, replyUserdata: UInt64 = 0) {
        guard let handle = self.mpv else { return }
        var val: Int32 = flag ? 1 : 0
        _ = mpv_set_property_async(handle, replyUserdata, name, MPV_FORMAT_FLAG, &val)
    }
    
    private func setPropertyInt64Async(_ name: String, _ value: Int64, replyUserdata: UInt64 = 0) {
        guard let handle = self.mpv else { return }
        var val: Int64 = value
        _ = mpv_set_property_async(handle, replyUserdata, name, MPV_FORMAT_INT64, &val)
    }
    
    // MARK: - Lifecycle & Engine Initialization
    
    /// Ensures the resident libmpv engine is created, configured, and initialized once.
    private func ensureMpvInitialized() {
        guard handleHolder == nil else { return }
        guard let handle = mpv_create() else {
            self.hasPlaybackError = true
            self.errorMessage = "Failed to allocate libmpv client context"
            logger.error("Failed to allocate libmpv client context")
            return
        }
        self.handleHolder = MPVHandleHolder(rawHandle: handle)
        let isTesting: Bool = {
            if NSClassFromString("XCTestCase") != nil { return true }
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
            if Bundle.main.bundlePath.hasSuffix(".xctest") { return true }
            let proc = ProcessInfo.processInfo.processName.lowercased()
            if proc.contains("test") || proc.contains("xctest") { return true }
            let args = ProcessInfo.processInfo.arguments.joined(separator: " ").lowercased()
            if args.contains("test") || args.contains("xctest") { return true }
            return false
        }()
        
        mpv_request_log_messages(handle, "v")
        
        // Defensive window & behavior options to prevent standalone popup windows
        mpv_set_option_string(handle, "force-window", "no")
        mpv_set_option_string(handle, "fullscreen", "no")
        mpv_set_option_string(handle, "ontop", "no")
        mpv_set_option_string(handle, "border", "no")
        mpv_set_option_string(handle, "window-dragging", "no")
        mpv_set_option_string(handle, "focus-on-open", "no")
        mpv_set_option_string(handle, "keepaspect-window", "no")
        mpv_set_option_string(handle, "input-cursor", "no")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "osd-level", "0")
        mpv_set_option_string(handle, "osd-bar", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        mpv_set_option_string(handle, "ytdl", "no")
        mpv_set_option_string(handle, "input-default-bindings", "no")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "input-app-events", "no")
        
        // Video output strictly locked to libmpv render API and hardware acceleration
        mpv_set_option_string(handle, "vo", isTesting ? "null" : "libmpv")
        mpv_set_option_string(handle, "hwdec", isTesting ? "no" : "videotoolbox")
        mpv_set_option_string(handle, "ao", isTesting ? "null" : "auto")
        
        // HDR / EDR & Color Management
        mpv_set_option_string(handle, "target-colorspace-hint", "yes")
        mpv_set_option_string(handle, "target-trc", "auto")
        mpv_set_option_string(handle, "tone-mapping", "auto")
        mpv_set_option_string(handle, "gamut-mapping-mode", "perceptual")
        mpv_set_option_string(handle, "hdr-compute-peak", "yes")
        
        // Subtitle defaults & engine lifecycle
        mpv_set_option_string(handle, "sub-auto", "fuzzy")
        mpv_set_option_string(handle, "sub-codepage", "auto")
        mpv_set_option_string(handle, "sub-font-size", "52")
        mpv_set_option_string(handle, "sub-border-size", "3")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "idle", "yes")
        
        let initCode = mpv_initialize(handle)
        if initCode < 0 {
            let errStr = mpv_error_string(initCode).map { String(cString: $0) } ?? "Code \(initCode)"
            self.hasPlaybackError = true
            self.errorMessage = "libmpv initialization failed: \(errStr)"
            logger.error("libmpv initialization failed: \(errStr, privacy: .public)")
            return
        }
        
        // Initialize render context manager only when vo=libmpv is active
        if !isTesting {
            renderContextManager.createRenderContext(mpvHandle: handle)
        }
        
        let properties: [(UInt64, String, mpv_format)] = [
            (1, "time-pos", MPV_FORMAT_DOUBLE),
            (2, "duration", MPV_FORMAT_DOUBLE),
            (3, "pause", MPV_FORMAT_FLAG),
            (4, "mute", MPV_FORMAT_FLAG),
            (5, "volume", MPV_FORMAT_DOUBLE),
            (6, "sub-text", MPV_FORMAT_STRING),
            (7, "sub-delay", MPV_FORMAT_DOUBLE),
            (8, "track-list", MPV_FORMAT_NODE),
            (9, "video-params", MPV_FORMAT_NODE),
            (10, "audio-params", MPV_FORMAT_NODE),
            (11, "audio-codec-name", MPV_FORMAT_STRING),
            (12, "audio-bitrate", MPV_FORMAT_DOUBLE),
            (13, "core-idle", MPV_FORMAT_FLAG),
            (14, "eof-reached", MPV_FORMAT_FLAG)
        ]
        for (replyUserdata, name, format) in properties {
            mpv_observe_property(handle, replyUserdata, name, format)
        }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, mpvWakeupHandler, context)
    }
    
    // MARK: - Media Loading API
    
    public func load(url: URL) { loadMedia(url: url) }
    
    public func loadMedia(url: URL) {
        if currentURL == url, mpv != nil {
            if !isPlaying { play() }
            return
        }
        
        if isAccessingSecurityScopedResource, let prevURL = securityScopedURL {
            prevURL.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
            isAccessingSecurityScopedResource = false
        }
        
        if url.startAccessingSecurityScopedResource() {
            self.securityScopedURL = url
            self.isAccessingSecurityScopedResource = true
            logger.info("Acquired security-scoped access for: \(url.path, privacy: .public)")
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
        self.audioSampleRate = "--"
        self.audioChannels = "--"
        self.audioCodecFormatted = ""
        self.audioBitrateFormatted = ""
        
        self.updateEDRMetrics()
        self.discoverCompanionSubtitles(for: url)
        self.ensureMpvInitialized()
        
        logger.info("Executing loadfile asynchronously for: \(url.path, privacy: .public)")
        executeCommandAsync(["loadfile", url.path, "replace"])
    }
    
    public func setup(url: URL, isAudioOnly: Bool = false) {
        loadMedia(url: url)
    }
    
    // MARK: - Native Non-Blocking Event Draining
    
    public func drainMpvEvents() {
        guard let handle = self.mpv else { return }
        while let eventPtr = mpv_wait_event(handle, 0) {
            let event = eventPtr.pointee
            if event.event_id == MPV_EVENT_NONE { break }
            if event.event_id == MPV_EVENT_SHUTDOWN { return }
            self.processMpvEvent(event, handle: handle)
        }
    }
    
    private func processMpvEvent(_ event: mpv_event, handle: OpaquePointer) {
        switch event.event_id {
        case MPV_EVENT_LOG_MESSAGE:
            if let logPtr = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                let text = String(cString: logPtr.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
                logger.debug("\(text, privacy: .public)")
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let propPtr = event.data?.assumingMemoryBound(to: mpv_event_property.self),
                  let nameCStr = propPtr.pointee.name else { return }
            let name = String(cString: nameCStr)
            handlePropertyChange(name: name, prop: propPtr.pointee)
        case MPV_EVENT_FILE_LOADED:
            logger.info("File loaded successfully into libmpv pipeline")
            self.hasPlaybackError = false
            self.errorMessage = nil
            self.scheduleAsyncParamsRefresh()
        case MPV_EVENT_END_FILE:
            self.isPlaying = false
            if let endFilePtr = event.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                let endFile = endFilePtr.pointee
                if endFile.error != 0 {
                    let errStr = mpv_error_string(endFile.error).map { String(cString: $0) } ?? "Unknown error (\(endFile.error))"
                    self.hasPlaybackError = true
                    self.errorMessage = "Playback failed: \(errStr)"
                    logger.error("Playback failed with error: \(errStr, privacy: .public) (code \(endFile.error, privacy: .public))")
                } else {
                    logger.info("File playback ended normally")
                }
            }
            let finishedURL = self.currentURL
            self.onFilePlaybackEnded?(finishedURL)
        default:
            break
        }
    }
    
    private func handlePropertyChange(name: String, prop: mpv_event_property) {
        switch name {
        case "time-pos":
            if prop.format == MPV_FORMAT_DOUBLE, let val = prop.data?.assumingMemoryBound(to: Double.self).pointee, val.isFinite, val >= 0 {
                self.currentTime = val
            }
        case "duration":
            if prop.format == MPV_FORMAT_DOUBLE, let val = prop.data?.assumingMemoryBound(to: Double.self).pointee, val.isFinite, val > 0 {
                self.duration = val
            }
        case "pause":
            if prop.format == MPV_FORMAT_FLAG, let val = prop.data?.assumingMemoryBound(to: Int32.self).pointee {
                self.isPlaying = (val == 0)
            }
        case "mute":
            if prop.format == MPV_FORMAT_FLAG, let val = prop.data?.assumingMemoryBound(to: Int32.self).pointee {
                self.isMuted = (val != 0)
            }
        case "volume":
            if prop.format == MPV_FORMAT_DOUBLE, let val = prop.data?.assumingMemoryBound(to: Double.self).pointee {
                self.volume = max(0.0, min(1.0, val / 100.0))
            }
        case "sub-text":
            if prop.format == MPV_FORMAT_STRING, let ptr = prop.data?.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee {
                let text = String(cString: ptr)
                self.activeSubtitleDialogue = text.isEmpty ? nil : text
            } else if prop.format == MPV_FORMAT_NONE {
                self.activeSubtitleDialogue = nil
            }
        case "sub-delay":
            if prop.format == MPV_FORMAT_DOUBLE, let val = prop.data?.assumingMemoryBound(to: Double.self).pointee {
                self.subtitleDelay = val
            }
        case "track-list", "video-params", "audio-params":
            scheduleAsyncParamsRefresh()
        case "audio-codec-name":
            if prop.format == MPV_FORMAT_STRING, let ptr = prop.data?.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee {
                self.audioCodecFormatted = Self.formatAudioCodecName(String(cString: ptr))
            }
        case "audio-bitrate":
            if prop.format == MPV_FORMAT_DOUBLE, let val = prop.data?.assumingMemoryBound(to: Double.self).pointee, val.isFinite, val > 0 {
                self.audioBitrateFormatted = String(format: "%.0f kbps", val / 1000.0)
            }
        case "core-idle":
            if prop.format == MPV_FORMAT_FLAG, let val = prop.data?.assumingMemoryBound(to: Int32.self).pointee {
                self.isBuffering = (val != 0 && self.isPlaying)
            }
        case "eof-reached":
            if prop.format == MPV_FORMAT_FLAG, let val = prop.data?.assumingMemoryBound(to: Int32.self).pointee, val != 0 {
                self.isPlaying = false
            }
        default:
            break
        }
    }
    
    // MARK: - Media Track & HDR Introspection
    
    private func scheduleAsyncParamsRefresh() {
        guard let holder = self.handleHolder else { return }
        Task.detached(priority: .utility) { [weak self, holder] in
            guard let activeHandle = holder.rawHandle else { return }
            let snapshot = Self.extractMediaParamsSnapshot(handle: activeHandle)
            await MainActor.run { [weak self] in
                guard let self = self, self.handleHolder === holder else { return }
                self.applyMediaParamsSnapshot(snapshot)
            }
        }
    }
    
    @MainActor
    private func applyMediaParamsSnapshot(_ snapshot: MPVMediaParamsSnapshot) {
        self.videoWidth = snapshot.width
        self.videoHeight = snapshot.height
        if !snapshot.sampleRate.isEmpty && snapshot.sampleRate != "--" { self.audioSampleRate = snapshot.sampleRate }
        if !snapshot.channels.isEmpty && snapshot.channels != "--" { self.audioChannels = snapshot.channels }
        if !snapshot.audioCodec.isEmpty { self.audioCodecFormatted = snapshot.audioCodec }
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
        } else if self.selectedAudioTrackId == nil, let defAudio = snapshot.audioTracks.first(where: { $0.isDefault })?.id ?? snapshot.audioTracks.first?.id {
            self.selectedAudioTrackId = defAudio
        }
        if let selSub = snapshot.selectedSubtitleTrackId { self.selectedSubtitleTrackId = selSub }
        self.updateEDRMetrics(detectedHDR: snapshot.hdrFormat)
    }
    

    
    // MARK: - Playback Control API
    
    public func togglePlayPause() { isPlaying ? pause() : play() }
    
    public func play() {
        isPlaying = true
        logger.info("Playback resumed")
        setPropertyStringAsync("pause", "no")
    }
    
    public func pause() {
        isPlaying = false
        logger.info("Playback paused")
        setPropertyStringAsync("pause", "yes")
    }
    
    public func seek(to seconds: Double) {
        let maxDur = duration > 0 ? duration : 86400
        let clamped = max(0, min(seconds, maxDur))
        currentTime = clamped
        logger.info("Seeking to absolute position: \(clamped, privacy: .public)s")
        executeCommandAsync(["seek", "\(clamped)", "absolute"])
    }
    
    public func seekRelative(seconds: Double) { seekBy(seconds) }
    
    public func seekBy(_ delta: Double) {
        let maxDur = duration > 0 ? duration : 36000
        let target = max(0, min(currentTime + delta, maxDur))
        currentTime = target
        logger.info("Seeking relative position by: \(delta, privacy: .public)s (target: \(target, privacy: .public)s)")
        executeCommandAsync(["seek", "\(delta)", "relative"])
    }
    
    public func setVolume(_ newVolume: Double) {
        let clamped = max(0.0, min(1.0, newVolume))
        self.volume = clamped
        setPropertyDoubleAsync("volume", clamped * 100.0)
        if clamped > 0 && isMuted {
            isMuted = false
            setPropertyStringAsync("mute", "no")
        }
    }
    
    public func toggleMute() {
        isMuted.toggle()
        setPropertyStringAsync("mute", isMuted ? "yes" : "no")
    }
    
    // MARK: - Audio & Subtitle Track Scheduling
    
    public func selectAudioTrack(_ track: MPVTrackItem) { selectAudioTrack(id: track.id) }
    
    public func selectAudioTrack(id: String) {
        self.selectedAudioTrackId = id
        guard let track = audioTracks.first(where: { $0.id == id }) else { return }
        setPropertyStringAsync("aid", "\(track.trackId)")
    }
    
    public func selectSubtitleTrack(_ sub: MPVSubtitleItem?) { selectSubtitleTrack(id: sub?.id) }
    
    public func selectSubtitleTrack(id: String?) {
        guard let id = id, let sub = subtitleTracks.first(where: { $0.id == id }) else {
            self.selectedSubtitleTrackId = nil
            setPropertyStringAsync("sid", "no")
            return
        }
        self.selectedSubtitleTrackId = id
        if sub.isExternal, let url = sub.fileURL {
            executeCommandAsync(["sub-add", url.path, "select"])
        } else {
            setPropertyStringAsync("sid", "\(sub.subtitleId)")
        }
    }
    
    public func selectSecondarySubtitleTrack(_ sub: MPVSubtitleItem?) { selectSecondarySubtitleTrack(id: sub?.id) }
    
    public func selectSecondarySubtitleTrack(id: String?) {
        guard let id = id, let sub = subtitleTracks.first(where: { $0.id == id }) else {
            self.selectedSecondarySubtitleTrackId = nil
            setPropertyStringAsync("secondary-sid", "no")
            return
        }
        self.selectedSecondarySubtitleTrackId = id
        if sub.isExternal, let url = sub.fileURL {
            executeCommandAsync(["sub-add", url.path, "auto"])
        }
        setPropertyStringAsync("secondary-sid", "\(sub.subtitleId)")
    }
    
    public func setSubtitleDelay(seconds: Double) {
        self.subtitleDelay = seconds
        setPropertyDoubleAsync("sub-delay", seconds)
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
        executeCommandAsync(["sub-add", url.path, select ? "select" : "auto"])
        logger.info("Loaded subtitle via sub-add: \(url.path, privacy: .public) (select: \(select))")
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
            setPropertyStringAsync("sid", "no")
        }
        if selectedSecondarySubtitleTrackId == id {
            selectedSecondarySubtitleTrackId = nil
            setPropertyStringAsync("secondary-sid", "no")
        }
        
        executeCommandAsync(["sub-remove", "\(sub.subtitleId)"])
        logger.info("Removed subtitle track: \(sub.title, privacy: .public)")
    }
    
    public func removeSubtitleTrack(_ sub: MPVSubtitleItem) {
        removeSubtitleTrack(id: sub.id)
    }
    

    
    // MARK: - Teardown & Reset
    
    /// Stops playback and resets state without destroying the resident libmpv engine.
    public func cleanUp() {
        pause()
        executeCommandAsync(["stop"])
        
        if isAccessingSecurityScopedResource, let url = securityScopedURL ?? currentURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
            isAccessingSecurityScopedResource = false
            logger.info("Released security-scoped access for: \(url.path, privacy: .public)")
        }
        
        currentURL = nil
        isPlaying = false
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
        handleHolder?.terminateAndClear()
        handleHolder = nil
    }
}
