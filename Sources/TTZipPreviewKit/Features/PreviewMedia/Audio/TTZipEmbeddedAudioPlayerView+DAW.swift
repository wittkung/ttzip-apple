// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit
import TTZipUI

extension TTZipEmbeddedAudioPlayerView {

    @ViewBuilder
    func standardDawPlayerBody(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let metrics = layoutMetrics(forWidth: availableWidth, height: availableHeight)

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: availableHeight > 460 ? 12 : 9) {
                inspectorTrackHeaderRow(metrics: metrics)

                if shouldShowFatalDiagnosticCard {
                    diagnosticErrorCard
                } else {
                    TTZipAudioWaveformView(
                        url: url,
                        audioEngine: audioEngine,
                        isCompact: false,
                        waveformHeight: metrics.waveformHeight,
                        availableWidth: metrics.availableWidth,
                        isWaveformOnlyPreview: isWaveformOnlyPreview
                    )

                    if isWaveformOnlyPreview {
                        waveformOnlyNoticeBanner
                    }

                    EmbeddedAudioControlsBar(
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

                EmbeddedAudioSpecsGrid(
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
                .fill(EmbeddedAudioColors.inspectorCardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(EmbeddedAudioColors.inspectorCardBorder, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    var diagnosticErrorCard: some View {
        if audioEngine.hasPlaybackError {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                    Text(TTZipAudioPreviewLocalization.text(.playbackFailureTitle))
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                        .lineLimit(1)
                    Spacer()
                    Text(formatBadge)
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TTZipTheme.cinnabarRed.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(audioEngine.errorMessage ?? AudioPreviewLocalization.text(.playbackDecodeError))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(EmbeddedAudioColors.controlPillSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack(spacing: 6) {
                    Button {
                        copyDiagnosticsToPasteboard()
                    } label: {
                        Label(
                            copySuccessToast ? TTZipAudioPreviewLocalization.text(.copied) : TTZipAudioPreviewLocalization.text(.copyDiagnostics),
                            systemImage: copySuccessToast ? "checkmark" : "doc.on.doc"
                        )
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize - 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(EmbeddedAudioColors.kintsugiGold)

                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(TTZipAudioPreviewLocalization.text(.openExternal), systemImage: "arrow.up.right.square")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize - 4)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        loadAudio(from: url)
                    } label: {
                        Label(TTZipAudioPreviewLocalization.text(.retry), systemImage: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .frame(minHeight: AudioInspectorLayoutMetrics.minimumHitTargetSize - 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(EmbeddedAudioColors.bambooGreen)
                }
            }
            .padding(10)
            .background(TTZipTheme.cinnabarRed.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(TTZipTheme.cinnabarRed.opacity(0.35), lineWidth: 0.5)
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
