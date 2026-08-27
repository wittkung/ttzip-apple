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

/// Backward-compatible alias for previous store naming.
public typealias SharedVideoPlayerStore = MPVMetalPlayerStore

/// High-performance Observable playback store driving the native libmpv Metal/EDR video engine.
@MainActor
public final class MPVMetalPlayerStore: ObservableObject {
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
    
    /// Native libmpv client handle pointer.
    public var mpv: OpaquePointer? {
        handleHolder?.rawHandle
    }
    
    /// Backward-compatible handle accessor.
    public var player: OpaquePointer? {
        mpv
    }
    
    private struct UncheckedHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }
    
    private final class MPVHandleHolder: @unchecked Sendable {
        var rawHandle: OpaquePointer?
        
        init(rawHandle: OpaquePointer?) {
            self.rawHandle = rawHandle
        }
        
        func terminateAndClear() {
            if let handle = rawHandle {
                rawHandle = nil
                let wrapper = UncheckedHandle(pointer: handle)
                DispatchQueue.global(qos: .utility).async {
                    mpv_terminate_destroy(wrapper.pointer)
                }
            }
        }
    }
    
    private var handleHolder: MPVHandleHolder?
    private var eventPollingTask: Task<Void, Never>?
    private var discoveredCompanionSubtitles: [MPVSubtitleItem] = []
    private weak var attachedView: NSView?
    
    public init() {}
    
    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        handleHolder?.terminateAndClear()
    }
    
    // MARK: - Native Command Dispatcher
    
    @discardableResult
    private func executeCommand(_ args: [String]) -> Int32 {
        guard let handle = self.mpv else { return -1 }
        var cStrings: [UnsafePointer<CChar>?] = args.map { strdup($0).map { UnsafePointer($0) } }
        defer {
            for ptr in cStrings {
                if let ptr = ptr {
                    free(UnsafeMutablePointer(mutating: ptr))
                }
            }
        }
        cStrings.append(nil)
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return mpv_command(handle, baseAddress)
        }
    }
    
    // MARK: - Lifecycle & Configuration
    
    /// Initializes and configures the libmpv instance with Apple Silicon hardware acceleration and EDR color pipeline.
    public func setup(url: URL, view: NSView? = nil, isAudioOnly: Bool = false) {
        if let view = view {
            self.attachedView = view
        }
        
        if currentURL == url, mpv != nil {
            if isPlaying {
                play()
            }
            return
        }
        
        cleanUp()
        
        self.currentURL = url
        self.isPlaying = false
        self.hasPlaybackError = false
        self.hasDecoderLimitation = false
        self.errorMessage = nil
        self.updateEDRMetrics()
        
        logger.info("Setting up player for media: \(url.path, privacy: .public) (isAudioOnly: \(isAudioOnly, privacy: .public))")
        
        if url.startAccessingSecurityScopedResource() {
            self.securityScopedURL = url
            self.isAccessingSecurityScopedResource = true
            logger.info("Acquired security-scoped access for: \(url.path, privacy: .public)")
        }
        
        // 1. Discover local companion subtitle files (.srt, .ass, .vtt, etc.)
        if !isAudioOnly {
            discoverCompanionSubtitles(for: url)
        }
        
        // 2. Instantiate native libmpv handle
        guard let handle = mpv_create() else {
            self.hasPlaybackError = true
            self.errorMessage = "Failed to allocate libmpv client context"
            logger.error("Failed to allocate libmpv client context")
            return
        }
        let holder = MPVHandleHolder(rawHandle: handle)
        self.handleHolder = holder
        
        // Request verbose log messages from libmpv
        mpv_request_log_messages(handle, "v")
        
        // Disable built-in mpv input bindings to prevent hijacking AppKit event loop
        mpv_set_option_string(handle, "input-default-bindings", "no")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "input-cursor", "no")
        
        if isAudioOnly {
            // Configure lightweight pure audio mode without video/EDR rendering pipeline
            mpv_set_option_string(handle, "vo", "null")
            mpv_set_option_string(handle, "video", "no")
            mpv_set_option_string(handle, "audio-display", "no")
            mpv_set_option_string(handle, "keep-open", "yes")
        } else {
            // 3. Configure Apple Silicon VideoToolbox Hardware Acceleration
            mpv_set_option_string(handle, "hwdec", "videotoolbox")
            mpv_set_option_string(handle, "vo", "gpu")
            
            // 4. Configure HDR10/Dolby Vision/HLG and Extended Dynamic Range Color Pipeline
            mpv_set_option_string(handle, "target-colorspace-hint", "yes")
            mpv_set_option_string(handle, "target-trc", "auto")
            mpv_set_option_string(handle, "tone-mapping", "auto")
            mpv_set_option_string(handle, "gamut-mapping-mode", "perceptual")
            mpv_set_option_string(handle, "hdr-compute-peak", "yes")
            
            // 5. Configure Universal Subtitle System (ASS, SRT, VTT with fuzzy auto-matching)
            mpv_set_option_string(handle, "sub-auto", "fuzzy")
            mpv_set_option_string(handle, "sub-codepage", "auto")
            mpv_set_option_string(handle, "sub-font-size", "52")
            mpv_set_option_string(handle, "sub-border-size", "3")
            mpv_set_option_string(handle, "keep-open", "yes")
            
            // 6. Bind native NSView handle if attached before mpv_initialize
            if let targetView = attachedView {
                var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(targetView).toOpaque()))
                mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
                logger.info("Bound wid to NSView before mpv_initialize: \(wid, privacy: .public)")
            } else {
                // Defensive fallback: if no view is attached (headless tests), prevent spawning rogue standalone NSWindows
                mpv_set_option_string(handle, "vo", "null")
            }
        }
        
        // 7. Initialize mpv core
        let initCode = mpv_initialize(handle)
        guard initCode >= 0 else {
            self.hasPlaybackError = true
            self.errorMessage = "libmpv initialization failed with code: \(initCode)"
            logger.error("libmpv initialization failed with code: \(initCode, privacy: .public)")
            return
        }
        
        // 8. Register observed properties for real-time reactive updates
        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 5, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 6, "track-list", MPV_FORMAT_NONE)
        mpv_observe_property(handle, 7, "sub-text", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 8, "video-params", MPV_FORMAT_NONE)
        mpv_observe_property(handle, 9, "sub-delay", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 10, "secondary-sid", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 11, "audio-params", MPV_FORMAT_NONE)
        mpv_observe_property(handle, 12, "audio-codec-name", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 13, "audio-bitrate", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 14, "core-idle", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 15, "eof-reached", MPV_FORMAT_FLAG)
        
        // 9. Start reactive event loop
        startEventLoop(url: url)
        
        // 10. Load target media file using native C string array command
        logger.info("Executing loadfile for: \(url.path, privacy: .public)")
        executeCommand(["loadfile", url.path, "replace"])
    }
    
    /// Attaches the playback view viewport window handle to the active mpv instance.
    public func attachViewport(_ view: NSView) {
        if self.attachedView === view && mpv != nil {
            return
        }
        self.attachedView = view
        if let url = currentURL, mpv == nil {
            setup(url: url, view: view)
        }
    }
    
    // MARK: - Reactive Event Loop
    
    private func startEventLoop(url: URL) {
        eventPollingTask?.cancel()
        eventPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.currentURL == url, let handle = self.mpv else { break }
                var processedAny = false
                while let eventPtr = mpv_wait_event(handle, 0) {
                    let event = eventPtr.pointee
                    if event.event_id == MPV_EVENT_NONE {
                        break
                    }
                    processedAny = true
                    if event.event_id == MPV_EVENT_SHUTDOWN {
                        return
                    }
                    self.processMpvEvent(event, handle: handle)
                }
                try? await Task.sleep(nanoseconds: processedAny ? 16_000_000 : 50_000_000)
            }
        }
    }
    
    private func processMpvEvent(_ event: mpv_event, handle: OpaquePointer) {
        switch event.event_id {
        case MPV_EVENT_LOG_MESSAGE:
            if let logPtr = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                let prefix = String(cString: logPtr.pointee.prefix)
                let text = String(cString: logPtr.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
                logger.debug("[\(prefix, privacy: .public)] \(text, privacy: .public)")
            }
            
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let propPtr = event.data?.assumingMemoryBound(to: mpv_event_property.self) else { return }
            let prop = propPtr.pointee
            guard let nameCStr = prop.name else { return }
            let name = String(cString: nameCStr)
            handlePropertyChange(name: name, prop: prop)
            
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
                    let errStr: String
                    if let cStr = mpv_error_string(endFile.error) {
                        errStr = String(cString: cStr)
                    } else {
                        errStr = "Unknown error (\(endFile.error))"
                    }
                    self.hasPlaybackError = true
                    self.errorMessage = "Playback failed: \(errStr)"
                    logger.error("Playback failed with error: \(errStr, privacy: .public) (code \(endFile.error, privacy: .public))")
                } else {
                    logger.info("File playback ended normally")
                }
            }
            
        default:
            break
        }
    }
    
    nonisolated private static func getMpvString(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let ptr = mpv_get_property_string(handle, name) else { return nil }
        let str = String(cString: ptr)
        mpv_free(ptr)
        return str
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
        if !snapshot.sampleRate.isEmpty && snapshot.sampleRate != "--" {
            self.audioSampleRate = snapshot.sampleRate
        }
        if !snapshot.channels.isEmpty && snapshot.channels != "--" {
            self.audioChannels = snapshot.channels
        }
        if !snapshot.audioCodec.isEmpty {
            self.audioCodecFormatted = snapshot.audioCodec
        }
        if !snapshot.bitrate.isEmpty {
            self.audioBitrateFormatted = snapshot.bitrate
        }
        if !snapshot.audioTracks.isEmpty {
            self.audioTracks = snapshot.audioTracks
        }
        
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
        if let selSub = snapshot.selectedSubtitleTrackId {
            self.selectedSubtitleTrackId = selSub
        }
        self.updateEDRMetrics(detectedHDR: snapshot.hdrFormat)
    }
    
    nonisolated private static func extractMediaParamsSnapshot(handle: OpaquePointer) -> MPVMediaParamsSnapshot {
        // 1. Video dimensions & HDR format
        var w: Int64 = 0
        mpv_get_property(handle, "video-params/w", MPV_FORMAT_INT64, &w)
        var h: Int64 = 0
        mpv_get_property(handle, "video-params/h", MPV_FORMAT_INT64, &h)
        
        let gamma = getMpvString(handle, "video-params/gamma")?.lowercased() ?? ""
        let primaries = getMpvString(handle, "video-params/primaries")?.lowercased() ?? ""
        
        var detectedHDR: MPVHDRFormat = .sdr
        if gamma.contains("pq") || primaries.contains("bt.2020") {
            detectedHDR = .hdr10
        } else if gamma.contains("dovi") || primaries.contains("dovi") {
            detectedHDR = .dolbyVision
        } else if gamma.contains("hlg") {
            detectedHDR = .hlg
        }
        
        // 2. Audio sample rate, channels, codec, bitrate
        var sampleRateStr = "--"
        var sr: Int64 = 0
        if mpv_get_property(handle, "audio-params/samplerate", MPV_FORMAT_INT64, &sr) >= 0, sr > 0 {
            sampleRateStr = sr >= 1_000_000 ? String(format: "%.4f MHz", Double(sr) / 1_000_000.0) : String(format: "%.1f kHz", Double(sr) / 1000.0)
        }
        
        var channelsStr = "--"
        if let chStr = getMpvString(handle, "audio-params/channels"), !chStr.isEmpty {
            switch chStr.lowercased() {
            case "mono", "1": channelsStr = "Mono"
            case "stereo", "2": channelsStr = "Stereo"
            case "5.1", "5.1(side)": channelsStr = "5.1 Surround"
            case "7.1": channelsStr = "7.1 Surround"
            default: channelsStr = chStr.capitalized
            }
        } else {
            var chCount: Int64 = 0
            if mpv_get_property(handle, "audio-params/channel-count", MPV_FORMAT_INT64, &chCount) >= 0, chCount > 0 {
                channelsStr = chCount == 1 ? "Mono" : (chCount == 2 ? "Stereo" : "\(chCount) Channels")
            }
        }
        
        var codecStr = ""
        if let rawCodec = getMpvString(handle, "audio-codec-name"), !rawCodec.isEmpty {
            codecStr = formatAudioCodecName(rawCodec)
        }
        
        var bitrateStr = ""
        var br: Double = 0
        if mpv_get_property(handle, "audio-bitrate", MPV_FORMAT_DOUBLE, &br) >= 0, br > 0 {
            bitrateStr = String(format: "%.0f kbps", br / 1000.0)
        }
        
        // 3. Audio & Subtitle tracks
        var count: Int64 = 0
        var audios: [MPVTrackItem] = []
        var subs: [MPVSubtitleItem] = []
        var selAudioId: String? = nil
        var selSubId: String? = nil
        
        if mpv_get_property(handle, "track-list/count", MPV_FORMAT_INT64, &count) >= 0 {
            for i in 0..<count {
                let prefix = "track-list/\(i)/"
                guard let type = getMpvString(handle, prefix + "type") else { continue }
                
                var trackId: Int64 = 0
                mpv_get_property(handle, prefix + "id", MPV_FORMAT_INT64, &trackId)
                let title = getMpvString(handle, prefix + "title") ?? ""
                let lang = getMpvString(handle, prefix + "lang") ?? ""
                let codec = getMpvString(handle, prefix + "codec") ?? ""
                
                var isSelectedFlag: Int32 = 0
                mpv_get_property(handle, prefix + "selected", MPV_FORMAT_FLAG, &isSelectedFlag)
                var isDefaultFlag: Int32 = 0
                mpv_get_property(handle, prefix + "default", MPV_FORMAT_FLAG, &isDefaultFlag)
                var isExternalFlag: Int32 = 0
                mpv_get_property(handle, prefix + "external", MPV_FORMAT_FLAG, &isExternalFlag)
                let extFile = getMpvString(handle, prefix + "external-filename")
                
                if type == "audio" {
                    let item = MPVTrackItem(
                        id: "mpv_audio_\(trackId)",
                        trackId: UInt32(max(0, trackId)),
                        title: title.isEmpty ? "Audio Track \(trackId)" : title,
                        language: lang.isEmpty ? "und" : lang,
                        codec: codec,
                        isDefault: isDefaultFlag != 0,
                        isSelected: isSelectedFlag != 0
                    )
                    audios.append(item)
                    if isSelectedFlag != 0 { selAudioId = item.id }
                } else if type == "sub" {
                    let item = MPVSubtitleItem(
                        id: "mpv_sub_\(trackId)",
                        subtitleId: Int32(trackId),
                        title: title.isEmpty ? (extFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Subtitle \(trackId)") : title,
                        language: lang.isEmpty ? "und" : lang,
                        format: codec.isEmpty ? "SRT" : codec.uppercased(),
                        isExternal: isExternalFlag != 0,
                        fileURL: extFile.map { URL(fileURLWithPath: $0) },
                        isDefault: isDefaultFlag != 0,
                        isSelected: isSelectedFlag != 0,
                        isSecondary: false
                    )
                    subs.append(item)
                    if isSelectedFlag != 0 { selSubId = item.id }
                }
            }
        }
        
        return MPVMediaParamsSnapshot(
            width: Int(w),
            height: Int(h),
            hdrFormat: detectedHDR,
            sampleRate: sampleRateStr,
            channels: channelsStr,
            audioCodec: codecStr,
            bitrate: bitrateStr,
            audioTracks: audios,
            subtitleTracks: subs,
            selectedAudioTrackId: selAudioId,
            selectedSubtitleTrackId: selSubId
        )
    }
    
    nonisolated private static func formatAudioCodecName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("flac") { return "FLAC Lossless" }
        if lower.contains("ape") { return "Monkey's Audio (APE)" }
        if lower.contains("dts") { return "DTS Digital Surround" }
        if lower.contains("opus") { return "Opus Audio" }
        if lower.contains("vorbis") { return "Ogg Vorbis" }
        if lower.contains("mp3") { return "MPEG-1 Layer III (MP3)" }
        if lower.contains("aac") { return "AAC Audio" }
        if lower.contains("alac") { return "Apple Lossless (ALAC)" }
        if lower.contains("pcm") { return "Linear PCM Audio" }
        if lower.contains("wma") { return "Windows Media Audio" }
        if lower.contains("wavpack") || lower.contains("wv") { return "WavPack Lossless" }
        if lower.contains("dsd") { return "Direct Stream Digital (DSD)" }
        return raw.uppercased()
    }
    
    // MARK: - Playback Control API
    
    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }
    
    public func play() {
        isPlaying = true
        logger.info("Playback resumed")
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, "pause", "no")
    }
    
    public func pause() {
        isPlaying = false
        logger.info("Playback paused")
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, "pause", "yes")
    }
    
    public func seek(to seconds: Double) {
        let maxDur = duration > 0 ? duration : 86400
        let clamped = max(0, min(seconds, maxDur))
        currentTime = clamped
        logger.info("Seeking to absolute position: \(clamped, privacy: .public)s")
        executeCommand(["seek", "\(clamped)", "absolute"])
    }
    
    public func seekRelative(seconds: Double) { seekBy(seconds) }
    
    public func seekBy(_ delta: Double) {
        let maxDur = duration > 0 ? duration : 36000
        let target = max(0, min(currentTime + delta, maxDur))
        currentTime = target
        logger.info("Seeking relative position by: \(delta, privacy: .public)s (target: \(target, privacy: .public)s)")
        executeCommand(["seek", "\(delta)", "relative"])
    }
    
    public func setVolume(_ newVolume: Double) {
        let clamped = max(0.0, min(1.0, newVolume))
        self.volume = clamped
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, "volume", "\(clamped * 100.0)")
        if clamped > 0 && isMuted {
            isMuted = false
            mpv_set_property_string(handle, "mute", "no")
        }
    }
    
    public func toggleMute() {
        isMuted.toggle()
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, "mute", isMuted ? "yes" : "no")
    }
    
    // MARK: - Audio & Subtitle Track Scheduling
    
    public func selectAudioTrack(_ track: MPVTrackItem) {
        selectAudioTrack(id: track.id)
    }
    
    public func selectAudioTrack(id: String) {
        self.selectedAudioTrackId = id
        guard let handle = mpv, let track = audioTracks.first(where: { $0.id == id }) else { return }
        mpv_set_property_string(handle, "aid", "\(track.trackId)")
    }
    
    public func selectSubtitleTrack(_ sub: MPVSubtitleItem?) {
        selectSubtitleTrack(id: sub?.id)
    }
    
    public func selectSubtitleTrack(id: String?) {
        guard let id = id, let sub = subtitleTracks.first(where: { $0.id == id }) else {
            self.selectedSubtitleTrackId = nil
            guard let handle = mpv else { return }
            mpv_set_property_string(handle, "sid", "no")
            return
        }
        self.selectedSubtitleTrackId = id
        guard let handle = mpv else { return }
        if sub.isExternal, let url = sub.fileURL {
            executeCommand(["sub-add", url.path, "select"])
        } else {
            mpv_set_property_string(handle, "sid", "\(sub.subtitleId)")
        }
    }
    
    public func selectSecondarySubtitleTrack(_ sub: MPVSubtitleItem?) {
        selectSecondarySubtitleTrack(id: sub?.id)
    }
    
    public func selectSecondarySubtitleTrack(id: String?) {
        guard let id = id, let sub = subtitleTracks.first(where: { $0.id == id }) else {
            self.selectedSecondarySubtitleTrackId = nil
            guard let handle = mpv else { return }
            mpv_set_property_string(handle, "secondary-sid", "no")
            return
        }
        self.selectedSecondarySubtitleTrackId = id
        guard let handle = mpv else { return }
        if sub.isExternal, let url = sub.fileURL {
            executeCommand(["sub-add", url.path, "auto"])
        }
        mpv_set_property_string(handle, "secondary-sid", "\(sub.subtitleId)")
    }
    
    public func setSubtitleDelay(seconds: Double) {
        self.subtitleDelay = seconds
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, "sub-delay", "\(seconds)")
    }
    
    public func addExternalSubtitle(url: URL) {
        let ext = url.pathExtension.lowercased()
        let sub = MPVSubtitleItem(
            id: "ext_sub_\(url.lastPathComponent)_\(UUID().uuidString.prefix(6))",
            subtitleId: Int32(subtitleTracks.count + 1),
            title: url.lastPathComponent,
            language: "Ext",
            format: ext.uppercased(),
            isExternal: true,
            fileURL: url,
            isSelected: true
        )
        self.subtitleTracks.append(sub)
        self.selectedSubtitleTrackId = sub.id
        executeCommand(["sub-add", url.path, "select"])
    }
    
    // MARK: - EDR & Companion Discovery
    
    public func updateEDRMetrics(detectedHDR: MPVHDRFormat = .sdr) {
        let maxHeadroom = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let currentHeadroom = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let peakNits = max(500.0, min(1600.0, Double(maxHeadroom) * 400.0))
        self.edrMetrics = MPVEDRMetrics(
            maxEDRHeadroom: maxHeadroom,
            currentEDRHeadroom: currentHeadroom,
            peakNits: peakNits,
            isHDRActive: maxHeadroom > 1.0 || detectedHDR.isHDR,
            hdrFormat: detectedHDR,
            toneMappingMode: "auto"
        )
    }
    
    private func discoverCompanionSubtitles(for videoURL: URL) {
        Task.detached(priority: .utility) { [weak self] in
            let parentDir = videoURL.deletingLastPathComponent()
            let baseName = videoURL.deletingPathExtension().lastPathComponent
            guard let files = try? FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil) else { return }
            
            var extSubs: [MPVSubtitleItem] = []
            for file in files {
                let ext = file.pathExtension.lowercased()
                if ["srt", "ass", "ssa", "vtt", "sub", "lrc"].contains(ext) {
                    let fname = file.deletingPathExtension().lastPathComponent
                    if fname.hasPrefix(baseName) || fname.localizedCaseInsensitiveContains(baseName) {
                        let sub = MPVSubtitleItem(
                            id: "ext_sub_\(file.lastPathComponent)",
                            subtitleId: Int32(extSubs.count + 1),
                            title: file.lastPathComponent,
                            language: "Ext",
                            format: ext.uppercased(),
                            isExternal: true,
                            fileURL: file
                        )
                        extSubs.append(sub)
                    }
                }
            }
            
            await MainActor.run { [weak self] in
                guard let self = self, self.currentURL == videoURL else { return }
                self.discoveredCompanionSubtitles = extSubs
                for companion in extSubs {
                    if !self.subtitleTracks.contains(where: { $0.fileURL?.path == companion.fileURL?.path || $0.title == companion.title }) {
                        self.subtitleTracks.append(companion)
                    }
                }
            }
        }
    }
    
    // MARK: - Teardown
    
    public func cleanUp() {
        if isAccessingSecurityScopedResource, let url = securityScopedURL ?? currentURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
            isAccessingSecurityScopedResource = false
            logger.info("Released security-scoped access for: \(url.path, privacy: .public)")
        }
        
        eventPollingTask?.cancel()
        eventPollingTask = nil
        handleHolder?.terminateAndClear()
        handleHolder = nil
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
}
