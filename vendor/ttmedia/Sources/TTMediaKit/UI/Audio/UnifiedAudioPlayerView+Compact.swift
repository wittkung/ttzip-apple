// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

extension UnifiedAudioPlayerView {

    // MARK: - Compact Inspector Audio Body (5-Tier Authentic Waveform Layout)

    @ViewBuilder
    public func compactPlayerBody(
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        isUltraCompact: Bool
    ) -> some View {
        let metrics = layoutMetrics(forWidth: availableWidth, height: availableHeight)

        VStack(alignment: .leading, spacing: metrics.isUltraCompact ? 6 : 8) {
            // Tier 1: Small Artwork / Restrained Acoustic Placeholder + Track Info + Mini Player Entry
            inspectorTrackHeaderRow(metrics: metrics)

            // Tier 2 & 3 & 4: Diagnostic Error Card OR Authentic Waveform + Timecode + Transport Controls
            if shouldShowFatalDiagnosticCard {
                diagnosticErrorCard
            } else {
                // Tier 2 & 3: Authentic Waveform, Playhead Scrubbing & Timecode Footer
                compactWaveformScrubberView(
                    isUltraCompact: metrics.isUltraCompact,
                    availableWidth: metrics.availableWidth,
                    waveformHeight: metrics.waveformHeight
                )

                if isWaveformOnlyPreview {
                    waveformOnlyNoticeBanner
                }

                // Tier 4: Primary & Secondary Transport Controls (Play/Pause, Seek, Volume, Speed)
                compactControlsBar(
                    isUltraCompact: metrics.isUltraCompact,
                    availableWidth: metrics.availableWidth
                )
            }

            // Tier 5: Secondary Technical Attributes Strip
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
                .fill(TTAudioTheme.inspectorCardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TTAudioTheme.inspectorCardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Tier 1: Track Header Row (Small Artwork + Context-Clear Title + Mini Entry)

    @ViewBuilder
    public func inspectorTrackHeaderRow(metrics: AudioInspectorLayoutMetrics) -> some View {
        let showsPrimaryTitle = AudioInspectorLayoutMetrics.shouldDisplayCompactHeaderTitle(
            metadataTitle: audioTitle ?? audioEngine.metadata?.title,
            fileName: fileName,
            hostDisplaysFileName: hostDisplaysFileName && metrics.isCompact
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

    public var fallbackHeaderSubtitle: String? {
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
    public var waveformOnlyNoticeBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TTAudioTheme.kintsugiGold)
            Text(AudioPreviewLocalization.text(.waveformOnlyPreviewNotice))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(TTAudioTheme.kintsugiGold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(TTAudioTheme.kintsugiGold.opacity(0.28), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    public func compactAcousticPlaceholderView(size: CGFloat) -> some View {
        let isPlaying = audioEngine.isPlaying
        Button {
            guard isPlaybackAvailable else { return }
            audioEngine.togglePlayPause()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TTAudioTheme.bambooGreen.opacity(isPlaying ? 0.18 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                (isPlaying ? TTAudioTheme.bambooGreen : TTAudioTheme.kintsugiGold).opacity(0.35),
                                lineWidth: 0.5
                            )
                    )

                Image(systemName: isPlaying ? "waveform" : "music.note")
                    .font(.system(size: max(14, size * 0.38), weight: .semibold))
                    .foregroundStyle(isPlaying ? TTAudioTheme.bambooGreen : TTAudioTheme.kintsugiGold)
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
                ? AudioPreviewLocalization.text(isPlaying ? .clickToPauseHelp : .clickToPlayHelp)
                : AudioPreviewLocalization.text(.waveformOnlyPreviewNotice)
        )
    }

    @ViewBuilder
    public func detachMiniPlayerButton(showsTitle: Bool) -> some View {
        Button {
            presentDetachedMiniPlayer()
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: "pip.enter")
                    .font(.system(size: 10, weight: .semibold))
                if showsTitle {
                    Text(AudioPreviewLocalization.text(.miniPlayerBadge))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(TTAudioTheme.bambooGreen)
            .padding(.horizontal, showsTitle ? 8 : 7)
            .frame(
                minWidth: AudioInspectorLayoutMetrics.minimumHitTargetSize,
                minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize
            )
            .background(TTAudioTheme.bambooGreen.opacity(0.12))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(TTAudioTheme.bambooGreen.opacity(0.30), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(AudioPreviewLocalization.text(.detachMiniPlayerHelp))
    }

    public func presentDetachedMiniPlayer() {
        let currentStore = audioEngine
        currentStore.currentURL = url
        if let onDetachMiniPlayer {
            onDetachMiniPlayer(
                currentStore,
                displayTitle,
                audioArtist ?? audioEngine.metadata?.artist,
                albumArtImage
            )
        } else {
            TTAudioMiniPlayerPresenter.shared.present(
                store: currentStore,
                title: displayTitle,
                artist: audioArtist ?? audioEngine.metadata?.artist,
                artwork: albumArtImage,
                parentWindow: NSApp.keyWindow
            )
        }
    }

    public func compactTrackHeaderView(isUltraCompact: Bool) -> some View {
        let metrics = layoutMetrics(
            forWidth: isUltraCompact ? 280 : 360,
            height: isUltraCompact ? 240 : 300
        )
        return inspectorTrackHeaderRow(metrics: metrics)
    }

    // MARK: - Tier 2 & 3: Authentic Waveform Scrubber & Timecode

    public func compactWaveformScrubberView(
        isUltraCompact: Bool,
        availableWidth: CGFloat? = nil,
        waveformHeight: CGFloat? = nil
    ) -> some View {
        AudioWaveformVisualizerView(
            url: url,
            audioEngine: audioEngine,
            isPlaying: audioEngine.isPlaying,
            currentTime: audioEngine.currentTime,
            duration: audioEngine.duration,
            sampleCount: 1600,
            isCompact: true,
            waveformHeight: waveformHeight ?? (isUltraCompact ? 42 : 48),
            availableWidth: availableWidth,
            isWaveformOnlyPreview: isWaveformOnlyPreview,
            windowedTileProvider: windowedTileProvider,
            onSeek: { targetSeconds in
                audioEngine.seek(to: targetSeconds)
            }
        )
    }

    // MARK: - Tier 4: Playback Transport Controls

    public func compactControlsBar(
        isUltraCompact: Bool,
        availableWidth: CGFloat? = nil
    ) -> some View {
        AudioPlaybackControlsBar(
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

    // MARK: - Tier 5: Technical Specs Badges Footer

    public func compactSpecsBadgesBar(
        isUltraCompact: Bool,
        availableWidth: CGFloat? = nil
    ) -> some View {
        let width = availableWidth ?? (isUltraCompact ? 280 : 360)
        let isNarrow = width < 320
        let isWide = width >= 430

        return HStack(spacing: 5) {
            specPill(text: formatBadge, accentColor: TTAudioTheme.bambooGreen, isProminent: true)

            if isLossless {
                specPill(
                    text: AudioPreviewLocalization.text(.losslessBadge),
                    accentColor: TTAudioTheme.kintsugiGold,
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
            .background(isProminent ? accentColor.opacity(0.12) : TTAudioTheme.controlPillSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isProminent ? accentColor.opacity(0.28) : TTAudioTheme.inspectorCardBorder,
                    lineWidth: 0.5
                )
            )
    }
}
