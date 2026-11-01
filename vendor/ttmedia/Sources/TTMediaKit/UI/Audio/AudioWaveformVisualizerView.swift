// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Explicit 6-state presentation state of the audio waveform visualizer.
public enum AudioWaveformDisplayState: Equatable, Sendable {
    /// Background waveform extraction is in progress and no peaks have arrived yet.
    case extracting
    /// Extraction completed or failed with no usable waveform samples.
    case unavailable
    /// Format supports authentic waveform preview & timeline scrubbing, but native playback is unavailable (e.g. `.ogg`/`.oga`/`.opus`).
    case waveformOnlyPreview(peaks: [Float])
    /// Authoritatively verified full-stream digital silence (`<= 0.0001` across the entire track).
    case verifiedSilence(peaks: [Float])
    /// Windowed sampled envelope or stream whose container completeness is unverified.
    case sampledOrUnverified(peaks: [Float])
    /// Exhaustively scanned and completeness-verified audible waveform envelope.
    case verifiedAudible(peaks: [Float])

    public var peaks: [Float] {
        switch self {
        case .extracting, .unavailable:
            return []
        case .waveformOnlyPreview(let peaks),
             .verifiedSilence(let peaks),
             .sampledOrUnverified(let peaks),
             .verifiedAudible(let peaks):
            return peaks
        }
    }

    public var hasWaveformBars: Bool {
        !peaks.isEmpty
    }
}

/// Acoustic Audio Waveform Visualizer featuring Voice-Memos style thin vertical ticks (`.voiceMemosTicks`),
/// default fixed-playhead scrolling local time-window viewport, and whole-track overview assist strip.
public struct AudioWaveformVisualizerView: View {
    public let url: URL?
    public let audioEngine: MPVAudioEngine?
    public let isPlaying: Bool
    public let currentTime: Double
    public let duration: Double
    public var sampleCount: Int = 1600
    public var isCompact: Bool = false
    public var waveformHeight: CGFloat? = nil
    public var availableWidth: CGFloat? = nil
    public var isWaveformOnlyPreview: Bool? = nil
    public var timelineMode: AudioTimelineViewportMode = .scrollingTimeWindow
    public var windowDuration: Double = AudioScrollingTimelineMapper.defaultWindowDuration
    public var showsOverviewStrip: Bool = false
    public var windowedTileProvider: (any AudioWaveformWindowedTileProviding)? = nil
    public var tileCache: AudioWindowedWaveformTileCache? = nil
    public var onSeek: ((Double) -> Void)? = nil

    @State private var standalonePeaks: [Float] = []
    @State private var standaloneSamplingMode: AudioWaveformSamplingMode? = nil
    @State private var standalonePrecisionStatus: AudioWaveformPrecisionStatus? = nil
    @State private var standaloneIsVerifiedSilence: Bool = false
    @State private var isStandaloneExtracting: Bool = false
    @State private var internalTileCache = AudioWindowedWaveformTileCache()

    public init(
        url: URL? = nil,
        audioEngine: MPVAudioEngine? = nil,
        isPlaying: Bool,
        currentTime: Double = 0,
        duration: Double = 0,
        sampleCount: Int = 1600,
        isCompact: Bool = false,
        waveformHeight: CGFloat? = nil,
        availableWidth: CGFloat? = nil,
        isWaveformOnlyPreview: Bool? = nil,
        timelineMode: AudioTimelineViewportMode = .scrollingTimeWindow,
        windowDuration: Double = AudioScrollingTimelineMapper.defaultWindowDuration,
        showsOverviewStrip: Bool = false,
        windowedTileProvider: (any AudioWaveformWindowedTileProviding)? = nil,
        tileCache: AudioWindowedWaveformTileCache? = nil,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.url = url
        self.audioEngine = audioEngine
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.sampleCount = sampleCount
        self.isCompact = isCompact
        self.waveformHeight = waveformHeight
        self.availableWidth = availableWidth
        self.isWaveformOnlyPreview = isWaveformOnlyPreview
        self.timelineMode = timelineMode
        self.windowDuration = max(1.0, windowDuration)
        self.showsOverviewStrip = showsOverviewStrip
        self.windowedTileProvider = windowedTileProvider
        self.tileCache = tileCache
        self.onSeek = onSeek
    }

    public var usesEngineWaveform: Bool {
        guard let audioEngine else { return false }
        guard let url else { return true }
        guard let engineURL = audioEngine.currentURL else { return false }
        return engineURL.standardizedFileURL.resolvingSymlinksInPath() ==
            url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public var effectivePeaks: [Float] {
        if usesEngineWaveform, let enginePeaks = audioEngine?.waveformSamples, !enginePeaks.isEmpty {
            return enginePeaks
        }
        return standalonePeaks
    }

    public var effectiveSamplingMode: AudioWaveformSamplingMode? {
        if usesEngineWaveform, let mode = audioEngine?.waveformSamplingMode {
            return mode
        }
        return standaloneSamplingMode
    }

    public var effectivePrecisionStatus: AudioWaveformPrecisionStatus? {
        if usesEngineWaveform, let status = audioEngine?.waveformPrecisionStatus {
            return status
        }
        return standalonePrecisionStatus
    }

    /// True when B-group format capability contract classifies the file as waveform-extractable but not natively playable (e.g. `.ogg`, `.oga`, `.opus`).
    public var isWaveformOnlyFormat: Bool {
        if let explicit = isWaveformOnlyPreview {
            return explicit
        }
        let targetURL = url ?? audioEngine?.currentURL
        if let ext = targetURL?.pathExtension, !ext.isEmpty {
            let support = MPVAudioEngine.formatSupport(forExtension: ext)
            if case .verifiedNativeCoreAudio(let spec) = support,
               spec.waveformExtracted && !spec.playbackVerified {
                return true
            }
        }
        if let audioEngine,
           !audioEngine.waveformSamples.isEmpty,
           audioEngine.failureReason == .outputEngineStartFailed {
            return true
        }
        return false
    }

    public var effectiveIsVerifiedSilence: Bool {
        if usesEngineWaveform, let audioEngine {
            if audioEngine.isVerifiedDigitalSilence {
                return true
            }
            if audioEngine.isWaveformCompletenessVerified,
               audioEngine.waveformSamplingMode == .exhaustiveBucketPeak,
               !audioEngine.waveformSamples.isEmpty,
               audioEngine.waveformSamples.allSatisfy({ abs($0) <= TTWaveformView.silenceAmplitudeThreshold }) {
                return true
            }
            return false
        }
        return standaloneIsVerifiedSilence
    }

    public var effectiveIsExtracting: Bool {
        if usesEngineWaveform, let audioEngine {
            return audioEngine.isExtractingWaveform || (audioEngine.isBuffering && effectivePeaks.isEmpty)
        }
        return isStandaloneExtracting
    }

    /// Resolves the canonical 6-state waveform presentation state from live engine or standalone data.
    public var resolvedDisplayState: AudioWaveformDisplayState {
        let peaks = effectivePeaks
        if effectiveIsExtracting && peaks.isEmpty {
            return .extracting
        }
        guard !peaks.isEmpty else {
            return .unavailable
        }
        if isWaveformOnlyFormat {
            return .waveformOnlyPreview(peaks: peaks)
        }
        if effectivePrecisionStatus == .sampledOrCompletenessUnverified ||
            effectiveSamplingMode == .windowedSampledEnvelope {
            return .sampledOrUnverified(peaks: peaks)
        }
        if effectiveIsVerifiedSilence {
            return .verifiedSilence(peaks: peaks)
        }
        return .verifiedAudible(peaks: peaks)
    }

    /// Checks whether the current track requires B-group high-resolution local tiles that are not yet connected.
    public var isLocalWindowAwaitingProvider: Bool {
        guard timelineMode == .scrollingTimeWindow, windowedTileProvider == nil else { return false }
        let peaks = effectivePeaks
        let resolvedDur = usesEngineWaveform ? (audioEngine?.duration ?? duration) : duration
        guard !peaks.isEmpty, resolvedDur > 0, resolvedDur.isFinite else { return false }
        let density = Double(peaks.count) / resolvedDur
        return density < AudioScrollingTimelineMapper.minimumWholeTrackBucketsPerSecond
    }

    /// Localized status badge text for waveform-only, sampled/unverified, local-window pending, or verified digital silence states.
    @MainActor
    public var statusBadgeText: String? {
        Self.statusBadge(for: resolvedDisplayState)
    }

    @MainActor
    static func statusBadge(for state: AudioWaveformDisplayState) -> String? {
        switch state {
        case .waveformOnlyPreview:
            return AudioPreviewLocalization.text(.waveformOnlyPreviewBadge)
        case .sampledOrUnverified:
            // Sampling quality is diagnostic metadata, not a playback integrity warning.
            return nil
        case .verifiedSilence:
            return AudioPreviewLocalization.text(.digitalSilenceBadge)
        case .verifiedAudible:
            return nil
        case .extracting, .unavailable:
            return nil
        }
    }

    /// Computes normalized playback progress in `[0.0, 1.0]`, safely guarding zero/NaN/infinite durations.
    public static func resolveProgressRatio(currentTime: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0.0 }
        return max(0.0, min(1.0, currentTime / duration))
    }

    /// Maps a normalized `[0.0, 1.0]` scrub ratio to target playback seconds, returning `nil` if duration is invalid.
    public static func resolveSeekSeconds(ratio: Double, duration: Double) -> Double? {
        guard duration.isFinite, duration > 0, ratio.isFinite else { return nil }
        let clampedRatio = max(0.0, min(1.0, ratio))
        return clampedRatio * duration
    }

    /// Maps a horizontal pointer coordinate within `width` to target playback seconds, clamping boundaries.
    public static func resolveSeekSeconds(locationX: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard width.isFinite, width > 0, locationX.isFinite else { return nil }
        let clampedX = max(0.0, min(width, locationX))
        let ratio = Double(clampedX / width)
        return resolveSeekSeconds(ratio: ratio, duration: duration)
    }

    private var effectiveCardHeight: CGFloat {
        if let waveformHeight {
            return max(36, waveformHeight)
        }
        return isCompact ? 46 : 62
    }

    private var isNarrowLayout: Bool {
        if let availableWidth {
            return availableWidth < 310
        }
        return isCompact
    }

    public var body: some View {
        let state = resolvedDisplayState
        let resolvedDuration = usesEngineWaveform ? (audioEngine?.duration ?? duration) : duration
        let activeCache = tileCache ?? internalTileCache

        VStack(spacing: isCompact ? 4 : 6) {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: isCompact ? 7 : 8, style: .continuous)
                    .fill(TTAudioTheme.waveformTrackSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: isCompact ? 7 : 8, style: .continuous)
                            .strokeBorder(TTAudioTheme.waveformTrackBorder, lineWidth: 0.5)
                    )

                switch state {
                case .extracting:
                    waveformExtractionPlaceholder
                case .unavailable:
                    waveformUnavailablePlaceholder
                case .waveformOnlyPreview(let peaks),
                     .verifiedSilence(let peaks),
                     .sampledOrUnverified(let peaks),
                     .verifiedAudible(let peaks):
                    AudioWaveformPlayheadLeafView(
                        url: url ?? audioEngine?.currentURL,
                        audioEngine: audioEngine,
                        fallbackCurrentTime: currentTime,
                        duration: resolvedDuration,
                        peaks: peaks,
                        isCompact: isCompact,
                        renderStyle: .voiceMemosTicks,
                        timelineMode: timelineMode,
                        windowDuration: windowDuration,
                        showsOverviewStrip: showsOverviewStrip,
                        windowedTileProvider: windowedTileProvider,
                        tileCache: activeCache,
                        onSeek: onSeek
                    )
                    .padding(.horizontal, isCompact ? 6 : 10)
                    .padding(.vertical, isCompact ? 4 : 6)
                }
            }
            .frame(height: effectiveCardHeight)

            waveformTimecodeFooter(state: state, resolvedDuration: resolvedDuration)
        }
        .task(id: url) {
            activeCache.invalidateAll()
            await loadStandaloneWaveformIfNeeded(for: url)
        }
        .onDisappear {
            activeCache.invalidateAll()
        }
    }

    @ViewBuilder
    private func waveformTimecodeFooter(state: AudioWaveformDisplayState, resolvedDuration: Double) -> some View {
        HStack(spacing: 6) {
            AudioTimecodeLeafView(audioEngine: audioEngine, fallbackCurrentTime: currentTime)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            if let badge = statusBadgeText {
                let badgeColor: Color = (state == .verifiedSilence(peaks: state.peaks))
                    ? TTAudioTheme.bambooGreen
                    : TTAudioTheme.kintsugiGold
                Text(badge)
                    .font(.system(size: isCompact ? 8.5 : 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(badgeColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(badgeColor.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(badgeColor.opacity(0.28), lineWidth: 0.5)
                    )
            } else if !isNarrowLayout {
                AudioLiveLevelMeterLeafView(audioEngine: audioEngine, showsLabel: !isCompact)
            }

            Spacer(minLength: 4)

            Text(Self.formatTimePrecise(resolvedDuration))
                .font(.system(size: isCompact ? 10 : 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 2)
    }

    private var waveformExtractionPlaceholder: some View {
        let label = AudioPreviewLocalization.text(.extractingWaveform)
        return HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(TTAudioTheme.bambooGreen)
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

    private var waveformUnavailablePlaceholder: some View {
        let label = AudioPreviewLocalization.text(.waveformUnavailable)
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

    @MainActor
    private func loadStandaloneWaveformIfNeeded(for targetURL: URL?) async {
        standalonePeaks = []
        standaloneSamplingMode = nil
        standalonePrecisionStatus = nil
        standaloneIsVerifiedSilence = false
        guard let targetURL else {
            isStandaloneExtracting = false
            return
        }
        if usesEngineWaveform && (!effectivePeaks.isEmpty || audioEngine?.isExtractingWaveform == true) {
            isStandaloneExtracting = false
            return
        }
        isStandaloneExtracting = true
        let analysis = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
            from: targetURL,
            targetSampleCount: sampleCount
        )
        guard !Task.isCancelled else { return }
        standalonePeaks = analysis?.peaks ?? []
        standaloneSamplingMode = analysis?.samplingMode
        standalonePrecisionStatus = analysis?.precisionStatus
        standaloneIsVerifiedSilence = analysis?.isVerifiedDigitalSilence ?? false
        isStandaloneExtracting = false
    }

    /// Formats time in `MM:SS.ms` for studio-precision display.
    public static func formatTimePrecise(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00.00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, ms)
    }
}

/// Leaf view rendering the Voice-Memos style scrolling time-window waveform and optional whole-track overview assist strip.
public struct AudioWaveformPlayheadLeafView: View {
    public let url: URL?
    public let audioEngine: MPVAudioEngine?
    public let fallbackCurrentTime: Double
    public let duration: Double
    public let peaks: [Float]
    public var isCompact: Bool = false
    public var renderStyle: TTWaveformRenderStyle = .voiceMemosTicks
    public var timelineMode: AudioTimelineViewportMode = .scrollingTimeWindow
    public var windowDuration: Double = AudioScrollingTimelineMapper.defaultWindowDuration
    public var showsOverviewStrip: Bool = false
    public var windowedTileProvider: (any AudioWaveformWindowedTileProviding)? = nil
    public var tileCache: AudioWindowedWaveformTileCache? = nil
    public let onSeek: ((Double) -> Void)?

    @State private var scrubPreviewTime: Double? = nil
    @State private var dragStartTime: Double? = nil

    public init(
        url: URL? = nil,
        audioEngine: MPVAudioEngine?,
        fallbackCurrentTime: Double,
        duration: Double,
        peaks: [Float],
        isCompact: Bool = false,
        renderStyle: TTWaveformRenderStyle = .voiceMemosTicks,
        timelineMode: AudioTimelineViewportMode = .scrollingTimeWindow,
        windowDuration: Double = AudioScrollingTimelineMapper.defaultWindowDuration,
        showsOverviewStrip: Bool = false,
        windowedTileProvider: (any AudioWaveformWindowedTileProviding)? = nil,
        tileCache: AudioWindowedWaveformTileCache? = nil,
        onSeek: ((Double) -> Void)?
    ) {
        self.url = url
        self.audioEngine = audioEngine
        self.fallbackCurrentTime = fallbackCurrentTime
        self.duration = duration
        self.peaks = peaks
        self.isCompact = isCompact
        self.renderStyle = renderStyle
        self.timelineMode = timelineMode
        self.windowDuration = max(1.0, windowDuration)
        self.showsOverviewStrip = showsOverviewStrip
        self.windowedTileProvider = windowedTileProvider
        self.tileCache = tileCache
        self.onSeek = onSeek
    }

    private var effectiveCurrentTime: Double {
        if let scrubPreviewTime {
            return scrubPreviewTime
        }
        return audioEngine?.currentTime ?? fallbackCurrentTime
    }

    private var effectiveDuration: Double {
        let engineDur = audioEngine?.duration ?? 0
        return engineDur > 0 ? engineDur : duration
    }

    private var progressRatio: Double {
        AudioWaveformVisualizerView.resolveProgressRatio(
            currentTime: effectiveCurrentTime,
            duration: effectiveDuration
        )
    }

    public var body: some View {
        let isSeekable = effectiveDuration.isFinite && effectiveDuration > 0
        let slotPitch: CGFloat = isCompact ? 3.0 : 3.4
        let tickWidth: CGFloat = isCompact ? 1.6 : 1.8

        VStack(spacing: isCompact ? 3 : 4) {
            GeometryReader { geo in
                let resolution = AudioScrollingTimelineMapper.resolveVisibleTicks(
                    currentTime: effectiveCurrentTime,
                    duration: effectiveDuration,
                    canvasWidth: geo.size.width,
                    slotPitch: slotPitch,
                    windowDuration: windowDuration,
                    wholeTrackPeaks: peaks,
                    tileCache: tileCache,
                    hasWindowedProvider: windowedTileProvider != nil,
                    resourceURL: url ?? audioEngine?.currentURL,
                    loadGeneration: audioEngine?.activeLoadGeneration ?? 0
                )

                if timelineMode == .scrollingTimeWindow,
                   resolution != .awaitingHighResTileProvider {
                    scrollingWindowCanvas(
                        size: geo.size,
                        resolution: resolution,
                        tickWidth: tickWidth,
                        isSeekable: isSeekable
                    )
                } else {
                    wholeTrackOverviewView(isSeekable: isSeekable, tickWidth: tickWidth)
                }
            }
            .frame(minHeight: isCompact ? 22 : 28)

            if showsOverviewStrip && timelineMode == .scrollingTimeWindow && effectiveDuration > 0 {
                wholeTrackAssistStrip(isSeekable: isSeekable)
                    .frame(height: isCompact ? 7 : 9)
            }
        }
        .onChange(of: effectiveCurrentTime) { _, newTime in
            triggerWindowTilePrefetch(at: newTime)
        }
        .onAppear {
            triggerWindowTilePrefetch(at: effectiveCurrentTime)
        }
    }

    private func triggerWindowTilePrefetch(at time: Double) {
        guard let provider = windowedTileProvider,
              let cache = tileCache,
              let targetURL = url ?? audioEngine?.currentURL else {
            return
        }
        let maxPeak = peaks.max() ?? 0.05
        cache.ensureVisibleTilesLoaded(
            currentTime: time,
            duration: effectiveDuration,
            windowDuration: windowDuration,
            resourceURL: targetURL,
            loadGeneration: audioEngine?.activeLoadGeneration ?? 0,
            ownerSessionID: audioEngine?.activeOwnerSessionID,
            stableReferencePeak: max(0.05, maxPeak),
            provider: provider
        )
    }

    @ViewBuilder
    private func scrollingWindowCanvas(
        size: CGSize,
        resolution: AudioScrollingWindowResolutionState,
        tickWidth: CGFloat,
        isSeekable: Bool
    ) -> some View {
        let ticks: [AudioScrollingWaveformTick] = {
            switch resolution {
            case .highResolutionTiles(let list),
                 .denseWholeTrackPeaks(let list),
                 .loadingWindowTile(let list):
                return list
            case .awaitingHighResTileProvider:
                return []
            }
        }()

        AudioScrollingWaveformCanvas(ticks: ticks, tickWidth: tickWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isSeekable, size.width > 1.0 else { return }
                    if dragStartTime == nil {
                        dragStartTime = effectiveCurrentTime
                    }
                    let anchor = dragStartTime ?? effectiveCurrentTime
                    if abs(value.translation.width) < 1.5 {
                        scrubPreviewTime = AudioScrollingTimelineMapper.resolveClickTargetTime(
                            currentTime: anchor,
                            clickX: value.location.x,
                            canvasWidth: size.width,
                            windowDuration: windowDuration,
                            duration: effectiveDuration
                        )
                    } else {
                        scrubPreviewTime = AudioScrollingTimelineMapper.resolveDragPreviewTime(
                            dragStartTime: anchor,
                            translationX: value.translation.width,
                            canvasWidth: size.width,
                            windowDuration: windowDuration,
                            duration: effectiveDuration
                        )
                    }
                    if let preview = scrubPreviewTime {
                        triggerWindowTilePrefetch(at: preview)
                    }
                }
                .onEnded { value in
                    guard isSeekable, size.width > 1.0 else { return }
                    let anchor = dragStartTime ?? effectiveCurrentTime
                    let finalTarget: Double?
                    if abs(value.translation.width) < 1.5 {
                        finalTarget = AudioScrollingTimelineMapper.resolveClickTargetTime(
                            currentTime: anchor,
                            clickX: value.location.x,
                            canvasWidth: size.width,
                            windowDuration: windowDuration,
                            duration: effectiveDuration
                        )
                    } else {
                        finalTarget = AudioScrollingTimelineMapper.resolveDragPreviewTime(
                            dragStartTime: anchor,
                            translationX: value.translation.width,
                            canvasWidth: size.width,
                            windowDuration: windowDuration,
                            duration: effectiveDuration
                        )
                    }
                    dragStartTime = nil
                    scrubPreviewTime = nil
                    if let finalTarget {
                        onSeek?(finalTarget)
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AudioPreviewLocalization.text(.scrollingWaveformAccessibilityLabel))
    }

    @ViewBuilder
    private func wholeTrackOverviewView(isSeekable: Bool, tickWidth: CGFloat) -> some View {
        TTWaveformView(
            waveformPeaks: peaks,
            progress: progressRatio,
            onSeek: { ratio in
                guard let targetSeconds = AudioWaveformVisualizerView.resolveSeekSeconds(
                    ratio: ratio,
                    duration: effectiveDuration
                ) else { return }
                onSeek?(targetSeconds)
            },
            activeColor: TTAudioTheme.bambooGreen,
            inactiveColor: TTAudioTheme.waveformInactiveBar,
            playheadColor: TTAudioTheme.kintsugiGold,
            barWidth: tickWidth,
            barSpacing: isCompact ? 1.4 : 1.6,
            cornerRadius: tickWidth * 0.5,
            isInteractive: isSeekable,
            renderStyle: renderStyle
        )
    }

    @ViewBuilder
    private func wholeTrackAssistStrip(isSeekable: Bool) -> some View {
        TTWaveformView(
            waveformPeaks: peaks,
            progress: progressRatio,
            onSeek: { ratio in
                guard let targetSeconds = AudioWaveformVisualizerView.resolveSeekSeconds(
                    ratio: ratio,
                    duration: effectiveDuration
                ) else { return }
                onSeek?(targetSeconds)
            },
            activeColor: TTAudioTheme.bambooGreen.opacity(0.82),
            inactiveColor: TTAudioTheme.waveformInactiveBar.opacity(0.55),
            playheadColor: TTAudioTheme.kintsugiGold,
            barWidth: 1.2,
            barSpacing: 1.2,
            cornerRadius: 0.6,
            isInteractive: isSeekable,
            renderStyle: .voiceMemosTicks
        )
        .accessibilityLabel(AudioPreviewLocalization.text(.overviewScrubberAccessibilityLabel))
    }
}

/// Isolated real-time level meter leaf component kept strictly separate from whole-track waveform samples.
public struct AudioLiveLevelMeterLeafView: View {
    public let audioEngine: MPVAudioEngine?
    public var showsLabel: Bool = true

    public init(audioEngine: MPVAudioEngine?, showsLabel: Bool = true) {
        self.audioEngine = audioEngine
        self.showsLabel = showsLabel
    }

    private var level: Float {
        guard let audioEngine, audioEngine.isPlaying else { return 0.0 }
        return max(0.0, min(1.0, audioEngine.currentLevel))
    }

    public var body: some View {
        HStack(spacing: 4) {
            if showsLabel {
                Text(AudioPreviewLocalization.text(.liveLevel))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(TTAudioTheme.bambooGreen)
                        .frame(width: max(0, geo.size.width * CGFloat(level)))
                }
            }
            .frame(width: showsLabel ? 40 : 32, height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AudioPreviewLocalization.text(.liveLevelAccessibility))
        .accessibilityValue(AudioPreviewLocalization.format(.liveLevelPercentFormat, Int(level * 100)))
    }
}

/// Isolated timecode text leaf component.
public struct AudioTimecodeLeafView: View {
    public let audioEngine: MPVAudioEngine?
    public let fallbackCurrentTime: Double

    public init(audioEngine: MPVAudioEngine?, fallbackCurrentTime: Double) {
        self.audioEngine = audioEngine
        self.fallbackCurrentTime = fallbackCurrentTime
    }

    private var currentTime: Double {
        audioEngine?.currentTime ?? fallbackCurrentTime
    }

    public var body: some View {
        Text(AudioWaveformVisualizerView.formatTimePrecise(currentTime))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(TTAudioTheme.bambooGreen)
            .lineLimit(1)
    }
}
