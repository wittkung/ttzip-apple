// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit

extension TTZipEmbeddedAudioPlayerView {

    @ViewBuilder
    func compactPlayerBody(
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let metrics = layoutMetrics(forWidth: availableWidth, height: availableHeight)

        VStack(alignment: .leading, spacing: metrics.isUltraCompact ? 6 : 8) {
            inspectorTrackHeaderRow(metrics: metrics)

            if shouldShowFatalDiagnosticCard {
                diagnosticErrorCard
            } else {
                compactWaveformScrubberView(
                    isUltraCompact: metrics.isUltraCompact,
                    availableWidth: metrics.availableWidth,
                    waveformHeight: metrics.waveformHeight
                )

                if isWaveformOnlyPreview {
                    waveformOnlyNoticeBanner
                }

                compactControlsBar(
                    isUltraCompact: metrics.isUltraCompact,
                    availableWidth: metrics.availableWidth
                )
            }

            compactSpecsBadgesBar(
                isUltraCompact: metrics.isUltraCompact,
                availableWidth: metrics.availableWidth
            )
        }
        .padding(.vertical, metrics.isUltraCompact ? 8 : 10)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(EmbeddedAudioColors.inspectorCardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(EmbeddedAudioColors.inspectorCardBorder, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    func inspectorTrackHeaderRow(metrics: AudioInspectorLayoutMetrics) -> some View {
        let showsPrimaryTitle = AudioInspectorLayoutMetrics.shouldDisplayCompactHeaderTitle(
            metadataTitle: audioTitle ?? audioEngine.metadata?.title,
            fileName: fileName,
            hostDisplaysFileName: false
        )

        HStack(alignment: .center, spacing: 10) {
            if let artwork = albumArtImage {
                artworkCardView(
                    image: artwork,
                    size: metrics.artworkSize,
                    cornerRadius: 8,
                    shadowRadius: 4
                )
            } else {
                compactAcousticPlaceholderView(size: metrics.artworkSize)
            }

            VStack(alignment: .leading, spacing: 2) {
                if showsPrimaryTitle {
                    Text(displayTitle)
                        .font(.system(size: metrics.isUltraCompact ? 12.5 : 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(metrics.isUltraCompact ? 1 : 2)
                        .truncationMode(.middle)
                        .help(displayTitle)
                }

                if let subtitle = displaySubtitle ?? fallbackHeaderSubtitle {
                    Text(subtitle)
                        .font(.system(size: showsPrimaryTitle ? 10.5 : 11.5, weight: showsPrimaryTitle ? .regular : .medium))
                        .foregroundStyle(showsPrimaryTitle ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isPlaybackAvailable {
                detachMiniPlayerButton(showsTitle: metrics.showsMiniPlayerTitle)
            }
        }
    }

    var fallbackHeaderSubtitle: String? {
        var parts: [String] = []
        if !displayCodecName.isEmpty {
            parts.append(displayCodecName)
        }
        if displaySampleRate != "--" && !displaySampleRate.isEmpty {
            parts.append(displaySampleRate)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    var waveformOnlyNoticeBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EmbeddedAudioColors.kintsugiGold)
            Text(TTZipAudioPreviewLocalization.text(.waveformOnlyPreviewNotice))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(EmbeddedAudioColors.kintsugiGold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(EmbeddedAudioColors.kintsugiGold.opacity(0.28), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    func compactAcousticPlaceholderView(size: CGFloat) -> some View {
        let isPlaying = audioEngine.isPlaying
        Button {
            guard isPlaybackAvailable else { return }
            audioEngine.togglePlayPause()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(EmbeddedAudioColors.bambooGreen.opacity(isPlaying ? 0.18 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                (isPlaying ? EmbeddedAudioColors.bambooGreen : EmbeddedAudioColors.kintsugiGold).opacity(0.35),
                                lineWidth: 0.5
                            )
                    )

                Image(systemName: isPlaying ? "waveform" : "music.note")
                    .font(.system(size: max(14, size * 0.38), weight: .semibold))
                    .foregroundStyle(isPlaying ? EmbeddedAudioColors.bambooGreen : EmbeddedAudioColors.kintsugiGold)
            }
            .frame(
                width: max(size, AudioInspectorLayoutMetrics.minimumHitTargetSize),
                height: max(size, AudioInspectorLayoutMetrics.minimumHitTargetSize)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPlaybackAvailable)
        .ttButtonHelp(
            isPlaybackAvailable
                ? TTZipAudioPreviewLocalization.text(isPlaying ? .clickToPauseHelp : .clickToPlayHelp)
                : TTZipAudioPreviewLocalization.text(.waveformOnlyPreviewNotice)
        )
    }

    @ViewBuilder
    func detachMiniPlayerButton(showsTitle: Bool) -> some View {
        Button {
            presentDetachedMiniPlayer()
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: "pip.enter")
                    .font(.system(size: 10, weight: .semibold))
                if showsTitle {
                    Text(TTZipAudioPreviewLocalization.text(.miniPlayerBadge))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(EmbeddedAudioColors.bambooGreen)
            .padding(.horizontal, showsTitle ? 8 : 7)
            .frame(
                minWidth: AudioInspectorLayoutMetrics.minimumHitTargetSize,
                minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize
            )
            .background(EmbeddedAudioColors.bambooGreen.opacity(0.12))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(EmbeddedAudioColors.bambooGreen.opacity(0.30), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(TTZipAudioPreviewLocalization.text(.detachMiniPlayerHelp))
    }

    private func presentDetachedMiniPlayer() {
        let currentStore = audioEngine
        currentStore.currentURL = url
        onDetachMiniPlayer(
            currentStore,
            displayTitle,
            audioArtist ?? audioEngine.metadata?.artist,
            albumArtImage
        )
    }

    func compactWaveformScrubberView(
        isUltraCompact: Bool,
        availableWidth: CGFloat? = nil,
        waveformHeight: CGFloat? = nil
    ) -> some View {
        TTZipAudioWaveformView(
            url: url,
            audioEngine: audioEngine,
            isCompact: true,
            waveformHeight: waveformHeight ?? (isUltraCompact ? 42 : 48),
            availableWidth: availableWidth,
            isWaveformOnlyPreview: isWaveformOnlyPreview
        )
    }

    func compactControlsBar(
        isUltraCompact: Bool,
        availableWidth: CGFloat? = nil
    ) -> some View {
        EmbeddedAudioControlsBar(
            isPlaying: audioEngine.isPlaying,
            volume: audioEngine.volume,
            isMuted: audioEngine.isMuted,
            playbackSpeed: audioEngine.playbackSpeed,
            availableWidth: availableWidth,
            isCompact: true,
            isUltraCompact: isUltraCompact,
            isPlaybackAvailable: isPlaybackAvailable,
            onTogglePlayPause: { audioEngine.togglePlayPause() },
            onSeekBy: { delta in audioEngine.seekBy(delta) },
            onSetVolume: { v in audioEngine.setVolume(v) },
            onToggleMute: { audioEngine.toggleMute() },
            onSetPlaybackSpeed: { spd in audioEngine.setPlaybackSpeed(spd) }
        )
    }

    func compactSpecsBadgesBar(
        isUltraCompact: Bool,
        availableWidth: CGFloat? = nil
    ) -> some View {
        let width = availableWidth ?? (isUltraCompact ? 280 : 360)
        let isNarrow = width < 320
        let isWide = width >= 430

        return HStack(spacing: 5) {
            specPill(text: formatBadge, accentColor: EmbeddedAudioColors.bambooGreen, isProminent: true)

            if isLossless {
                specPill(
                    text: TTZipAudioPreviewLocalization.text(.losslessBadge),
                    accentColor: EmbeddedAudioColors.kintsugiGold,
                    isProminent: true
                )
            }

            if displaySampleRate != "--" && !displaySampleRate.isEmpty {
                specPill(text: displaySampleRate)
            }

            if displayBitrate != "--" && !displayBitrate.isEmpty {
                specPill(text: displayBitrate)
            }

            if !isNarrow, displayChannels != "--" && !displayChannels.isEmpty {
                specPill(text: displayChannels)
            }

            Spacer(minLength: 0)

            if isWide, !fileSizeFormatted.isEmpty && fileSizeFormatted != "--" {
                specPill(text: fileSizeFormatted)
            }
        }
    }

    private func specPill(
        text: String,
        accentColor: Color = .secondary,
        isProminent: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: 9, weight: isProminent ? .bold : .medium, design: .monospaced))
            .foregroundStyle(isProminent ? accentColor : .secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isProminent ? accentColor.opacity(0.12) : EmbeddedAudioColors.controlPillSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isProminent ? accentColor.opacity(0.28) : EmbeddedAudioColors.inspectorCardBorder,
                    lineWidth: 0.5
                )
            )
    }
}
