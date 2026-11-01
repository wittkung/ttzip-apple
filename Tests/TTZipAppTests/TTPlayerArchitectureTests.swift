// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import CoreMedia
import AVFoundation
import TTMediaKit
@testable import TTZipApp
@testable import TTZipPreviewKit

final class TTPlayerArchitectureTests: XCTestCase {
    
    @MainActor
    func testTTPlayerModelsEnumCoverage() {
        XCTAssertEqual(VideoCodecType.allCases.count, 6)
        XCTAssertEqual(VideoCodecType.h264.rawValue, "avc1")
        XCTAssertEqual(VideoCodecType.hevc.rawValue, "hvc1")
        XCTAssertEqual(VideoCodecType.prores422.rawValue, "apcn")
        XCTAssertEqual(VideoCodecType.prores4444.rawValue, "ap4h")
        XCTAssertEqual(VideoCodecType.av1.rawValue, "av01")
        XCTAssertEqual(VideoCodecType.vp9.rawValue, "vp09")
        
        XCTAssertEqual(SleepAssertionMode.videoPlayback, .videoPlayback)
        XCTAssertEqual(SleepAssertionMode.audioPlayback, .audioPlayback)
        
        XCTAssertEqual(UnifiedVideoPlayerView.VideoPlayerEngine.avSampleBuffer, .avSampleBuffer)
    }
    
    @MainActor
    func testPlaybackHistoryStoreLifecycle() {
        let store = PlaybackHistoryStore.shared
        let dummyURL = URL(fileURLWithPath: "/tmp/sample_movie_2026.mkv")
        
        store.recordCheckpoint(url: dummyURL, currentTime: 50.0, duration: 100.0)
        let resumeInfo = store.queryResumeInfo(for: dummyURL)
        XCTAssertNotNil(resumeInfo)
        XCTAssertEqual(resumeInfo?.savedTime, 50.0)
        XCTAssertEqual(resumeInfo?.duration, 100.0)
        XCTAssertEqual(resumeInfo?.formattedTime, "00:50")
        XCTAssertEqual(resumeInfo?.progressFraction, 0.5)
        
        store.recordCheckpoint(url: dummyURL, currentTime: 97.0, duration: 100.0)
        XCTAssertNil(store.queryResumeInfo(for: dummyURL))
    }
    
    @MainActor
    func testSleepPreventerReentrancy() {
        let preventer = SleepPreventer.shared
        preventer.holdSleep()
        preventer.holdSleep()
        preventer.releaseSleep()
        preventer.releaseSleep()
        preventer.forceReset()
    }
    
    @MainActor
    func testAVSampleBufferPlayerCoordinatorLifecycle() {
        let coordinator = AVSampleBufferPlayerCoordinator()
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(coordinator.currentTime, .zero)
        XCTAssertEqual(coordinator.volume, 1.0)
        XCTAssertFalse(coordinator.isMuted)
        XCTAssertEqual(coordinator.displayLayer.videoGravity, .resizeAspect)
        
        coordinator.volume = 0.75
        XCTAssertEqual(coordinator.volume, 0.75)
        
        coordinator.playbackRate = 1.5
        XCTAssertEqual(coordinator.playbackRate, 1.5)
        
        coordinator.displayLayer.videoGravity = .resizeAspectFill
        XCTAssertEqual(coordinator.displayLayer.videoGravity, .resizeAspectFill)
        
        coordinator.isMuted = true
        XCTAssertTrue(coordinator.isMuted)
        
        coordinator.teardown()
    }
    
    @MainActor
    func testUnifiedVideoPlayerViewMounting() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample_video.mp4")
        let videoView = UnifiedVideoPlayerView(url: dummyURL, isFullScreen: false)
        let hostingView = NSHostingView(rootView: videoView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(hostingView.frame.size.width, 320)
        XCTAssertEqual(hostingView.frame.size.height, 200)
    }
}
