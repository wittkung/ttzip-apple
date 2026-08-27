// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import TTZipCore

/// Observable playback coordinator managing AVFoundation backend, Rust track demuxing, and Metal EDR metrics.
@MainActor
public final class MPVMetalPlayerStore: ObservableObject {
    @Published public var player: AVPlayer?
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
    @Published public var edrMetrics: MPVEDRMetrics = MPVEDRMetrics()
    
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var failureNotificationToken: Any?
    private var bufferObservation: NSKeyValueObservation?
    
    private var playbackTimer: Timer?
    @Published public var currentFrameImage: NSImage? = nil
    @Published public var activeSubtitleDialogue: String? = nil
    
    public init() {}
    
    public func setup(url: URL) {
        if currentURL == url, (player != nil || duration > 0) {
            if isPlaying {
                play()
            }
            return
        }
        
        cleanUp()
        
        self.currentURL = url
        self.isPlaying = false; self.hasPlaybackError = false; self.hasDecoderLimitation = false
        self.errorMessage = nil
        self.updateEDRMetrics()
        
        // 1. Asynchronously extract tracks, chapters, and container metadata via Rust demuxer
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            let headerData = (try? handle.read(upToCount: 2 * 1024 * 1024)) ?? Data()
            if !headerData.isEmpty {
                let summary = try? demuxMediaTracks(data: headerData)
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentURL == url else { return }
                    self.demuxSummary = summary
                    if self.duration == 0, let durMs = summary?.durationMs, durMs > 0 {
                        self.duration = Double(durMs) / 1000.0
                    }
                    self.populateTracksFromDemux(summary)
                }
            }
        }
        
        // 2. Discover local companion subtitle files (.srt, .ass, .vtt)
        discoverCompanionSubtitles(for: url)
        
        // 3. Initialize native AVPlayer hardware pipeline
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = Float(volume)
        newPlayer.isMuted = isMuted
        self.player = newPlayer
        
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self = self, self.currentURL == url else { return }
                switch observedItem.status {
                case .readyToPlay:
                    let d = CMTimeGetSeconds(observedItem.duration)
                    if d.isFinite && d > 0 {
                        self.duration = d
                    }
                    self.hasPlaybackError = false
                    self.isBuffering = false
                    self.hasDecoderLimitation = false
                case .failed:
                    self.hasDecoderLimitation = true
                    if self.duration == 0 {
                        self.duration = 7200 // default 2 hours if unspecified
                    }
                default:
                    break
                }
            }
        }
        
        failureNotificationToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notif in
            let errorDesc = (notif.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard let self = self, self.currentURL == url else { return }
                self.hasDecoderLimitation = true
                if let errorDesc = errorDesc {
                    self.errorMessage = errorDesc
                }
            }
        }
        
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self, !self.hasDecoderLimitation else { return }
                let secs = CMTimeGetSeconds(time)
                if secs.isFinite && secs >= 0 {
                    self.currentTime = secs
                }
                if let currentItem = newPlayer.currentItem {
                    let d = CMTimeGetSeconds(currentItem.duration)
                    if d.isFinite && d > 0 {
                        self.duration = d
                    }
                }
            }
        }
    }
    
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    public func play() {
        isPlaying = true
        if !hasDecoderLimitation, let p = player {
            p.play()
        } else {
            startClockTimer()
        }
    }
    
    public func pause() {
        isPlaying = false
        if !hasDecoderLimitation, let p = player {
            p.pause()
        } else {
            stopClockTimer()
        }
    }
    
    public func seek(to seconds: Double) {
        let maxDur = duration > 0 ? duration : 86400
        let clamped = max(0, min(seconds, maxDur))
        currentTime = clamped
        if !hasDecoderLimitation, let p = player {
            p.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    
    private func startClockTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isPlaying else { return }
                let nextTime = self.currentTime + 0.05
                if self.duration > 0 && nextTime >= self.duration {
                    self.currentTime = self.duration
                    self.pause()
                } else {
                    self.currentTime = nextTime
                }
            }
        }
    }
    
    private func stopClockTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    public func seekBy(_ delta: Double) {
        let maxDur = duration > 0 ? duration : 36000
        let target = max(0, min(currentTime + delta, maxDur))
        seek(to: target)
    }
    
    public func setVolume(_ newVolume: Double) {
        let clamped = max(0.0, min(1.0, newVolume))
        self.volume = clamped
        player?.volume = Float(clamped)
        if clamped > 0 && isMuted {
            isMuted = false
            player?.isMuted = false
        }
    }
    
    public func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }
    
    public func selectAudioTrack(_ track: MPVTrackItem) {
        self.selectedAudioTrackId = track.id
        guard let item = player?.currentItem else { return }
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
            let options = group.options
            if let matched = options.first(where: {
                $0.displayName.localizedCaseInsensitiveContains(track.language) ||
                $0.displayName.localizedCaseInsensitiveContains(track.title)
            }) {
                item.select(matched, in: group)
            }
        }
    }
    
    public func selectSubtitleTrack(_ sub: MPVSubtitleItem?) {
        guard let sub = sub else {
            self.selectedSubtitleTrackId = nil
            if let item = player?.currentItem {
                Task { @MainActor in
                    if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                        item.select(nil, in: group)
                    }
                }
            }
            return
        }
        self.selectedSubtitleTrackId = sub.id
        guard let item = player?.currentItem else { return }
        Task { @MainActor in
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                if let matched = group.options.first(where: {
                    $0.displayName.localizedCaseInsensitiveContains(sub.language) ||
                    $0.displayName.localizedCaseInsensitiveContains(sub.title)
                }) {
                    item.select(matched, in: group)
                }
            }
        }
    }

    
    public func updateEDRMetrics() {
        let maxHeadroom = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let currentHeadroom = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let peakNits = max(500.0, min(1600.0, Double(maxHeadroom) * 400.0))
        self.edrMetrics = MPVEDRMetrics(
            maxEDRHeadroom: maxHeadroom,
            currentEDRHeadroom: currentHeadroom,
            peakNits: peakNits,
            isHDRActive: maxHeadroom > 1.0
        )
    }
    
    private func populateTracksFromDemux(_ summary: UniFfiMediaDemuxSummary?) {
        guard let summary = summary else { return }
        var audios: [MPVTrackItem] = []
        var subs: [MPVSubtitleItem] = []
        
        for track in summary.tracks {
            switch track.trackType {
            case .audio:
                let item = MPVTrackItem(
                    id: "demux_audio_\(track.trackId)",
                    trackId: track.trackId,
                    title: track.title ?? "Audio Track \(track.trackId)",
                    language: track.language ?? "und",
                    codec: track.codec,
                    isDefault: track.isDefault
                )
                audios.append(item)
            case .subtitle:
                let item = MPVSubtitleItem(
                    id: "demux_sub_\(track.trackId)",
                    title: track.title ?? "Subtitle \(track.trackId)",
                    language: track.language ?? "und",
                    format: track.codec.uppercased(),
                    isExternal: false,
                    fileURL: nil
                )
                subs.append(item)
            case .video:
                break
            }
        }
        
        if !audios.isEmpty {
            self.audioTracks = audios
            if self.selectedAudioTrackId == nil {
                self.selectedAudioTrackId = audios.first(where: { $0.isDefault })?.id ?? audios.first?.id
            }
        }
        if !subs.isEmpty {
            for s in subs where !self.subtitleTracks.contains(where: { $0.id == s.id }) {
                self.subtitleTracks.append(s)
            }
        }
    }
    
    private func discoverCompanionSubtitles(for videoURL: URL) {
        let parentDir = videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil) else { return }
        
        var extSubs: [MPVSubtitleItem] = []
        for file in files {
            let ext = file.pathExtension.lowercased()
            if ["srt", "ass", "vtt", "sub", "lrc"].contains(ext) {
                let fname = file.deletingPathExtension().lastPathComponent
                if fname.hasPrefix(baseName) || fname.localizedCaseInsensitiveContains(baseName) {
                    let sub = MPVSubtitleItem(
                        id: "ext_sub_\(file.lastPathComponent)",
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
        self.subtitleTracks = extSubs
    }
    
    public func cleanUp() {
        if let obs = timeObserverToken, let p = player {
            p.removeTimeObserver(obs)
            timeObserverToken = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        if let token = failureNotificationToken {
            NotificationCenter.default.removeObserver(token)
            failureNotificationToken = nil
        }
        playbackTimer?.invalidate()
        playbackTimer = nil
        
        player?.pause()
        player?.rate = 0
        player?.replaceCurrentItem(with: nil)
        player = nil
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
        selectedAudioTrackId = nil
        selectedSubtitleTrackId = nil
    }
}
