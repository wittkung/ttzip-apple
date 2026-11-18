// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import Foundation
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

    func testWaveformExtractionAcrossFiveSampleCategoriesAndSilencePolicy() async throws {
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
