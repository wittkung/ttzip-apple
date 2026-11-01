// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AVFoundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class AudioWaveformExtractionTests: XCTestCase {
    
    // MARK: - Helper: Generate Synthetic 16-bit PCM WAV File
    
    private func createTestWavFile(in directory: URL, durationSec: Double = 1.0, sampleRate: Int = 44100) throws -> URL {
        let fileURL = directory.appendingPathComponent("test_audio.wav")
        let totalSamples = Int(Double(sampleRate) * durationSec)
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate * Int(numChannels) * Int(bitsPerSample / 8))
        let blockAlign = Int16(numChannels * (bitsPerSample / 8))
        let dataSize = Int32(totalSamples * Int(numChannels) * 2)
        
        var data = Data()
        // RIFF Header
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        var chunkSize = Int32(36 + dataSize).littleEndian
        data.append(Data(bytes: &chunkSize, count: 4))
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        
        // fmt subchunk
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        var subchunk1Size = Int32(16).littleEndian
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat = Int16(1).littleEndian // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var channels = numChannels.littleEndian
        data.append(Data(bytes: &channels, count: 2))
        var sRate = Int32(sampleRate).littleEndian
        data.append(Data(bytes: &sRate, count: 4))
        var bRate = byteRate.littleEndian
        data.append(Data(bytes: &bRate, count: 4))
        var bAlign = blockAlign.littleEndian
        data.append(Data(bytes: &bAlign, count: 2))
        var bPerSample = bitsPerSample.littleEndian
        data.append(Data(bytes: &bPerSample, count: 2))
        
        // data subchunk
        data.append(contentsOf: [UInt8]("data".utf8))
        var dSize = dataSize.littleEndian
        data.append(Data(bytes: &dSize, count: 4))
        
        // Generate audio sine wave with dynamic envelope
        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            // 440 Hz tone with rising and falling amplitude
            let envelope = sin(Double.pi * t / durationSec)
            let sampleVal = Int16(sin(2.0 * Double.pi * 440.0 * t) * envelope * 30000.0)
            var littleEndianSample = sampleVal.littleEndian
            data.append(Data(bytes: &littleEndianSample, count: 2))
        }
        
        try data.write(to: fileURL)
        return fileURL
    }
    
    // MARK: - Test 1: Real Waveform Extraction & Normalization
    
    func testRealWaveformExtractionFromWavFile() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Waveform")
        let wavURL = try createTestWavFile(in: tempDirURL, durationSec: 1.5)
        let extractor = AudioWaveformExtractor()
        
        let sampleCount = 36
        let peaks = await extractor.extractWaveform(from: wavURL, targetSampleCount: sampleCount)
        
        XCTAssertEqual(peaks.count, sampleCount, "Waveform sample count should match target \(sampleCount)")
        for (idx, peak) in peaks.enumerated() {
            XCTAssertGreaterThanOrEqual(peak, 0.02, "Sample height at \(idx) cannot be lower than minimum 0.02")
            XCTAssertLessThanOrEqual(peak, 1.0, "Sample height at \(idx) cannot exceed 1.0")
        }
        
        // Verify symmetric peak envelope
        let middleIndex = sampleCount / 2
        let edgeIndex = 1
        XCTAssertGreaterThan(peaks[middleIndex], peaks[edgeIndex], "Middle envelope amplitude should be greater than boundary amplitude")
    }
    
    // MARK: - Test 2: In-Memory Waveform Cache Hit
    
    func testWaveformExtractorCacheBehavior() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Waveform")
        let wavURL = try createTestWavFile(in: tempDirURL, durationSec: 0.5)
        let extractor = AudioWaveformExtractor()
        
        let firstResult = await extractor.extractWaveform(from: wavURL, targetSampleCount: 24)
        let secondResult = await extractor.extractWaveform(from: wavURL, targetSampleCount: 24)
        
        XCTAssertEqual(firstResult, secondResult, "Second extraction should hit in-memory cache and return identical data")
    }
    
    // MARK: - Test 3: Fallback Waveform on Non-Audio File
    
    func testFallbackWaveformOnCorruptFile() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Waveform")
        let corruptURL = tempDirURL.appendingPathComponent("not_audio.txt")
        try "corrupted audio content".write(to: corruptURL, atomically: true, encoding: .utf8)
        
        let extractor = AudioWaveformExtractor()
        let peaks = await extractor.extractWaveform(from: corruptURL, targetSampleCount: 20)
        
        XCTAssertEqual(peaks.count, 20, "Should return requested count of fallback samples on parse failure")
        XCTAssertTrue(peaks.allSatisfy { $0 >= 0.02 && $0 <= 1.0 }, "Fallback waveform values must be within [0.02, 1.0]")
    }
    
    // MARK: - Test 4: Default Waveform Generator
    
    func testDefaultWaveformGenerator() async {
        let extractor = AudioWaveformExtractor()
        let def = await extractor.defaultWaveform(count: 32)
        
        XCTAssertEqual(def.count, 32)
        XCTAssertTrue(def.allSatisfy { $0 > 0 && $0 <= 1.0 })
    }
    
    // MARK: - Test 5: 1600-Sample Waveform Extraction for DAW Oscillogram
    
    func test1600SampleWaveformExtractionFromWavFile() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Waveform")
        let wavURL = try createTestWavFile(in: tempDirURL, durationSec: 2.0)
        let extractor = AudioWaveformExtractor()
        
        let sampleCount = 1600
        let peaks = await extractor.extractWaveform(from: wavURL, targetSampleCount: sampleCount)
        
        XCTAssertEqual(peaks.count, sampleCount, "Waveform bucket count must equal exactly 1600 samples")
        XCTAssertTrue(peaks.allSatisfy { $0 >= 0.0 && $0 <= 1.0 }, "Waveform peaks must be bounded in [0.0, 1.0]")
        XCTAssertTrue(peaks.contains { $0 > 0.1 }, "Waveform should contain positive audio signal peaks")
    }
    
    // MARK: - Test 6: All Audio Formats Unified In-App Embedded View Instantiation
    
    @MainActor
    func testAllAudioFormatsUnifiedPlaybackViewInstantiation() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Waveform")
        let allExtensions = [
            "ogg", "opus", "flac", "ape", "wma", "wav", "mp3", "aac",
            "m4a", "aiff", "alac", "caf", "dsf", "dff", "wv", "aifc", "m4b", "dts", "mid", "midi", "mka"
        ]
        
        for ext in allExtensions {
            let fileURL = tempDirURL.appendingPathComponent("test_track.\(ext)")
            try sampleAudioPayload(for: ext).write(to: fileURL)
            
            // 1. Verify MediaPreviewFactory routes to .audio(url)
            let detected = MediaPreviewFactory.detectType(url: fileURL)
            switch detected {
            case .audio(let u):
                XCTAssertEqual(u, fileURL, "Format .\(ext) must route to .audio(url)")
            default:
                XCTFail("Format .\(ext) failed to route to .audio, got \(detected)")
            }
            
            // 2. Verify UnifiedAudioPlayerView direct microkernel instantiation
            let playerView = UnifiedAudioPlayerView(url: fileURL, fileName: "test_track.\(ext)")
            XCTAssertEqual(playerView.formatBadge, ext.uppercased())
            XCTAssertEqual(playerView.fileName, "test_track.\(ext)")
            XCTAssertEqual(playerView.url, fileURL)
        }
    }

    private func sampleAudioPayload(for ext: String) -> Data {
        var header: [UInt8]
        switch ext {
        case "ogg":
            header = [0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00, 0x01] + Array("vorbis".utf8)
        case "opus":
            header = [0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00] + Array("OpusHead".utf8)
        case "flac":
            header = [0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22]
        case "ape":
            header = [0x4D, 0x41, 0x43, 0x20, 0x96, 0x0F, 0x00, 0x00]
        case "wma":
            header = [
                0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9,
                0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B
            ]
        case "wav":
            header = [0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45]
        case "mp3":
            header = [0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        case "aac":
            header = [0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC]
        case "m4a", "alac":
            header = [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20]
        case "m4b":
            header = [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x42, 0x20]
        case "aiff":
            header = [0x46, 0x4F, 0x52, 0x4D, 0x00, 0x00, 0x00, 0x24, 0x41, 0x49, 0x46, 0x46]
        case "aifc":
            header = [0x46, 0x4F, 0x52, 0x4D, 0x00, 0x00, 0x00, 0x24, 0x41, 0x49, 0x46, 0x43]
        case "caf":
            header = [0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00]
        case "dsf":
            header = [0x44, 0x53, 0x44, 0x20, 0x1C, 0x00, 0x00, 0x00]
        case "dff":
            header = [0x46, 0x52, 0x4D, 0x38, 0x00, 0x00, 0x00, 0x00]
        case "wv":
            header = [0x77, 0x76, 0x70, 0x6B, 0x20, 0x00, 0x00, 0x00]
        case "dts":
            header = [0x7F, 0xFE, 0x80, 0x01, 0xFC, 0x3C, 0x00, 0x00]
        case "mid", "midi":
            header = [0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06]
        case "mka":
            header = [0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00, 0x83, 0x81, 0x02]
        default:
            header = [0x49, 0x44, 0x33, 0x04, 0x00, 0x00]
        }
        return Data(header) + Data(repeating: 0x00, count: 64)
    }
}
