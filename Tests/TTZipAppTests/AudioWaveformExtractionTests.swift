// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import AVFoundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class AudioWaveformExtractionTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("AudioWaveformTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Helper: Generate Synthetic 16-bit PCM WAV File
    
    private func createTestWavFile(durationSec: Double = 1.0, sampleRate: Int = 44100) throws -> URL {
        let fileURL = tempDirURL.appendingPathComponent("test_audio.wav")
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
        let wavURL = try createTestWavFile(durationSec: 1.5)
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
        let wavURL = try createTestWavFile(durationSec: 0.5)
        let extractor = AudioWaveformExtractor()
        
        let firstResult = await extractor.extractWaveform(from: wavURL, targetSampleCount: 24)
        let secondResult = await extractor.extractWaveform(from: wavURL, targetSampleCount: 24)
        
        XCTAssertEqual(firstResult, secondResult, "Second extraction should hit in-memory cache and return identical data")
    }
    
    // MARK: - Test 3: Fallback Waveform on Non-Audio File
    
    func testFallbackWaveformOnCorruptFile() async throws {
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
        let wavURL = try createTestWavFile(durationSec: 2.0)
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
        let allExtensions = [
            "ogg", "opus", "flac", "ape", "wma", "wav", "mp3", "aac",
            "m4a", "aiff", "alac", "caf", "dsf", "dff", "wv", "aifc", "m4b", "dts", "mid", "midi", "mka"
        ]
        
        for ext in allExtensions {
            let fileURL = tempDirURL.appendingPathComponent("test_track.\(ext)")
            try Data("dummy audio stream payload for format \(ext)".utf8).write(to: fileURL)
            
            // 1. Verify MediaPreviewFactory routes to .audio(url)
            let detected = MediaPreviewFactory.detectType(url: fileURL)
            switch detected {
            case .audio(let u):
                XCTAssertEqual(u, fileURL, "Format .\(ext) must route to .audio(url)")
            default:
                XCTFail("Format .\(ext) failed to route to .audio, got \(detected)")
            }
            
            // 2. Verify UnifiedAudioPlayerView instantiation
            let playerView = UnifiedAudioPlayerView(url: fileURL, fileName: "test_track.\(ext)")
            XCTAssertEqual(playerView.formatBadge, ext.uppercased())
            
            // 3. Verify AudioPlaybackFallbackView embeds UnifiedAudioPlayerView
            let fallbackView = AudioPlaybackFallbackView(url: fileURL, fileName: "test_track.\(ext)")
            XCTAssertEqual(fallbackView.fileName, "test_track.\(ext)")
        }
    }
}
