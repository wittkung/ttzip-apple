// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit

struct TTZipAudioWaveformView: View {
    let url: URL
    let audioEngine: MPVAudioEngine
    let isCompact: Bool
    let waveformHeight: CGFloat
    let availableWidth: CGFloat?
    let isWaveformOnlyPreview: Bool

    @State private var standaloneAnalysis: AudioWaveformAnalysis?
    @State private var isStandaloneExtracting = false
    @State private var tileCache = AudioWindowedWaveformTileCache()

    private enum Content {
        case extracting
        case unavailable
        case waveform(peaks: [Float], badge: Badge?)
    }

    private enum Badge {
        case waveformOnly
        case digitalSilence

        @MainActor
        var text: String {
            switch self {
            case .waveformOnly: TTZipAudioPreviewLocalization.text(.waveformOnlyPreviewBadge)
            case .digitalSilence: TTZipAudioPreviewLocalization.text(.digitalSilenceBadge)
            }
        }

        var color: Color {
            switch self {
            case .waveformOnly: EmbeddedAudioColors.kintsugiGold
            case .digitalSilence: EmbeddedAudioColors.bambooGreen
            }
        }
    }

    private var usesEngineWaveform: Bool {
        audioEngine.currentURL?.standardizedFileURL.resolvingSymlinksInPath() ==
            url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private var content: Content {
        let usesEngine = usesEngineWaveform
        let peaks = usesEngine && !audioEngine.waveformSamples.isEmpty
            ? audioEngine.waveformSamples
            : standaloneAnalysis?.peaks ?? []
        if peaks.isEmpty {
            let extracting = usesEngine
                ? audioEngine.isExtractingWaveform || audioEngine.isBuffering
                : isStandaloneExtracting
            return extracting ? .extracting : .unavailable
        }
        if isWaveformOnlyPreview {
            return .waveform(peaks: peaks, badge: .waveformOnly)
        }

        let precision = (usesEngine ? audioEngine.waveformPrecisionStatus : nil)
            ?? standaloneAnalysis?.precisionStatus
        let sampling = (usesEngine ? audioEngine.waveformSamplingMode : nil)
            ?? standaloneAnalysis?.samplingMode
        let showsSilence = precision != .sampledOrCompletenessUnverified
            && sampling != .windowedSampledEnvelope
            && isVerifiedSilence(usesEngine: usesEngine)
        return .waveform(peaks: peaks, badge: showsSilence ? .digitalSilence : nil)
    }

    private func isVerifiedSilence(usesEngine: Bool) -> Bool {
        guard usesEngine else { return standaloneAnalysis?.isVerifiedDigitalSilence == true }
        if audioEngine.isVerifiedDigitalSilence { return true }
        return audioEngine.isWaveformCompletenessVerified
            && audioEngine.waveformSamplingMode == .exhaustiveBucketPeak
            && !audioEngine.waveformSamples.isEmpty
            && audioEngine.waveformSamples.allSatisfy { abs($0) <= AudioWaveformWindowLimits.silencePeakFloor }
    }

    var body: some View {
        let content = content
        VStack(spacing: isCompact ? 4 : 6) {
            let shape = RoundedRectangle(cornerRadius: isCompact ? 7 : 8, style: .continuous)
            ZStack {
                shape.fill(WaveformColors.trackSurface)
                    .overlay(shape.strokeBorder(WaveformColors.trackBorder, lineWidth: 0.5))
                switch content {
                case .extracting:
                    extractionPlaceholder
                case .unavailable:
                    unavailablePlaceholder
                case .waveform(let peaks, _):
                    TTZipAudioWaveformTimeline(
                        url: url,
                        audioEngine: audioEngine,
                        peaks: peaks,
                        isCompact: isCompact,
                        tileCache: tileCache
                    )
                    .padding(.horizontal, isCompact ? 6 : 10)
                    .padding(.vertical, isCompact ? 4 : 6)
                }
            }
            .frame(height: max(36, waveformHeight))

            timecodeFooter(content)
        }
        .task(id: url) {
            tileCache.invalidateAll()
            await loadStandaloneWaveform()
        }
        .onDisappear {
            tileCache.invalidateAll()
        }
    }

    private func timecodeFooter(_ content: Content) -> some View {
        HStack(spacing: 6) {
            AudioWaveformTimecode(audioEngine: audioEngine)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            if case .waveform(_, let badge?) = content {
                Text(badge.text)
                    .font(.system(size: isCompact ? 8.5 : 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(badge.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(badge.color.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(badge.color.opacity(0.28), lineWidth: 0.5))
            } else if availableWidth.map({ $0 >= 310 }) ?? !isCompact {
                AudioWaveformLevelMeter(audioEngine: audioEngine, showsLabel: !isCompact)
            }

            Spacer(minLength: 4)

            Text(formatWaveformTimecode(audioEngine.duration))
                .font(.system(size: isCompact ? 10 : 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 2)
    }

    private var extractionPlaceholder: some View {
        let label = TTZipAudioPreviewLocalization.text(.extractingWaveform)
        return HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(EmbeddedAudioColors.bambooGreen)
            Text(label)
                .font(.system(size: isCompact ? 10 : 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(label)
    }

    private var unavailablePlaceholder: some View {
        let label = TTZipAudioPreviewLocalization.text(.waveformUnavailable)
        return HStack(spacing: 6) {
            Image(systemName: "waveform.slash")
                .font(.system(size: isCompact ? 11 : 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: isCompact ? 10 : 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(label)
    }

    private func loadStandaloneWaveform() async {
        standaloneAnalysis = nil
        if usesEngineWaveform && (!audioEngine.waveformSamples.isEmpty || audioEngine.isExtractingWaveform) {
            isStandaloneExtracting = false
            return
        }
        isStandaloneExtracting = true
        let analysis = await AudioWaveformExtractor.shared.extractWaveformAnalysis(from: url, targetSampleCount: 1600)
        guard !Task.isCancelled else { return }
        standaloneAnalysis = analysis
        isStandaloneExtracting = false
    }
}

private struct AudioWaveformTimecode: View {
    let audioEngine: MPVAudioEngine

    var body: some View {
        Text(formatWaveformTimecode(audioEngine.currentTime))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(EmbeddedAudioColors.bambooGreen)
            .lineLimit(1)
    }
}

private struct AudioWaveformLevelMeter: View {
    let audioEngine: MPVAudioEngine
    let showsLabel: Bool

    private var level: Float {
        guard audioEngine.isPlaying else { return 0 }
        return max(0, min(1, audioEngine.currentLevel))
    }

    var body: some View {
        HStack(spacing: 4) {
            if showsLabel {
                Text(TTZipAudioPreviewLocalization.text(.liveLevel))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(EmbeddedAudioColors.bambooGreen)
                        .frame(width: max(0, geo.size.width * CGFloat(level)))
                }
            }
            .frame(width: showsLabel ? 40 : 32, height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TTZipAudioPreviewLocalization.text(.liveLevelAccessibility))
        .accessibilityValue(TTZipAudioPreviewLocalization.format(.liveLevelPercentFormat, Int(level * 100)))
    }
}

private func formatWaveformTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite && seconds >= 0 else { return "00:00.00" }
    let wholeSeconds = Int(seconds)
    let centiseconds = Int(seconds.truncatingRemainder(dividingBy: 1) * 100)
    return String(format: "%02d:%02d.%02d", wholeSeconds / 60, wholeSeconds % 60, centiseconds)
}
