// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import AVFoundation
import CoreVideo
import CoreMedia
@testable import TTZipCore
@testable import TTZipApp

// MARK: - Layer 1: Real Media Fixture Synthesizer

enum MediaFixtureSynthesizer {
    static func createSyntheticMP4(
        at url: URL,
        durationSeconds: Double = 1.0,
        fps: Int32 = 30,
        size: CGSize = CGSize(width: 320, height: 240)
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else {
            throw NSError(domain: "MediaFixtureSynthesizer", code: -1)
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        let totalFrames = Int(durationSeconds * Double(fps))
        for frameIndex in 0..<totalFrames {
            var spins = 0
            while !input.isReadyForMoreMediaData && spins < 100 {
                Thread.sleep(forTimeInterval: 0.005)
                spins += 1
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, nil, &buffer)
            guard status == kCVReturnSuccess, let buf = buffer else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                let color = UInt8((frameIndex * 255) / max(totalFrames, 1))
                memset(base, Int32(color), rowBytes * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            let frameTime = CMTime(value: Int64(frameIndex), timescale: fps)
            adaptor.append(buf, withPresentationTime: frameTime)
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
    }
    
    static func createSyntheticEBMLMKV(title: String = "Test MKV", durationMs: UInt64 = 1000) -> Data {
        let ebmlHdr = ebmlBox(id: 0x1A45_DFA3, data: ebmlString(id: 0x4282, str: "matroska"))
        var infoBody = Data()
        infoBody.append(ebmlUint(id: 0x2AD7_B1, val: 1_000_000, bytes: 3))
        infoBody.append(ebmlFloat32(id: 0x4489, val: Float(durationMs)))
        infoBody.append(ebmlString(id: 0x7BA9, str: title))
        let infoBox = ebmlBox(id: 0x1549_A966, data: infoBody)
        
        var vSub = Data()
        vSub.append(ebmlUint(id: 0xB0, val: 1920, bytes: 2))
        vSub.append(ebmlUint(id: 0xBA, val: 1080, bytes: 2))
        var vBody = Data()
        vBody.append(ebmlUint(id: 0xD7, val: 1, bytes: 1))
        vBody.append(ebmlUint(id: 0x83, val: 1, bytes: 1))
        vBody.append(ebmlString(id: 0x86, str: "V_MPEG4/ISO/AVC"))
        vBody.append(ebmlString(id: 0x536E, str: "H.264 Video"))
        vBody.append(ebmlBox(id: 0xE0, data: vSub))
        let track1 = ebmlBox(id: 0xAE, data: vBody)
        
        var aSub = Data()
        aSub.append(ebmlUint(id: 0x9F, val: 2, bytes: 1))
        aSub.append(ebmlFloat32(id: 0xB5, val: 44100.0))
        var aBody = Data()
        aBody.append(ebmlUint(id: 0xD7, val: 2, bytes: 1))
        aBody.append(ebmlUint(id: 0x83, val: 2, bytes: 1))
        aBody.append(ebmlString(id: 0x86, str: "A_AAC"))
        aBody.append(ebmlString(id: 0x22B5_9C, str: "eng"))
        aBody.append(ebmlBox(id: 0xE1, data: aSub))
        let track2 = ebmlBox(id: 0xAE, data: aBody)
        
        var tracksBody = Data()
        tracksBody.append(track1)
        tracksBody.append(track2)
        let tracksBox = ebmlBox(id: 0x1654_AE6B, data: tracksBody)
        
        var segmentBody = Data()
        segmentBody.append(infoBox)
        segmentBody.append(tracksBox)
        
        var mkvData = Data()
        mkvData.append(ebmlHdr)
        mkvData.append(ebmlBox(id: 0x1853_8067, data: segmentBody))
        return mkvData
    }
    
    private static func ebmlBox(id: UInt32, data: Data) -> Data {
        var out = Data()
        if id > 0x00FF_FFFF {
            var be = id.bigEndian; withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        } else if id > 0xFFFF {
            var be = id.bigEndian; withUnsafeBytes(of: &be) { out.append(contentsOf: $0[1...3]) }
        } else if id > 0xFF {
            var be = id.bigEndian; withUnsafeBytes(of: &be) { out.append(contentsOf: $0[2...3]) }
        } else {
            out.append(UInt8(id))
        }
        let sz = data.count
        if sz < 0x7F {
            out.append(0x80 | UInt8(sz))
        } else if sz < 0x3FFF {
            out.append(0x40 | UInt8(sz >> 8))
            out.append(UInt8(sz & 0xFF))
        } else {
            out.append(0x20 | UInt8(sz >> 16))
            out.append(UInt8((sz >> 8) & 0xFF))
            out.append(UInt8(sz & 0xFF))
        }
        out.append(data)
        return out
    }
    
    private static func ebmlUint(id: UInt32, val: UInt64, bytes: Int) -> Data {
        var be = val.bigEndian
        let raw = withUnsafeBytes(of: &be) { Data($0[(8 - bytes)..<8]) }
        return ebmlBox(id: id, data: raw)
    }
    
    private static func ebmlString(id: UInt32, str: String) -> Data {
        ebmlBox(id: id, data: Data(str.utf8))
    }
    
    private static func ebmlFloat32(id: UInt32, val: Float) -> Data {
        var be = val.bitPattern.bigEndian
        let raw = withUnsafeBytes(of: &be) { Data($0) }
        return ebmlBox(id: id, data: raw)
    }
}

// MARK: - Layer 2: Headless UI Hierarchy Inspector

@MainActor
final class UIHierarchyInspector {
    let window: NSWindow
    let hostingView: NSHostingView<AnyView>
    
    init<V: View>(rootView: V, size: CGSize = CGSize(width: 800, height: 600)) {
        self.window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.hostingView = NSHostingView(rootView: AnyView(rootView))
        self.hostingView.frame = NSRect(origin: .zero, size: size)
        self.window.contentView = hostingView
        self.hostingView.layoutSubtreeIfNeeded()
    }
    
    func allSubviews() -> [NSView] {
        var result: [NSView] = []
        func collect(from v: NSView) {
            result.append(v)
            for sub in v.subviews { collect(from: sub) }
        }
        collect(from: hostingView)
        return result
    }
    
    func assertNoOccludingModalCard() {
        for v in allSubviews() {
            let className = NSStringFromClass(type(of: v))
            XCTAssertFalse(className.contains("ErrorPresentationSheet"), "Unexpected error sheet: \(className)")
            XCTAssertFalse(className.contains("NSAlert"), "Unexpected alert modal: \(className)")
        }
    }
}

// MARK: - Integration Test Suite

final class RealMediaPlaybackIntegrationTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("RealMediaTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL { try? FileManager.default.removeItem(at: url) }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Real H.264 MP4 Synthesis & AVAsset Verification
    func testMediaFixtureSynthesizerGeneratesValidH264MP4() async throws {
        let videoURL = tempDirURL.appendingPathComponent("fixture_test.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 1.0, fps: 30)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path))
        let attr = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        let fileSize = (attr[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(fileSize, 500, "Synthesized MP4 should have non-trivial binary size")
        
        let asset = AVURLAsset(url: videoURL)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable, "Synthesized MP4 must be playable by AVFoundation")
        
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertEqual(seconds, 1.0, accuracy: 0.1, "Duration should match 1.0s")
        
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "Should have exactly 1 video track")
    }
    
    // MARK: - Test 2: Valid EBML MKV Generation & Demux Verification
    func testMediaFixtureSynthesizerGeneratesValidEBMLMKV() throws {
        let mkvData = MediaFixtureSynthesizer.createSyntheticEBMLMKV(title: "Integration MKV", durationMs: 1500)
        let mkvURL = tempDirURL.appendingPathComponent("fixture_test.mkv")
        try mkvData.write(to: mkvURL)
        
        let summary = try demuxMediaTracks(data: mkvData)
        XCTAssertEqual(summary.containerFormat, "matroska")
        XCTAssertEqual(summary.title, "Integration MKV")
        XCTAssertEqual(summary.durationMs, 1500)
        XCTAssertEqual(summary.tracks.count, 2)
        
        let videoTrack = summary.tracks.first(where: { $0.trackType == .video })
        XCTAssertNotNil(videoTrack)
        XCTAssertEqual(videoTrack?.width, 1920)
        XCTAssertEqual(videoTrack?.height, 1080)
        XCTAssertEqual(videoTrack?.codec, "V_MPEG4/ISO/AVC")
        
        let audioTrack = summary.tracks.first(where: { $0.trackType == .audio })
        XCTAssertNotNil(audioTrack)
        XCTAssertEqual(audioTrack?.channels, 2)
        XCTAssertEqual(audioTrack?.sampleRate, 44100)
    }
    
    // MARK: - Test 3: UI Hierarchy Headless Window Mount & Zero-Occlusion Assertion
    @MainActor
    func testUIHierarchyInspectorMountsMediaPreviewWithoutOcclusion() throws {
        let videoURL = tempDirURL.appendingPathComponent("ui_fixture.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 1.0)
        
        let mediaView = MediaPreviewView(fileURL: videoURL, fileName: "ui_fixture.mp4")
        let inspector = UIHierarchyInspector(rootView: mediaView, size: CGSize(width: 800, height: 600))
        
        let views = inspector.allSubviews()
        XCTAssertFalse(views.isEmpty, "View hierarchy should contain mounted subviews")
        inspector.assertNoOccludingModalCard()
        XCTAssertEqual(inspector.hostingView.frame.size.width, 800.0)
        XCTAssertEqual(inspector.hostingView.frame.size.height, 600.0)
    }
    
    // MARK: - Test 4: AVPlayerItem ReadyToPlay State Machine Contract & Timeline Stepping
    @MainActor
    func testRealAVPlayerItemReadyToPlayAndTimelineProgressionContract() async throws {
        let videoURL = tempDirURL.appendingPathComponent("playback_fixture.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 1.0, fps: 30)
        
        let item = AVPlayerItem(url: videoURL)
        let player = AVPlayer(playerItem: item)
        
        player.play()
        XCTAssertTrue(player.rate > 0 || player.timeControlStatus != .paused, "Player rate or timeControlStatus should reflect active playback")
        
        await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
        let curr = CMTimeGetSeconds(player.currentTime())
        XCTAssertEqual(curr, 0.5, accuracy: 0.05)
        
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
    
    // MARK: - Test 5: SharedVideoPlayerStore End-to-End Real Media State Contract
    @MainActor
    func testSharedVideoPlayerStoreEndToEndIntegrationWithRealMedia() async throws {
        let videoURL = tempDirURL.appendingPathComponent("store_fixture.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 1.0, fps: 30)
        
        let store = SharedVideoPlayerStore()
        store.setup(url: videoURL)
        
        XCTAssertNotNil(store.player)
        XCTAssertEqual(store.currentURL, videoURL)
        XCTAssertFalse(store.hasPlaybackError)
        XCTAssertFalse(store.hasDecoderLimitation)
        
        store.togglePlayPause()
        XCTAssertTrue(store.isPlaying)
        
        store.seek(to: 0.6)
        XCTAssertEqual(store.currentTime, 0.6, accuracy: 0.01)
        
        store.togglePlayPause()
        XCTAssertFalse(store.isPlaying)
        
        store.cleanUp()
        XCTAssertNil(store.currentURL)
        XCTAssertFalse(store.isPlaying)
    }
}
