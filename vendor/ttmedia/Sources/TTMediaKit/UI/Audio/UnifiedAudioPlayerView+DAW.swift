// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

extension UnifiedAudioPlayerView {

    // MARK: - Standard Expanded Audio Body (5-Tier Authentic Waveform + Specs Grid)

    @ViewBuilder
    public func standardDawPlayerBody(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let metrics = layoutMetrics(forWidth: availableWidth, height: availableHeight)

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: availableHeight > 460 ? 12 : 9) {
                // Tier 1: Small Artwork / Restrained Acoustic Placeholder + Track Info + Mini Player Entry
                inspectorTrackHeaderRow(metrics: metrics)

                // Tier 2, 3, 4: Diagnostic Error Card OR Authentic Waveform + Timecode + Transport Controls
                if shouldShowFatalDiagnosticCard {
                    diagnosticErrorCard
                } else {
                    AudioWaveformVisualizerView(
                        url: url,
                        audioEngine: audioEngine,
                        isPlaying: audioEngine.isPlaying,
                        currentTime: audioEngine.currentTime,
                        duration: audioEngine.duration,
                        sampleCount: 1600,
                        isCompact: false,
                        waveformHeight: metrics.waveformHeight,
                        availableWidth: metrics.availableWidth,
                        isWaveformOnlyPreview: isWaveformOnlyPreview,
                        windowedTileProvider: windowedTileProvider,
                        onSeek: { targetSeconds in
                            audioEngine.seek(to: targetSeconds)
                        }
                    )

                    if isWaveformOnlyPreview {
                        waveformOnlyNoticeBanner
                    }

                    AudioPlaybackControlsBar(
                        isPlaying: audioEngine.isPlaying,
                        volume: audioEngine.volume,
                        isMuted: audioEngine.isMuted,
                        playbackSpeed: audioEngine.playbackSpeed,
                        availableWidth: metrics.availableWidth,
                        isCompact: false,
                        isUltraCompact: false,
                        isPlaybackAvailable: isPlaybackAvailable,
                        onTogglePlayPause: { audioEngine.togglePlayPause() },
                        onSeekBy: { delta in audioEngine.seekBy(delta) },
                        onSetVolume: { v in audioEngine.setVolume(v) },
                        onToggleMute: { audioEngine.toggleMute() },
                        onSetPlaybackSpeed: { spd in audioEngine.setPlaybackSpeed(spd) }
                    )
                    .frame(maxWidth: .infinity)
                }

                // Tier 5: Audio Specs Inspection Grid
                AudioSpecsInspectionGrid(
                    formatBadge: formatBadge,
                    displayCodec: displayCodecName,
                    displaySampleRate: displaySampleRate,
                    displayBitrate: displayBitrate,
                    displayChannels: displayChannels,
                    fileSize: fileSizeFormatted,
                    durationFormatted: formatTimePrecise(audioEngine.duration)
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TTAudioTheme.inspectorCardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TTAudioTheme.inspectorCardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Track Header Section (Kept for Public Compatibility)

    public var trackHeaderSection: some View {
        let metrics = layoutMetrics(forWidth: 360, height: 380)
        return inspectorTrackHeaderRow(metrics: metrics)
    }

    public func headerBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.5))
    }

    // MARK: - Fail-Fast Diagnostic Card

    @ViewBuilder
    public var diagnosticErrorCard: some View {
        if audioEngine.hasPlaybackError {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TTAudioTheme.cinnabarRed)
                    Text(AudioPreviewLocalization.text(.playbackFailureTitle))
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(TTAudioTheme.cinnabarRed)
                        .lineLimit(1)
                    Spacer()
                    Text(formatBadge)
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(TTAudioTheme.cinnabarRed)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TTAudioTheme.cinnabarRed.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(audioEngine.errorMessage ?? AudioPreviewLocalization.text(.playbackDecodeError))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TTAudioTheme.controlPillSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack(spacing: 6) {
                    Button {
                        copyDiagnosticsToPasteboard()
                    } label: {
                        Label(
                            copySuccessToast ? AudioPreviewLocalization.text(.copied) : AudioPreviewLocalization.text(.copyDiagnostics),
                            systemImage: copySuccessToast ? "checkmark" : "doc.on.doc"
                        )
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize - 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(TTAudioTheme.kintsugiGold)

                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(AudioPreviewLocalization.text(.openExternal), systemImage: "arrow.up.right.square")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize - 4)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        ownedLoadGeneration = audioEngine.load(url: url, ownerSessionID: sessionId)
                    } label: {
                        Label(AudioPreviewLocalization.text(.retry), systemImage: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize - 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTAudioTheme.bambooGreen)
                }
            }
            .padding(10)
            .background(TTAudioTheme.cinnabarRed.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(TTAudioTheme.cinnabarRed.opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    private func copyDiagnosticsToPasteboard() {
        let rawDiag = audioEngine.diagnosticDetail ?? "N/A"
        let diagnostics = "[TTMedia Audio Diagnostics]\nFile: \(fileName)\nPath: \(url.path)\nFormat: \(formatBadge)\nEngine: AVAudioPlayer\nError: \(audioEngine.errorMessage ?? "Unknown error")\nUnderlying: \(rawDiag)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        copySuccessToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copySuccessToast = false
        }
    }
}
