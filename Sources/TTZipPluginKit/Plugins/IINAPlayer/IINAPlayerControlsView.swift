// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit

/// Control overlays for IINAPlayer including audio track, subtitle, and chapter selection menus.
public struct IINAPlayerControlsView: View {
    @ObservedObject var viewModel: IINAPlayerViewModel
    let url: URL
    
    public init(viewModel: IINAPlayerViewModel, url: URL) {
        self.viewModel = viewModel
        self.url = url
    }
    
    public var body: some View {
        VStack {
            topControlBar
            Spacer()
            bottomControlBar
        }
    }
    
    // MARK: - Top Header Bar with Chapter & HDR Badges
    
    private var topControlBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.tv.fill")
                .foregroundStyle(.orange)
            
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            
            if let chapter = viewModel.currentChapter {
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 9))
                    Text(chapter.title)
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.18))
                .foregroundStyle(.white.opacity(0.9))
                .clipShape(Capsule())
            }
            
            Spacer()
            
            if viewModel.isHDR {
                HStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 10))
                    Text("HDR10 • \(Int(viewModel.maxEDRNits)) nits EDR")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.85))
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            
            Text(url.pathExtension.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.2))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.75), Color.clear], startPoint: .top, endPoint: .bottom)
        )
    }
    
    // MARK: - Bottom Scrubber & Multi-Track Playback Controls
    
    private var bottomControlBar: some View {
        VStack(spacing: 8) {
            // Time Scrubber
            HStack(spacing: 10) {
                Text(Self.formatTime(viewModel.currentTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                
                Slider(
                    value: Binding(
                        get: { viewModel.currentTime },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(1.0, viewModel.duration)
                )
                .tint(.orange)
                
                Text(Self.formatTime(viewModel.duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            
            // Buttons Row
            HStack(spacing: 18) {
                Button(action: { viewModel.skip(seconds: -10) }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.skip(seconds: 10) }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                
                // Audio Tracks Menu
                audioTracksMenu
                
                // Subtitles Menu
                subtitlesMenu
                
                // Chapters Menu
                chaptersMenu
                
                Spacer()
                
                // Volume Controls
                HStack(spacing: 6) {
                    Button(action: { viewModel.toggleMute() }) {
                        Image(systemName: viewModel.isMuted || viewModel.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    
                    Slider(value: $viewModel.volume, in: 0...1.0)
                        .frame(width: 70)
                        .tint(.orange)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 10)
        .background(
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        )
    }
    
    // MARK: - Audio Tracks Menu
    
    private var audioTracksMenu: some View {
        Menu {
            if viewModel.audioTracks.isEmpty {
                Text("No Alternate Audio Tracks").disabled(true)
            } else {
                ForEach(viewModel.audioTracks, id: \.trackId) { track in
                    Button(action: { viewModel.selectAudioTrack(id: track.trackId) }) {
                        HStack {
                            let label = track.title ?? "\(track.language?.uppercased() ?? "Track") (\(track.codec))"
                            Text(label)
                            if viewModel.selectedAudioTrackId == track.trackId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 14))
                Text("Audio")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(viewModel.selectedAudioTrackId != nil ? .orange : .white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    // MARK: - Subtitles Menu
    
    private var subtitlesMenu: some View {
        Menu {
            Button(action: { viewModel.selectSubtitleTrack(id: nil) }) {
                HStack {
                    Text("Off")
                    if viewModel.selectedSubtitleTrackId == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            if !viewModel.subtitleTracks.isEmpty {
                Divider()
                ForEach(viewModel.subtitleTracks, id: \.trackId) { track in
                    Button(action: { viewModel.selectSubtitleTrack(id: track.trackId) }) {
                        HStack {
                            let label = track.title ?? "\(track.language?.uppercased() ?? "Subtitle") (\(track.codec))"
                            Text(label)
                            if viewModel.selectedSubtitleTrackId == track.trackId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 14))
                Text("Subtitles")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(viewModel.selectedSubtitleTrackId != nil ? .orange : .white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    // MARK: - Chapters Menu
    
    private var chaptersMenu: some View {
        Menu {
            if viewModel.chapters.isEmpty {
                Text("No Chapters Detected").disabled(true)
            } else {
                ForEach(Array(viewModel.chapters.enumerated()), id: \.offset) { _, chapter in
                    Button(action: { viewModel.jumpToChapter(chapter) }) {
                        HStack {
                            let timeStr = Self.formatTime(Double(chapter.startTimeMs) / 1000.0)
                            Text("\(chapter.title) (\(timeStr))")
                            if viewModel.currentChapter?.startTimeMs == chapter.startTimeMs {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 14))
                Text("Chapters")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(viewModel.currentChapter != nil ? .orange : .white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    public static func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(0, time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
