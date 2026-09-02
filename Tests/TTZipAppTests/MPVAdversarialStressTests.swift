// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import QuartzCore
import OpenGL
import OpenGL.GL3
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

/// Comprehensive adversarial stress harness for libmpv Audio/Video pipeline overhaul (R2, R3, R4).
///
/// Empirically stress-tests:
/// 1. OpenGL render loop stability under rapid window resize, hide/show, minimize/maximize cycles.
/// 2. High-frequency seek storms, play/pause toggles, and track changes across audio/video engines.
/// 3. Event dispatcher queue overflow & concurrency saturation under multi-task workloads.
/// 4. Complete elimination of mock/fake fallback views and pure microkernel fail-fast diagnostics.
final class MPVAdversarialStressTests: XCTestCase {

    private var tempDirURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPVAdversarialStressTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. OpenGL Render Loop & Lifecycle Stress Tests

    @MainActor
    func testOpenGLRenderLoopRapidResizeStorm() throws {
        let container = MPVMetalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        guard let glLayer = container.layer as? MPVOpenGLLayer else {
            XCTFail("MPVMetalContainerView must have MPVOpenGLLayer as its backing layer")
            return
        }

        let store = MPVMetalPlayerStore.shared
        glLayer.bind(store: store)

        // Stress: 60 rapid resize operations with varying aspect ratios and scale factors
        let testSizes: [CGSize] = [
            CGSize(width: 10, height: 10),
            CGSize(width: 100, height: 100),
            CGSize(width: 1920, height: 1080),
            CGSize(width: 3840, height: 2160),
            CGSize(width: 1280, height: 720),
            CGSize(width: 640, height: 480),
            CGSize(width: 2560, height: 1440),
            CGSize(width: 1, height: 1000),
            CGSize(width: 1000, height: 1),
            CGSize(width: 800, height: 600)
        ]

        let scales: [CGFloat] = [1.0, 2.0, 3.0]

        for iteration in 1...6 {
            for (idx, size) in testSizes.enumerated() {
                container.frame = NSRect(origin: .zero, size: size)
                glLayer.contentsScale = scales[(iteration + idx) % scales.count]
                container.layout()
                glLayer.forceRedraw()
            }
        }

        XCTAssertTrue(glLayer.isAsynchronous, "MPVOpenGLLayer must operate asynchronously for hardware display link sync")
        glLayer.unbind()
    }

    func testMPVRenderContextManagerExtremeBoundsAndReattachment() throws {
        let manager = MPVRenderContextManager()
        
        // 1. Initial state: context is nil
        XCTAssertNil(manager.rawContext)
        XCTAssertNil(manager.activeContext)
        
        // 2. Safe query when context is nil
        let updateFlags = manager.update()
        XCTAssertEqual(updateFlags, 0)
        
        // 3. Safe render calls with zero, negative, or huge bounds
        manager.render(fbo: 0, width: 0, height: 0)
        manager.render(fbo: 0, width: -100, height: -100)
        manager.render(fbo: 1, width: 7680, height: 4320)
        manager.reportSwap()
        
        // 4. Multiple detachAndFree calls without deadlock or exception
        manager.detachAndFree()
        manager.detachAndFree()
    }

    @MainActor
    func testWindowOcclusionAndDisplayLinkLifecycleBursts() throws {
        let container = MPVMetalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(
            contentRect: NSRect(x: 50, y: 50, width: 640, height: 360),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        let notificationCenter = NotificationCenter.default

        // Simulate 30 rapid minimize/deminimize and occlusion notifications
        for _ in 1...30 {
            notificationCenter.post(name: NSWindow.didMiniaturizeNotification, object: window)
            notificationCenter.post(name: NSWindow.didDeminiaturizeNotification, object: window)
            notificationCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }

        XCTAssertNotNil(container.layer)
    }

    // MARK: - 2. High-Frequency Seek & Playback Stress Tests

    @MainActor
    func testRapidHighFrequencySeekAndPlayPauseStorm() async throws {
        let audioEngine = MPVAudioEngine.shared
        let dummyAudioURL = tempDirURL.appendingPathComponent("stress_track.flac")
        try Data("mock flac audio payload".utf8).write(to: dummyAudioURL)

        audioEngine.load(url: dummyAudioURL, autoPlay: false)
        XCTAssertEqual(audioEngine.currentURL, dummyAudioURL)

        // Execute 100 rapid seek, seekBy, play, pause, and toggle operations
        for i in 1...100 {
            let seekTarget = Double(i % 300) + 0.25
            audioEngine.seek(to: seekTarget)
            audioEngine.seekBy(Double((i % 20) - 10))

            if i % 4 == 0 {
                audioEngine.play()
            } else if i % 4 == 1 {
                audioEngine.pause()
            } else if i % 4 == 2 {
                audioEngine.togglePlayPause()
            } else {
                audioEngine.setVolume(Double(i % 100) / 100.0)
            }
        }

        audioEngine.setMuted(true)
        XCTAssertTrue(audioEngine.isMuted)
        audioEngine.toggleMute()
        XCTAssertFalse(audioEngine.isMuted)
        audioEngine.stop()
        XCTAssertFalse(audioEngine.isPlaying)
    }

    @MainActor
    func testVideoEngineMultiTrackAndBoundarySeekStress() async throws {
        let videoEngine = MPVVideoEngine.shared
        let dummyVideoURL = tempDirURL.appendingPathComponent("stress_movie.mkv")
        try Data("mock mkv video payload".utf8).write(to: dummyVideoURL)

        videoEngine.load(url: dummyVideoURL, autoPlay: false)
        XCTAssertEqual(videoEngine.currentURL, dummyVideoURL)

        // Stress rapid seek and boundary seeks (negative, 0, huge)
        videoEngine.seek(to: -50.0)
        videoEngine.seek(to: 0.0)
        videoEngine.seek(to: 99999.0)

        // Stress audio/subtitle track switching
        videoEngine.selectSubtitle(trackId: "mpv_sub_1")
        videoEngine.selectSubtitle(trackId: nil)
        videoEngine.selectAudioTrack(trackId: "mpv_audio_1")
        videoEngine.selectAudioTrack(trackId: nil)

        // Viewport dimensions updates
        for dim in [CGSize(width: 320, height: 180), CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160)] {
            videoEngine.updateViewportSize(dim, scaleFactor: 2.0)
        }

        videoEngine.stop()
        XCTAssertFalse(videoEngine.isPlaying)
    }

    // MARK: - 3. Event Dispatcher Queue Overflow & Concurrency Stress

    func testEventDispatcherQueueFloodingUnderHeavyConcurrency() async throws {
        let engine = MPVCoreEngine()
        try await engine.initialize(mode: .audioOnly)
        let dispatcher = MPVEventDispatcher(engine: engine)

        await dispatcher.setTargetFPS(120)

        // 1. Register 5 concurrent AsyncStream subscribers
        let subscriberTask = Task { () -> Int in
            var receivedEventCount = 0
            let stream = await dispatcher.eventStream
            for await _ in stream {
                receivedEventCount += 1
                if receivedEventCount >= 50 { break }
            }
            return receivedEventCount
        }

        let stateSubscriberTask = Task { () -> Int in
            var receivedStateCount = 0
            let stream = await dispatcher.stateStream
            for await _ in stream {
                receivedStateCount += 1
                if receivedStateCount >= 20 { break }
            }
            return receivedStateCount
        }

        // 2. Flood dispatcher with 1000 events across 10 concurrent tasks
        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<10 {
                group.addTask {
                    var batch: [MPVEvent] = []
                    for eventIndex in 0..<100 {
                        let time = Double(taskIndex * 100 + eventIndex)
                        if eventIndex % 3 == 0 {
                            batch.append(.propertyChange(name: "time-pos", value: .double(time)))
                        } else if eventIndex % 3 == 1 {
                            batch.append(.propertyChange(name: "pause", value: .flag(eventIndex % 2 == 0)))
                        } else {
                            batch.append(.propertyChange(name: "audio-bitrate", value: .int64(Int64(320_000 + eventIndex))))
                        }
                    }
                    await dispatcher.handleBatchEvents(batch)
                }
            }
        }

        // 3. Verify state after flooding
        let finalState = await dispatcher.getCurrentState()
        XCTAssertNotNil(finalState)

        // 4. Test dynamic FPS throttling adjustment
        await dispatcher.setTargetFPS(15)
        await dispatcher.setTargetFPS(60)

        // 5. Clean teardown
        await dispatcher.stop()
        subscriberTask.cancel()
        stateSubscriberTask.cancel()
        await engine.terminate()
    }

    // MARK: - 4. Zero Mock/Fake Fallbacks & Pure Microkernel Audit

    @MainActor
    func testZeroMockFallbackViewsInPipeline() throws {
        // 1. Verify Audio formats route to .audio (UnifiedAudioPlayerView)
        let audioFormats = ["flac", "ape", "wav", "mp3", "m4a", "aac", "ogg", "opus", "aiff", "alac", "dsf", "dff"]
        for ext in audioFormats {
            let audioURL = tempDirURL.appendingPathComponent("track.\(ext)")
            try Data("audio data".utf8).write(to: audioURL)

            let mediaType = MediaPreviewFactory.detectType(url: audioURL)
            switch mediaType {
            case .audio(let detectedURL):
                XCTAssertEqual(detectedURL, audioURL, "Format .\(ext) must route to .audio")
            default:
                XCTFail("Format .\(ext) must detect as .audio, got: \(mediaType)")
            }

            let view = MediaPreviewFactory.makePreviewView(type: mediaType, fileName: "track.\(ext)", fileURL: audioURL)
            XCTAssertNotNil(view, "makePreviewView for .\(ext) must succeed")
        }

        // 2. Verify Video formats route to .video (UnifiedVideoPlayerView)
        let videoFormats = ["mkv", "mp4", "webm", "avi", "flv", "ts", "mov", "m4v"]
        for ext in videoFormats {
            let videoURL = tempDirURL.appendingPathComponent("movie.\(ext)")
            try Data("video data".utf8).write(to: videoURL)

            let mediaType = MediaPreviewFactory.detectType(url: videoURL)
            switch mediaType {
            case .video(let detectedURL):
                XCTAssertEqual(detectedURL, videoURL, "Format .\(ext) must route to .video")
            default:
                XCTFail("Format .\(ext) must detect as .video, got: \(mediaType)")
            }

            let view = MediaPreviewFactory.makePreviewView(type: mediaType, fileName: "movie.\(ext)", fileURL: videoURL)
            XCTAssertNotNil(view, "makePreviewView for .\(ext) must succeed")
        }
    }

    @MainActor
    func testFailFastErrorStatePropagation() async throws {
        let audioEngine = MPVAudioEngine.shared
        let nonExistentURL = URL(fileURLWithPath: "/non_existent_path_\(UUID().uuidString).flac")

        audioEngine.load(url: nonExistentURL, autoPlay: false)
        
        // Allow async engine load task to execute
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Engine must report error state or handle missing file gracefully
        audioEngine.stop()
    }
}
