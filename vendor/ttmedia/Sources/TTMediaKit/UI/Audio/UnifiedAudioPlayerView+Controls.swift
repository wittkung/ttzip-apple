// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

// MARK: - Audiophile Color Theme

/// Audiophile and visualizer theme palette adhering to MetastudyLine optical standards.
public enum TTAudioTheme {
    /// Bamboo Green dynamic accent (#8FA876 in dark / #5F7A4A in light for optimal contrast).
    public static let bambooGreen = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(red: 143.0 / 255.0, green: 168.0 / 255.0, blue: 118.0 / 255.0, alpha: 1.0)
        } else {
            return NSColor(red: 95.0 / 255.0, green: 122.0 / 255.0, blue: 74.0 / 255.0, alpha: 1.0)
        }
    }))

    /// Kintsugi Gold dynamic secondary accent (#E6C35C in dark / #8C6D23 in light).
    public static let kintsugiGold = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(red: 230.0 / 255.0, green: 195.0 / 255.0, blue: 92.0 / 255.0, alpha: 1.0)
        } else {
            return NSColor(red: 140.0 / 255.0, green: 109.0 / 255.0, blue: 35.0 / 255.0, alpha: 1.0)
        }
    }))

    /// Cinnabar Red (#D15947).
    public static let cinnabarRed = Color(red: 0.82, green: 0.35, blue: 0.28)

    /// Archival Amber (#D97706).
    public static let archiveAmber = Color(red: 0.85, green: 0.47, blue: 0.15)

    /// Adaptive card surface reducing background bleed in the right inspector.
    public static let inspectorCardSurface = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.11, green: 0.13, blue: 0.12, alpha: 0.82)
        } else {
            return NSColor(srgbRed: 0.96, green: 0.97, blue: 0.95, alpha: 0.92)
        }
    }))

    /// Specular 0.5pt border token for the audio inspector card.
    public static let inspectorCardBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.10)
        } else {
            return NSColor.black.withAlphaComponent(0.08)
        }
    }))

    /// Adaptive waveform slot background for clear contrast in both dark and light appearances.
    public static let waveformTrackSurface = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.08, green: 0.13, blue: 0.10, alpha: 0.90)
        } else {
            return NSColor(srgbRed: 0.89, green: 0.92, blue: 0.88, alpha: 0.92)
        }
    }))

    /// Specular 0.5pt border for the waveform slot.
    public static let waveformTrackBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.12)
        } else {
            return NSColor(srgbRed: 0.35, green: 0.46, blue: 0.32, alpha: 0.22)
        }
    }))

    /// Inactive waveform bar color adaptive to dark and light appearances.
    public static let waveformInactiveBar = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.32)
        } else {
            return NSColor(srgbRed: 0.28, green: 0.36, blue: 0.26, alpha: 0.34)
        }
    }))

    /// Subtle control capsule surface for volume and playback rate controls.
    public static let controlPillSurface = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.06)
        } else {
            return NSColor.black.withAlphaComponent(0.05)
        }
    }))
}

// MARK: - Format Helper

/// Auxiliary audio preview formatting and inspection utilities for TTMediaKit audio pipeline.
public enum AudioPreviewFormatHelper {
    /// Determines whether the given file extension represents a lossless acoustic format.
    public static func isLosslessFormat(extension ext: String) -> Bool {
        let normalized = ext.lowercased()
        return ["flac", "ape", "wav", "aiff", "aifc", "alac", "dsf", "dff", "wv"].contains(normalized)
    }

    /// Determines whether a file extension is a waveform-only preview format (.ogg/.oga/.opus)
    /// when native AVAudioEngine playback is not verified.
    public static func isWaveformOnlyExtension(_ ext: String) -> Bool {
        let normalized = ext.lowercased()
        return ["ogg", "oga", "opus"].contains(normalized)
    }
}

// MARK: - Playback Transport Controls Bar

/// DAW-grade playback transport bar with seeking, play/pause, volume slider, and playback rate selector.
/// Enforces >= 28x28pt minimum hit targets and responsive spacing across narrow/regular/wide sidebars.
public struct AudioPlaybackControlsBar: View {
    public let isPlaying: Bool
    public let volume: Double
    public let isMuted: Bool
    public let playbackSpeed: Double
    public var availableWidth: CGFloat? = nil
    public var isCompact: Bool = false
    public var isUltraCompact: Bool = false
    public var isPlaybackAvailable: Bool = true
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
        availableWidth: CGFloat? = nil,
        isCompact: Bool = false,
        isUltraCompact: Bool = false,
        isPlaybackAvailable: Bool = true,
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
        self.availableWidth = availableWidth
        self.isCompact = isCompact
        self.isUltraCompact = isUltraCompact
        self.isPlaybackAvailable = isPlaybackAvailable
        self.onTogglePlayPause = onTogglePlayPause
        self.onSeekBy = onSeekBy
        self.onSetVolume = onSetVolume
        self.onToggleMute = onToggleMute
        self.onSetPlaybackSpeed = onSetPlaybackSpeed
    }

    private var metrics: AudioInspectorLayoutMetrics {
        AudioInspectorLayoutMetrics(
            availableWidth: availableWidth ?? (isUltraCompact ? 280 : (isCompact ? 340 : 420)),
            availableHeight: isUltraCompact ? 240 : (isCompact ? 300 : 420)
        )
    }

    public var body: some View {
        let layout = metrics
        VStack(spacing: isUltraCompact ? 6 : 8) {
            transportPrimaryRow(layout: layout)
            transportSecondaryRow(layout: layout)
        }
    }

    private func transportPrimaryRow(layout: AudioInspectorLayoutMetrics) -> some View {
        let buttonDiameter = layout.playButtonSize
        let seekIconSize: CGFloat = isCompact ? 14.5 : 16.5

        return HStack(spacing: isUltraCompact ? 18 : 24) {
            Button {
                onSeekBy(-15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: seekIconSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(
                        minWidth: AudioInspectorLayoutMetrics.minimumHitTargetSize,
                        minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ttButtonHelp(AudioPreviewLocalization.format(.rewindSecondsFormat, 15))

            Button {
                guard isPlaybackAvailable else { return }
                onTogglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(isPlaybackAvailable ? TTAudioTheme.bambooGreen : Color.secondary.opacity(0.28))
                        .frame(width: buttonDiameter, height: buttonDiameter)
                        .shadow(
                            color: isPlaybackAvailable ? TTAudioTheme.bambooGreen.opacity(0.32) : .clear,
                            radius: isPlaying ? 7 : 3
                        )

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: isCompact ? 14 : 16, weight: .bold))
                        .foregroundStyle(isPlaybackAvailable ? .white : .secondary)
                        .offset(x: isPlaying ? 0 : 1)
                }
                .frame(
                    minWidth: max(buttonDiameter, AudioInspectorLayoutMetrics.minimumHitTargetSize),
                    minHeight: max(buttonDiameter, AudioInspectorLayoutMetrics.minimumHitTargetSize)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isPlaybackAvailable)
            .ttButtonHelp(
                isPlaybackAvailable
                    ? AudioPreviewLocalization.text(isPlaying ? .pause : .play)
                    : AudioPreviewLocalization.text(.waveformOnlyPreviewNotice)
            )

            Button {
                onSeekBy(15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: seekIconSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(
                        minWidth: AudioInspectorLayoutMetrics.minimumHitTargetSize,
                        minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ttButtonHelp(AudioPreviewLocalization.format(.forwardSecondsFormat, 15))
        }
    }

    private func transportSecondaryRow(layout: AudioInspectorLayoutMetrics) -> some View {
        HStack(spacing: 10) {
            // Volume & Mute Control Capsule
            HStack(spacing: 4) {
                Button {
                    onToggleMute()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : (volume > 0.5 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isMuted ? TTAudioTheme.cinnabarRed : Color.secondary)
                        .frame(
                            width: AudioInspectorLayoutMetrics.minimumHitTargetSize,
                            height: AudioInspectorLayoutMetrics.minimumHitTargetSize
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ttButtonHelp(AudioPreviewLocalization.text(isMuted ? .unmute : .mute))

                Slider(
                    value: Binding(
                        get: { volume },
                        set: { onSetVolume($0) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .tint(TTAudioTheme.bambooGreen)
                .frame(width: layout.volumeSliderWidth)
                .padding(.trailing, 8)
            }
            .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize)
            .background(TTAudioTheme.controlPillSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(TTAudioTheme.inspectorCardBorder, lineWidth: 0.5)
            )

            Spacer(minLength: 4)

            // Playback Rate Selector Capsule
            Menu {
                ForEach(speedOptions, id: \.self) { speed in
                    Button {
                        onSetPlaybackSpeed(speed)
                    } label: {
                        HStack {
                            if abs(playbackSpeed - speed) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                            Text(speed == 1.0 ? AudioPreviewLocalization.format(.normalPlaybackSpeedFormat, "1.0×") : String(format: "%.2g×", speed))
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 10, weight: .medium))
                    Text(String(format: "%.2g×", playbackSpeed))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize)
                .background(TTAudioTheme.controlPillSurface)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(TTAudioTheme.inspectorCardBorder, lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .ttButtonHelp(AudioPreviewLocalization.text(.changePlaybackSpeedHelp))
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
        VStack(alignment: .leading, spacing: 7) {
            Label(AudioPreviewLocalization.text(.audioSpecsTitle), systemImage: "waveform.circle.fill")
                .font(.system(size: 10.5, weight: .bold, design: .serif))
                .foregroundStyle(TTAudioTheme.kintsugiGold)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    specTag(title: AudioPreviewLocalization.text(.specFormat), value: formatBadge)
                    specTag(title: AudioPreviewLocalization.text(.specSampleRate), value: displaySampleRate)
                }
                GridRow {
                    specTag(title: AudioPreviewLocalization.text(.specBitrate), value: displayBitrate)
                    specTag(title: AudioPreviewLocalization.text(.specChannels), value: displayChannels)
                }
                GridRow {
                    specTag(title: AudioPreviewLocalization.text(.specFileSize), value: fileSize.isEmpty ? "--" : fileSize)
                    specTag(title: AudioPreviewLocalization.text(.specDuration), value: durationFormatted)
                }
            }
        }
        .padding(10)
        .background(TTAudioTheme.controlPillSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(TTAudioTheme.inspectorCardBorder, lineWidth: 0.5)
        )
    }

    private func specTag(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
