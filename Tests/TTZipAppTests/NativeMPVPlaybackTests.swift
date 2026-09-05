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
import TTZipUI
@testable import TTZipPreviewKit
import TTZipBenchmarkKit
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
    
    // MARK: - Test 1: Unified Video and Camera Formats Factory Routing
    
    @MainActor
    func testAllSixteenVideoExtensionsFactoryRouting() async throws {
        let videoFormats = [
            "mkv", "mp4", "webm", "avi", "flv", "ts", "wmv", "vob",
            "rmvb", "ogv", "3gp", "m2ts", "mov", "m4v", "f4v", "asf",
            "mts", "mxf"
        ]
        
        for ext in videoFormats {
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
        
        // 5. Professional RAW images and playlist support
        for raw in ["arw", "cr3", "nef", "dng"] {
            XCTAssertTrue(MediaPreviewFactory.imageExtensions.contains(raw))
        }
        for pro in ["mts", "m2ts", "mxf"] {
            XCTAssertTrue(MediaPlaylistStore.supportedExtensions.contains(pro))
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
    func testCompanionSubtitleDiscovery() async throws {
        let videoURL = tempDirURL.appendingPathComponent("episode_01.mkv")
        try Data("video stream".utf8).write(to: videoURL)
        
        let srtURL = tempDirURL.appendingPathComponent("episode_01.en.srt")
        try Data("1\n00:00:01,000 --> 00:00:04,000\nHello World\n".utf8).write(to: srtURL)
        
        let assURL = tempDirURL.appendingPathComponent("episode_01.ja.ass")
        try Data("[Script Info]\nTitle: Japanese\n".utf8).write(to: assURL)
        
        let store = MPVMetalPlayerStore()
        store.setup(url: videoURL)
        
        for _ in 0..<25 {
            if store.subtitleTracks.count >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        
        XCTAssertGreaterThanOrEqual(store.subtitleTracks.count, 2, "Should discover at least 2 external subtitle files")
        let formats = store.subtitleTracks.map { $0.format }
        XCTAssertTrue(formats.contains("SRT"), "Should discover SRT subtitle")
        XCTAssertTrue(formats.contains("ASS"), "Should discover ASS subtitle")
        
        store.cleanUp()
    }
    
    // MARK: - Test 6: MediaPlaylistStore Directory Discovery & Navigation
    
    @MainActor
    func testMediaPlaylistStoreDiscoveryAndNavigation() throws {
        let ep1 = tempDirURL.appendingPathComponent("Show.S01E01.1080p.mkv")
        let ep2 = tempDirURL.appendingPathComponent("Show.S01E02.1080p.mkv")
        let ep10 = tempDirURL.appendingPathComponent("Show.S01E10.1080p.mkv")
        let txtDoc = tempDirURL.appendingPathComponent("notes.txt")
        
        try Data("ep1 data".utf8).write(to: ep1)
        try Data("ep2 data".utf8).write(to: ep2)
        try Data("ep10 data".utf8).write(to: ep10)
        try Data("notes".utf8).write(to: txtDoc)
        
        let playlistStore = MediaPlaylistStore()
        playlistStore.populateFromDirectory(for: ep1)
        
        XCTAssertEqual(playlistStore.items.count, 3, "Only 3 video files should be in the playlist (ignoring txt)")
        XCTAssertEqual(playlistStore.items[0].url.lastPathComponent, "Show.S01E01.1080p.mkv")
        XCTAssertEqual(playlistStore.items[1].url.lastPathComponent, "Show.S01E02.1080p.mkv")
        XCTAssertEqual(playlistStore.items[2].url.lastPathComponent, "Show.S01E10.1080p.mkv")
        
        XCTAssertEqual(playlistStore.currentIndex, 0)
        XCTAssertFalse(playlistStore.hasPrevious)
        XCTAssertTrue(playlistStore.hasNext)
        
        let nextItem = playlistStore.playNext()
        XCTAssertEqual(nextItem?.url.standardizedFileURL.path, ep2.standardizedFileURL.path)
        XCTAssertEqual(playlistStore.currentIndex, 1)
        XCTAssertTrue(playlistStore.hasPrevious)
        XCTAssertTrue(playlistStore.hasNext)
        
        let ep10Item = playlistStore.playNext()
        XCTAssertEqual(ep10Item?.url.standardizedFileURL.path, ep10.standardizedFileURL.path)
        XCTAssertEqual(playlistStore.currentIndex, 2)
        XCTAssertFalse(playlistStore.hasNext)
        XCTAssertTrue(playlistStore.hasPrevious)
        
        let prevItem = playlistStore.playPrevious()
        XCTAssertEqual(prevItem?.url.standardizedFileURL.path, ep2.standardizedFileURL.path)
        XCTAssertEqual(playlistStore.currentIndex, 1)
    }
    
    // MARK: - Test 7: MPVPlaylistDrawerView Mount & Selection Interaction
    
    @MainActor
    func testMPVPlaylistDrawerViewMountAndSelection() throws {
        let ep1 = tempDirURL.appendingPathComponent("ep01.mp4")
        let ep2 = tempDirURL.appendingPathComponent("ep02.mp4")
        try Data("ep1".utf8).write(to: ep1)
        try Data("ep2".utf8).write(to: ep2)
        
        let playlistStore = MediaPlaylistStore()
        playlistStore.setItems([
            MediaPlaylistItem(url: ep1, title: "Episode 1", fileSize: 1024 * 1024 * 50, isCurrent: true),
            MediaPlaylistItem(url: ep2, title: "Episode 2", fileSize: 1024 * 1024 * 60)
        ], activeIndex: 0)
        
        var selectedItem: MediaPlaylistItem? = nil
        var closed = false
        
        let drawerView = MPVPlaylistDrawerView(
            playlistStore: playlistStore,
            onSelectItem: { item in selectedItem = item },
            onClose: { closed = true }
        )
        
        let inspector = UIHierarchyInspector(rootView: drawerView, size: CGSize(width: 280, height: 400))
        XCTAssertFalse(inspector.allSubviews().isEmpty, "Playlist drawer must mount subviews")
        
        drawerView.onSelectItem(playlistStore.items[1])
        XCTAssertEqual(selectedItem?.url, ep2)
        
        drawerView.onClose()
        XCTAssertTrue(closed)
    }
    
    // MARK: - Test 8: MPVMetalNSView Layer Setup and Lifecycle Verification
    
    @MainActor
    func testMPVMetalNSViewLayerAndLifecycle() {
        let store = MPVMetalPlayerStore()
        let nsView = MPVMetalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        nsView.store = store
        
        XCTAssertTrue(nsView.wantsLayer, "MPVMetalNSView must set wantsLayer = true")
        XCTAssertNotNil(nsView.layer)
        XCTAssertTrue(nsView.layer is MPVOpenGLLayer, "Backing layer must be MPVOpenGLLayer")
        XCTAssertTrue(nsView.layer?.wantsExtendedDynamicRangeContent == true, "Layer must request EDR content")
        XCTAssertTrue(nsView.acceptsFirstResponder)
        
        var playPauseToggled = false
        var fullScreenToggled = false
        nsView.onTogglePlayPause = { playPauseToggled = true }
        nsView.onToggleFullScreen = { fullScreenToggled = true }
        
        nsView.onTogglePlayPause?()
        XCTAssertTrue(playPauseToggled)
        
        nsView.onToggleFullScreen?()
        XCTAssertTrue(fullScreenToggled)
        
        // Render Context Manager verification
        XCTAssertNotNil(store.renderContextManager)
        
        store.cleanUp()
    }
    
    // MARK: - Test 9: MPVOpenGLLayer Binding and Pixel Format Allocation
    
    @MainActor
    func testMPVOpenGLLayerPixelFormatAndBinding() {
        let store = MPVMetalPlayerStore()
        let layer = MPVOpenGLLayer()
        layer.bind(store: store)
        
        let pf = layer.copyCGLPixelFormat(forDisplayMask: 0)
        XCTAssertNotNil(pf, "copyCGLPixelFormat must allocate a valid CGLPixelFormatObj")
        
        let ctx = layer.copyCGLContext(forPixelFormat: pf)
        XCTAssertNotNil(ctx, "copyCGLContext must allocate a valid CGLContextObj")
        
        layer.unbind()
        store.cleanUp()
    }
    
    // MARK: - Test 10: Subtitle Deduplication Single Rasterization Path
    
    @MainActor
    func testSubtitleDeduplicationSingleRasterizationPath() throws {
        let videoURL = tempDirURL.appendingPathComponent("subtitle_test.mkv")
        try Data("mock mkv video stream".utf8).write(to: videoURL)
        
        let store = MPVMetalPlayerStore()
        store.setup(url: videoURL)
        store.activeSubtitleDialogue = "Hello world dialogue line"
        
        let playerView = MPVMetalVideoPlayerView(url: videoURL, store: store)
        let inspector = UIHierarchyInspector(rootView: playerView, size: CGSize(width: 800, height: 450))
        
        // Assert: No redundant SwiftUI NSTextField or text overlay with subtitle text
        let allSubviews = inspector.allSubviews()
        for view in allSubviews {
            if let tf = view as? NSTextField {
                XCTAssertNotEqual(tf.stringValue, "Hello world dialogue line", "SwiftUI text overlay bubble must NOT be rendered; libass handles subtitles exclusively")
            }
        }
        
        store.cleanUp()
    }
    
    // MARK: - Test 11: Full Screen Rendering Context Exclusivity & Seamless Recovery
    
    @MainActor
    func testFullScreenRenderingContextExclusivityAndPlaceholder() throws {
        let videoURL = tempDirURL.appendingPathComponent("exclusive_test.mp4")
        try Data("mock mp4 stream".utf8).write(to: videoURL)
        
        let store = MPVMetalPlayerStore()
        store.setup(url: videoURL)
        store.play()
        XCTAssertTrue(store.isPlaying, "Playback should be active initially")
        XCTAssertFalse(store.isFullScreen, "store.isFullScreen must default to false")
        
        // 1. Mount inline player in window
        let inlinePlayer = MPVMetalVideoPlayerView(url: videoURL, store: store, isFullScreen: false)
        let inlineInspector = UIHierarchyInspector(rootView: inlinePlayer, size: CGSize(width: 640, height: 360))
        
        let initialViews = inlineInspector.allSubviews()
        let initialGLViews = initialViews.compactMap { $0 as? MPVMetalNSView }
        XCTAssertFalse(initialGLViews.isEmpty, "Inline view must contain MPVMetalNSView when not fullscreen")
        
        // 2. Transition into full screen
        store.setFullScreen(true)
        inlineInspector.hostingView.layoutSubtreeIfNeeded()
        
        // 3. Verify single-layer in-place model retains MPVMetalNSView without unmounting
        let fsInlineViews = inlineInspector.allSubviews()
        let fsInlineGLViews = fsInlineViews.compactMap { $0 as? MPVMetalNSView }
        XCTAssertFalse(fsInlineGLViews.isEmpty, "Inline viewport must retain MPVMetalNSView during in-place full-screen expansion")
        
        // 4. Verify playback is NOT paused during full screen transition
        XCTAssertTrue(store.isPlaying, "Playback must continue playing during full-screen transition")
        
        // 5. Transition out of full screen back to inline
        store.setFullScreen(false)
        inlineInspector.hostingView.layoutSubtreeIfNeeded()
        
        // 6. Verify inline view remounted MPVMetalNSView
        let restoredViews = inlineInspector.allSubviews()
        let restoredGLViews = restoredViews.compactMap { $0 as? MPVMetalNSView }
        XCTAssertFalse(restoredGLViews.isEmpty, "Inline viewport must seamlessly remount MPVMetalNSView on exit from full screen")
        XCTAssertTrue(store.isPlaying, "Playback must remain continuous on return to inline view")
        
        store.cleanUp()
    }
    
    // MARK: - Test 12: Single-Layer In-Place Resizing & Context Defense
    
    @MainActor
    func testSingleLayerInPlaceResizingAndContextDefense() {
        let store = MPVMetalPlayerStore()
        let manager = store.renderContextManager
        
        let layer = MPVOpenGLLayer()
        layer.bind(store: store)
        
        let pf = layer.copyCGLPixelFormat(forDisplayMask: 0)
        let glCtx = layer.copyCGLContext(forPixelFormat: pf)
        
        // Mode 1: Inline mode (store.isFullScreen == false)
        store.setFullScreen(false)
        XCTAssertFalse(store.isFullScreen)
        
        // Single layer is allowed to draw in inline mode
        _ = layer.canDraw(inCGLContext: glCtx, pixelFormat: pf, forLayerTime: 0, displayTime: nil)
        XCTAssertTrue(layer.isBound)
        
        // Mode 2: In-place fullscreen expansion
        store.setFullScreen(true)
        XCTAssertTrue(store.isFullScreen)
        
        // Single layer seamlessly continues to draw in full screen mode without destruction
        _ = layer.canDraw(inCGLContext: glCtx, pixelFormat: pf, forLayerTime: 0, displayTime: nil)
        XCTAssertTrue(layer.isBound)
        
        layer.unbind()
        store.cleanUp()
    }
    
    // MARK: - Test 13: Render Context Manager UpdateHandler Ownership Protection
    
    @MainActor
    func testRenderContextManagerUpdateHandlerOwnershipProtection() {
        let manager = MPVRenderContextManager()
        let layerA = MPVOpenGLLayer()
        let layerB = MPVOpenGLLayer()
        
        final class CallTracker: @unchecked Sendable {
            var layerACalled = false
            var layerBCalled = false
        }
        let tracker = CallTracker()
        
        // Layer A registers
        manager.setUpdateHandler(owner: layerA) {
            tracker.layerACalled = true
        }
        
        // Layer B registers
        manager.setUpdateHandler(owner: layerB) {
            tracker.layerBCalled = true
        }
        
        // Layer A unbinds and attempts to clear handler
        manager.setUpdateHandler(owner: layerA, nil)
        
        // Layer B's handler must still be active and callable
        let store = MPVMetalPlayerStore()
        layerB.bind(store: store)
        store.renderContextManager.setUpdateHandler(owner: layerB) {
            tracker.layerBCalled = true
        }
        store.renderContextManager.setUpdateHandler(owner: layerA, nil)
        
        // Unbinding Layer B clears it properly
        store.renderContextManager.setUpdateHandler(owner: layerB, nil)
        
        layerA.unbind()
        layerB.unbind()
        store.cleanUp()
    }
    
    // MARK: - Test 14: Media Player FullScreen Notification and State Toggle
    
    @MainActor
    func testMediaPlayerFullScreenNotificationAndStateToggle() {
        let store = MPVMetalPlayerStore()
        XCTAssertFalse(store.isFullScreen)
        
        var notificationFired = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TTZipToggleMediaFocusNotification"),
            object: nil,
            queue: .main
        ) { _ in
            notificationFired = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
            object: nil
        )
        XCTAssertTrue(notificationFired, "TTZipToggleMediaFocusNotification must be broadcast on toggle")
        
        store.setFullScreen(true)
        XCTAssertTrue(store.isFullScreen)
        store.setFullScreen(false)
        XCTAssertFalse(store.isFullScreen)
        store.cleanUp()
    }
    
    // MARK: - Test 15: Inline Player URL Retention on Re-appearance
    
    @MainActor
    func testInlinePlayerURLRetentionOnReappearance() throws {
        let videoURL1 = tempDirURL.appendingPathComponent("video1.mp4")
        let videoURL2 = tempDirURL.appendingPathComponent("video2.mp4")
        try Data("v1".utf8).write(to: videoURL1)
        try Data("v2".utf8).write(to: videoURL2)
        
        let store = MPVMetalPlayerStore()
        store.setup(url: videoURL1)
        XCTAssertEqual(store.currentURL, videoURL1)
        
        // Simulate playlist switching in full screen mode to video2
        store.setFullScreen(true)
        store.load(url: videoURL2)
        XCTAssertEqual(store.currentURL, videoURL2)
        
        // Inline player view mounts with the current active track
        let playerView = MPVMetalVideoPlayerView(url: store.currentURL ?? videoURL1, store: store, isFullScreen: false)
        let inspector = UIHierarchyInspector(rootView: playerView, size: CGSize(width: 640, height: 360))
        
        // Exit full screen
        store.setFullScreen(false)
        inspector.hostingView.layoutSubtreeIfNeeded()
        
        // Verify that store.currentURL is NOT reverted back to videoURL1
        XCTAssertEqual(store.currentURL, videoURL2, "Inline view on re-appearance must preserve the active playlist track without reverting")
        
        store.cleanUp()
    }
    
    // MARK: - Test 16: Render Context Manager Context Activation & Restoration on Teardown
    
    @MainActor
    func testDetachAndFreeInternalRestoresAndFreesWithActiveCGLContext() {
        let manager = MPVRenderContextManager()
        let layer = MPVOpenGLLayer()
        let pf = layer.copyCGLPixelFormat(forDisplayMask: 0)
        _ = layer.copyCGLContext(forPixelFormat: pf)
        
        let previousContext = CGLGetCurrentContext()
        
        // Calling detachAndFree without initial context must cleanly no-op
        manager.detachAndFree()
        XCTAssertNil(manager.rawContext)
        XCTAssertNil(manager.activeContext)
        XCTAssertEqual(CGLGetCurrentContext(), previousContext, "CGL context must be restored to previous context after detachAndFree")
        
        // When active context is present, detachAndFree must set and restore
        let store = MPVMetalPlayerStore()
        layer.bind(store: store)
        store.renderContextManager.detachAndFree()
        XCTAssertNil(store.renderContextManager.activeContext)
        
        layer.unbind()
        store.cleanUp()
    }
    
    // MARK: - Test 17: Owner Protection on Update Handler Registration
    
    @MainActor
    func testInactiveLayerCannotHijackUpdateHandler() {
        let manager = MPVRenderContextManager()
        let layerA = MPVOpenGLLayer()
        let layerB = MPVOpenGLLayer()
        
        final class Tracker: @unchecked Sendable {
            var aTriggered = false
            var bTriggered = false
        }
        let tracker = Tracker()
        
        // Layer A registers -> Accepted
        manager.setUpdateHandler(owner: layerA) {
            tracker.aTriggered = true
        }
        XCTAssertEqual(manager.activeUpdateHandlerOwner, ObjectIdentifier(layerA))
        
        // Layer B registers -> Overwrites with new active owner
        manager.setUpdateHandler(owner: layerB) {
            tracker.bTriggered = true
        }
        XCTAssertEqual(manager.activeUpdateHandlerOwner, ObjectIdentifier(layerB))
        
        // Layer A unbinds -> Does NOT clear Layer B's active handler
        manager.setUpdateHandler(owner: layerA, nil)
        XCTAssertEqual(manager.activeUpdateHandlerOwner, ObjectIdentifier(layerB), "Inactive layer unbind must NOT clear active layer's handler")
        
        // Layer B unbinds -> Clears properly
        manager.setUpdateHandler(owner: layerB, nil)
        XCTAssertNil(manager.activeUpdateHandlerOwner)
    }
    
    // MARK: - Test 18: Rapid Repeated FullScreen Toggling Stress Loop
    
    @MainActor
    func testRapidRepeatedFullScreenTogglingStressLoop() throws {
        let videoURL = tempDirURL.appendingPathComponent("stress_toggle.mp4")
        try Data("dummy_stress".utf8).write(to: videoURL)
        
        let store = MPVMetalPlayerStore()
        store.setup(url: videoURL)
        store.play()
        XCTAssertTrue(store.isPlaying)
        
        let playerView = MPVMetalVideoPlayerView(url: videoURL, store: store, isFullScreen: false)
        let inspector = UIHierarchyInspector(rootView: playerView, size: CGSize(width: 640, height: 360))
        
        // Stress test: Rapidly toggle full screen 10 times in tight succession
        for cycle in 1...10 {
            store.setFullScreen(true)
            inspector.hostingView.layoutSubtreeIfNeeded()
            XCTAssertTrue(store.isFullScreen, "Cycle \(cycle): Store must be in fullscreen")
            
            store.setFullScreen(false)
            inspector.hostingView.layoutSubtreeIfNeeded()
            XCTAssertFalse(store.isFullScreen, "Cycle \(cycle): Store must be in inline mode")
            XCTAssertTrue(store.isPlaying, "Cycle \(cycle): Playback must remain continuous across toggles")
        }
        
        // Verify final UI state
        let finalViews = inspector.allSubviews()
        let finalGLViews = finalViews.compactMap { $0 as? MPVMetalNSView }
        XCTAssertFalse(finalGLViews.isEmpty, "Inline view must hold MPVMetalNSView after stress toggling loop")
        
        store.cleanUp()
    }
    
    // MARK: - Test 19: Double-Click Fullscreen Debounce Does Not Pause Playback
    
    @MainActor
    func testDoubleClickFullscreenDebounceDoesNotPausePlayback() {
        let nsView = MPVMetalNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        var playPauseCalled = false
        var fullScreenCalled = false
        
        nsView.onTogglePlayPause = { playPauseCalled = true }
        nsView.onToggleFullScreen = { fullScreenCalled = true }
        
        // Simulate click 1 of double click
        let click1 = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1.0
        )!
        nsView.mouseUp(with: click1)
        
        // Immediately simulate click 2 of double click
        let click2 = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 2, clickCount: 2, pressure: 1.0
        )!
        nsView.mouseUp(with: click2)
        
        XCTAssertTrue(fullScreenCalled, "Double click must trigger onToggleFullScreen")
        XCTAssertFalse(playPauseCalled, "Double click must cancel the scheduled play/pause toggle")
    }
    
    // MARK: - Test 20: MediaPlaybackCoordinator Dynamic Session Tracking & Relative Seek
    
    @MainActor
    func testMediaPlaybackCoordinatorDynamicSessionTrackingAndRelativeSeek() throws {
        let videoURL1 = tempDirURL.appendingPathComponent("track1.mp4")
        let videoURL2 = tempDirURL.appendingPathComponent("track2.mp4")
        try Data("t1".utf8).write(to: videoURL1)
        try Data("t2".utf8).write(to: videoURL2)
        
        let store = MPVMetalPlayerStore()
        store.setup(url: videoURL1)
        
        var relativeSeekDelta: Double = 0
        MediaPlaybackCoordinator.shared.registerSession(
            id: videoURL1.path,
            isPlaying: true,
            togglePlayPause: { store.togglePlayPause() },
            seekBy: { delta in relativeSeekDelta = delta }
        )
        
        XCTAssertTrue(MediaPlaybackCoordinator.shared.isMediaActive)
        
        // Trigger seek via coordinator
        MediaPlaybackCoordinator.shared.triggerSeek(by: 5.0)
        XCTAssertEqual(relativeSeekDelta, 5.0, "Coordinator seek must relay relative step")
        
        // Simulate switching to track 2
        store.load(url: videoURL2)
        MediaPlaybackCoordinator.shared.registerSession(
            id: videoURL2.path,
            isPlaying: true,
            togglePlayPause: { store.togglePlayPause() },
            seekBy: { delta in relativeSeekDelta = delta }
        )
        MediaPlaybackCoordinator.shared.updatePlaybackState(id: videoURL2.path, isPlaying: true)
        
        // Unregister track 1 must NOT deactivate the session of track 2
        MediaPlaybackCoordinator.shared.unregisterSession(id: videoURL1.path)
        XCTAssertTrue(MediaPlaybackCoordinator.shared.isMediaActive, "Unregistering stale track ID must not deactivate current track session")
        
        // Unregister track 2 must cleanly deactivate
        MediaPlaybackCoordinator.shared.unregisterSession(id: videoURL2.path)
        XCTAssertFalse(MediaPlaybackCoordinator.shared.isMediaActive, "Unregistering current track ID must cleanly deactivate session")
        
        store.cleanUp()
    }
}
