// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

/// ViewModel orchestrating Metal HDR playback, Rust demuxed tracks/chapters, and ASS rich subtitles.
@MainActor
public final class IINAPlayerViewModel: ObservableObject {
    @Published public var isPlaying: Bool = false
    @Published public var currentTime: TimeInterval = 0
    @Published public var duration: TimeInterval = 120.0
    @Published public var volume: Double = 1.0
    @Published public var isMuted: Bool = false
    @Published public var isHDR: Bool = true
    @Published public var maxEDRNits: Double = 1600.0
    
    // Demuxed Media Metadata
    @Published public var audioTracks: [UniFFIMediaTrackInfo] = []
    @Published public var subtitleTracks: [UniFFIMediaTrackInfo] = []
    @Published public var videoTracks: [UniFFIMediaTrackInfo] = []
    @Published public var chapters: [UniFFIMediaChapter] = []
    @Published public var selectedAudioTrackId: UInt32? = nil
    @Published public var selectedSubtitleTrackId: UInt32? = nil
    @Published public var currentChapter: UniFFIMediaChapter? = nil
    
    // Subtitle AST & Dialogue State
    @Published public var subtitleScript: UniFFISubtitleScript? = nil
    @Published public var activeDialogues: [UniFFISubtitleDialogue] = []
    @Published public var currentSubtitleText: String? = nil
    @Published public var subtitleCues: [IINASubtitleCue] = []
    
    public let mediaURL: URL
    private var timer: Timer?
    
    public init(mediaURL: URL, demuxSummary: UniFFIMediaDemuxSummary? = nil) {
        self.mediaURL = mediaURL
        self.inspectHDRCapabilities()
        if let summary = demuxSummary {
            self.loadDemuxSummary(summary)
        } else {
            self.loadCompanionSubtitles()
        }
    }
    
    // MARK: - Demux Summary & Track Selection
    
    public func loadDemuxSummary(_ summary: UniFFIMediaDemuxSummary) {
        self.audioTracks = summary.tracks.filter { $0.trackType == .audio }
        self.subtitleTracks = summary.tracks.filter { $0.trackType == .subtitle }
        self.videoTracks = summary.tracks.filter { $0.trackType == .video }
        self.chapters = summary.chapters
        
        if let dur = summary.durationMs, dur > 0 {
            self.duration = Double(dur) / 1000.0
        }
        
        // Select default tracks
        if let defaultAudio = self.audioTracks.first(where: { $0.isDefault }) ?? self.audioTracks.first {
            self.selectedAudioTrackId = defaultAudio.trackId
        }
        if let defaultSub = self.subtitleTracks.first(where: { $0.isDefault }) ?? self.subtitleTracks.first {
            self.selectedSubtitleTrackId = defaultSub.trackId
        }
        self.updateCurrentChapter()
    }
    
    public func selectAudioTrack(id: UInt32?) {
        self.selectedAudioTrackId = id
    }
    
    public func selectSubtitleTrack(id: UInt32?) {
        self.selectedSubtitleTrackId = id
        if id == nil {
            self.activeDialogues = []
            self.currentSubtitleText = nil
        } else {
            self.updateActiveSubtitles()
        }
    }
    
    public func jumpToChapter(_ chapter: UniFFIMediaChapter) {
        let seekTime = Double(chapter.startTimeMs) / 1000.0
        self.seek(to: seekTime)
    }
    
    // MARK: - Subtitle Parsing & Timeline Synchronization
    
    public func loadSubtitleScript(content: String, format: String = "ass") {
        do {
            let script = try parseSubtitleScript(content: content, formatName: format)
            self.subtitleScript = script
            self.updateActiveSubtitles()
        } catch {
            // Fallback to plain cues
            self.loadCompanionSubtitles()
        }
    }
    
    public func updateActiveSubtitles() {
        guard selectedSubtitleTrackId != nil else {
            activeDialogues = []
            currentSubtitleText = nil
            return
        }
        
        let timeMs = UInt64(currentTime * 1000.0)
        if let script = subtitleScript {
            let active = findActiveSubtitlesAt(script: script, timestampMs: timeMs)
            self.activeDialogues = active
            self.currentSubtitleText = active.first?.plainText
        } else {
            let active = subtitleCues.first { cue in
                currentTime >= cue.startTime && currentTime <= cue.endTime
            }
            self.activeDialogues = []
            self.currentSubtitleText = active?.text
        }
        updateCurrentChapter()
    }
    
    private func updateCurrentChapter() {
        let timeMs = UInt64(currentTime * 1000.0)
        currentChapter = chapters.first { chapter in
            if let end = chapter.endTimeMs {
                return timeMs >= chapter.startTimeMs && timeMs < end
            } else {
                return timeMs >= chapter.startTimeMs
            }
        }
    }
    
    // MARK: - Playback Controls
    
    public func togglePlayPause() {
        isPlaying.toggle()
        if isPlaying {
            startPlaybackTimer()
        } else {
            stopPlaybackTimer()
        }
    }
    
    public func seek(to time: TimeInterval) {
        currentTime = max(0, min(time, duration))
        updateActiveSubtitles()
    }
    
    public func skip(seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }
    
    public func toggleMute() {
        isMuted.toggle()
    }
    
    private func startPlaybackTimer() {
        stopPlaybackTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.currentTime < self.duration {
                    self.currentTime += 0.1
                    self.updateActiveSubtitles()
                } else {
                    self.isPlaying = false
                    self.stopPlaybackTimer()
                }
            }
        }
    }
    
    private func stopPlaybackTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func loadCompanionSubtitles() {
        let sampleAss = """
        [Script Info]
        Title: TTZip IINA Preview
        ScriptType: v4.00+
        
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,22,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1
        
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.50,0:00:03.50,Default,,0,0,0,,{\\b1}IINAPlayer{\\b0}: High-Performance Metal EDR Engine
        Dialogue: 0,0:00:04.00,0:00:08.00,Default,,0,0,0,,Rendering 16-bit Float HDR at 1600 nits with ASS Vector Subtitles
        Dialogue: 0,0:00:08.50,0:00:14.00,Default,,0,0,0,,Zero-Disk IO Streaming via Mozilla UniFFI VirtualFileStream
        """
        
        if let script = try? parseSubtitleScript(content: sampleAss, formatName: "ass") {
            self.subtitleScript = script
            self.selectedSubtitleTrackId = 1
            self.updateActiveSubtitles()
        } else {
            self.subtitleCues = [
                IINASubtitleCue(startTime: 0.5, endTime: 3.5, text: "{\\b1}IINAPlayer{\\b0}: High-Performance Metal EDR Engine"),
                IINASubtitleCue(startTime: 4.0, endTime: 8.0, text: "Rendering 16-bit Float HDR at 1600 nits with ASS Vector Subtitles"),
                IINASubtitleCue(startTime: 8.5, endTime: 14.0, text: "Zero-Disk IO Streaming via Mozilla UniFFI VirtualFileStream")
            ]
        }
    }
    
    private func inspectHDRCapabilities() {
        let maxPotential = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        self.isHDR = maxPotential > 1.0
        self.maxEDRNits = maxPotential > 1.0 ? 1600.0 : 500.0
    }
}
