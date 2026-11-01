// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import AVFoundation
import Foundation
import SwiftUI
import TTI18nCore
import XCTest
@testable import TTMediaKit

@MainActor
final class AudioInspectorLayoutAndWaveformTests: XCTestCase {

    private var isolatedSampleDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        isolatedSampleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("A2AudioInspectorSamples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedSampleDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let isolatedSampleDir {
            try? FileManager.default.removeItem(at: isolatedSampleDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Width Tiers, Layout Metrics & Compact Header Title Deduplication

    func testInspectorLayoutMetricsAndCompactTitleDeduplication() {
        let narrowLow = AudioInspectorLayoutMetrics(availableWidth: 280, availableHeight: 220)
        XCTAssertEqual(narrowLow.widthTier, .narrow)
        XCTAssertTrue(narrowLow.isCompact)
        XCTAssertTrue(narrowLow.isUltraCompact)
        XCTAssertFalse(narrowLow.showsExtendedCompactSpecs)
        XCTAssertGreaterThanOrEqual(narrowLow.waveformHeight, 40.0)
        XCTAssertGreaterThanOrEqual(narrowLow.secondaryButtonMinSize, 28.0)

        let regularNormal = AudioInspectorLayoutMetrics(availableWidth: 360, availableHeight: 300)
        XCTAssertEqual(regularNormal.widthTier, .regular)
        XCTAssertTrue(regularNormal.isCompact)
        XCTAssertFalse(regularNormal.isUltraCompact)
        XCTAssertTrue(regularNormal.showsExtendedCompactSpecs)

        let wideExpanded = AudioInspectorLayoutMetrics(availableWidth: 480, availableHeight: 440)
        XCTAssertEqual(wideExpanded.widthTier, .wide)
        XCTAssertFalse(wideExpanded.isCompact)
        XCTAssertTrue(wideExpanded.showsFullSpecsGrid)

        // When host inspector already displays fileName, suppress duplicate filename in compact header
        XCTAssertFalse(
            AudioInspectorLayoutMetrics.shouldDisplayCompactHeaderTitle(
                metadataTitle: nil,
                fileName: "VoiceMemo_2026_10_17.m4a",
                hostDisplaysFileName: true
            )
        )
        XCTAssertFalse(
            AudioInspectorLayoutMetrics.shouldDisplayCompactHeaderTitle(
                metadataTitle: "VoiceMemo_2026_10_17",
                fileName: "VoiceMemo_2026_10_17.m4a",
                hostDisplaysFileName: true
            )
        )
        XCTAssertTrue(
            AudioInspectorLayoutMetrics.shouldDisplayCompactHeaderTitle(
                metadataTitle: "Interview Episode 04",
                fileName: "VoiceMemo_2026_10_17.m4a",
                hostDisplaysFileName: true
            )
        )
    }

    // MARK: - 2. Five Sample Categories & Unified 0.0001 Silence / Low-Amplitude Threshold

    func testVoiceMemosTicksAcrossFiveSampleCategoriesAndUnifiedSilencePolicy() async throws {
        let defaultShared = TTWaveformView(waveformPeaks: [0.2, 0.5, 0.9], progress: 0.5)
        XCTAssertEqual(defaultShared.renderStyle, .discreteBars)

        // Verify unified 0.0001 threshold in TTWaveformView.resolveVoiceMemosTickHeight
        let silentTickHeight = TTWaveformView.resolveVoiceMemosTickHeight(amplitude: 0.0, canvasHeight: 48.0)
        let subThresholdHeight = TTWaveformView.resolveVoiceMemosTickHeight(amplitude: 0.00008, canvasHeight: 48.0)
        let lowAudibleHeight = TTWaveformView.resolveVoiceMemosTickHeight(amplitude: 0.0004, canvasHeight: 48.0)
        let fullPeakHeight = TTWaveformView.resolveVoiceMemosTickHeight(amplitude: 1.0, canvasHeight: 48.0)

        XCTAssertEqual(silentTickHeight, 1.5, accuracy: 0.01)
        XCTAssertEqual(subThresholdHeight, 1.5, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(lowAudibleHeight, 3.2)
        XCTAssertEqual(fullPeakHeight, 48.0 * 0.90, accuracy: 0.05)

        // Category 1: Reproducible real speech fixture (committed in repo, zero .gemini dependency)
        let speechDesc = try AudioSpeechTestSampleFixtures.writeReproducibleRealSpeechWAV(
            to: isolatedSampleDir.appendingPathComponent("01_Real_Speech_Voiceover.wav")
        )
        XCTAssertEqual(speechDesc.sourceKind, .reproducibleRealSpeechFixture)

        // Category 2: Real speech with explicit 0.55s pauses
        let pausedSpeechDesc = try AudioSpeechTestSampleFixtures.writeRealSpeechWithExplicitPausesWAV(
            to: isolatedSampleDir.appendingPathComponent("02_Real_Speech_With_Pauses.wav")
        )
        XCTAssertEqual(pausedSpeechDesc.sourceKind, .reproducibleRealSpeechFixture)

        // Category 3: Synthetic music chord progression
        let musicDesc = try AudioSpeechTestSampleFixtures.writeSyntheticMusicProgressionWAV(
            to: isolatedSampleDir.appendingPathComponent("03_Synthetic_Music_Progression.wav")
        )
        XCTAssertEqual(musicDesc.sourceKind, .syntheticTestSample)

        // Category 4: Low-amplitude audible signal (peak = 0.0004 > 0.0001)
        let lowAmpDesc = try AudioSpeechTestSampleFixtures.writeSyntheticLowAmplitudeAudibleWAV(
            to: isolatedSampleDir.appendingPathComponent("04_Low_Amplitude_Audible.wav"),
            peakAmplitude: 0.0004
        )
        XCTAssertEqual(lowAmpDesc.sourceKind, .syntheticTestSample)

        // Category 5: Digital silence (0.0)
        let silenceDesc = try AudioSpeechTestSampleFixtures.writeDigitalSilenceWAV(
            to: isolatedSampleDir.appendingPathComponent("05_Digital_Silence.wav")
        )
        XCTAssertEqual(silenceDesc.sourceKind, .syntheticTestSample)

        try await verifyExtractedSampleCategory(speechDesc, expectsSilence: false, expectsPauses: true)
        try await verifyExtractedSampleCategory(pausedSpeechDesc, expectsSilence: false, expectsPauses: true)
        try await verifyExtractedSampleCategory(musicDesc, expectsSilence: false, expectsPauses: false)
        try await verifyExtractedSampleCategory(lowAmpDesc, expectsSilence: false, expectsPauses: false)
        try await verifyExtractedSampleCategory(silenceDesc, expectsSilence: true, expectsPauses: true)
    }

    private func verifyExtractedSampleCategory(
        _ descriptor: AudioTestSampleDescriptor,
        expectsSilence: Bool,
        expectsPauses: Bool
    ) async throws {
        let engine = MPVAudioEngine()
        defer { engine.stop() }

        _ = engine.load(url: descriptor.url, ownerSessionID: "cat-\(descriptor.url.lastPathComponent)")
        await waitUntilWaveformSettled(on: engine)

        XCTAssertFalse(engine.hasPlaybackError, "Unexpected playback error on \(descriptor.description)")
        XCTAssertFalse(engine.waveformSamples.isEmpty)
        XCTAssertEqual(engine.isVerifiedDigitalSilence, expectsSilence, "Silence mismatch for \(descriptor.description)")

        if expectsSilence {
            XCTAssertLessThanOrEqual(engine.waveformSamples.max() ?? 1.0, 0.0001)
        } else {
            XCTAssertGreaterThan(engine.waveformSamples.max() ?? 0.0, 0.0001)
        }
        if expectsPauses && !expectsSilence {
            let nearZeroCount = engine.waveformSamples.filter { $0 < 0.05 }.count
            XCTAssertGreaterThan(nearZeroCount, 15, "Expected discernible pause valleys in \(descriptor.description)")
        }
    }

    // MARK: - 3. Fixed-Playhead Scrolling Viewport, Boundaries, Speed Invariance & Scrubbing

    func testFixedPlayheadScrollingBoundariesSpeedInvarianceAndPullScrubbing() {
        let peaks = (0..<600).map { idx -> Float in
            let phase = Double(idx) / 25.0
            return (idx % 40 < 8) ? 0.0 : Float(min(0.95, 0.15 + 0.75 * abs(sin(phase))))
        }
        let duration = 20.0
        let windowSpan = 6.0
        let canvasWidth: CGFloat = 240.0
        let centerX = canvasWidth * 0.5

        // Start boundary (t = 0): left of fixed center playhead must have zero fabricated ticks (all ticks >= centerX)
        let startState = AudioScrollingTimelineMapper.resolveVisibleTicks(
            currentTime: 0.0,
            duration: duration,
            canvasWidth: canvasWidth,
            slotPitch: 3.0,
            windowDuration: windowSpan,
            wholeTrackPeaks: peaks
        )
        guard case .denseWholeTrackPeaks(let startTicks) = startState else {
            return XCTFail("Expected denseWholeTrackPeaks at start boundary")
        }
        XCTAssertFalse(startTicks.isEmpty)
        XCTAssertTrue(startTicks.allSatisfy { $0.xPosition >= centerX && $0.trackTime >= 0.0 })

        // Middle (t = 10.0): both sides within track bounds; left of center is played, right is unplayed
        let midState = AudioScrollingTimelineMapper.resolveVisibleTicks(
            currentTime: 10.0,
            duration: duration,
            canvasWidth: canvasWidth,
            slotPitch: 3.0,
            windowDuration: windowSpan,
            wholeTrackPeaks: peaks
        )
        guard case .denseWholeTrackPeaks(let midTicks) = midState else {
            return XCTFail("Expected denseWholeTrackPeaks at midpoint")
        }
        XCTAssertTrue(midTicks.filter { $0.xPosition < centerX - 1.0 }.allSatisfy { $0.isPlayed })
        XCTAssertTrue(midTicks.filter { $0.xPosition > centerX + 1.0 }.allSatisfy { !$0.isPlayed })

        // End boundary (t = duration): right of fixed center playhead must have zero fabricated ticks (all ticks <= centerX)
        let endState = AudioScrollingTimelineMapper.resolveVisibleTicks(
            currentTime: duration,
            duration: duration,
            canvasWidth: canvasWidth,
            slotPitch: 3.0,
            windowDuration: windowSpan,
            wholeTrackPeaks: peaks
        )
        guard case .denseWholeTrackPeaks(let endTicks) = endState else {
            return XCTFail("Expected denseWholeTrackPeaks at end boundary")
        }
        XCTAssertFalse(endTicks.isEmpty)
        XCTAssertTrue(endTicks.allSatisfy { $0.xPosition <= centerX && $0.trackTime <= duration })

        // Pull-to-scrub gesture mapping: dragging left (-60pt on 240pt width over 6s window) advances time by +1.5s
        let scrubbedForward = AudioScrollingTimelineMapper.resolveDragPreviewTime(
            dragStartTime: 10.0,
            translationX: -60.0,
            canvasWidth: canvasWidth,
            windowDuration: windowSpan,
            duration: duration
        )
        XCTAssertEqual(scrubbedForward ?? -1, 11.5, accuracy: 0.001)

        // Clamping at [0, duration]
        let clampedZero = AudioScrollingTimelineMapper.resolveDragPreviewTime(
            dragStartTime: 1.0,
            translationX: 200.0,
            canvasWidth: canvasWidth,
            windowDuration: windowSpan,
            duration: duration
        )
        XCTAssertEqual(clampedZero ?? -1, 0.0, accuracy: 0.001)
    }

    // MARK: - 4. Long Audio (>= 30 min) Local Tile Provider & Deduplication Cache

    func testThirtyMinuteLongAudioHonestyAndWindowedTileDeduplication() async throws {
        let thirtyMinDuration = 1_800.0 // 30 minutes
        let wholeTrack1600Peaks = [Float](repeating: 0.42, count: 1600)

        // Without local tile provider: 1600 / 1800s = 0.88 buckets/sec (< 12 buckets/sec).
        // Mapper MUST refuse to stretch whole-track peaks into fake local detail.
        let unstretchedState = AudioScrollingTimelineMapper.resolveVisibleTicks(
            currentTime: 600.0,
            duration: thirtyMinDuration,
            canvasWidth: 288.0,
            slotPitch: 3.0,
            windowDuration: 6.0,
            wholeTrackPeaks: wholeTrack1600Peaks,
            tileCache: nil,
            hasWindowedProvider: false
        )
        XCTAssertEqual(unstretchedState, .awaitingHighResTileProvider)

        // With MockWindowedWaveformTileProvider + AudioWindowedWaveformTileCache:
        let mockProvider = MockWindowedWaveformTileProvider()
        let tileCache = AudioWindowedWaveformTileCache()
        let longURL = isolatedSampleDir.appendingPathComponent("30Min_Lecture_Archive.wav")

        // Simulate 10 consecutive 30Hz playback frames around t = 602.0..602.3s within the same 6s quantized tile
        for frame in 0..<10 {
            let playhead = 602.0 + Double(frame) * 0.033
            tileCache.ensureVisibleTilesLoaded(
                currentTime: playhead,
                duration: thirtyMinDuration,
                windowDuration: 6.0,
                resourceURL: longURL,
                loadGeneration: 1,
                provider: mockProvider
            )
        }
        // Allow async tile task to complete
        let deadline = Date().addingTimeInterval(2.0)
        while !tileCache.inFlightKeys.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }

        let providerCallCount = await mockProvider.recordedRequestCount()
        XCTAssertEqual(
            providerCallCount,
            tileCache.cachedTiles.count,
            "Tile cache must deduplicate requests across 30Hz refresh ticks for the same visible tile keys"
        )

        let tiledState = AudioScrollingTimelineMapper.resolveVisibleTicks(
            currentTime: 602.0,
            duration: thirtyMinDuration,
            canvasWidth: 288.0,
            slotPitch: 3.0,
            windowDuration: 6.0,
            wholeTrackPeaks: wholeTrack1600Peaks,
            tileCache: tileCache,
            hasWindowedProvider: true,
            resourceURL: longURL,
            loadGeneration: 1
        )
        guard case .highResolutionTiles(let ticks) = tiledState else {
            return XCTFail("Expected highResolutionTiles from MockWindowedWaveformTileProvider, got \(tiledState)")
        }
        XCTAssertGreaterThan(ticks.count, 40)
        XCTAssertTrue(ticks.contains { $0.amplitude > 0.3 })
        XCTAssertTrue(ticks.contains { $0.amplitude == 0.0 })
    }

    // MARK: - 5. Waveform-Only Preview State (.ogg / .oga / .opus) & Lifecycle Isolation

    func testOggWaveformOnlyPreviewKeepsWaveformAndDisablesNativePlay() async throws {
        let oggURL = isolatedSampleDir.appendingPathComponent("Archive_Voice_Note.ogg")
        _ = try AudioSpeechTestSampleFixtures.writeReproducibleRealSpeechWAV(to: oggURL)

        let engine = MPVAudioEngine()
        defer { engine.stop() }
        _ = engine.load(url: oggURL, ownerSessionID: "ogg-waveform-only-session")
        await waitUntilWaveformSettled(on: engine)

        let playerView = UnifiedAudioPlayerView(
            url: oggURL,
            fileName: oggURL.lastPathComponent,
            audioEngine: engine,
            hostDisplaysFileName: true
        )
        XCTAssertTrue(playerView.isWaveformOnlyPreview)
        XCTAssertFalse(playerView.isPlaybackAvailable)
        XCTAssertFalse(playerView.shouldShowFatalDiagnosticCard)

        let visualizer = AudioWaveformVisualizerView(
            url: oggURL,
            audioEngine: engine,
            isPlaying: false,
            currentTime: 1.2,
            duration: max(1.0, engine.duration),
            isCompact: true,
            waveformHeight: 48,
            availableWidth: 360,
            isWaveformOnlyPreview: true
        )
        XCTAssertFalse(visualizer.effectivePeaks.isEmpty)
        XCTAssertEqual(visualizer.resolvedDisplayState, .waveformOnlyPreview(peaks: visualizer.effectivePeaks))
        XCTAssertEqual(visualizer.statusBadgeText, AudioPreviewLocalization.text(.waveformOnlyPreviewBadge))
    }

    func testRapidSwitchingAndSidebarResizingPreservesLifecycleIsolation() async throws {
        let speechA = try AudioSpeechTestSampleFixtures.writeReproducibleRealSpeechWAV(
            to: isolatedSampleDir.appendingPathComponent("Switch_A_Speech.wav")
        ).url
        let silenceB = try AudioSpeechTestSampleFixtures.writeDigitalSilenceWAV(
            to: isolatedSampleDir.appendingPathComponent("Switch_B_Silence.wav")
        ).url
        let speechC = try AudioSpeechTestSampleFixtures.writeRealSpeechWithExplicitPausesWAV(
            to: isolatedSampleDir.appendingPathComponent("Switch_C_PausedSpeech.wav")
        ).url

        let engine = MPVAudioEngine()
        defer { engine.stop() }

        let genA = engine.load(url: speechA, ownerSessionID: "s-A")
        let genB = engine.load(url: silenceB, ownerSessionID: "s-B")
        let genC = engine.load(url: speechC, ownerSessionID: "s-C")

        engine.stopIfCurrent(url: speechA, generation: genA, sessionID: "s-A")
        engine.stopIfCurrent(url: silenceB, generation: genB, sessionID: "s-B")
        XCTAssertEqual(engine.currentURL, speechC)
        XCTAssertEqual(engine.activeLoadGeneration, genC)

        await waitUntilWaveformSettled(on: engine)
        XCTAssertEqual(engine.currentURL, speechC)
        XCTAssertFalse(engine.isVerifiedDigitalSilence)
        XCTAssertGreaterThan(engine.waveformSamples.max() ?? 0, 0.2)
    }

    // MARK: - 6. Multi-Width Dark/Light Snapshot Export for Voice Memos Ticks

    func testExportVoiceMemosTicksSnapshotsAcrossWidthsAndAppearances() async throws {
        let originalBCP47 = AudioPreviewLocalization.currentLanguageBCP47
        defer { AudioPreviewLocalization.setLanguage(bcp47: originalBCP47) }
        AudioPreviewLocalization.setLanguage(bcp47: "zh-Hans")

        let speechDesc = try AudioSpeechTestSampleFixtures.writeRealSpeechWithExplicitPausesWAV(
            to: isolatedSampleDir.appendingPathComponent("语音备忘录参考样本_VoiceMemos_Speech_With_Pauses.wav")
        )
        let engine = MPVAudioEngine()
        defer { engine.stop() }

        _ = engine.load(url: speechDesc.url, ownerSessionID: "snapshot-session")
        await waitUntilWaveformSettled(on: engine)
        let seekTime = min(max(0.8, engine.duration * 0.42), max(0.1, engine.duration - 0.2))
        engine.seek(to: seekTime)

        let view = UnifiedAudioPlayerView(
            url: speechDesc.url,
            fileName: speechDesc.url.lastPathComponent,
            audioEngine: engine,
            hostDisplaysFileName: true
        )
        let hosting = NSHostingView(rootView: view)

        for width in [CGFloat(280), CGFloat(360), CGFloat(480)] {
            for appearanceName in [NSAppearance.Name.darkAqua, NSAppearance.Name.aqua] {
                hosting.appearance = NSAppearance(named: appearanceName)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: 248)
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 35_000_000)
                hosting.layoutSubtreeIfNeeded()

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    XCTFail("Failed to allocate bitmapImageRep for width \(Int(width))")
                    continue
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let outDir = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"],
                   let pngData = rep.representation(using: .png, properties: [:]) {
                    let themeTag = (appearanceName == .darkAqua) ? "dark" : "light"
                    let outURL = URL(fileURLWithPath: outDir)
                        .appendingPathComponent("a2_voicememos_\(Int(width))pt_\(themeTag).png")
                    try? pngData.write(to: outURL)
                }
            }
        }
    }

    func testExportScrollingPlaybackAndScrubbingFrameSequence() async throws {
        guard let outDir = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] else { return }
        let speechDesc = try AudioSpeechTestSampleFixtures.writeRealSpeechWithExplicitPausesWAV(
            to: isolatedSampleDir.appendingPathComponent("Scrolling_Demo_VoiceMemos.wav")
        )
        let engine = MPVAudioEngine()
        defer { engine.stop() }

        _ = engine.load(url: speechDesc.url, ownerSessionID: "scrolling-video-session")
        await waitUntilWaveformSettled(on: engine)

        let view = UnifiedAudioPlayerView(
            url: speechDesc.url,
            fileName: speechDesc.url.lastPathComponent,
            audioEngine: engine,
            hostDisplaysFileName: true
        )
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 248)

        let totalDur = max(2.0, engine.duration)
        // Simulate playback progression (0.0 -> 0.85 * duration) then scrub back to 0.30 * duration
        let timeSteps: [Double] = (0..<18).map { Double($0) / 17.0 * (totalDur * 0.85) }
            + [totalDur * 0.70, totalDur * 0.52, totalDur * 0.36, totalDur * 0.25, totalDur * 0.25, totalDur * 0.25]

        for (index, t) in timeSteps.enumerated() {
            engine.seek(to: t)
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let frameURL = URL(fileURLWithPath: outDir)
                        .appendingPathComponent(String(format: "scroll_frame_%02d.png", index))
                    try? png.write(to: frameURL)
                }
            }
        }
    }

    private func waitUntilWaveformSettled(on engine: MPVAudioEngine, timeoutSeconds: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !engine.isExtractingWaveform && (!engine.waveformSamples.isEmpty || engine.hasPlaybackError) {
                return
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
