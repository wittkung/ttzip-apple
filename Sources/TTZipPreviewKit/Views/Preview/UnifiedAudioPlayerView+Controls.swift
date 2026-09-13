// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// Auxiliary audio preview formatting and inspection utilities for TTZip audio pipeline.
public enum AudioPreviewFormatHelper {
    /// Determines whether the given file extension represents a lossless acoustic format.
    public static func isLosslessFormat(extension ext: String) -> Bool {
        let normalized = ext.lowercased()
        return ["flac", "ape", "wav", "aiff", "aifc", "alac", "dsf", "dff", "wv"].contains(normalized)
    }
}

// MARK: - Playback Transport Controls Bar

/// DAW-grade playback transport bar with seeking, play/pause, volume slider, and playback rate selector.
public struct AudioPlaybackControlsBar: View {
    public let isPlaying: Bool
    public let volume: Double
    public let isMuted: Bool
    public let playbackSpeed: Double
    public let onTogglePlayPause: () -> Void
    public let onSeekBy: (Double) -> Void
    public let onSetVolume: (Double) -> Void
    public let onToggleMute: () -> Void
    public let onSetPlaybackSpeed: (Double) -> Void

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    public init(
        isPlaying: Bool,
        volume: Double,
        isMuted: Bool,
        playbackSpeed: Double,
        onTogglePlayPause: @escaping () -> Void,
        onSeekBy: @escaping (Double) -> Void,
        onSetVolume: @escaping (Double) -> Void,
        onToggleMute: @escaping () -> Void,
        onSetPlaybackSpeed: @escaping (Double) -> Void
    ) {
        self.isPlaying = isPlaying
        self.volume = volume
        self.isMuted = isMuted
        self.playbackSpeed = playbackSpeed
        self.onTogglePlayPause = onTogglePlayPause
        self.onSeekBy = onSeekBy
        self.onSetVolume = onSetVolume
        self.onToggleMute = onToggleMute
        self.onSetPlaybackSpeed = onSetPlaybackSpeed
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Main Transport Buttons: Rewind 15s | Play/Pause | Forward 15s
            HStack(spacing: 28) {
                Button {
                    onSeekBy(-15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Rewind 15 seconds")

                Button {
                    onTogglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        TTZipTheme.bambooGreen,
                                        Color(red: 0.15, green: 0.65, blue: 0.45)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 50, height: 50)
                            .shadow(color: TTZipTheme.bambooGreen.opacity(0.4), radius: isPlaying ? 10 : 4)

                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")

                Button {
                    onSeekBy(15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Forward 15 seconds")
            }

            // Secondary Controls: Volume Slider & Playback Rate Capsule
            HStack(spacing: 16) {
                // Volume & Mute Control
                HStack(spacing: 8) {
                    Button {
                        onToggleMute()
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : (volume > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"))
                            .font(.system(size: 11))
                            .foregroundStyle(isMuted ? TTZipTheme.cinnabarRed : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isMuted ? "Unmute" : "Mute")

                    Slider(
                        value: Binding(
                            get: { volume },
                            set: { onSetVolume($0) }
                        ),
                        in: 0...1
                    )
                    .tint(TTZipTheme.bambooGreen.opacity(0.75))
                    .frame(width: 80)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.03))
                .clipShape(Capsule())

                // Playback Rate Menu
                Menu {
                    ForEach(speedOptions, id: \.self) { speed in
                        Button {
                            onSetPlaybackSpeed(speed)
                        } label: {
                            HStack {
                                if abs(playbackSpeed - speed) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                                Text(speed == 1.0 ? "1.0× (Normal)" : String(format: "%.2g×", speed))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .font(.system(size: 9.5))
                        Text(String(format: "%.2g×", playbackSpeed))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change playback speed")
            }
        }
    }
}

// MARK: - Audio Specs Inspection Grid

/// High-density DAW telemetry grid displaying codec, sample rate, channels, bitrate, and engine specs.
public struct AudioSpecsInspectionGrid: View {
    public let formatBadge: String
    public let displayCodec: String
    public let displaySampleRate: String
    public let displayBitrate: String
    public let displayChannels: String
    public let fileSize: String
    public let durationFormatted: String

    public init(
        formatBadge: String,
        displayCodec: String,
        displaySampleRate: String,
        displayBitrate: String,
        displayChannels: String,
        fileSize: String,
        durationFormatted: String
    ) {
        self.formatBadge = formatBadge
        self.displayCodec = displayCodec
        self.displaySampleRate = displaySampleRate
        self.displayBitrate = displayBitrate
        self.displayChannels = displayChannels
        self.fileSize = fileSize
        self.durationFormatted = durationFormatted
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Audio Specs", systemImage: "waveform.circle.fill")
                .font(.system(size: 11, weight: .bold, design: .serif))
                .foregroundStyle(TTZipTheme.kintsugiGold)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    specTag(title: "Format", value: formatBadge)
                    specTag(title: "Sample Rate", value: displaySampleRate)
                }
                GridRow {
                    specTag(title: "Bitrate", value: displayBitrate)
                    specTag(title: "Channels", value: displayChannels)
                }
                GridRow {
                    specTag(title: "File Size", value: fileSize.isEmpty ? "--" : fileSize)
                    specTag(title: "Duration", value: durationFormatted)
                }
                GridRow {
                    specTag(title: "Audio Engine", value: "libmpv Hi-Fi Core")
                    specTag(title: "Waveform Bins", value: "1600 Samples")
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8)
        )
        .padding(.horizontal, 16)
    }

    private func specTag(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
