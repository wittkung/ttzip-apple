// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AVFoundation
@testable import TTZipCore
@testable import TTZipApp

final class VideoPlaybackZeroKickoutTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("VideoPlaybackZeroKickout_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: All Video Containers Route Directly to In-App Video Playback
    
    @MainActor
    func testAllVideoContainersRouteToInAppVideoPlayback() async throws {
        let testContainers = [
            "mkv", "webm", "ts", "m2ts", "mp4", "mov", "m4v",
            "avi", "flv", "wmv", "ogv", "3gp", "vob", "rmvb", "divx", "asf"
        ]
        
        for ext in testContainers {
            let videoURL = tempDirURL.appendingPathComponent("test_sample.\(ext)")
            try Data("mock media container stream data payload".utf8).write(to: videoURL)
            
            // 1. Synchronous detection
            let syncType = MediaPreviewFactory.detectType(url: videoURL)
            switch syncType {
            case .video(let detectedURL):
                XCTAssertEqual(detectedURL, videoURL, "Extension .\(ext) sync detection URL mismatch")
            default:
                XCTFail("Extension .\(ext) must synchronously detect as .video for zero-kickout, got: \(syncType)")
            }
            
            // 2. Asynchronous detection
            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: videoURL)
            switch asyncType {
            case .video(let detectedURL):
                XCTAssertEqual(detectedURL, videoURL, "Extension .\(ext) async detection URL mismatch")
            default:
                XCTFail("Extension .\(ext) must asynchronously detect as .video for zero-kickout, got: \(asyncType)")
            }
            
            // 3. Icon name
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "sample.\(ext)"), "film.fill")
        }
    }
    
    // MARK: - Test 2: SharedVideoPlayerStore Lifecycle and AVPlayer Setup
    
    @MainActor
    func testSharedVideoPlayerStoreLifecycle() throws {
        let store = SharedVideoPlayerStore()
        let mkvURL = tempDirURL.appendingPathComponent("movie_trailer.mkv")
        try Data("mock ebml mkv video stream".utf8).write(to: mkvURL)
        
        // 1. Setup
        store.setup(url: mkvURL)
        XCTAssertNotNil(store.player, "AVPlayer should be initialized")
        XCTAssertEqual(store.currentURL, mkvURL)
        XCTAssertFalse(store.isPlaying)
        
        // 2. Play / Pause toggle
        store.togglePlayPause()
        XCTAssertTrue(store.isPlaying)
        
        store.togglePlayPause()
        XCTAssertFalse(store.isPlaying)
        
        // 3. Seek
        store.seek(to: 15.0)
        XCTAssertEqual(store.currentTime, 15.0)
        
        store.seekBy(5.0)
        XCTAssertEqual(store.currentTime, 20.0)
        
        // 4. Teardown
        store.cleanUp()
        XCTAssertNil(store.player)
        XCTAssertNil(store.currentURL)
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(store.currentTime, 0)
        XCTAssertEqual(store.duration, 0)
    }
    
    // MARK: - Test 3: Zero-Kickout In-App View Hierarchy Instantiation
    
    @MainActor
    func testZeroKickoutInAppViewHierarchyInstantiation() {
        let webmURL = tempDirURL.appendingPathComponent("clip.webm")
        try? Data("mock webm content".utf8).write(to: webmURL)
        
        // 1. Factory makePreviewView for .video
        let viewFromVideo = MediaPreviewFactory.makePreviewView(
            type: .video(webmURL),
            fileName: "clip.webm",
            fileURL: webmURL
        )
        XCTAssertNotNil(viewFromVideo)
        
        // 2. Factory makePreviewView for legacy .unsupportedVideo fallback (routed to in-app player)
        let viewFromUnsupported = MediaPreviewFactory.makePreviewView(
            type: .unsupportedVideo(webmURL, "WEBM"),
            fileName: "clip.webm",
            fileURL: webmURL
        )
        XCTAssertNotNil(viewFromUnsupported)
        
        // 3. Direct UnifiedVideoPlayerView instantiation
        let playerView = UnifiedVideoPlayerView(url: webmURL)
        XCTAssertNotNil(playerView)
    }
}
