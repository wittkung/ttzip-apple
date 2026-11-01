// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
@testable import TTMediaKit

@MainActor
final class AudioAuthenticityAndLoadingTests: XCTestCase {

    // MARK: - Helpers

    internal func previewFixtureRootIfAvailable() -> URL? {
        if let testSrcDir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let runfilesCandidates = [
                URL(fileURLWithPath: testSrcDir).appendingPathComponent("_main/infra/ttmedia/Tests/Fixtures/preview"),
                URL(fileURLWithPath: testSrcDir).appendingPathComponent("infra/ttmedia/Tests/Fixtures/preview")
            ]
            for candidate in runfilesCandidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Tests/Fixtures/preview")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let direct = dir.appendingPathComponent("Fixtures/preview")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Synthesizes a 16-bit PCM mono WAV in memory with customizable per-sample amplitude closure.
    internal func makeTestWAVData(
        sampleRate: Int = 16_000,
        frameCount: Int = 16_000,
        sampleGenerator: (Int, Int) -> Int16
    ) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * Int(numChannels) * Int(bitsPerSample / 8))
        let blockAlign = UInt16(numChannels * (bitsPerSample / 8))
        let dataSize = UInt32(frameCount * Int(blockAlign))
        let chunkSize = 36 + dataSize

        var data = Data(capacity: Int(44 + dataSize))
        data.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: chunkSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataSize.littleEndian) { data.append(contentsOf: $0) }

        var samples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            samples[i] = sampleGenerator(i, frameCount).littleEndian
        }
        samples.withUnsafeBufferPointer { ptr in
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(ptr.baseAddress)?.assumingMemoryBound(to: UInt8.self),
                count: frameCount * MemoryLayout<Int16>.size
            ))
        }
        return data
    }

    // MARK: - 1. Silent vs Audible Waveform Authenticity

    func testSilentAudioProducesNearZeroWaveform() async throws {
        let silentData = makeTestWAVData(sampleRate: 16_000, frameCount: 16_000) { _, _ in 0 }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-silent-\(UUID().uuidString).wav")
        try silentData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let analysis = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
            from: tempURL,
            targetSampleCount: 256
        )
        let unwrapped = try XCTUnwrap(analysis)
        XCTAssertEqual(unwrapped.peaks.count, 256)
        XCTAssertEqual(unwrapped.samplingMode, .exhaustiveBucketPeak)
        XCTAssertTrue(unwrapped.isVerifiedDigitalSilence)
        XCTAssertTrue(
            unwrapped.peaks.allSatisfy { $0 <= 0.001 },
            "Silent WAV must yield near-zero waveform peaks, got max=\(unwrapped.peaks.max() ?? -1)"
        )

        let engine = MPVAudioEngine()
        engine.load(url: tempURL)
        await engine.waitForWaveform()
        XCTAssertFalse(engine.hasPlaybackError)
        XCTAssertFalse(engine.isBuffering)
        XCTAssertFalse(engine.isExtractingWaveform)
        XCTAssertEqual(engine.waveformSamples.count, 1600)
        XCTAssertEqual(engine.waveformSamplingMode, .exhaustiveBucketPeak)
        XCTAssertTrue(engine.isVerifiedDigitalSilence)
        XCTAssertTrue(engine.waveformSamples.allSatisfy { $0 <= 0.001 })

        let root = try XCTUnwrap(previewFixtureRootIfAvailable(), "Required preview corpus is missing")
        let silenceURL = root.appendingPathComponent("edge-cases/silence.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: silenceURL.path), "Required silence fixture is missing")
        engine.load(url: silenceURL)
        await engine.waitForWaveform()
        XCTAssertFalse(engine.hasPlaybackError)
        XCTAssertTrue(engine.isVerifiedDigitalSilence)
        XCTAssertTrue(engine.waveformSamples.allSatisfy { $0 <= 0.001 })
    }

    func testAudibleAudioWaveformReflectsActualContentEnvelope() async throws {
        let stepData = makeTestWAVData(sampleRate: 44_100, frameCount: 88_200) { idx, total in
            let phase = sin(2.0 * Double.pi * 440.0 * Double(idx) / 44_100.0)
            let scale: Double = idx < (total / 2) ? 3_000.0 : 29_000.0
            return Int16(clamping: Int(phase * scale))
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-envelope-\(UUID().uuidString).wav")
        try stepData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let extractedPeaks = await AudioWaveformExtractor.shared.extractAuthenticWaveform(
            from: tempURL,
            targetSampleCount: 1600
        )
        let peaks = try XCTUnwrap(extractedPeaks)
        XCTAssertEqual(peaks.count, 1600)

        let nonZeroCount = peaks.filter { $0 > 0.02 }.count
        XCTAssertGreaterThan(nonZeroCount, 1550, "1600-bin extraction should not leave striding holes")

        let firstHalfAvg = peaks.prefix(750).reduce(0, +) / 750.0
        let secondHalfAvg = peaks.suffix(750).reduce(0, +) / 750.0
        XCTAssertLessThan(firstHalfAvg, 0.25, "Quiet first half should have low normalized amplitude")
        XCTAssertGreaterThan(secondHalfAvg, 0.80, "Loud second half should have high normalized amplitude")
        XCTAssertGreaterThan(secondHalfAvg, firstHalfAvg * 4.0)
    }

    // MARK: - 2. Same-Path File Overwrite & Mid-Decode Version Race Protection

    func testSamePathOverwriteInvalidatesCacheAndUpdatesWaveform() async throws {
        let samePathURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-overwrite-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: samePathURL) }

        let silentData = makeTestWAVData(sampleRate: 16_000, frameCount: 16_000) { _, _ in 0 }
        try silentData.write(to: samePathURL, options: .atomic)

        let rawFirstAnalysis = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
            from: samePathURL,
            targetSampleCount: 256
        )
        let firstAnalysis = try XCTUnwrap(rawFirstAnalysis)
        XCTAssertTrue(firstAnalysis.isVerifiedDigitalSilence)
        XCTAssertTrue(firstAnalysis.peaks.allSatisfy { $0 <= 0.001 })

        let loudData = makeTestWAVData(sampleRate: 16_000, frameCount: 16_000) { idx, _ in
            let phase = sin(2.0 * Double.pi * 440.0 * Double(idx) / 16_000.0)
            return Int16(clamping: Int(phase * 28_000.0))
        }
        XCTAssertEqual(silentData.count, loudData.count, "Even same-byte-count overwrite must invalidate cache")
        try loudData.write(to: samePathURL)

        let rawSecondAnalysis = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
            from: samePathURL,
            targetSampleCount: 256
        )
        let secondAnalysis = try XCTUnwrap(rawSecondAnalysis)
        XCTAssertFalse(secondAnalysis.isVerifiedDigitalSilence)
        XCTAssertGreaterThan(secondAnalysis.peaks.max() ?? 0, 0.90)
    }

    func testMidDecodeInPlaceOverwriteAndAtomicReplaceDiscardStaleResult() async throws {
        let extractor = AudioWaveformExtractor()
        let frameCount = 131_072 // 4 buffers of 32,768 frames
        let silentWAV = makeTestWAVData(sampleRate: 32_768, frameCount: frameCount) { _, _ in 0 }
        let loudWAV = makeTestWAVData(sampleRate: 32_768, frameCount: frameCount) { idx, _ in
            let phase = sin(2.0 * Double.pi * 440.0 * Double(idx) / 32_768.0)
            return Int16(clamping: Int(phase * 28_000.0))
        }

        // Case A: Deterministic in-place overwrite (same inode via pwrite) mid-decode
        let inPlaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-mid-inplace-\(UUID().uuidString).wav")
        try silentWAV.write(to: inPlaceURL)
        defer { try? FileManager.default.removeItem(at: inPlaceURL) }

        var preInode = stat()
        XCTAssertEqual(stat(inPlaceURL.path, &preInode), 0)

        await extractor.setTestOnFirstBufferRead {
            let fd = open(inPlaceURL.path, O_WRONLY)
            guard fd >= 0 else { return }
            _ = loudWAV.withUnsafeBytes { rawBuf in
                pwrite(fd, rawBuf.baseAddress, rawBuf.count, 0)
            }
            fsync(fd)
            close(fd)
        }
        let inPlaceRaceResult = await extractor.extractWaveformAnalysis(from: inPlaceURL, targetSampleCount: 256)
        await extractor.setTestOnFirstBufferRead(nil)

        var postInode = stat()
        XCTAssertEqual(stat(inPlaceURL.path, &postInode), 0)
        XCTAssertEqual(preInode.st_ino, postInode.st_ino, "In-place pwrite must keep the same inode")
        XCTAssertNil(inPlaceRaceResult, "Mid-decode in-place overwrite must discard stale/torn result")
        let cachedAfterInPlaceRace = await extractor.hasCachedAnalysis(for: inPlaceURL, targetSampleCount: 256)
        XCTAssertFalse(cachedAfterInPlaceRace, "Discarded mid-decode result must not poison cache")

        let rawFreshInPlace = await extractor.extractWaveformAnalysis(from: inPlaceURL, targetSampleCount: 256)
        let freshInPlace = try XCTUnwrap(rawFreshInPlace)
        XCTAssertFalse(freshInPlace.isVerifiedDigitalSilence)
        XCTAssertGreaterThan(freshInPlace.peaks.max() ?? 0, 0.90)

        // Case B: Deterministic atomic replacement (new inode via atomic rename) mid-decode
        let atomicURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-mid-atomic-\(UUID().uuidString).wav")
        try silentWAV.write(to: atomicURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: atomicURL) }

        await extractor.setTestOnFirstBufferRead {
            try? loudWAV.write(to: atomicURL, options: .atomic)
        }
        let atomicRaceResult = await extractor.extractWaveformAnalysis(from: atomicURL, targetSampleCount: 256)
        await extractor.setTestOnFirstBufferRead(nil)

        XCTAssertNil(atomicRaceResult, "Mid-decode atomic replacement must discard old waveform result")
        let cachedAfterAtomicRace = await extractor.hasCachedAnalysis(for: atomicURL, targetSampleCount: 256)
        XCTAssertFalse(cachedAfterAtomicRace, "Old waveform must never be cached under new file version")

        let rawFreshAtomic = await extractor.extractWaveformAnalysis(from: atomicURL, targetSampleCount: 256)
        let freshAtomic = try XCTUnwrap(rawFreshAtomic)
        XCTAssertFalse(freshAtomic.isVerifiedDigitalSilence)
        XCTAssertGreaterThan(freshAtomic.peaks.max() ?? 0, 0.90)
    }

    func testMidDecodeReadFailureAndTruncatedStreamNeverMasqueradeAsCompleteOrSilent() async throws {
        let extractor = AudioWaveformExtractor()
        // First buffer (0..<32,768) is pure digital silence; buffers 2..4 (32,768..<131,072) are loud tone.
        let fullWAV = makeTestWAVData(sampleRate: 32_768, frameCount: 131_072) { idx, _ in
            guard idx >= 32_768 else { return 0 }
            let phase = sin(2.0 * Double.pi * 440.0 * Double(idx) / 32_768.0)
            return Int16(clamping: Int(phase * 28_000.0))
        }
        let midFailURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-mid-fail-\(UUID().uuidString).wav")
        try fullWAV.write(to: midFailURL)
        defer { try? FileManager.default.removeItem(at: midFailURL) }

        // 1. Mid-stream failure after buffer #1 (which only saw silent frames) must return nil and not cache.
        await extractor.setTestFailAfterBufferCount(1)
        let partialFailureResult = await extractor.extractWaveformAnalysis(from: midFailURL, targetSampleCount: 256)
        await extractor.setTestFailAfterBufferCount(nil)

        XCTAssertNil(
            partialFailureResult,
            "Mid-stream read failure after silent first buffer must return nil, never partial waveform or false digital silence"
        )
        let isCachedAfterFailure = await extractor.hasCachedAnalysis(for: midFailURL, targetSampleCount: 256)
        XCTAssertFalse(isCachedAfterFailure, "Failed or incomplete decode must never enter cache")

        // 2. Truncated WAV file on disk (header declares 131,072 frames, physical file truncated after 32,768 silent frames)
        let truncatedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-truncated-\(UUID().uuidString).wav")
        let truncatedBytes = fullWAV.prefix(44 + 32_768 * 2)
        try truncatedBytes.write(to: truncatedURL)
        defer { try? FileManager.default.removeItem(at: truncatedURL) }

        let truncatedResult = await extractor.extractWaveformAnalysis(from: truncatedURL, targetSampleCount: 256)
        XCTAssertNil(truncatedResult, "Truncated WAV container must fail complete-decode contract and return nil")
        let isTruncatedCached = await extractor.hasCachedAnalysis(for: truncatedURL, targetSampleCount: 256)
        XCTAssertFalse(isTruncatedCached)

        // 3. Subsequent full decode on intact file succeeds and detects the loud second half
        let rawComplete = await extractor.extractWaveformAnalysis(from: midFailURL, targetSampleCount: 256)
        let completeAnalysis = try XCTUnwrap(rawComplete)
        XCTAssertEqual(completeAnalysis.samplingMode, .exhaustiveBucketPeak)
        XCTAssertTrue(completeAnalysis.isCompletenessVerified)
        XCTAssertFalse(completeAnalysis.isVerifiedDigitalSilence)
        XCTAssertGreaterThan(completeAnalysis.peaks.max() ?? 0, 0.90)
    }

    func testTailTruncatedCompressedAudioFormatsRejectedAndUnverifiedNeverCached() async throws {
        let root = try XCTUnwrap(previewFixtureRootIfAvailable(), "Required preview corpus is missing")
        let extractor = AudioWaveformExtractor()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-comp-trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Compressed formats with authoritative container / header / EOS metadata:
        //    Intact file must verify completeness and cache; 99% and 70% tail-truncated copies must be rejected (nil) and never cached.
        let authoritativeCompressedExts = ["mp3", "m4a", "m4b", "m4r", "flac", "ogg", "oga", "opus"]
        for ext in authoritativeCompressedExts {
            let intactURL = root.appendingPathComponent("audio/tone.\(ext)")
            let fullData = try Data(contentsOf: intactURL)

            let rawIntactAnalysis = await extractor.extractWaveformAnalysis(from: intactURL, targetSampleCount: 256)
            let intactAnalysis = try XCTUnwrap(
                rawIntactAnalysis,
                "Intact .\(ext) must decode cleanly"
            )
            XCTAssertTrue(intactAnalysis.isCompletenessVerified, "Intact .\(ext) must verify container/codec completeness")
            XCTAssertEqual(intactAnalysis.samplingMode, .exhaustiveBucketPeak)
            let intactCached = await extractor.hasCachedAnalysis(for: intactURL, targetSampleCount: 256)
            XCTAssertTrue(intactCached, "Authoritatively complete .\(ext) must be cached")

            // Test both 99% tail truncation (< 4096 missing frames, catching the former blanket tolerance regression) and 70% truncation
            for ratio in [0.99, 0.70] {
                let cutBytes = max(16, Int(Double(fullData.count) * ratio))
                let truncURL = tempDir.appendingPathComponent("trunc_\(Int(ratio * 100)).\(ext)")
                try fullData.prefix(cutBytes).write(to: truncURL)

                let truncResult = await extractor.extractWaveformAnalysis(from: truncURL, targetSampleCount: 256)
                XCTAssertNil(
                    truncResult,
                    "Tail-truncated .\(ext) at \(Int(ratio * 100))% (\(cutBytes)/\(fullData.count)B) must be rejected as incomplete"
                )
                let isCached = await extractor.hasCachedAnalysis(for: truncURL, targetSampleCount: 256)
                XCTAssertFalse(isCached, "Tail-truncated .\(ext) must never enter complete-result cache")
            }
        }

        // 2. Ogg/Opus truncated at an exact OggS page boundary before the final EOS page (missing 0x04 EOS flag)
        for (ext, pageBoundaryCut) in [("ogg", 7389), ("opus", 9713)] {
            let intactURL = root.appendingPathComponent("audio/tone.\(ext)")
            let fullData = try Data(contentsOf: intactURL)
            let pageTruncURL = tempDir.appendingPathComponent("page_boundary_trunc.\(ext)")
            try fullData.prefix(pageBoundaryCut).write(to: pageTruncURL)

            let pageTruncResult = await extractor.extractWaveformAnalysis(from: pageTruncURL, targetSampleCount: 256)
            XCTAssertNil(pageTruncResult, "Ogg stream .\(ext) missing final EOS page must be rejected even on page boundary")
            let isCached = await extractor.hasCachedAnalysis(for: pageTruncURL, targetSampleCount: 256)
            XCTAssertFalse(isCached)
        }

        // 3. Headerless elementary packet streams (aac ADTS, ac3, eac3):
        //    - Mid-packet tail truncation (99% and 85%) must be rejected (nil) and never cached.
        //    - Intact or packet-aligned stream lacks container total-length proof, so isCompletenessVerified must be false,
        //      samplingMode must be .windowedSampledEnvelope, isVerifiedDigitalSilence must be false, and it must never enter cache.
        for ext in ["aac", "ac3", "eac3"] {
            let intactURL = root.appendingPathComponent("audio/tone.\(ext)")
            let fullData = try Data(contentsOf: intactURL)

            for ratio in [0.99, 0.85] {
                let cutBytes = Int(Double(fullData.count) * ratio)
                let midPacketURL = tempDir.appendingPathComponent("mid_pkt_\(Int(ratio * 100)).\(ext)")
                try fullData.prefix(cutBytes).write(to: midPacketURL)

                let midPacketResult = await extractor.extractWaveformAnalysis(from: midPacketURL, targetSampleCount: 256)
                XCTAssertNil(
                    midPacketResult,
                    "Mid-packet tail-truncated .\(ext) at \(Int(ratio * 100))% must be rejected"
                )
                let isCached = await extractor.hasCachedAnalysis(for: midPacketURL, targetSampleCount: 256)
                XCTAssertFalse(isCached)
            }

            let rawElementaryAnalysis = await extractor.extractWaveformAnalysis(from: intactURL, targetSampleCount: 256)
            let elementaryAnalysis = try XCTUnwrap(
                rawElementaryAnalysis,
                "Intact elementary stream .\(ext) should still extract waveform envelope"
            )
            XCTAssertFalse(
                elementaryAnalysis.isCompletenessVerified,
                "Headerless elementary stream .\(ext) cannot confirm absence of packet-boundary truncation"
            )
            XCTAssertEqual(
                elementaryAnalysis.samplingMode,
                .windowedSampledEnvelope,
                "Unverified elementary stream .\(ext) must not claim exhaustiveBucketPeak"
            )
            XCTAssertFalse(
                elementaryAnalysis.isVerifiedDigitalSilence,
                "Unverified elementary stream .\(ext) must never claim verified digital silence"
            )
            let isElementaryCached = await extractor.hasCachedAnalysis(for: intactURL, targetSampleCount: 256)
            XCTAssertFalse(
                isElementaryCached,
                "Unverified elementary stream .\(ext) must never be written to the complete-result cache"
            )
        }
    }

    func testCAFExtremeLengthNegativeAndTruncatedHeaderSafety() async throws {
        func makeCAFPacket(chunks: [(type: String, size: Int64, payload: [UInt8])]) -> Data {
            var d = Data([0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00]) // "caff" v1 flags=0
            for chunk in chunks {
                d.append(contentsOf: chunk.type.utf8.prefix(4))
                withUnsafeBytes(of: chunk.size.bigEndian) { d.append(contentsOf: $0) }
                d.append(contentsOf: chunk.payload)
            }
            return d
        }

        // 1. Truncated file header (< 8 bytes) & truncated chunk header (8 + 10 bytes)
        XCTAssertEqual(
            AudioContainerCompletenessValidator.validateCAF(data: Data([0x63, 0x61, 0x66]), fileLengthFrames: 100),
            .rejectedTruncatedOrCorrupt
        )
        let truncatedChunkHeader = Data([0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00, 0x64, 0x65, 0x73, 0x63, 0x00, 0x00])
        XCTAssertEqual(
            AudioContainerCompletenessValidator.validateCAF(data: truncatedChunkHeader, fileLengthFrames: 100),
            .rejectedTruncatedOrCorrupt
        )

        // 2. Extreme positive chunk sizes near Int64.max (must not overflow offset + 12 + Int(chunkSize))
        for hugeSize in [Int64.max, Int64.max - 8, Int64.max - 12, Int64(Int32.max) + 1] {
            let hugeDescCAF = makeCAFPacket(chunks: [("desc", hugeSize, [UInt8](repeating: 0, count: 32))])
            XCTAssertEqual(
                AudioContainerCompletenessValidator.validateCAF(data: hugeDescCAF, fileLengthFrames: 100),
                .rejectedTruncatedOrCorrupt,
                "CAF desc chunk with size \(hugeSize) must be rejected without integer overflow"
            )
            let hugeDataCAF = makeCAFPacket(chunks: [
                ("desc", 32, [UInt8](repeating: 0, count: 32)),
                ("data", hugeSize, [UInt8](repeating: 0, count: 16))
            ])
            XCTAssertEqual(
                AudioContainerCompletenessValidator.validateCAF(data: hugeDataCAF, fileLengthFrames: 100),
                .rejectedTruncatedOrCorrupt,
                "CAF data chunk with size \(hugeSize) must be rejected without integer overflow"
            )
        }

        // 3. Negative chunk sizes (-2, Int64.min, and -1 on non-data chunk) vs valid -1 unknown-length data chunk
        for negSize in [Int64(-2), Int64.min, Int64(-4096)] {
            let negDataCAF = makeCAFPacket(chunks: [
                ("desc", 32, [UInt8](repeating: 0, count: 32)),
                ("data", negSize, [UInt8](repeating: 0, count: 16))
            ])
            XCTAssertEqual(
                AudioContainerCompletenessValidator.validateCAF(data: negDataCAF, fileLengthFrames: 100),
                .rejectedTruncatedOrCorrupt
            )
        }
        let negDescCAF = makeCAFPacket(chunks: [("desc", -1, [UInt8](repeating: 0, count: 32))])
        XCTAssertEqual(
            AudioContainerCompletenessValidator.validateCAF(data: negDescCAF, fileLengthFrames: 100),
            .rejectedTruncatedOrCorrupt
        )
        let unknownLenDataCAF = makeCAFPacket(chunks: [
            ("desc", 32, [UInt8](repeating: 0, count: 32)),
            ("data", -1, [UInt8](repeating: 0, count: 16))
        ])
        XCTAssertEqual(
            AudioContainerCompletenessValidator.validateCAF(data: unknownLenDataCAF, fileLengthFrames: 100),
            .unverifiedElementaryStream(expectedDecodedFrames: 100, justifiedCodecPrimingFrames: 0)
        )
    }

    // MARK: - 3. Long Audio Precision Boundary & Short Impulse Between Windows

    func testLongAudioSingleShortImpulseAndSilencePrecisionBoundary() async throws {
        // 4,200,000 frames (> 4,000,000 windowed threshold).
        // Place a 32-frame impulse at [832,000 ..< 832,032] strictly between Window 50 and Window 51.
        let totalFrames = 4_200_000
        let impulseStart = 832_000
        let impulseEnd = 832_032
        let impulseWAV = makeTestWAVData(sampleRate: 48_000, frameCount: totalFrames) { idx, _ in
            (idx >= impulseStart && idx < impulseEnd) ? ((idx % 2 == 0) ? 30_000 : -30_000) : 0
        }
        let impulseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-long-impulse-\(UUID().uuidString).wav")
        try impulseWAV.write(to: impulseURL)
        defer { try? FileManager.default.removeItem(at: impulseURL) }

        // A. When sequential verification is disabled, sparse 256-window sampling misses the impulse
        // between windows 50 and 51: it MUST preserve real zero values (0.0), report sampledOrCompletenessUnverified,
        // never claim verified digital silence, and never enter the complete-result cache.
        let rawUnverified = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
            from: impulseURL,
            targetSampleCount: 256,
            allowSequentialSilenceVerification: false
        )
        let unverifiedAnalysis = try XCTUnwrap(rawUnverified)
        XCTAssertEqual(unverifiedAnalysis.samplingMode, .windowedSampledEnvelope)
        XCTAssertEqual(unverifiedAnalysis.precisionStatus, .sampledOrCompletenessUnverified)
        XCTAssertFalse(unverifiedAnalysis.isCompletenessVerified)
        XCTAssertFalse(unverifiedAnalysis.isVerifiedDigitalSilence)
        XCTAssertTrue(
            unverifiedAnalysis.peaks.allSatisfy { $0 == 0.0 },
            "Unverified silence must preserve real 0.0 sample values without fabricating non-zero amplitude"
        )
        let isUnverifiedCached = await AudioWaveformExtractor.shared.hasCachedAnalysis(
            for: impulseURL,
            targetSampleCount: 256,
            allowSequentialSilenceVerification: false
        )
        XCTAssertFalse(isUnverifiedCached, "Unverified sampled result must never be written to complete cache")

        // B. Default extraction runs sequential SIMD verification when sparse windows read zero,
        // catching the 32-frame impulse in its exact bucket!
        let rawVerified = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
            from: impulseURL,
            targetSampleCount: 256,
            allowSequentialSilenceVerification: true
        )
        let verifiedAnalysis = try XCTUnwrap(rawVerified)
        XCTAssertEqual(verifiedAnalysis.samplingMode, .exhaustiveBucketPeak)
        XCTAssertEqual(verifiedAnalysis.precisionStatus, .exhaustiveVerified)
        XCTAssertTrue(verifiedAnalysis.isCompletenessVerified)
        XCTAssertFalse(verifiedAnalysis.isVerifiedDigitalSilence)
        let expectedBucket = Int((Int64(impulseStart) * 256) / Int64(totalFrames))
        XCTAssertEqual(verifiedAnalysis.peaks[expectedBucket], 1.0, accuracy: 0.01)
        let nonZeroBuckets = verifiedAnalysis.peaks.enumerated().filter { $0.element > 0.01 }.map(\.offset)
        XCTAssertEqual(nonZeroBuckets, [expectedBucket], "Only the bucket containing the short impulse should spike")
    }

    // MARK: - 4. Separation of Whole-Track Waveform and Real-Time Level

    func testPlaybackMeteringDoesNotMutateWholeTrackWaveform() async throws {
        let toneData = makeTestWAVData(sampleRate: 16_000, frameCount: 16_000) { idx, _ in
            let phase = sin(2.0 * Double.pi * 440.0 * Double(idx) / 16_000.0)
            return Int16(clamping: Int(phase * 20_000.0))
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-meter-\(UUID().uuidString).wav")
        try toneData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let engine = MPVAudioEngine()
        engine.load(url: tempURL)
        await engine.waitForWaveform()

        let initialWaveform = engine.waveformSamples
        XCTAssertEqual(initialWaveform.count, 1600)

        engine.play()
        try? await Task.sleep(nanoseconds: 120_000_000)
        let waveformDuringPlayback = engine.waveformSamples
        engine.pause()

        XCTAssertEqual(
            initialWaveform,
            waveformDuringPlayback,
            "Real-time playback metering must never mutate whole-track waveformSamples"
        )
        XCTAssertEqual(engine.currentLevel, 0.0, "Pausing playback must reset currentLevel to 0.0")
    }

    // MARK: - 5. Off-Actor Bounded Cancellation & Non-Blocking Rapid Switching

    func testRapidSwitchingCancelsInFlightDecodeWithoutBlockingNewFile() async throws {
        await AudioWaveformExtractor.shared.clearCache()
        await AudioWaveformExtractor.shared.setTestPerBufferDelay(nanoseconds: 25_000_000)
        defer {
            Task {
                await AudioWaveformExtractor.shared.setTestPerBufferDelay(nanoseconds: 0)
            }
        }

        let slowWAV = makeTestWAVData(sampleRate: 32_768, frameCount: 655_360) { idx, _ in
            Int16(clamping: (idx % 200) * 100)
        }
        let fastSilentWAV = makeTestWAVData(sampleRate: 16_000, frameCount: 16_000) { _, _ in 0 }

        let slowURL1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-slow1-\(UUID().uuidString).wav")
        let slowURL2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-slow2-\(UUID().uuidString).wav")
        let fastURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-fast-\(UUID().uuidString).wav")
        try slowWAV.write(to: slowURL1)
        try slowWAV.write(to: slowURL2)
        try fastSilentWAV.write(to: fastURL)
        defer {
            try? FileManager.default.removeItem(at: slowURL1)
            try? FileManager.default.removeItem(at: slowURL2)
            try? FileManager.default.removeItem(at: fastURL)
        }

        let task1 = Task {
            await AudioWaveformExtractor.shared.extractWaveformAnalysis(from: slowURL1, targetSampleCount: 256)
        }
        let task2 = Task {
            await AudioWaveformExtractor.shared.extractWaveformAnalysis(from: slowURL2, targetSampleCount: 256)
        }
        try? await Task.sleep(nanoseconds: 35_000_000)
        task1.cancel()
        task2.cancel()

        let startNs = DispatchTime.now().uptimeNanoseconds
        let fastResult = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
            from: fastURL,
            targetSampleCount: 256
        )
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        let (cancelledResult1, cancelledResult2) = await (task1.value, task2.value)

        XCTAssertNil(cancelledResult1, "Cancelled in-flight decode task1 must abort and return nil")
        XCTAssertNil(cancelledResult2, "Cancelled in-flight decode task2 must abort and return nil")
        XCTAssertNotNil(fastResult)
        XCTAssertTrue(fastResult?.isVerifiedDigitalSilence ?? false)
        // Without cancellation, slowURL1 + slowURL2 would take >500ms; with cancellation, fastURL finishes quickly.
        XCTAssertLessThan(elapsedMs, 220.0, "Cancelled decodes must stop promptly without head-of-line blocking")
    }

    // MARK: - 6. Main-Thread Preparation Budget & Stage Timing Measurements

    func testMainThreadPreparationBudgetAndStageTimingMeasurements() async throws {
        let engine = MPVAudioEngine()

        // 1. Small WAV (<= 16 MiB): warm up process-wide CoreAudio HAL, then measure warm stage timings
        let smallWAV = makeTestWAVData(sampleRate: 16_000, frameCount: 16_000) { idx, _ in
            Int16(clamping: Int(sin(Double(idx) * 0.1) * 12_000.0))
        }
        let smallURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-small-budget-\(UUID().uuidString).wav")
        try smallWAV.write(to: smallURL)
        defer { try? FileManager.default.removeItem(at: smallURL) }

        engine.load(url: smallURL)
        engine.play()
        engine.pause()
        _ = try XCTUnwrap(engine.lastTimingMetrics)

        // Warm measurement after CoreAudio HAL initialization
        engine.load(url: smallURL)
        engine.play()
        engine.pause()
        let smallMetrics = try XCTUnwrap(engine.lastTimingMetrics)
        XCTAssertTrue(smallMetrics.didPrepareSynchronously)
        XCTAssertFalse(smallMetrics.usedDataFallback)
        XCTAssertGreaterThanOrEqual(smallMetrics.firstPlayDurationMs, 0.0)
        XCTAssertLessThan(smallMetrics.urlInitDurationMs, MPVAudioEngine.maxMainThreadStageBudgetMs * 2.0)

        // 2. Large WAV (> 16 MiB): prepareToPlay() skipped during load(url:), firstPlayDurationMs measured on play()
        let largeFrameCount = Int(MPVAudioEngine.maxSynchronousPrepareBytes / 2) + 64_000
        let largeWAV = makeTestWAVData(sampleRate: 48_000, frameCount: largeFrameCount) { _, _ in 0 }
        let largeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-large-budget-\(UUID().uuidString).wav")
        try largeWAV.write(to: largeURL)
        defer { try? FileManager.default.removeItem(at: largeURL) }

        engine.load(url: largeURL)
        engine.play()
        engine.pause()
        let largeMetrics = try XCTUnwrap(engine.lastTimingMetrics)
        XCTAssertFalse(largeMetrics.didPrepareSynchronously)
        XCTAssertEqual(largeMetrics.prepareDurationMs, 0.0)
        XCTAssertGreaterThanOrEqual(largeMetrics.firstPlayDurationMs, 0.0)
        XCTAssertLessThan(largeMetrics.urlInitDurationMs, MPVAudioEngine.maxMainThreadStageBudgetMs * 2.0)

        // 3. Oversized Data budget & corrupt file failure termination
        engine.load(data: Data(count: MPVAudioEngine.maxDirectDataBytes + 1024))
        XCTAssertTrue(engine.hasPlaybackError)
        XCTAssertFalse(engine.isBuffering)
        XCTAssertFalse(engine.isExtractingWaveform)

        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-corrupt-\(UUID().uuidString).wav")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        engine.load(url: corruptURL)
        XCTAssertTrue(engine.hasPlaybackError)
        XCTAssertFalse(engine.isBuffering)
        XCTAssertFalse(engine.isExtractingWaveform)
        XCTAssertTrue(engine.waveformSamples.isEmpty)
        XCTAssertNotNil(engine.diagnosticDetail)
    }
}
