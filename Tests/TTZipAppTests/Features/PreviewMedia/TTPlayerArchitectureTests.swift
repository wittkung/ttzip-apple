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
    func testVideoTimelinePreviewAvoidsTrackAndStaysInsideViewport() {
        let size = CGSize(width: 156, height: 128)
        let viewport = CGSize(width: 400, height: 300)
        let top = VideoTimelinePreviewLayout.center(
            track: CGRect(x: 10, y: 10, width: 380, height: 28),
            pointerX: 0,
            preview: size,
            viewport: viewport
        )
        XCTAssertGreaterThan(top.y - 64, 38)
        XCTAssertGreaterThanOrEqual(top.x - 78, 8)

        let bottom = VideoTimelinePreviewLayout.center(
            track: CGRect(x: 10, y: 250, width: 380, height: 28),
            pointerX: 380,
            preview: size,
            viewport: viewport
        )
        XCTAssertLessThan(bottom.y + 64, 250)
        XCTAssertLessThanOrEqual(bottom.x + 78, 392)
    }

    @MainActor
    func testProductArchiveVideoAutoplaysAndReleasesBothPreviewLeases() async throws {
        let folder = try makeTemporaryDirectory(prefix: "ProductVideoRoute")
        let videoURL = folder.appendingPathComponent("immersive.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 5)
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: folder.appendingPathComponent("source.zip"),
            entryPath: videoURL.lastPathComponent,
            stagedReadURL: nil
        )
        var stagedURL: URL?
        let inspector = UIHierarchyInspector(rootView: MediaPreviewView(
            fileData: try Data(contentsOf: videoURL),
            fileName: videoURL.lastPathComponent,
            isImmersiveFullscreen: true,
            showsFloatingFullScreenButton: false,
            resourceContext: context,
            onPreviewTypeResolved: { stagedURL = $0.ephemeralMediaURL }
        ))
        defer { inspector.updateRootView(EmptyView()) }

        let player = try await waitForPlayingVideo(in: inspector)
        let staged = try XCTUnwrap(stagedURL)
        let session = try XCTUnwrap(VideoPlaybackSessionBridge.activeSessionHandle(for: staged))
        XCTAssertEqual(player.sessionID, session.sessionID)
        XCTAssertTrue(player.isPresenting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 2)

        inspector.updateRootView(EmptyView())
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    @MainActor
    func testProductVideoCanvasMenuKeepsWindowOwnershipAndDrivesPlayback() async throws {
        let folder = try makeTemporaryDirectory(prefix: "ProductVideoCanvasMenu")
        let videoURL = folder.appendingPathComponent("canvas-menu.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 10)
        let inspector = UIHierarchyInspector(rootView: MediaPreviewView(
            fileURL: videoURL,
            fileName: videoURL.lastPathComponent,
            isImmersiveFullscreen: true,
            showsFloatingFullScreenButton: false
        ))
        defer { inspector.updateRootView(EmptyView()) }

        let player = try await waitForPlayingVideo(in: inspector)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: inspector.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try XCTUnwrap(player.menu(for: event))
        let visibility = try XCTUnwrap(player.controlsVisibility)
        let rotationTitle = TTZipVideoInteractionLocalization.text(.rotationMenu)
        let resetTitle = TTZipVideoInteractionLocalization.text(.resetOrientation)
        let rotation = try XCTUnwrap(menu.item(withTitle: rotationTitle)?.submenu)

        XCTAssertTrue(TTMediaOwnedMenuRegistry.doesMenuBelongToWindow(menu, window: inspector.window))
        XCTAssertTrue(TTMediaOwnedMenuRegistry.doesMenuBelongToControls(
            menuID: ObjectIdentifier(rotation), controlsVisibility: visibility
        ))
        XCTAssertEqual(menu.item(withTitle: MediaLocalization.text(.fullscreen))?.keyEquivalent, "f")
        let summary = try XCTUnwrap(player.formatDetailsSummary)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(menu.item(withTitle: summary)?.isEnabled, false)
        XCTAssertEqual(rotation.item(withTitle: resetTitle)?.isEnabled, false)

        let rotateClockwise = try XCTUnwrap(rotation.item(withTitle: TTZipVideoInteractionLocalization.text(.rotateClockwise)))
        try invokeVideoMenuItem(rotateClockwise)
        try await waitForVideoMenuState(in: inspector) { player.userRotationDegrees == 90 }
        let rotatedMenu = try XCTUnwrap(player.menu(for: event))
        let reset = try XCTUnwrap(rotatedMenu.item(withTitle: rotationTitle)?.submenu?.item(withTitle: resetTitle))
        XCTAssertTrue(reset.isEnabled)
        try invokeVideoMenuItem(reset)
        try await waitForVideoMenuState(in: inspector) { player.userRotationDegrees == 0 }

        let pause = try XCTUnwrap(rotatedMenu.item(withTitle: MediaLocalization.text(.pause)))
        XCTAssertEqual(pause.keyEquivalent, " ")
        XCTAssertFalse(pause.target === player, "Expected TTZip to provide the menu action target")
        try invokeVideoMenuItem(pause)
        try await waitForVideoMenuState(in: inspector) { !player.isPlaying }
        let pausedMenu = try XCTUnwrap(player.menu(for: event))
        XCTAssertNotNil(pausedMenu.item(withTitle: MediaLocalization.text(.play)))
    }

    @MainActor
    func testProductVideoFullscreenMenuPinsArchiveMediaBeforeRequest() async throws {
        let folder = try makeTemporaryDirectory(prefix: "ProductVideoFullscreen")
        let videoURL = folder.appendingPathComponent("archive-video.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 5)
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: folder.appendingPathComponent("source.zip"),
            entryPath: videoURL.lastPathComponent,
            stagedReadURL: nil
        )
        var stagedURL: URL?
        let inspector = UIHierarchyInspector(rootView: MediaPreviewView(
            fileData: try Data(contentsOf: videoURL),
            fileName: videoURL.lastPathComponent,
            showsFloatingFullScreenButton: false,
            resourceContext: context,
            onPreviewTypeResolved: { stagedURL = $0.ephemeralMediaURL }
        ))
        defer {
            inspector.updateRootView(EmptyView())
            if let stagedURL { TTMediaDetector.endFullscreenEphemeralHandoff(for: stagedURL) }
        }

        try await waitForVideoMenuState(in: inspector) {
            stagedURL != nil && inspector.allSubviews().contains { $0 is AVSampleBufferPlayerNSView }
        }
        let player = try XCTUnwrap(inspector.allSubviews().compactMap { $0 as? AVSampleBufferPlayerNSView }.first)
        let staged = try XCTUnwrap(stagedURL)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: inspector.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try XCTUnwrap(player.menu(for: event))
        let fullscreen = try XCTUnwrap(menu.item(withTitle: MediaLocalization.text(.fullscreen)))
        XCTAssertEqual(fullscreen.keyEquivalent, "f")
        XCTAssertFalse(fullscreen.target === player, "Expected TTZip to provide the fullscreen action target")
        XCTAssertFalse(inspector.window.isVisible)

        let leaseCount = TTMediaDetector.activeEphemeralLeaseCount(for: staged)
        XCTAssertEqual(leaseCount, 2)
        let request = expectation(description: "TTZip receives the fullscreen URL with the handoff pinned")
        let center = NotificationCenter.default
        let observer = center.addObserver(forName: .ttZipVideoFullscreenRequested, object: nil, queue: nil) { notification in
            XCTAssertEqual(notification.object as? URL, staged)
            XCTAssertEqual(notification.userInfo?["url"] as? URL, staged)
            XCTAssertEqual(notification.userInfo?["name"] as? String, staged.lastPathComponent)
            XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), leaseCount + 1)
            request.fulfill()
        }
        defer { center.removeObserver(observer) }

        try invokeVideoMenuItem(fullscreen)
        await fulfillment(of: [request], timeout: 1)
        inspector.updateRootView(EmptyView())
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        let consumer = TTMediaEphemeralLeaseBox()
        consumer.bind(url: staged, consumeFullscreenHandoff: true)
        XCTAssertEqual(consumer.boundURL, staged)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 1)
        consumer.release()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    @MainActor
    func testNativeVideoWithoutHostPresentationKeepsCanvasTransportAndNoFullscreenPin() async throws {
        let folder = try makeTemporaryDirectory(prefix: "NativeVideoFullscreen")
        let videoURL = folder.appendingPathComponent("native-video.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 5)
        let preview = await TTMediaDetector.detectTypeFromMemoryAsync(
            data: try Data(contentsOf: videoURL),
            suggestedName: videoURL.lastPathComponent
        )
        let staged = try XCTUnwrap(preview.ephemeralMediaURL)
        let lease = TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: staged)
        let visibility = MediaControlsVisibility()
        visibility.acquireInteractionLock(id: "native-only-test")
        let inspector = UIHierarchyInspector(rootView:
            AVSampleBufferVideoPlayerView(url: staged, autoPlay: true)
                .environment(\.mediaControlsVisibility, visibility)
        )
        defer {
            inspector.updateRootView(EmptyView())
            visibility.tearDown()
            lease.release()
            TTMediaDetector.endFullscreenEphemeralHandoff(for: staged)
        }

        let player = try await waitForPlayingVideo(in: inspector)
        let sessionID = player.sessionID
        let canvasPoint = NSPoint(x: player.bounds.midX, y: player.bounds.minY + 12)
        XCTAssertTrue(visibility.isVisible)
        XCTAssertFalse(player.isControlBarVisible)
        XCTAssertFalse(inspector.allSubviews().contains { $0 is NSButton })
        XCTAssertFalse(player.shouldIgnoreCanvasClick(at: canvasPoint))
        XCTAssertFalse(inspector.window.isVisible)
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: player.convert(canvasPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: inspector.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertNil(player.menu(for: rightClick))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: player.convert(canvasPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: inspector.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        XCTAssertNotNil(player.onCanvasDoubleClick)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 1)
        player.mouseUp(with: event)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 1)

        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: inspector.window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
        player.keyDown(with: space)
        try await waitForVideoMenuState(in: inspector) { !player.isPlaying }
        XCTAssertEqual(player.sessionID, sessionID)

        inspector.updateRootView(EmptyView())
        lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    @MainActor
    func testProductVideoCanvasFeedbackAppearsAndDismisses() async throws {
        let folder = try makeTemporaryDirectory(prefix: "ProductVideoCanvasFeedback")
        let videoURL = folder.appendingPathComponent("canvas-feedback.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 10)
        let inspector = UIHierarchyInspector(rootView: MediaPreviewView(
            fileURL: videoURL,
            fileName: videoURL.lastPathComponent,
            isImmersiveFullscreen: true,
            showsFloatingFullScreenButton: false
        ))
        defer { inspector.updateRootView(EmptyView()) }

        let player = try await waitForPlayingVideo(in: inspector)
        let togglePlayback = try XCTUnwrap(player.onCanvasSingleClick)
        togglePlayback()
        try await waitForVideoMenuState(in: inspector) { !player.isPlaying }
        let baseline = try brightVideoCenterPixels(in: inspector.hostingView)

        let toggleMute = try XCTUnwrap(player.onMuteToggle)
        toggleMute()
        XCTAssertEqual(player.audioRenderer.volume, 0)
        try await waitForVideoFeedback(in: inspector, baseline: baseline, visible: true)
        try await waitForVideoFeedback(in: inspector, baseline: baseline, visible: false)

        let changeVolume = try XCTUnwrap(player.onVolumeChange)
        changeVolume(0.1)
        XCTAssertEqual(player.audioRenderer.volume, 0.1, accuracy: 0.001)
        try await waitForVideoFeedback(in: inspector, baseline: baseline, visible: true)
        try await waitForVideoFeedback(in: inspector, baseline: baseline, visible: false)

        changeVolume(0)
        try await waitForVideoFeedback(in: inspector, baseline: baseline, visible: true)
        inspector.updateRootView(EmptyView())
        XCTAssertTrue(inspector.allSubviews().allSatisfy { !($0 is AVSampleBufferPlayerNSView) })
        XCTAssertFalse(inspector.window.isVisible)
    }

    @MainActor
    func testProductVideoSubtitleNoticeAppearsAndExpires() async throws {
        let folder = try makeTemporaryDirectory(prefix: "ProductVideoSubtitleNotice")
        let videoURL = folder.appendingPathComponent("subtitle-notice.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 10)
        let visibility = MediaControlsVisibility()
        visibility.acquireInteractionLock(id: "subtitle-notice-test")
        let inspector = UIHierarchyInspector(rootView: MediaPreviewView(
            fileURL: videoURL,
            fileName: videoURL.lastPathComponent,
            isImmersiveFullscreen: true,
            showsFloatingFullScreenButton: false
        ).environment(\.mediaControlsVisibility, visibility))
        defer {
            inspector.updateRootView(EmptyView())
            visibility.tearDown()
        }

        let player = try await waitForPlayingVideo(in: inspector)
        try XCTUnwrap(player.onCanvasSingleClick)()
        try await waitForVideoMenuState(in: inspector) { !player.isPlaying }

        let baseline = try brightVideoNoticePixels(in: inspector.hostingView)
        let offItem = try XCTUnwrap(subtitleMenu(in: inspector)?.item(withTitle: MediaLocalization.text(.off)))
        try invokeVideoMenuItem(offItem)
        try await waitForSubtitleNotice(in: inspector, baseline: baseline, visible: true)
        try await waitForSubtitleNotice(in: inspector, baseline: baseline, visible: false)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(inspector.window.isVisible)
    }

    @MainActor
    private func waitForSubtitleNotice(
        in inspector: UIHierarchyInspector,
        baseline: Int,
        visible: Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            inspector.hostingView.layoutSubtreeIfNeeded()
            let brightPixels = try brightVideoNoticePixels(in: inspector.hostingView)
            if (brightPixels > baseline + 12) == visible { return }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < deadline
        XCTFail("Expected subtitle notice visibility to be \(visible), baseline \(baseline)")
    }

    @MainActor
    private func brightVideoNoticePixels(in host: NSView) throws -> Int {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let left = bitmap.pixelsWide - Int(280 * scale)
        let right = bitmap.pixelsWide - Int(12 * scale)
        var count = 0
        for x in stride(from: left, to: right, by: 2) {
            for y in stride(from: Int(55 * scale), to: Int(100 * scale), by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      min(color.redComponent, color.greenComponent, color.blueComponent) > 0.82 else {
                    continue
                }
                count += 1
            }
        }
        return count
    }

    @MainActor
    private func waitForVideoFeedback(
        in inspector: UIHierarchyInspector,
        baseline: Int,
        visible: Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            inspector.hostingView.layoutSubtreeIfNeeded()
            let brightPixels = try brightVideoCenterPixels(in: inspector.hostingView)
            if (brightPixels > baseline + 12) == visible { return }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        XCTFail("Expected center feedback visibility to be \(visible), baseline \(baseline)")
    }

    @MainActor
    private func brightVideoCenterPixels(in host: NSView) throws -> Int {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let centerX = bitmap.pixelsWide / 2
        let centerY = bitmap.pixelsHigh / 2
        let radius = Int(22 * CGFloat(bitmap.pixelsWide) / host.bounds.width)
        var count = 0
        for x in (centerX - radius)..<(centerX + radius) {
            for y in (centerY - radius)..<(centerY + radius) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      min(color.redComponent, color.greenComponent, color.blueComponent) > 0.82 else {
                    continue
                }
                count += 1
            }
        }
        return count
    }

    @MainActor
    private func invokeVideoMenuItem(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        let target = try XCTUnwrap(item.target)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: target, from: item))
    }

    @MainActor
    private func waitForVideoMenuState(
        in inspector: UIHierarchyInspector,
        matching: () -> Bool
    ) async throws {
        for _ in 0..<60 {
            inspector.hostingView.layoutSubtreeIfNeeded()
            if matching() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(matching(), "Expected the menu action to update the mounted video")
    }

    @MainActor
    func testVideoFailureRetryReopensRepairedFile() async throws {
        let folder = try makeTemporaryDirectory(prefix: "ProductVideoRetry")
        let videoURL = folder.appendingPathComponent("repair.mp4")
        let validVideo = folder.appendingPathComponent("valid.mp4")
        try Data("invalid MP4".utf8).write(to: videoURL)
        try MediaFixtureSynthesizer.createSyntheticMP4(at: validVideo, durationSeconds: 5)
        var failure: VideoPlaybackStatus?
        let preview = AVSampleBufferVideoPlayerView(url: videoURL, autoPlay: true, renderStatus: { status in
            if case .failed(let detail?, _) = status, !detail.isEmpty {
                return AnyView(TTZipVideoPlaybackStatusView(status: status).onAppear {
                    failure = status
                })
            }
            return AnyView(TTZipVideoPlaybackStatusView(status: status))
        })
        let inspector = UIHierarchyInspector(rootView: preview)
        defer { inspector.updateRootView(EmptyView()) }

        for _ in 0..<100 {
            inspector.hostingView.layoutSubtreeIfNeeded()
            if failure != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let status = try XCTUnwrap(failure, "Expected a mounted failure overlay for the corrupt file")
        guard case .failed(_, let retry) = status else {
            XCTFail("Expected the failure overlay to provide a retry action")
            return
        }
        let failedSession = try XCTUnwrap(VideoPlaybackSessionBridge.activeSessionHandle(for: videoURL))

        try Data(contentsOf: validVideo).write(to: videoURL, options: .atomic)
        retry()

        let player = try await waitForPlayingVideo(in: inspector)
        let recoveredSession = try XCTUnwrap(VideoPlaybackSessionBridge.activeSessionHandle(for: videoURL))
        XCTAssertNotEqual(recoveredSession.sessionID, failedSession.sessionID)
        XCTAssertEqual(player.sessionID, recoveredSession.sessionID)
        XCTAssertTrue(player.isPresenting)
    }

    @MainActor
    private func waitForPlayingVideo(in inspector: UIHierarchyInspector) async throws -> AVSampleBufferPlayerNSView {
        for _ in 0..<100 {
            inspector.hostingView.layoutSubtreeIfNeeded()
            if let player = inspector.allSubviews().compactMap({ $0 as? AVSampleBufferPlayerNSView }).first,
               player.isPlaying, CMTimeGetSeconds(player.currentTime) > 0 {
                return player
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(nil, "Expected the native viewport to mount and advance playback")
    }

    @MainActor
    func testVideoPreviewControlsContextDrivesRealPlayback() async throws {
        let folder = try makeTemporaryDirectory(prefix: "ProductVideoControls")
        let videoURL = folder.appendingPathComponent("controls.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: videoURL, durationSeconds: 5)
        let visibility = MediaControlsVisibility()
        visibility.acquireInteractionLock(id: "play-button-test")
        var latestContext: VideoPlaybackControlsContext?
        let preview = AVSampleBufferVideoPlayerView(url: videoURL)
            .environment(\.videoPlaybackControls) { context in
                AnyView(
                    TTZipVideoPlaybackControls(context: context)
                        .onChange(of: context.transport.duration, initial: true) { _, _ in
                            latestContext = context
                        }
                        .onChange(of: context.transport.isPlaying) { _, _ in
                            latestContext = context
                        }
                        .onChange(of: context.transport.currentTime) { _, _ in
                            latestContext = context
                        }
                        .onChange(of: context.viewportSize) { _, _ in
                            latestContext = context
                        }
                )
            }
            .environment(\.mediaControlsVisibility, visibility)
        let inspector = UIHierarchyInspector(rootView: preview, size: CGSize(width: 640, height: 400))
        defer {
            inspector.updateRootView(EmptyView())
            visibility.tearDown()
        }

        let ready = try await waitForVideoControls(in: inspector) {
            guard let context = latestContext,
                  CMTimeGetSeconds(context.transport.duration) > 0,
                  !context.transport.isPlaying,
                  context.viewportSize.width >= 380 else { return nil }
            return context
        }
        XCTAssertTrue(visibility.isVisible)
        try await verifyFormatBadgeInteraction(in: inspector, visibility: visibility)
        XCTAssertEqual(ready.videoURL, videoURL)
        verifyExportCapabilities(for: ready.videoURL)
        let subtitleButton = try XCTUnwrap(
            inspector.allSubviews().compactMap { $0 as? TTZipSubtitleTrackMenu.MenuButton }.first
        )
        let subtitleMenu = try XCTUnwrap(subtitleButton.trackMenu)
        XCTAssertEqual(subtitleMenu.item(withTitle: MediaLocalization.text(.off))?.state, .on)
        XCTAssertEqual(subtitleMenu.item(withTitle: MediaLocalization.text(.loadSubtitles))?.isEnabled, true)
        XCTAssertEqual(subtitleMenu.item(withTitle: MediaLocalization.text(.subtitleStyle))?.isEnabled, true)

        ready.send(.togglePlayPause)
        let playing = try await waitForVideoControls(in: inspector) {
            guard let context = latestContext,
                  context.transport.isPlaying,
                  CMTimeGetSeconds(context.transport.currentTime) > 0 else { return nil }
            return context
        }
        try await verifyFormatBadgeInteraction(in: inspector, visibility: visibility)
        let uninterrupted = try await waitForVideoControls(in: inspector) {
            guard let context = latestContext, context.transport.isPlaying,
                  context.transport.currentTime > playing.transport.currentTime else { return nil }
            return context
        }
        uninterrupted.send(.togglePlayPause)
        _ = try await waitForVideoControls(in: inspector) {
            guard let context = latestContext, !context.transport.isPlaying else { return nil }
            return context
        }

        inspector.window.setContentSize(CGSize(width: 320, height: 400))
        _ = try await waitForVideoControls(in: inspector) {
            guard let context = latestContext, context.viewportSize.width < 380 else { return nil }
            return context
        }
        XCTAssertTrue(visibility.isVisible)
        try await verifyFormatBadgeInteraction(in: inspector, visibility: visibility)
    }

    @MainActor
    func testVideoSubtitlePickerHandlesCancelSelectionFailureAndViewportClose() async throws {
        let folder = try makeTemporaryDirectory(prefix: "VideoSubtitlePicker")
        let video = folder.appendingPathComponent("video.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(at: video, durationSeconds: 10)
        let subtitles = folder.appendingPathComponent("subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: subtitles, withIntermediateDirectories: false)
        let valid = subtitles.appendingPathComponent("chosen.srt")
        try Data("1\n00:00:00,000 --> 00:00:08,000\nMounted subtitle\n\n".utf8).write(to: valid)
        let invalid = subtitles.appendingPathComponent("invalid.srt")
        try Data().write(to: invalid)

        let visibility = MediaControlsVisibility(inactivityDuration: .zero)
        var completion: VideoSubtitlePresentation.Selection?
        var failure: String?
        var dismissFailure: VideoSubtitlePresentation.DismissFailure?
        let presentation = VideoSubtitlePresentation { directory, extensions, complete in
            XCTAssertEqual(directory, folder)
            XCTAssertEqual(extensions, ["srt", "vtt", "ttml", "dfxp", "ass", "ssa"])
            completion = complete
        } attachFailureAlert: { viewport, message, dismiss in
            failure = message
            dismissFailure = dismiss
            return viewport
        }
        let preview = AVSampleBufferVideoPlayerView(url: video, autoPlay: true, subtitlePresentation: presentation)
            .environment(\.videoPlaybackControls) { AnyView(TTZipVideoPlaybackControls(context: $0)) }
            .environment(\.mediaControlsVisibility, visibility)
        let inspector = UIHierarchyInspector(rootView: preview, size: CGSize(width: 760, height: 400))
        defer { inspector.updateRootView(EmptyView()) }
        _ = try await waitForPlayingVideo(in: inspector)

        func requestFile() throws -> VideoSubtitlePresentation.Selection {
            completion = nil
            let load = try XCTUnwrap(subtitleMenu(in: inspector)?.item(withTitle: MediaLocalization.text(.loadSubtitles)))
            try invokeVideoMenuItem(load)
            XCTAssertTrue(visibility.hasActiveInteractionLock)
            return try XCTUnwrap(completion)
        }

        let cancel = try requestFile()
        cancel(nil)
        XCTAssertFalse(visibility.hasActiveInteractionLock)
        XCTAssertNil(failure)
        XCTAssertEqual(subtitleMenu(in: inspector)?.item(withTitle: MediaLocalization.text(.off))?.state, .on)

        let accept = try requestFile()
        cancel(valid)
        XCTAssertTrue(visibility.hasActiveInteractionLock)
        accept(valid)
        XCTAssertFalse(visibility.hasActiveInteractionLock)
        try await waitForVideoMenuState(in: inspector) {
            subtitleMenu(in: inspector)?.items.contains {
                $0.representedObject as? String == valid.absoluteString && $0.state == .on
            } == true
        }

        let reject = try requestFile()
        reject(invalid)
        try await waitForVideoMenuState(in: inspector) { failure?.isEmpty == false }
        XCTAssertFalse(visibility.hasActiveInteractionLock)
        XCTAssertFalse(visibility.isVisible)
        try XCTUnwrap(dismissFailure)()
        try await waitForVideoMenuState(in: inspector) { failure == nil }

        let afterClose = try requestFile()
        inspector.updateRootView(EmptyView())
        XCTAssertFalse(visibility.hasActiveInteractionLock)
        afterClose(invalid)
        XCTAssertNil(failure)
        XCTAssertFalse(inspector.window.isVisible)
    }

    @MainActor
    private func verifyExportCapabilities(for videoURL: URL) {
        XCTAssertNil(GIFExportManager.shared.compatibilityIssue(for: videoURL))
        XCTAssertNil(VideoLosslessTrimManager.shared.compatibilityIssue(for: videoURL))
        XCTAssertEqual(MediaContainerRemuxManager.shared.executionPath(for: videoURL), .isoBMFFPassthrough)
        XCTAssertEqual(
            MediaAudioExtractManager.shared.executionPath(for: videoURL, mode: .encapsulatedM4a),
            .avFoundationM4A
        )
    }

    @MainActor
    private func subtitleMenu(in inspector: UIHierarchyInspector) -> NSMenu? {
        inspector.allSubviews().compactMap { ($0 as? TTZipSubtitleTrackMenu.MenuButton)?.trackMenu }.first
    }

    @MainActor
    private func verifyFormatBadgeInteraction(
        in inspector: UIHierarchyInspector,
        visibility: MediaControlsVisibility
    ) async throws {
        let badge = try XCTUnwrap(
            inspector.allSubviews().compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "video_format_badge_button" }
        )
        XCTAssertEqual(badge.accessibilityLabel(), TTZipVideoInteractionLocalization.text(.formatDetails))
        XCTAssertFalse(badge.title.isEmpty)

        visibility.releaseInteractionLock(id: "play-button-test")
        defer { visibility.acquireInteractionLock(id: "play-button-test") }
        XCTAssertFalse(visibility.hasActiveInteractionLock)

        XCTAssertTrue(badge.accessibilityPerformPress())
        try await waitForPopoverLock(true, in: inspector, visibility: visibility)
        XCTAssertTrue(badge.accessibilityPerformPress())
        try await waitForPopoverLock(false, in: inspector, visibility: visibility)
    }

    @MainActor
    private func waitForPopoverLock(
        _ locked: Bool,
        in inspector: UIHierarchyInspector,
        visibility: MediaControlsVisibility
    ) async throws {
        for _ in 0..<20 {
            inspector.hostingView.layoutSubtreeIfNeeded()
            if visibility.hasActiveInteractionLock == locked { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Expected format details interaction lock to be \(locked)")
    }

    @MainActor
    private func waitForVideoControls(
        in inspector: UIHierarchyInspector,
        matching: () -> VideoPlaybackControlsContext?
    ) async throws -> VideoPlaybackControlsContext {
        for _ in 0..<60 {
            inspector.hostingView.layoutSubtreeIfNeeded()
            let views = inspector.allSubviews()
            let rendererMounted = views.contains { $0 is AVSampleBufferPlayerNSView }
            let subtitleButtonMounted = views.contains {
                ($0 as? TTZipSubtitleTrackMenu.MenuButton)?.accessibilityLabel() == MediaLocalization.text(.subtitles)
            }
            if rendererMounted, subtitleButtonMounted, let context = matching() { return context }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(nil, "Expected the real player and subtitle button to mount and report the requested playback state")
    }

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
}
