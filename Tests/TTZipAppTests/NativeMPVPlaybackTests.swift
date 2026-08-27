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
import Metal
import QuartzCore
@testable import TTZipCore
@testable import TTZipApp

final class NativeMPVPlaybackTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMPVTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: All 16 Video Extensions Unified Factory Routing
    
    @MainActor
    func testAllSixteenVideoExtensionsFactoryRouting() async throws {
        let sixteenFormats = [
            "mkv", "mp4", "webm", "avi", "flv", "ts", "wmv", "vob",
            "rmvb", "ogv", "3gp", "m2ts", "mov", "m4v", "f4v", "asf"
        ]
        
        for ext in sixteenFormats {
            let fileURL = tempDirURL.appendingPathComponent("video_sample.\(ext)")
            try Data("sample video stream payload".utf8).write(to: fileURL)
            
            // 1. Sync detection
            let syncType = MediaPreviewFactory.detectType(url: fileURL)
            switch syncType {
            case .video(let detectedURL):
                XCTAssertEqual(detectedURL, fileURL, "Format .\(ext) sync detection mismatch")
            default:
                XCTFail("Format .\(ext) must detect as .video, got: \(syncType)")
            }
            
            // 2. Async detection
            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: fileURL)
            switch asyncType {
            case .video(let detectedURL):
                XCTAssertEqual(detectedURL, fileURL, "Format .\(ext) async detection mismatch")
            default:
                XCTFail("Format .\(ext) must detect as .video asynchronously, got: \(asyncType)")
            }
            
            // 3. SF Symbol icon
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "clip.\(ext)"), "film.fill")
            
            // 4. Factory view generation
            let view = MediaPreviewFactory.makePreviewView(
                type: .video(fileURL),
                fileName: "video_sample.\(ext)",
                fileURL: fileURL
            )
            XCTAssertNotNil(view, "Factory makePreviewView must succeed for format .\(ext)")
        }
    }
    
    // MARK: - Test 2: MPVMetalPlayerStore State Machine Lifecycle
    
    @MainActor
    func testMPVMetalPlayerStoreLifecycleAndOperations() throws {
        let store = MPVMetalPlayerStore()
        let videoURL = tempDirURL.appendingPathComponent("test_movie.mp4")
        try Data("mock mp4 stream data".utf8).write(to: videoURL)
        
        // 1. Setup
        store.setup(url: videoURL)
        XCTAssertNotNil(store.player, "AVPlayer must be instantiated")
        XCTAssertEqual(store.currentURL, videoURL)
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(store.volume, 1.0)
        XCTAssertFalse(store.isMuted)
        
        // 2. Play / Pause / Play
        store.play()
        XCTAssertTrue(store.isPlaying)
        store.pause()
        XCTAssertFalse(store.isPlaying)
        store.togglePlayPause()
        XCTAssertTrue(store.isPlaying)
        store.togglePlayPause()
        XCTAssertFalse(store.isPlaying)
        
        // 3. Precise Seek & SeekBy
        store.seek(to: 42.5)
        XCTAssertEqual(store.currentTime, 42.5, accuracy: 0.001)
        store.seekBy(5.0)
        XCTAssertEqual(store.currentTime, 47.5, accuracy: 0.001)
        store.seekBy(-10.0)
        XCTAssertEqual(store.currentTime, 37.5, accuracy: 0.001)
        
        // 4. Volume & Mute
        store.setVolume(0.75)
        XCTAssertEqual(store.volume, 0.75, accuracy: 0.001)
        XCTAssertFalse(store.isMuted)
        store.toggleMute()
        XCTAssertTrue(store.isMuted)
        store.toggleMute()
        XCTAssertFalse(store.isMuted)
        
        // 5. Track and Subtitle Selections
        let audioTrack = MPVTrackItem(trackId: 1, title: "English Surround 5.1", language: "eng", codec: "eac3")
        store.audioTracks = [audioTrack]
        store.selectAudioTrack(audioTrack)
        XCTAssertEqual(store.selectedAudioTrackId, audioTrack.id)
        
        let subTrack = MPVSubtitleItem(title: "English SDH", language: "eng", format: "ASS")
        store.subtitleTracks = [subTrack]
        store.selectSubtitleTrack(subTrack)
        XCTAssertEqual(store.selectedSubtitleTrackId, subTrack.id)
        store.selectSubtitleTrack(nil)
        XCTAssertNil(store.selectedSubtitleTrackId)
        
        // 6. EDR Metrics
        store.updateEDRMetrics()
        XCTAssertGreaterThanOrEqual(store.edrMetrics.peakNits, 500.0)
        XCTAssertLessThanOrEqual(store.edrMetrics.peakNits, 1600.0)
        
        // 7. Cleanup
        store.cleanUp()
        XCTAssertNil(store.player)
        XCTAssertNil(store.currentURL)
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(store.currentTime, 0)
        XCTAssertEqual(store.audioTracks.count, 0)
        XCTAssertEqual(store.subtitleTracks.count, 0)
    }
    
    // MARK: - Test 3: CAMetalLayer EDR Configuration Verification
    
    @MainActor
    func testAVPlayerLayerContainerViewConfiguration() {
        let player = AVPlayer()
        let nsView = AVPlayerLayerContainerView.PlayerNSView()
        nsView.playerLayer.player = player
        
        XCTAssertTrue(nsView.wantsLayer)
        XCTAssertNotNil(nsView.playerLayer)
        XCTAssertEqual(nsView.playerLayer.videoGravity, AVLayerVideoGravity.resizeAspect)
        
        nsView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        nsView.layout()
        XCTAssertEqual(nsView.playerLayer.frame.size, CGSize(width: 640, height: 480))
    }

    
    // MARK: - Test 4: MPVVideoControlBarView & MPVMetalVideoPlayerView Viewport Mount
    
    @MainActor
    func testMPVMetalVideoPlayerViewHierarchyAndControlBar() throws {
        let videoURL = tempDirURL.appendingPathComponent("trailer.mkv")
        try Data("mock mkv header stream".utf8).write(to: videoURL)
        
        let playerView = MPVMetalVideoPlayerView(url: videoURL)
        let inspector = UIHierarchyInspector(rootView: playerView, size: CGSize(width: 960, height: 540))
        
        let subviews = inspector.allSubviews()
        XCTAssertFalse(subviews.isEmpty, "MPV Metal player view must mount subviews")
        inspector.assertNoOccludingModalCard()
        
        let store = MPVMetalPlayerStore()
        store.setup(url: videoURL)
        
        var fullScreenToggled = false
        var externalOpened = false
        
        let controlBar = MPVVideoControlBarView(
            store: store,
            onToggleFullScreen: { fullScreenToggled = true },
            onOpenExternal: { externalOpened = true }
        )
        
        let controlBarInspector = UIHierarchyInspector(rootView: controlBar, size: CGSize(width: 600, height: 60))
        XCTAssertFalse(controlBarInspector.allSubviews().isEmpty, "Control bar must mount subviews")
        
        controlBar.onToggleFullScreen()
        XCTAssertTrue(fullScreenToggled, "Full screen callback must be invoked")
        
        controlBar.onOpenExternal()
        XCTAssertTrue(externalOpened, "External player callback must be invoked")
        
        store.cleanUp()
    }
    
    // MARK: - Test 5: External Companion Subtitle Sniffing
    
    @MainActor
    func testCompanionSubtitleDiscovery() throws {
        let videoURL = tempDirURL.appendingPathComponent("episode_01.mkv")
        try Data("video stream".utf8).write(to: videoURL)
        
        let srtURL = tempDirURL.appendingPathComponent("episode_01.en.srt")
        try Data("1\n00:00:01,000 --> 00:00:04,000\nHello World\n".utf8).write(to: srtURL)
        
        let assURL = tempDirURL.appendingPathComponent("episode_01.ja.ass")
        try Data("[Script Info]\nTitle: Japanese\n".utf8).write(to: assURL)
        
        let store = MPVMetalPlayerStore()
        store.setup(url: videoURL)
        
        XCTAssertGreaterThanOrEqual(store.subtitleTracks.count, 2, "Should discover at least 2 external subtitle files")
        let formats = store.subtitleTracks.map { $0.format }
        XCTAssertTrue(formats.contains("SRT"), "Should discover SRT subtitle")
        XCTAssertTrue(formats.contains("ASS"), "Should discover ASS subtitle")
        
        store.cleanUp()
    }
}
