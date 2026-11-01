// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
@testable import TTMediaKit

final class AudioWaveformWindowExtractionTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await AudioWaveformExtractor.shared.setTestPerBufferDelay(nanoseconds: 0)
        await AudioWaveformExtractor.shared.setTestOnFirstBufferRead(nil)
        await AudioWaveformExtractor.shared.setTestFailAfterBufferCount(nil)
        await AudioWaveformExtractor.shared.clearCache()

        await AudioWaveformWindowExtractor.shared.setTestPerBufferDelay(nanoseconds: 0)
        await AudioWaveformWindowExtractor.shared.setTestOnFirstBufferRead(nil)
        await AudioWaveformWindowExtractor.shared.setTestFailAfterBufferCount(nil)
        await AudioWaveformWindowExtractor.shared.setSessionValidator(nil)
        await AudioWaveformWindowExtractor.shared.setCacheLimits(
            maxTiles: AudioWaveformWindowLimits.maxCachedTiles,
            maxPayloadBytes: AudioWaveformWindowLimits.maxCachePayloadBytes
        )
        await AudioWaveformWindowExtractor.shared.setSequentialSeekThresholdFrames(
            AudioWaveformWindowLimits.sequentialAccurateSeekThresholdFrames
        )
        await AudioWaveformWindowExtractor.shared.clearCache()
    }

    // MARK: - 1. Numerical Accuracy Against Ground-Truth PCM

    func testNumericalAccuracyAgainstGroundTruthPCM() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = tempDir.appendingPathComponent("stereo_ground_truth.wav")
        let sampleRate = 10_000
        try writeStereoGroundTruthWAV(to: wavURL, sampleRate: sampleRate)

        let fullReq = AudioWaveformWindowRequest(
            url: wavURL,
            startTime: 0.0,
            windowDuration: 3.0,
            targetBucketCount: 30,
            referencePeak: 1.0
        )
        let fullTile = try await AudioWaveformWindowExtractor.shared.extractWindow(fullReq)
        XCTAssertEqual(fullTile.coverageStatus, .completeWindow)
        XCTAssertEqual(fullTile.channelCount, 2)
        XCTAssertEqual(fullTile.channelAggregation, .maxAbsoluteAcrossChannels)
        XCTAssertEqual(fullTile.peaks.count, 30)
        XCTAssertEqual(fullTile.bucketDuration, 0.1, accuracy: 1e-6)

        for b in 0..<10 {
            XCTAssertEqual(fullTile.rawAbsolutePeaks[b], 0.60, accuracy: 2e-4, "Bucket \(b) should reflect ch1=0.60 > ch0=0.25")
            XCTAssertEqual(fullTile.peaks[b], 0.60, accuracy: 2e-4)
        }
        for b in 10..<20 {
            XCTAssertEqual(fullTile.rawAbsolutePeaks[b], 0.80, accuracy: 2e-4, "Bucket \(b) should reflect ch0=0.80 > ch1=0.10")
            XCTAssertEqual(fullTile.peaks[b], 0.80, accuracy: 2e-4)
        }
        for b in 20..<30 {
            XCTAssertEqual(fullTile.rawAbsolutePeaks[b], 0.40, accuracy: 2e-4, "Bucket \(b) should reflect ch1=0.40 > ch0=0.0")
            XCTAssertEqual(fullTile.peaks[b], 0.40, accuracy: 2e-4)
        }

        XCTAssertEqual(fullTile.bucketIndex(forTime: 0.05), 0)
        XCTAssertEqual(fullTile.bucketIndex(forTime: 1.55), 15)
        XCTAssertNil(fullTile.bucketIndex(forTime: 3.05))
        XCTAssertEqual(fullTile.normalizedPeak(atTime: 1.25) ?? 0, 0.80, accuracy: 2e-4)
        XCTAssertEqual(fullTile.rawAbsolutePeak(atTime: 2.25) ?? 0, 0.40, accuracy: 2e-4)
        XCTAssertEqual(fullTile.bucketCenterTime(at: 0) ?? -1, 0.05, accuracy: 1e-6)

        let tailReq = AudioWaveformWindowRequest(
            url: wavURL,
            startTime: 2.0,
            windowDuration: 2.0,
            targetBucketCount: 20,
            referencePeak: 1.0
        )
        let tailTile = try await AudioWaveformWindowExtractor.shared.extractWindow(tailReq)
        XCTAssertEqual(tailTile.coverageStatus, .partialTailAtEOF)
        XCTAssertEqual(tailTile.coveredStartTime, 2.0, accuracy: 1e-4)
        XCTAssertEqual(tailTile.coveredEndTime, 3.0, accuracy: 1e-4)
        XCTAssertEqual(tailTile.peaks.count, 10, "Partial tail window at EOF must not pad past-EOF buckets with fake zeros")
        XCTAssertTrue(tailTile.peaks.allSatisfy { abs($0 - 0.40) < 1e-3 })
    }

    // MARK: - 2. Authentic Speech Waveform (Voiced Syllables, Pauses, Whisper)

    func testAuthenticSpeechSyllablesPausesAndWhisperSegments() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let speechURL = tempDir.appendingPathComponent("authentic_speech_cadence.wav")
        try writeAuthenticSpeechCadenceWAV(to: speechURL, sampleRate: 16_000)
        let sha = try sha256Hex(of: speechURL)
        XCTAssertFalse(sha.isEmpty)

        let req = AudioWaveformWindowRequest(
            url: speechURL,
            startTime: 0.0,
            windowDuration: 4.0,
            targetBucketCount: 160,
            referencePeak: 0.85
        )
        let tile = try await AudioWaveformWindowExtractor.shared.extractWindow(req)
        XCTAssertEqual(tile.coverageStatus, .completeWindow)
        XCTAssertEqual(tile.peaks.count, 160)
        XCTAssertFalse(tile.isLocalWindowSilent)

        let syllable1Peak = tile.rawAbsolutePeaks[4..<24].max() ?? 0
        let pause1Max = tile.rawAbsolutePeaks[34..<50].max() ?? 1
        let syllable2Peak = tile.rawAbsolutePeaks[56..<80].max() ?? 0
        let pause2Max = tile.rawAbsolutePeaks[90..<106].max() ?? 1
        let whisperPeak = tile.rawAbsolutePeaks[116..<144].max() ?? 0

        XCTAssertGreaterThan(syllable1Peak, 0.55, "First voiced syllable must show strong acoustic peak")
        XCTAssertLessThan(pause1Max, 0.001, "Inter-word pause must drop to near-zero amplitude")
        XCTAssertGreaterThan(syllable2Peak, 0.70, "Second voiced syllable must show strong acoustic peak")
        XCTAssertLessThan(pause2Max, 0.001, "Second pause must drop to near-zero amplitude")
        XCTAssertGreaterThan(whisperPeak, 0.04, "Low-amplitude speech segment must remain audible above silence floor")
        XCTAssertLessThan(whisperPeak, 0.20, "Low-amplitude speech segment must stay distinct from loud syllables")
    }

    // MARK: - 3. Compressed Audio Post-Seek Time Alignment & Decode/Playback Capability

    func testCompressedAudioPostSeekAlignmentMatchesSequentialReference() async throws {
        let audioDir = try resolvePreviewAudioCorpusDirectory()
        let compressedFiles = ["tone.mp3", "tone.m4a", "tone.aac", "tone.flac", "tone.ogg"]

        for name in compressedFiles {
            let fileURL = audioDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                XCTFail("Missing corpus fixture: \(fileURL.path)")
                continue
            }
            let req = AudioWaveformWindowRequest(
                url: fileURL,
                startTime: 0.25,
                windowDuration: 0.50,
                targetBucketCount: 25,
                referencePeak: 1.0
            )
            let tile = try await AudioWaveformWindowExtractor.shared.extractWindow(req)
            XCTAssertEqual(tile.peaks.count, 25, "25 buckets expected for \(name)")
            XCTAssertGreaterThan(tile.rawMaxPeak, 0.05, "Non-empty signal expected for \(name)")

            let refPeaks = try decodeSequentialReferenceWindow(
                url: fileURL,
                startFrame: tile.startFrame,
                frameCount: tile.endFrame - tile.startFrame,
                bucketCount: 25
            )
            for i in 0..<25 {
                XCTAssertEqual(
                    tile.rawAbsolutePeaks[i],
                    refPeaks[i],
                    accuracy: 0.02,
                    "Post-seek bucket \(i) mismatch for \(name)"
                )
            }
        }

        await AudioWaveformWindowExtractor.shared.setSequentialSeekThresholdFrames(1_000)
        await AudioWaveformWindowExtractor.shared.clearCache()
        let m4aURL = audioDir.appendingPathComponent("tone.m4a")
        let prerollTile = try await AudioWaveformWindowExtractor.shared.extractWindow(
            AudioWaveformWindowRequest(url: m4aURL, startTime: 0.30, windowDuration: 0.40, targetBucketCount: 20, referencePeak: 1.0)
        )
        XCTAssertTrue(prerollTile.didApplySeekOffsetAdjustment)
        XCTAssertGreaterThan(prerollTile.rawMaxPeak, 0.05)

        XCTAssertTrue(MPVAudioEngine.waveformOnlyCoreAudioExtensions.contains("ogg"))
        XCTAssertTrue(MPVAudioEngine.waveformOnlyCoreAudioExtensions.contains("opus"))
        XCTAssertTrue(MPVAudioEngine.formatSupport(forExtension: "ogg").isWaveformOnlyWithoutPlayback)
        XCTAssertFalse(MPVAudioEngine.formatSupport(forExtension: "ogg").isPlayableNatively)
        XCTAssertTrue(MPVAudioEngine.formatSupport(forExtension: "mp3").isWaveformDecodable)
        XCTAssertFalse(MPVAudioEngine.formatSupport(forExtension: "mp3").isWaveformOnlyWithoutPlayback)
    }

    // MARK: - 4. Long Audio (>= 30 Minutes) Local Window vs Whole-Track Overview

    func testLongAudio30MinuteLocalWindowPreservesShortPulseMissedByOverview() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let longWAV = tempDir.appendingPathComponent("long_30min_short_pulse.wav")
        let sampleRate = 8_000
        let totalSeconds = 1_800
        let totalFrames = sampleRate * totalSeconds // 14,400,000 frames (> 4M threshold)
        let pulseStartFrame = 901 * sampleRate + 1_600 // t = 901.20s (between 256-window strides)
        let pulseFrameCount = 640 // 80ms pulse
        try writeLongSparsePulseWAV(
            to: longWAV,
            sampleRate: sampleRate,
            totalFrames: totalFrames,
            pulseStartFrame: pulseStartFrame,
            pulseFrameCount: pulseFrameCount,
            pulseAmplitude: 0.90
        )

        let overview = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
            from: longWAV,
            targetSampleCount: 1600,
            allowSequentialSilenceVerification: false
        )
        XCTAssertNotNil(overview)
        XCTAssertEqual(overview?.samplingMode, .windowedSampledEnvelope)
        XCTAssertEqual(overview?.rawMaxPeak ?? 1.0, 0.0, accuracy: 1e-4, "256-window overview misses inter-window 80ms pulse")

        let windowReq = AudioWaveformWindowRequest(
            url: longWAV,
            startTime: 900.0,
            windowDuration: 6.0,
            targetBucketCount: 180,
            referencePeak: 1.0
        )
        let windowTile = try await AudioWaveformWindowExtractor.shared.extractWindow(windowReq)
        let decodedFrames = await AudioWaveformWindowExtractor.shared.lastDecodedTotalFrames()

        XCTAssertEqual(windowTile.samplingMode, .exhaustiveBucketPeak)
        XCTAssertEqual(decodedFrames, 48_000, "Must only decode the 6s local window (48k frames), not the 14.4M-frame track")
        XCTAssertFalse(windowTile.isLocalWindowSilent)
        XCTAssertEqual(windowTile.rawMaxPeak, 0.90, accuracy: 1e-3)
        let pulseBucketIndex = windowTile.bucketIndex(forTime: 901.22)
        XCTAssertNotNil(pulseBucketIndex)
        if let idx = pulseBucketIndex {
            XCTAssertGreaterThan(windowTile.peaks[idx], 0.85, "Local window must capture exact 80ms pulse at t=901.22s")
        }
    }

    // MARK: - 5. Silence Semantics Distinction

    func testSilenceSemanticsDistinguishLocalPauseFromWholeTrackSilence() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mixedURL = tempDir.appendingPathComponent("voiced_then_silent.wav")
        try writeStereoGroundTruthWAV(to: mixedURL, sampleRate: 8_000, thirdSecondAmplitude: 0.0)
        _ = await AudioWaveformExtractor.shared.extractWaveformAnalysis(from: mixedURL, targetSampleCount: 160)

        let pauseTile = try await AudioWaveformWindowExtractor.shared.extractWindow(
            AudioWaveformWindowRequest(url: mixedURL, startTime: 2.05, windowDuration: 0.90, targetBucketCount: 18)
        )
        XCTAssertTrue(pauseTile.isLocalWindowSilent, "Silent third second must be marked locally silent")
        XCTAssertTrue(pauseTile.isLocalWindowComplete)
        XCTAssertTrue(pauseTile.peaks.allSatisfy { $0 == 0.0 })
        XCTAssertTrue(pauseTile.isWholeTrackCompletenessVerified)
        XCTAssertFalse(pauseTile.isWholeTrackVerifiedDigitalSilence, "Local pause must never claim whole-track digital silence")

        let fullSilenceURL = tempDir.appendingPathComponent("full_digital_silence.wav")
        try writeConstantMonoWAV(to: fullSilenceURL, sampleRate: 8_000, frameCount: 16_000, amplitude: 0.0)
        let wholeSilent = await AudioWaveformExtractor.shared.extractWaveformAnalysis(from: fullSilenceURL, targetSampleCount: 160)
        XCTAssertEqual(wholeSilent?.isVerifiedDigitalSilence, true)

        let silentTile = try await AudioWaveformWindowExtractor.shared.extractWindow(
            AudioWaveformWindowRequest(url: fullSilenceURL, startTime: 0.2, windowDuration: 1.0, targetBucketCount: 20)
        )
        XCTAssertTrue(silentTile.isLocalWindowSilent)
        XCTAssertTrue(silentTile.isWholeTrackCompletenessVerified)
        XCTAssertTrue(silentTile.isWholeTrackVerifiedDigitalSilence)
    }

    // MARK: - 6. Error & Boundary Cases

    func testInvalidParametersCorruptTruncatedUnsupportedEmptyAndPastEOF() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validWAV = tempDir.appendingPathComponent("valid.wav")
        try writeConstantMonoWAV(to: validWAV, sampleRate: 8_000, frameCount: 16_000, amplitude: 0.5)

        await assertThrowsWindowError(
            AudioWaveformWindowRequest(url: validWAV, startTime: -0.1, windowDuration: 1.0, targetBucketCount: 10),
            expectedCase: { if case .invalidStartTime = $0 { return true }; return false }
        )
        await assertThrowsWindowError(
            AudioWaveformWindowRequest(url: validWAV, startTime: .nan, windowDuration: 1.0, targetBucketCount: 10),
            expectedCase: { if case .invalidStartTime = $0 { return true }; return false }
        )
        await assertThrowsWindowError(
            AudioWaveformWindowRequest(url: validWAV, startTime: 0.0, windowDuration: 0.01, targetBucketCount: 10),
            expectedCase: { if case .invalidWindowDuration = $0 { return true }; return false }
        )
        await assertThrowsWindowError(
            AudioWaveformWindowRequest(url: validWAV, startTime: 0.0, windowDuration: 1.0, targetBucketCount: 0),
            expectedCase: { if case .bucketCountOutOfBounds = $0 { return true }; return false }
        )
        await assertThrowsWindowError(
            AudioWaveformWindowRequest(url: tempDir.appendingPathComponent("missing.wav"), startTime: 0.0),
            expectedCase: { if case .fileNotFound = $0 { return true }; return false }
        )

        let emptyWAV = tempDir.appendingPathComponent("empty.wav")
        try Data().write(to: emptyWAV)
        await assertThrowsWindowError(
            AudioWaveformWindowRequest(url: emptyWAV, startTime: 0.0),
            expectedCase: { if case .emptyAudioFile = $0 { return true }; return false }
        )

        let wmaURL = tempDir.appendingPathComponent("unsupported.wma")
        try Data([0x30, 0x26, 0xB2, 0x75]).write(to: wmaURL)
        await assertThrowsWindowError(
            AudioWaveformWindowRequest(url: wmaURL, startTime: 0.0),
            expectedCase: { if case .unsupportedFormat(let ext, _) = $0 { return ext == "wma" }; return false }
        )

        let pastEOFTile = try await AudioWaveformWindowExtractor.shared.extractWindow(
            AudioWaveformWindowRequest(url: validWAV, startTime: 5.0, windowDuration: 1.0, targetBucketCount: 20)
        )
        XCTAssertEqual(pastEOFTile.coverageStatus, .emptyAtOrPastEOF)
        XCTAssertTrue(pastEOFTile.peaks.isEmpty)
        XCTAssertTrue(pastEOFTile.isLocalWindowComplete)
        XCTAssertFalse(pastEOFTile.isLocalWindowSilent)

        let truncatedWAV = tempDir.appendingPathComponent("truncated.wav")
        try Data( try Data(contentsOf: validWAV).prefix(44 + 8_000) ).write(to: truncatedWAV)
        await assertThrowsWindowError(
            AudioWaveformWindowRequest(url: truncatedWAV, startTime: 0.5, windowDuration: 1.5, targetBucketCount: 30),
            expectedCase: { if case .corruptOrTruncatedStream = $0 { return true }; return false }
        )
    }

    // MARK: - 7. Cancellation Isolation, Multi-Caller Coalescing & Playback Independence

    func testCancellationStagesCoalescedCallerIsolationAndPlaybackIndependence() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = tempDir.appendingPathComponent("coalesce_cancel.wav")
        try writeConstantMonoWAV(to: wavURL, sampleRate: 48_000, frameCount: 48_000 * 4, amplitude: 0.6)

        let preCancelled = Task<AudioWaveformWindowTile, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AudioWaveformWindowExtractor.shared.extractWindow(
                AudioWaveformWindowRequest(url: wavURL, startTime: 0.0, windowDuration: 1.0, targetBucketCount: 20)
            )
        }
        do {
            _ = try await preCancelled.value
            XCTFail("Expected pre-cancelled task to throw .cancelled")
        } catch let err as AudioWaveformWindowError {
            XCTAssertEqual(err, .cancelled)
        }

        await AudioWaveformWindowExtractor.shared.setTestPerBufferDelay(nanoseconds: 15_000_000)
        let sharedReq = AudioWaveformWindowRequest(url: wavURL, startTime: 0.5, windowDuration: 2.0, targetBucketCount: 40)

        let callerA = Task { try await AudioWaveformWindowExtractor.shared.extractWindow(sharedReq) }
        try await Task.sleep(nanoseconds: 8_000_000)
        let callerB = Task { try await AudioWaveformWindowExtractor.shared.extractWindow(sharedReq) }
        try await Task.sleep(nanoseconds: 8_000_000)

        callerA.cancel()
        do {
            _ = try await callerA.value
            XCTFail("Caller A should have thrown .cancelled")
        } catch let err as AudioWaveformWindowError {
            XCTAssertEqual(err, .cancelled)
        }

        let tileB = try await callerB.value
        XCTAssertEqual(tileB.peaks.count, 40, "Cancelling coalesced Caller A must not abort Caller B")
        let metrics = await AudioWaveformWindowExtractor.shared.metricsSnapshot()
        XCTAssertGreaterThanOrEqual(metrics.coalescedJoinCount, 1)

        await AudioWaveformWindowExtractor.shared.setTestPerBufferDelay(nanoseconds: 0)
        let engine = await MainActor.run { MPVAudioEngine() }
        _ = await MainActor.run { engine.load(url: wavURL, ownerSessionID: "play-session") }
        let isPlayingBeforeCancel = await MainActor.run { engine.isPlaying }
        await MainActor.run {
            engine.requestScrollingWaveformWindow(aroundTime: 1.0, windowDuration: 1.0, targetBucketCount: 20)
            engine.cancelWaveformWindowRequests()
        }
        let isPlayingAfterCancel = await MainActor.run { engine.isPlaying }
        XCTAssertEqual(isPlayingAfterCancel, isPlayingBeforeCancel, "Cancelling window requests must not stop playback")
        await MainActor.run { engine.stop() }
    }

    // MARK: - 8. Resource Mutation Consistency & Session/Generation Fencing

    func testResourceMutationInvalidationAndSessionGenerationFencing() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("mutable_track.wav")
        let replacementURL = tempDir.appendingPathComponent("replacement_track.wav")
        try writeConstantMonoWAV(to: targetURL, sampleRate: 8_000, frameCount: 16_000, amplitude: 0.20)
        try writeConstantMonoWAV(to: replacementURL, sampleRate: 8_000, frameCount: 16_000, amplitude: 0.85)

        let req = AudioWaveformWindowRequest(
            url: targetURL,
            startTime: 0.0,
            windowDuration: 1.0,
            targetBucketCount: 10,
            referencePeak: 1.0
        )
        let initialTile = try await AudioWaveformWindowExtractor.shared.extractWindow(req)
        XCTAssertEqual(initialTile.rawMaxPeak, 0.20, accuracy: 1e-3)
        XCTAssertFalse(initialTile.servedFromCache)

        let cachedTile = try await AudioWaveformWindowExtractor.shared.extractWindow(req)
        XCTAssertTrue(cachedTile.servedFromCache)

        _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: replacementURL)
        let replacedTile = try await AudioWaveformWindowExtractor.shared.extractWindow(req)
        XCTAssertFalse(replacedTile.servedFromCache, "Atomic file replacement must invalidate old cached window tile")
        XCTAssertEqual(replacedTile.rawMaxPeak, 0.85, accuracy: 1e-3)

        let staleExpectedReq = AudioWaveformWindowRequest(
            url: targetURL,
            startTime: 0.0,
            windowDuration: 1.0,
            targetBucketCount: 10,
            expectedResourceVersion: initialTile.resourceVersion,
            referencePeak: 1.0
        )
        await assertThrowsWindowError(
            staleExpectedReq,
            expectedCase: { if case .resourceVersionChanged = $0 { return true }; return false }
        )

        let engine = await MainActor.run { MPVAudioEngine() }
        await MainActor.run {
            engine.load(url: targetURL, ownerSessionID: "session-new")
            engine.pause()
        }
        let activeGen = await MainActor.run { engine.activeLoadGeneration }
        let staleEngineReq = AudioWaveformWindowRequest(
            url: targetURL,
            startTime: 0.0,
            windowDuration: 1.0,
            targetBucketCount: 10,
            ownerSessionID: "session-old",
            loadGeneration: activeGen > 0 ? activeGen - 1 : 999
        )
        do {
            _ = try await engine.extractWaveformWindow(staleEngineReq)
            XCTFail("Expected stale session/generation to throw")
        } catch let err as AudioWaveformWindowError {
            if case .staleSessionOrGeneration = err {} else { XCTFail("Unexpected error \(err)") }
        }
        await MainActor.run { engine.stop() }
    }

    // MARK: - 9. Shared Concurrency Budget & Bounded LRU Tile Cache Eviction

    func testConcurrencyGateLRUCacheEvictionAndDecodedFrameBudget() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var urls: [URL] = []
        for i in 0..<4 {
            let u = tempDir.appendingPathComponent("concurrent_\(i).wav")
            try writeConstantMonoWAV(to: u, sampleRate: 24_000, frameCount: 48_000, amplitude: Float(0.2 + Double(i) * 0.15))
            urls.append(u)
        }

        await AudioWaveformExtractor.shared.setTestPerBufferDelay(nanoseconds: 10_000_000)
        await AudioWaveformWindowExtractor.shared.setTestPerBufferDelay(nanoseconds: 10_000_000)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await AudioWaveformExtractor.shared.extractWaveformAnalysis(from: urls[0], targetSampleCount: 200)
            }
            group.addTask {
                _ = await AudioWaveformExtractor.shared.extractWaveformAnalysis(from: urls[1], targetSampleCount: 200)
            }
            group.addTask {
                _ = try? await AudioWaveformWindowExtractor.shared.extractWindow(
                    AudioWaveformWindowRequest(url: urls[2], startTime: 0.0, windowDuration: 1.0, targetBucketCount: 50)
                )
            }
            group.addTask {
                _ = try? await AudioWaveformWindowExtractor.shared.extractWindow(
                    AudioWaveformWindowRequest(url: urls[3], startTime: 0.0, windowDuration: 1.0, targetBucketCount: 50)
                )
            }
        }

        await AudioWaveformExtractor.shared.setTestPerBufferDelay(nanoseconds: 0)
        await AudioWaveformWindowExtractor.shared.setTestPerBufferDelay(nanoseconds: 0)
        let concurrencyMetrics = await AudioWaveformWindowExtractor.shared.metricsSnapshot()
        XCTAssertLessThanOrEqual(
            concurrencyMetrics.peakConcurrentDecodesObserved,
            AudioWaveformExtractor.maxConcurrentDecodes,
            "Shared concurrency gate must never exceed maxConcurrentDecodes = 2"
        )

        await AudioWaveformWindowExtractor.shared.clearCache()
        await AudioWaveformWindowExtractor.shared.setCacheLimits(maxTiles: 3, maxPayloadBytes: 4_096)
        for step in 0..<6 {
            _ = try await AudioWaveformWindowExtractor.shared.extractWindow(
                AudioWaveformWindowRequest(url: urls[0], startTime: Double(step) * 0.2, windowDuration: 0.2, targetBucketCount: 64)
            )
        }
        let cacheMetrics = await AudioWaveformWindowExtractor.shared.metricsSnapshot()
        XCTAssertLessThanOrEqual(cacheMetrics.cachedTileCount, 3)
        XCTAssertLessThanOrEqual(cacheMetrics.cachedPayloadBytes, 4_096)
        XCTAssertGreaterThanOrEqual(cacheMetrics.evictionCount, 3)
    }

    // MARK: - 10. Whole-Track Regression & Engine Scrolling Window Prefetch

    func testWholeTrackOverviewUnbrokenAndScrollingWindowPrefetch() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = tempDir.appendingPathComponent("engine_scrolling.wav")
        try writeStereoGroundTruthWAV(to: wavURL, sampleRate: 10_000)

        let engine = await MainActor.run { MPVAudioEngine() }
        await MainActor.run {
            engine.load(url: wavURL, ownerSessionID: "scroll-session")
            engine.pause()
        }
        await engine.waitForWaveform()

        let overviewCount = await MainActor.run { engine.waveformSamples.count }
        XCTAssertEqual(overviewCount, 1600)

        await MainActor.run {
            engine.requestScrollingWaveformWindow(
                aroundTime: 0.2,
                windowDuration: 1.0,
                targetBucketCount: 20,
                prefetchNextTile: true
            )
        }
        await engine.waitForWaveformWindow()
        try await Task.sleep(nanoseconds: 40_000_000)

        let activeTile = await MainActor.run { engine.activeWaveformWindowTile }
        XCTAssertNotNil(activeTile)
        XCTAssertEqual(activeTile?.peaks.count, 20)
        let overviewAfterWindow = await MainActor.run { engine.waveformSamples.count }
        XCTAssertEqual(overviewAfterWindow, 1600, "Local window extraction must not overwrite 1600-bucket overview")

        let nextWindowTile = try await AudioWaveformWindowExtractor.shared.extractWindow(
            AudioWaveformWindowRequest(
                url: wavURL,
                startTime: 1.0,
                windowDuration: 1.0,
                targetBucketCount: 20,
                expectedResourceVersion: activeTile?.resourceVersion,
                referencePeak: activeTile?.referencePeak
            )
        )
        XCTAssertTrue(nextWindowTile.servedFromCache, "Next adjacent tile should have been prefetched into LRU cache")
        await MainActor.run { engine.stop() }
    }

    // MARK: - Test Fixtures & Ground-Truth Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ttmedia_win_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resolvePreviewAudioCorpusDirectory() throws -> URL {
        if let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let managed = URL(fileURLWithPath: srcdir)
                .appendingPathComponent("_main/infra/ttmedia/Tests/Fixtures/preview/audio")
            guard FileManager.default.fileExists(atPath: managed.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: managed.path])
            }
            return managed
        }
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = cursor.appendingPathComponent("Tests/Fixtures/preview/audio")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw NSError(domain: "AudioWaveformWindowExtractionTests", code: 404)
    }

    private func assertThrowsWindowError(
        _ request: AudioWaveformWindowRequest,
        expectedCase: (AudioWaveformWindowError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await AudioWaveformWindowExtractor.shared.extractWindow(request)
            XCTFail("Expected AudioWaveformWindowError to be thrown", file: file, line: line)
        } catch let error as AudioWaveformWindowError {
            XCTAssertTrue(expectedCase(error), "Unexpected AudioWaveformWindowError: \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected non-window error: \(error)", file: file, line: line)
        }
    }

    private func writeFloatPCMWAV(
        to url: URL,
        sampleRate: Int,
        channels: AVAudioChannelCount,
        frameCount: Int,
        fill: (UnsafePointer<UnsafeMutablePointer<Float>>, Int) -> Void
    ) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        fill(buffer.floatChannelData!, frameCount)
        try file.write(from: buffer)
    }

    private func writeStereoGroundTruthWAV(to url: URL, sampleRate: Int, thirdSecondAmplitude: Float = 0.40) throws {
        try writeFloatPCMWAV(to: url, sampleRate: sampleRate, channels: 2, frameCount: sampleRate * 3) { ch, totalFrames in
            for i in 0..<totalFrames {
                let sign: Float = (i % 2 == 0) ? 1.0 : -1.0
                if i < sampleRate {
                    ch[0][i] = 0.25 * sign
                    ch[1][i] = 0.60 * sign
                } else if i < sampleRate * 2 {
                    ch[0][i] = 0.80 * sign
                    ch[1][i] = 0.10 * sign
                } else {
                    ch[0][i] = 0.0
                    ch[1][i] = thirdSecondAmplitude * sign
                }
            }
        }
    }

    private func writeAuthenticSpeechCadenceWAV(to url: URL, sampleRate: Int) throws {
        try writeFloatPCMWAV(to: url, sampleRate: sampleRate, channels: 1, frameCount: sampleRate * 4) { ch, totalFrames in
            for i in 0..<totalFrames {
                let t = Double(i) / Double(sampleRate)
                let carrier = Float(0.60 * sin(2.0 * .pi * 145.0 * t) + 0.28 * sin(2.0 * .pi * 720.0 * t) + 0.12 * sin(2.0 * .pi * 2450.0 * t))
                if t >= 0.10 && t < 0.70 {
                    ch[0][i] = 0.72 * Float(sin(.pi * (t - 0.10) / 0.60)) * carrier
                } else if t >= 1.40 && t < 2.10 {
                    ch[0][i] = 0.84 * Float(sin(.pi * (t - 1.40) / 0.70)) * carrier
                } else if t >= 2.85 && t < 3.65 {
                    ch[0][i] = 0.09 * Float(sin(.pi * (t - 2.85) / 0.80)) * carrier
                } else {
                    ch[0][i] = 0.0
                }
            }
        }
    }

    private func writeConstantMonoWAV(to url: URL, sampleRate: Int, frameCount: Int, amplitude: Float) throws {
        try writeFloatPCMWAV(to: url, sampleRate: sampleRate, channels: 1, frameCount: frameCount) { ch, totalFrames in
            for i in 0..<totalFrames {
                ch[0][i] = (i % 2 == 0) ? amplitude : -amplitude
            }
        }
    }

    private func writeLongSparsePulseWAV(
        to url: URL,
        sampleRate: Int,
        totalFrames: Int,
        pulseStartFrame: Int,
        pulseFrameCount: Int,
        pulseAmplitude: Float
    ) throws {
        let dataBytes = totalFrames * 2
        let riffBytes = 36 + dataBytes
        var header = Data(capacity: 44)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(littleEndianUInt32(UInt32(riffBytes)))
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(littleEndianUInt32(16))
        header.append(littleEndianUInt16(1)) // PCM
        header.append(littleEndianUInt16(1)) // mono
        header.append(littleEndianUInt32(UInt32(sampleRate)))
        header.append(littleEndianUInt32(UInt32(sampleRate * 2)))
        header.append(littleEndianUInt16(2))
        header.append(littleEndianUInt16(16))
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(littleEndianUInt32(UInt32(dataBytes)))

        try header.write(to: url)
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(44 + dataBytes)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let sampleVal = Int16((pulseAmplitude * Float(Int16.max)).rounded())
        var pulseBytes = [UInt8](repeating: 0, count: pulseFrameCount * 2)
        for i in 0..<pulseFrameCount {
            let v = (i % 2 == 0) ? sampleVal : -sampleVal
            let u = UInt16(bitPattern: v)
            pulseBytes[i * 2] = UInt8(u & 0xFF)
            pulseBytes[i * 2 + 1] = UInt8((u >> 8) & 0xFF)
        }
        _ = pulseBytes.withUnsafeBytes { rawBuf in
            pwrite(fd, rawBuf.baseAddress, pulseBytes.count, off_t(44 + pulseStartFrame * 2))
        }
    }

    private func decodeSequentialReferenceWindow(
        url: URL,
        startFrame: Int64,
        frameCount: Int64,
        bucketCount: Int
    ) throws -> [Float] {
        var extRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &extRef) == noErr, let extFile = extRef else {
            throw NSError(domain: "AudioWaveformWindowExtractionTests", code: -1)
        }
        defer { ExtAudioFileDispose(extFile) }
        guard let (fileFormat, _) = AudioWaveformExtractor.queryFileFormatAndLength(extFile: extFile),
              let (buffer, channels) = AudioContainerCompletenessValidator.makeSequentialClientBuffer(
                  extFile: extFile,
                  fileFormat: fileFormat,
                  bufferCapacity: 8192
              ) else {
            throw NSError(domain: "AudioWaveformWindowExtractionTests", code: -2)
        }
        _ = AudioWaveformExtractor.discardWarmupFrames(
            extFile: extFile,
            buffer: buffer,
            bufferCapacity: 8192,
            discardCount: startFrame,
            requestedStartFrame: startFrame,
            didAdjust: false,
            cancelToken: WaveformCancelToken(),
            path: url.path
        )
        var buckets = [Float](repeating: 0.0, count: bucketCount)
        var readInWin: Int64 = 0
        let grid = WindowBucketGrid(
            expectedFramesInWindow: frameCount,
            coveredBucketCount: bucketCount,
            isPartialTail: false,
            framesPerBucket: Double(frameCount) / Double(bucketCount),
            totalSpan: Double(max(1, frameCount))
        )
        while readInWin < frameCount {
            let req = UInt32(min(Int64(8192), frameCount - readInWin))
            buffer.frameLength = req
            var io = req
            guard ExtAudioFileRead(extFile, &io, buffer.mutableAudioBufferList) == noErr, io > 0,
                  let chData = buffer.floatChannelData else { break }
            let endFrame = readInWin + Int64(io)
            let (firstB, lastB) = grid.bucketRange(localStartFrame: readInWin, localEndFrame: endFrame)
            for b in firstB...lastB {
                let (bStart, bEnd) = grid.frameBounds(forBucket: b)
                let sStart = max(0, Int(bStart - readInWin))
                let sEnd = min(Int(io), max(sStart + 1, Int(bEnd - readInWin)))
                let peak = AudioWaveformExtractor.peakAmplitudeSIMD(
                    channelData: chData,
                    channelCount: channels,
                    framesRead: max(1, sEnd - sStart),
                    offset: sStart
                )
                if peak > buckets[b] { buckets[b] = peak }
            }
            readInWin += Int64(io)
        }
        return buckets
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    private func littleEndianUInt16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}
