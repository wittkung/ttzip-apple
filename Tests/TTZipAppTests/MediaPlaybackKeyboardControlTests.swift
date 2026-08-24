// SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine for macOS.

import XCTest
import AppKit
import AVFoundation
@testable import TTZipCore
@testable import TTZipApp

final class MediaPlaybackKeyboardControlTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("MediaKeyTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Session Registration, Play/Pause Toggle & State Sync
    
    @MainActor
    func testMediaPlaybackCoordinatorPlayPauseToggle() throws {
        let coordinator = MediaPlaybackCoordinator.shared
        let testSessionID = "test_session_\(UUID().uuidString)"
        
        var playPauseCalled = false
        var lastSeekAmount: Double = 0
        
        coordinator.registerSession(
            id: testSessionID,
            isPlaying: false,
            togglePlayPause: {
                playPauseCalled = true
            },
            seekBy: { delta in
                lastSeekAmount = delta
            }
        )
        
        XCTAssertTrue(coordinator.isMediaActive, "Coordinator 应标记媒体会话处于活跃状态")
        XCTAssertFalse(coordinator.isPlaying, "初始播放状态应为 false")
        
        // 触发播放/暂停
        coordinator.triggerPlayPause()
        XCTAssertTrue(playPauseCalled, "触发后 playPauseHandler 闭包应被调用")
        
        // 更新播放状态
        coordinator.updatePlaybackState(id: testSessionID, isPlaying: true)
        XCTAssertTrue(coordinator.isPlaying, "Coordinator 播放状态应同步更新为 true")
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(), "媒体播放中 shouldInterceptMediaKeys 应返回 true")
        
        // 触发快进/快退
        coordinator.triggerSeek(by: -5.0)
        XCTAssertEqual(lastSeekAmount, -5.0, "快退 5 秒分发不正确")
        
        coordinator.triggerSeek(by: 5.0)
        XCTAssertEqual(lastSeekAmount, 5.0, "快进 5 秒分发不正确")
        
        coordinator.triggerSeek(by: 15.0)
        XCTAssertEqual(lastSeekAmount, 15.0, "Shift 步进 15 秒分发不正确")
        
        // 注销会话
        coordinator.unregisterSession(id: testSessionID)
        XCTAssertFalse(coordinator.isMediaActive, "注销后 isMediaActive 应恢复为 false")
        XCTAssertFalse(coordinator.isPlaying, "注销后 isPlaying 应重置为 false")
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(), "注销后 shouldInterceptMediaKeys 应返回 false")
    }
    
    // MARK: - Test 2: SharedVideoPlayerStore seekBy Bounds Clamping
    
    @MainActor
    func testSharedVideoPlayerStoreSeekByBoundsClamping() throws {
        let store = SharedVideoPlayerStore()
        let testMediaURL = tempDirURL.appendingPathComponent("sample_video.mp4")
        try Data("mock media binary stream".utf8).write(to: testMediaURL)
        
        store.setup(url: testMediaURL)
        store.duration = 100.0
        store.currentTime = 10.0
        
        // 1. 正常后退 5 秒 -> 5.0
        store.seekBy(-5.0)
        XCTAssertEqual(store.currentTime, 5.0, accuracy: 0.01, "后退 5 秒后当前时间应为 5.0")
        
        // 2. 超限后退 -> 截断至 0.0
        store.seekBy(-20.0)
        XCTAssertEqual(store.currentTime, 0.0, accuracy: 0.01, "过度后退应截断为 0.0")
        
        // 3. 正常前进 15 秒 -> 15.0
        store.seekBy(15.0)
        XCTAssertEqual(store.currentTime, 15.0, accuracy: 0.01, "前进 15 秒后当前时间应为 15.0")
        
        // 4. 超限前进 -> 截断至 duration (100.0)
        store.seekBy(200.0)
        XCTAssertEqual(store.currentTime, 100.0, accuracy: 0.01, "过度前进应截断为总时长 100.0")
        
        store.cleanUp()
    }
    
    // MARK: - Test 3: Hover & Focus State Interception Logic
    
    @MainActor
    func testHoverAndFocusStateInterception() throws {
        let coordinator = MediaPlaybackCoordinator.shared
        let sessionID = "hover_test_session_\(UUID().uuidString)"
        
        coordinator.registerSession(
            id: sessionID,
            isPlaying: false,
            togglePlayPause: {},
            seekBy: { _ in }
        )
        
        // 未播放且未悬停 -> 不拦截方向键（允许目录导航）
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(), "未播放且未悬停时应允许目录左右键导航")
        
        // 鼠标悬停在播放器上 -> 拦截方向键（允许快进快退）
        coordinator.setHovered(id: sessionID, isHovered: true)
        XCTAssertTrue(coordinator.isFocusedOrHovered)
        XCTAssertTrue(coordinator.shouldInterceptMediaKeys(), "鼠标悬停在播放器上时应拦截方向键以供快进快退")
        
        // 鼠标移出
        coordinator.setHovered(id: sessionID, isHovered: false)
        XCTAssertFalse(coordinator.shouldInterceptMediaKeys(), "鼠标移出且未播放时不应拦截方向键")
        
        coordinator.unregisterSession(id: sessionID)
    }
}
