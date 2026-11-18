// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit
import TTZipUI

enum EmbeddedAudioColors {
    /// Bamboo Green dynamic accent (#8FA876 in dark / #5F7A4A in light for optimal contrast).
    static let bambooGreen = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(red: 143.0 / 255.0, green: 168.0 / 255.0, blue: 118.0 / 255.0, alpha: 1.0)
        } else {
            return NSColor(red: 95.0 / 255.0, green: 122.0 / 255.0, blue: 74.0 / 255.0, alpha: 1.0)
        }
    }))

    /// Kintsugi Gold dynamic secondary accent (#E6C35C in dark / #8C6D23 in light).
    static let kintsugiGold = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(red: 230.0 / 255.0, green: 195.0 / 255.0, blue: 92.0 / 255.0, alpha: 1.0)
        } else {
            return NSColor(red: 140.0 / 255.0, green: 109.0 / 255.0, blue: 35.0 / 255.0, alpha: 1.0)
        }
    }))

    /// Adaptive card surface reducing background bleed in the right inspector.
    static let inspectorCardSurface = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.11, green: 0.13, blue: 0.12, alpha: 0.82)
        } else {
            return NSColor(srgbRed: 0.96, green: 0.97, blue: 0.95, alpha: 0.92)
        }
    }))

    /// Specular 0.5pt border token for the audio inspector card.
    static let inspectorCardBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.10)
        } else {
            return NSColor.black.withAlphaComponent(0.08)
        }
    }))

    /// Subtle control capsule surface for volume and playback rate controls.
    static let controlPillSurface = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.06)
        } else {
            return NSColor.black.withAlphaComponent(0.05)
        }
    }))
}

struct EmbeddedAudioControlsBar: View {
    let isPlaying: Bool
    let volume: Double
    let isMuted: Bool
    let playbackSpeed: Double
    var availableWidth: CGFloat? = nil
    var isCompact: Bool = false
    var isUltraCompact: Bool = false
    var isPlaybackAvailable: Bool = true
    let onTogglePlayPause: () -> Void
    let onSeekBy: (Double) -> Void
    let onSetVolume: (Double) -> Void
    let onToggleMute: () -> Void
    let onSetPlaybackSpeed: (Double) -> Void

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    init(
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

    var body: some View {
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
            .ttButtonHelp(TTZipAudioPreviewLocalization.format(.rewindSecondsFormat, 15))

            Button {
                guard isPlaybackAvailable else { return }
                onTogglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(isPlaybackAvailable ? EmbeddedAudioColors.bambooGreen : Color.secondary.opacity(0.28))
                        .frame(width: buttonDiameter, height: buttonDiameter)
                        .shadow(
                            color: isPlaybackAvailable ? EmbeddedAudioColors.bambooGreen.opacity(0.32) : .clear,
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
                    ? TTZipAudioPreviewLocalization.text(isPlaying ? .pause : .play)
                    : TTZipAudioPreviewLocalization.text(.waveformOnlyPreviewNotice)
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
            .ttButtonHelp(TTZipAudioPreviewLocalization.format(.forwardSecondsFormat, 15))
        }
    }

    private func transportSecondaryRow(layout: AudioInspectorLayoutMetrics) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button {
                    onToggleMute()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : (volume > 0.5 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isMuted ? TTZipTheme.cinnabarRed : Color.secondary)
                        .frame(
                            width: AudioInspectorLayoutMetrics.minimumHitTargetSize,
                            height: AudioInspectorLayoutMetrics.minimumHitTargetSize
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ttButtonHelp(TTZipAudioPreviewLocalization.text(isMuted ? .unmute : .mute))

                Slider(
                    value: Binding(
                        get: { volume },
                        set: { onSetVolume($0) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .tint(EmbeddedAudioColors.bambooGreen)
                .frame(width: layout.volumeSliderWidth)
                .padding(.trailing, 8)
            }
            .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize)
            .background(EmbeddedAudioColors.controlPillSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(EmbeddedAudioColors.inspectorCardBorder, lineWidth: 0.5)
            )

            Spacer(minLength: 4)

            Menu {
                ForEach(speedOptions, id: \.self) { speed in
                    Button {
                        onSetPlaybackSpeed(speed)
                    } label: {
                        HStack {
                            if abs(playbackSpeed - speed) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                            Text(speed == 1.0 ? TTZipAudioPreviewLocalization.format(.normalPlaybackSpeedFormat, "1.0×") : String(format: "%.2g×", speed))
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
                .background(EmbeddedAudioColors.controlPillSurface)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(EmbeddedAudioColors.inspectorCardBorder, lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .ttButtonHelp(TTZipAudioPreviewLocalization.text(.changePlaybackSpeedHelp))
        }
    }
}

// MARK: - Audio Specs Inspection Grid

/// High-density DAW telemetry grid displaying codec, sample rate, channels, bitrate, and engine specs.
struct EmbeddedAudioSpecsGrid: View {
    let formatBadge: String
    let displayCodec: String
    let displaySampleRate: String
    let displayBitrate: String
    let displayChannels: String
    let fileSize: String
    let durationFormatted: String

    init(
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(TTZipAudioPreviewLocalization.text(.audioSpecsTitle), systemImage: "waveform.circle.fill")
                .font(.system(size: 10.5, weight: .bold, design: .serif))
                .foregroundStyle(EmbeddedAudioColors.kintsugiGold)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    specTag(title: TTZipAudioPreviewLocalization.text(.specFormat), value: formatBadge)
                    specTag(title: TTZipAudioPreviewLocalization.text(.specSampleRate), value: displaySampleRate)
                }
                GridRow {
                    specTag(title: TTZipAudioPreviewLocalization.text(.specBitrate), value: displayBitrate)
                    specTag(title: TTZipAudioPreviewLocalization.text(.specChannels), value: displayChannels)
                }
                GridRow {
                    specTag(title: TTZipAudioPreviewLocalization.text(.specFileSize), value: fileSize.isEmpty ? "--" : fileSize)
                    specTag(title: TTZipAudioPreviewLocalization.text(.specDuration), value: durationFormatted)
                }
            }
        }
        .padding(10)
        .background(EmbeddedAudioColors.controlPillSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(EmbeddedAudioColors.inspectorCardBorder, lineWidth: 0.5)
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
