// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import AVFoundation
import SwiftUI
import TTZipUI
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp
@testable import TTZipPreviewKit

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
    func testAudioFormatsRouteToEmbeddedPlaybackView() async throws {
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
            
            let playerView = TTZipEmbeddedAudioPlayerView(url: fileURL, fileName: "test_track.\(ext)") { _, _, _, _ in }
            XCTAssertEqual(playerView.formatBadge, ext.uppercased())
            XCTAssertEqual(playerView.fileName, "test_track.\(ext)")
            XCTAssertEqual(playerView.url, fileURL)
        }
    }

    @MainActor
    func testDetachedAudioPanelKeepsLoadedSessionAndFollowsParentWindow() throws {
        let directory = try makeTemporaryDirectory(prefix: "MiniAudio")
        let url = try createTestWavFile(in: directory)
        let engine = MPVAudioEngine()
        let generation = engine.load(url: url, ownerSessionID: "mini-panel")
        defer { engine.stop() }
        XCTAssertGreaterThan(engine.duration, 0)

        let firstParent = NSWindow()
        let secondParent = NSWindow()
        firstParent.isReleasedWhenClosed = false
        secondParent.isReleasedWhenClosed = false

        var shownPanel: NSPanel?
        let presenter = AudioMiniPlayerPresenter { shownPanel = $0 }
        defer { presenter.dismiss() }

        presenter.present(store: engine, title: "First", artist: nil, artwork: nil, parentWindow: firstParent)
        let firstPanel = try XCTUnwrap(shownPanel)
        let firstHost = try XCTUnwrap(firstPanel.contentView as? NSHostingView<CompactAudioMiniPlayerView>)
        XCTAssertTrue(firstHost.rootView.store === engine)
        XCTAssertEqual(firstHost.rootView.title, "First")

        presenter.present(store: engine, title: "Second", artist: nil, artwork: nil, parentWindow: secondParent)
        let secondPanel = try XCTUnwrap(shownPanel)
        XCTAssertNil(firstPanel.contentView)
        XCTAssertFalse(firstPanel === secondPanel)
        firstParent.close()
        let secondHost = try XCTUnwrap(secondPanel.contentView as? NSHostingView<CompactAudioMiniPlayerView>)
        XCTAssertTrue(secondHost.rootView.store === engine)
        XCTAssertEqual(engine.activeLoadGeneration, generation)

        firstHost.rootView.onRestore()
        XCTAssertNotNil(secondPanel.contentView)
        secondParent.close()
        XCTAssertNil(secondPanel.contentView)

        presenter.present(store: engine, title: "Third", artist: nil, artwork: nil, parentWindow: nil)
        let thirdPanel = try XCTUnwrap(shownPanel)
        let thirdHost = try XCTUnwrap(thirdPanel.contentView as? NSHostingView<CompactAudioMiniPlayerView>)
        thirdHost.rootView.onRestore()
        XCTAssertNil(thirdPanel.contentView)
        XCTAssertEqual(engine.activeLoadGeneration, generation)
        XCTAssertEqual(engine.activeOwnerSessionID, "mini-panel")
    }

    @MainActor
    func testEmbeddedAudioHostKeepsNewSameURLSessionWhenOldWindowCloses() async throws {
        let directory = try makeTemporaryDirectory(prefix: "EmbeddedAudio")
        let url = try createTestWavFile(in: directory, durationSec: 2.0)
        let engine = MPVAudioEngine.shared
        let coordinator = MediaPlaybackCoordinator.shared
        let firstWindow = makeAudioPreviewWindow(for: url)
        defer {
            firstWindow.contentView = nil
            engine.stop()
        }

        try await waitForAudioPreview {
            engine.currentURL == url && engine.activeOwnerSessionID != nil && engine.duration > 0
        }
        let firstSession = try XCTUnwrap(engine.activeOwnerSessionID)
        let firstGeneration = engine.activeLoadGeneration
        XCTAssertEqual(coordinator.activeSessionID, firstSession)

        let secondWindow = makeAudioPreviewWindow(for: url)
        defer { secondWindow.contentView = nil }
        try await waitForAudioPreview {
            engine.currentURL == url && engine.activeLoadGeneration > firstGeneration && engine.duration > 0
        }
        let secondSession = try XCTUnwrap(engine.activeOwnerSessionID)
        let secondGeneration = engine.activeLoadGeneration
        XCTAssertNotEqual(firstSession, secondSession)
        XCTAssertEqual(coordinator.activeSessionID, secondSession)

        firstWindow.contentView = nil
        await Task.yield()
        XCTAssertEqual(engine.currentURL, url)
        XCTAssertEqual(engine.activeOwnerSessionID, secondSession)
        XCTAssertEqual(engine.activeLoadGeneration, secondGeneration)
        XCTAssertEqual(coordinator.activeSessionID, secondSession)
        coordinator.triggerSeek(by: 0.5)
        XCTAssertEqual(engine.currentTime, 0.5, accuracy: 0.05)

        secondWindow.contentView = nil
        try await waitForAudioPreview { engine.currentURL == nil && coordinator.activeSessionID == nil }
    }

    @MainActor
    func testEmbeddedAudioWaveformRendersLoadedTrackInBothLayouts() async throws {
        let directory = try makeTemporaryDirectory(prefix: "EmbeddedWaveform")
        let url = try createTestWavFile(in: directory, durationSec: 2.0)
        let engine = MPVAudioEngine.shared

        for size in [NSSize(width: 320, height: 300), NSSize(width: 460, height: 440)] {
            let window = makeAudioPreviewWindow(for: url, size: size)
            defer {
                window.contentView = nil
                window.close()
                engine.stop()
            }

            try await waitForAudioPreview {
                engine.currentURL == url && engine.duration > 0 && engine.waveformSamples.contains { $0 > 0.01 }
            }
            let host = try XCTUnwrap(window.contentView)
            try await assertRenderedWaveform(in: host)
            XCTAssertFalse(window.isVisible)
        }
    }

    @MainActor
    func testEmbeddedOggRendersWaveformAndRejectsPlayback() async throws {
        let directory = try makeTemporaryDirectory(prefix: "EmbeddedOgg")
        let url = directory.appendingPathComponent("tone.ogg")
        let payload = try loadRealAudioCorpusFixture(for: "ogg", fixturesRoot: locatePreviewFixturesRoot())
        XCTAssertEqual(payload.prefix(4), Data("OggS".utf8))
        try payload.write(to: url)

        let engine = MPVAudioEngine.shared
        let coordinator = MediaPlaybackCoordinator.shared
        let window = makeAudioPreviewWindow(for: url)
        defer {
            window.contentView = nil
            window.close()
            engine.stop()
        }
        try await waitForAudioPreview {
            engine.currentURL == url && engine.activeOwnerSessionID != nil && !engine.isExtractingWaveform
                && engine.waveformSamples.contains { $0 > 0.01 }
        }
        XCTAssertEqual(coordinator.activeSessionID, try XCTUnwrap(engine.activeOwnerSessionID))
        let productView = TTZipEmbeddedAudioPlayerView(url: url, fileName: url.lastPathComponent) { _, _, _, _ in }
        XCTAssertTrue(productView.isWaveformOnlyPreview)
        XCTAssertFalse(productView.isPlaybackAvailable)
        XCTAssertFalse(productView.shouldShowFatalDiagnosticCard)

        let host = try XCTUnwrap(window.contentView)
        try await assertRenderedWaveform(in: host)
        coordinator.triggerPlayPause()
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testExportEmbeddedWaveformAcrossWidthsAndAppearances() async throws {
        let directory = try makeTemporaryDirectory(prefix: "WaveformAppearance")
        let url = try createTestWavFile(in: directory, durationSec: 8)
        let engine = MPVAudioEngine.shared

        for width in [280, 360, 480] {
            let size = NSSize(width: width, height: 248)
            let window = makeAudioPreviewWindow(for: url, size: size)
            defer {
                window.contentView = nil
                window.close()
                engine.stop()
            }
            try await waitForAudioPreview {
                engine.currentURL == url && engine.duration > 0 && engine.waveformSamples.contains { $0 > 0.01 }
            }
            engine.seek(to: engine.duration * 0.42)
            let host = try XCTUnwrap(window.contentView)
            var appearances: Set<Data> = []
            for (appearance, tag) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                host.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(35))
                try await assertRenderedWaveform(in: host)
                let png = try captureWaveformPNG(in: host, named: "ttzip_waveform_\(width)pt_\(tag)")
                appearances.insert(png)
            }
            XCTAssertEqual(appearances.count, 2, "Both appearances should render differently at \(width)pt")
            XCTAssertFalse(window.isVisible)
        }
    }

    @MainActor
    func testExportEmbeddedWaveformScrollAndSeekFrames() async throws {
        let directory = try makeTemporaryDirectory(prefix: "WaveformSeek")
        let url = try createTestWavFile(in: directory, durationSec: 8)
        let engine = MPVAudioEngine.shared
        let coordinator = MediaPlaybackCoordinator.shared
        let window = makeAudioPreviewWindow(for: url, size: NSSize(width: 360, height: 248))
        defer {
            window.contentView = nil
            window.close()
            engine.stop()
        }
        try await waitForAudioPreview {
            engine.currentURL == url && engine.duration > 0 && engine.waveformSamples.contains { $0 > 0.01 }
        }
        let host = try XCTUnwrap(window.contentView)
        host.appearance = NSAppearance(named: .darkAqua)
        try await assertRenderedWaveform(in: host)

        let progress = (0..<18).map { Double($0) / 17 * 0.85 } + [0.70, 0.52, 0.36, 0.25, 0.25, 0.25]
        var frames: Set<Data> = []
        for (index, fraction) in progress.enumerated() {
            let position = engine.duration * fraction
            coordinator.triggerSeek(by: position - engine.currentTime)
            XCTAssertEqual(engine.currentTime, position, accuracy: 0.05)
            try await Task.sleep(for: .milliseconds(20))
            let name = String(format: "ttzip_waveform_scroll_%02d", index)
            frames.insert(try captureWaveformPNG(in: host, named: name))
        }
        XCTAssertGreaterThan(frames.count, 2)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    private func assertRenderedWaveform(in host: NSView) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            if try renderedWaveformPlayheadHeight(in: host) >= 24 { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTFail("Waveform playhead is missing at \(host.bounds.size)")
    }

    @MainActor
    private func captureWaveformPNG(in host: NSView, named name: String) throws -> Data {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(host.bounds.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(host.bounds.height))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let output = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        }
        return png
    }

    @MainActor
    private func renderedWaveformPlayheadHeight(in host: NSView) throws -> CGFloat {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let middle = bitmap.pixelsWide / 2
        var tallestRun = 0
        for x in (middle - 2)...(middle + 2) {
            var run = 0
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.9,
                      color.redComponent > color.greenComponent + 0.08,
                      color.greenComponent > color.blueComponent + 0.12 else {
                    run = 0
                    continue
                }
                run += 1
                tallestRun = max(tallestRun, run)
            }
        }
        return CGFloat(tallestRun) * host.bounds.height / CGFloat(bitmap.pixelsHigh)
    }

    @MainActor
    private func makeAudioPreviewWindow(
        for url: URL,
        size: NSSize = NSSize(width: 360, height: 300)
    ) -> NSWindow {
        let preview = AudioPreviewHostView(
            url: url,
            fileName: url.lastPathComponent,
            resourceContext: .diskFile(url: url),
            isFullScreen: false
        )
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: preview)
        host.frame = frame
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func waitForAudioPreview(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Audio preview did not reach the expected session state")
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
