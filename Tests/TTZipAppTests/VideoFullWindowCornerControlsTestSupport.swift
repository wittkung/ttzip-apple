// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import os
import SwiftUI
import TTMediaKit
import TTZipCore
import XCTest
@testable import TTZipApp
@testable import TTZipPreviewKit

// MARK: - Deterministic Media Test Clock & Main Queue Advancement

final class DeterministicMediaTestClock: Sendable {
    private struct State {
        var currentInstant: ContinuousClock.Instant = ContinuousClock.now
        var cancelledIDs: Set<UUID> = []
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    deinit {
        cancelAll()
    }

    var now: MediaControlsVisibility.Now {
        { [self] in
            self.currentInstant()
        }
    }

    var wait: MediaControlsVisibility.Wait {
        { [self] duration in
            try await self.sleep(for: duration)
        }
    }

    func currentInstant() -> ContinuousClock.Instant {
        state.withLock { state in
            state.currentInstant
        }
    }

    func cancelAll() {
        let remaining = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            defer {
                state.waiters.removeAll()
                state.cancelledIDs.removeAll()
            }
            return Array(state.waiters.values)
        }
        for continuation in remaining {
            continuation.resume(throwing: CancellationError())
        }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        if duration <= .zero {
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let shouldCancel = state.withLock { state -> Bool in
                    if Task.isCancelled || state.cancelledIDs.remove(id) != nil {
                        return true
                    }
                    state.waiters[id] = continuation
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let removed = state.withLock { state -> CheckedContinuation<Void, Error>? in
                if let continuation = state.waiters.removeValue(forKey: id) {
                    return continuation
                }
                state.cancelledIDs.insert(id)
                return nil
            }
            removed?.resume(throwing: CancellationError())
        }
    }

    @MainActor
    func advance(by duration: Duration) async {
        for _ in 0..<3 {
            await advanceMediaTestMainQueue()
        }
        let waitersToResume = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            if duration > .zero {
                state.currentInstant = state.currentInstant.advanced(by: duration)
            }
            defer {
                state.waiters.removeAll()
            }
            return Array(state.waiters.values)
        }
        for continuation in waitersToResume {
            continuation.resume()
        }
        for _ in 0..<3 {
            await advanceMediaTestMainQueue()
        }
    }
}

@MainActor
func advanceMediaTestMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

// MARK: - Two-Window Fixture Context

@MainActor
struct TwoPlayerWindowsTestContext {
    let windowA: StandalonePlaybackNSWindow
    let windowB: StandalonePlaybackNSWindow
    let hostA: NSView
    let hostB: NSView
    let playerViewA: AVSampleBufferPlayerNSView
    let playerViewB: AVSampleBufferPlayerNSView
    let closeBtnA: VideoWindowCornerClusterNSButton
    let closeBtnB: VideoWindowCornerClusterNSButton
    let trafficA: StandalonePlaybackTrafficLightsController
    let trafficB: StandalonePlaybackTrafficLightsController
    let controlsA: MediaControlsVisibility
    let controlsB: MediaControlsVisibility
    let size: NSSize

    func tearDown() {
        windowA.contentView = nil
        windowB.contentView = nil
        windowA.close()
        windowB.close()
    }
}

// MARK: - Offscreen Video Window Fixture, Synthetic Pointer Driver & Pixel Sampling Support

extension VideoFullWindowCornerControlsOnDemandTests {
    func openOffscreenStandaloneVideoWindow(
        named name: String,
        origin: AppViewState?,
        clock: DeterministicMediaTestClock?
    ) async throws -> (url: URL, window: StandalonePlaybackNSWindow, host: NSView, size: NSSize) {
        let manager = StandalonePlaybackWindowManager.shared
        if let clock {
            manager.windowFactory = { session in
                StandalonePlaybackNSWindow.makeStandardPlayerWindow(
                    title: session.item.name,
                    now: clock.now,
                    wait: clock.wait
                )
            }
        } else {
            manager.windowFactory = nil
        }
        let videoURL = try makeTempVideoFile(named: name)
        let selected = origin.map { _ in DiskItemInfo(url: videoURL) }
        origin?.selectionState.select(selected)
        let opened = await manager.openOrFocus(
            item: ImmersiveMediaItem(url: videoURL, name: videoURL.lastPathComponent),
            originBrowserWindowID: origin?.windowID ?? UUID(),
            originSelectedItem: selected,
            createAppKitWindow: true
        )
        XCTAssertNotNil(opened)
        let window = try XCTUnwrap(manager.playerWindow)
        let size = NSSize(width: 880, height: 540)
        window.setContentSize(size)
        let host = try XCTUnwrap(window.contentView)
        host.frame = NSRect(origin: .zero, size: size)
        return (videoURL, window, host, size)
    }

    func makeTwoPlayerWindowsContext(
        videoURL: URL,
        clock: DeterministicMediaTestClock
    ) async throws -> TwoPlayerWindowsTestContext {
        let manager = StandalonePlaybackWindowManager.shared
        let controlsA = MediaControlsVisibility(now: clock.now, wait: clock.wait)
        let controlsB = MediaControlsVisibility(now: clock.now, wait: clock.wait)
        let windowA = StandalonePlaybackNSWindow.makeStandardPlayerWindow(
            title: "Window A",
            now: clock.now,
            wait: clock.wait
        )
        let windowB = StandalonePlaybackNSWindow.makeStandardPlayerWindow(
            title: "Window B",
            now: clock.now,
            wait: clock.wait
        )
        let size = NSSize(width: 820, height: 500)
        let item = ImmersiveMediaItem(url: videoURL, name: videoURL.lastPathComponent)
        let rootViewA = StandalonePlaybackWindowContentView(
            manager: manager,
            windowOverride: windowA,
            itemOverride: item,
            controlsOverride: controlsA
        ).frame(width: size.width, height: size.height)
        let rootViewB = StandalonePlaybackWindowContentView(
            manager: manager,
            windowOverride: windowB,
            itemOverride: item,
            controlsOverride: controlsB
        ).frame(width: size.width, height: size.height)

        let hostA = NSHostingView(rootView: rootViewA)
        let hostB = NSHostingView(rootView: rootViewB)
        hostA.sizingOptions = []
        hostB.sizingOptions = []

        windowA.contentView = hostA
        windowA.setContentSize(size)
        hostA.frame = NSRect(origin: .zero, size: size)
        let playerViewA = try await waitForPlayerView(in: hostA, window: windowA, requirePlaying: false)

        windowB.contentView = hostB
        windowB.setContentSize(size)
        hostB.frame = NSRect(origin: .zero, size: size)
        let playerViewB = try await waitForPlayerView(in: hostB, window: windowB, requirePlaying: false)

        let closeBtnA = try XCTUnwrap(
            findButton(id: "StandalonePlaybackCloseButton", in: hostA) as? VideoWindowCornerClusterNSButton
        )
        let closeBtnB = try XCTUnwrap(
            findButton(id: "StandalonePlaybackCloseButton", in: hostB) as? VideoWindowCornerClusterNSButton
        )
        let trafficA = try XCTUnwrap(windowA.trafficLightsController)
        let trafficB = try XCTUnwrap(windowB.trafficLightsController)

        return TwoPlayerWindowsTestContext(
            windowA: windowA,
            windowB: windowB,
            hostA: hostA,
            hostB: hostB,
            playerViewA: playerViewA,
            playerViewB: playerViewB,
            closeBtnA: closeBtnA,
            closeBtnB: closeBtnB,
            trafficA: trafficA,
            trafficB: trafficB,
            controlsA: controlsA,
            controlsB: controlsB,
            size: size
        )
    }

    func makeTempVideoFile(named name: String) throws -> URL {
        let fileName = "\(UUID().uuidString)-\(name)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try encodeTemplateVideoFile(at: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func encodeTemplateVideoFile(at url: URL) throws {
        let size = CGSize(width: 160, height: 120)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 1,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttributes
        )
        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoFullWindowCornerControlsOnDemandTests", code: -1)
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        appendSolidVideoFrames(writer: writer, input: input, adaptor: adaptor, size: size, frameCount: 12)
        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + .seconds(5)) == .success else {
            writer.cancelWriting()
            throw NSError(domain: "VideoFixtureTimeout", code: 1)
        }
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "VideoFixtureEncoding", code: 1)
        }
    }

    private func appendSolidVideoFrames(
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        size: CGSize,
        frameCount: Int
    ) {
        for frameIndex in 0..<frameCount {
            waitForWriterInputReady(input)
            guard let pixelBuffer = makeClearedPixelBuffer(size: size) else {
                continue
            }
            if input.isReadyForMoreMediaData && writer.status == .writing {
                let presentationTime = CMTime(value: Int64(frameIndex), timescale: 10)
                adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
            }
        }
    }

    private func waitForWriterInputReady(_ input: AVAssetWriterInput) {
        var spins = 0
        while !input.isReadyForMoreMediaData && spins < 50 {
            Thread.sleep(forTimeInterval: 0.002)
            spins += 1
        }
    }

    private func makeClearedPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let totalBytes = CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(size.height)
            memset(baseAddress, 0, totalBytes)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    func waitForPlayerView(
        in host: NSView,
        window: NSWindow,
        requirePlaying: Bool = true
    ) async throws -> AVSampleBufferPlayerNSView {
        await waitUntil(
            in: window,
            timeout: .seconds(3),
            description: "AVSampleBufferPlayerNSView ready"
        ) {
            guard let found = self.findView(ofType: AVSampleBufferPlayerNSView.self, in: host),
                  found.bounds.width > 0,
                  found.bounds.height > 0 else {
                return false
            }
            return !requirePlaying || found.isPlaying
        }
        return try XCTUnwrap(findView(ofType: AVSampleBufferPlayerNSView.self, in: host))
    }

    func flushWindowLayout(_ window: NSWindow) {
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.superview?.needsLayout = true
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func waitUntil(
        in window: NSWindow,
        timeout: Duration = .seconds(2),
        description: String,
        condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            flushWindowLayout(window)
            if condition() {
                return
            }
            await advanceMediaTestMainQueue()
        }
        flushWindowLayout(window)
        XCTAssertTrue(condition(), "Timed out waiting for observable condition: \(description)")
    }

    func findView<T: NSView>(
        ofType type: T.Type,
        in root: NSView,
        where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let matched = root as? T, predicate(matched) {
            return matched
        }
        for child in root.subviews {
            if let found = findView(ofType: type, in: child, where: predicate) {
                return found
            }
        }
        return nil
    }

    func findButton(id: String, in root: NSView) -> NSButton? {
        findView(ofType: NSButton.self, in: root) { button in
            button.accessibilityIdentifier() == id
        }
    }

    func findSensor(id: String, in root: NSView) -> VideoWindowCornerSensorNSView? {
        findView(ofType: VideoWindowCornerSensorNSView.self, in: root) { sensor in
            sensor.accessibilityIdentifier() == id
        }
    }

    func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow,
        clickCount: Int = 0
    ) throws -> NSEvent {
        let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: clickCount > 0 ? 1.0 : 0.0
        )
        return try XCTUnwrap(event)
    }

    /// Controlled synthetic pointer driver for offscreen `NSWindow` component tests.
    ///
    /// Measurement & Proof Boundary:
    /// - Headless/offscreen `NSWindow` instances do not receive live WindowServer `NSTrackingArea` callbacks.
    /// - This driver tracks per-view inside state (`sensor.isPointerInside`, `button.isPointerHovered`, and
    ///   `hoveredPlayerViewIDs` for `AVSampleBufferPlayerNSView`) so that `mouseEntered` is invoked strictly on
    ///   `outside -> inside` transitions, `mouseMoved` while `inside`, and `mouseExited` strictly on
    ///   `inside -> outside` transitions.
    /// - Subview exit transitions (`VideoWindowCornerSensorNSView` / `VideoWindowCornerClusterNSButton`) are
    ///   delivered before the destination `AVSampleBufferPlayerNSView` interior move because
    ///   `VideoWindowCornerSensorNSView.mouseExited` calls `super.mouseExited(with:)`, which forwards up the
    ///   AppKit `nextResponder` chain to `NSHostingView` and triggers SwiftUI `.onContinuousHover(.ended)`.
    func dispatchPointerMove(
        in root: NSView,
        window: NSWindow,
        locationInWindow: NSPoint
    ) throws {
        let event = try makeMouseEvent(type: .mouseMoved, location: locationInWindow, window: window)
        deliverCornerPointerTransitionsRecursively(
            in: root,
            event: event,
            locationInWindow: locationInWindow
        )
        if let player = findView(ofType: AVSampleBufferPlayerNSView.self, in: root) {
            deliverPlayerPointerTransition(
                to: player,
                event: event,
                locationInWindow: locationInWindow
            )
        }
    }

    private func deliverCornerPointerTransitionsRecursively(
        in view: NSView,
        event: NSEvent,
        locationInWindow: NSPoint
    ) {
        if let sensor = view as? VideoWindowCornerSensorNSView {
            deliverSensorPointerTransition(to: sensor, event: event, locationInWindow: locationInWindow)
        }
        if let button = view as? VideoWindowCornerClusterNSButton {
            deliverButtonPointerTransition(to: button, event: event, locationInWindow: locationInWindow)
        }
        for child in view.subviews {
            deliverCornerPointerTransitionsRecursively(
                in: child,
                event: event,
                locationInWindow: locationInWindow
            )
        }
    }

    private func deliverSensorPointerTransition(
        to sensor: VideoWindowCornerSensorNSView,
        event: NSEvent,
        locationInWindow: NSPoint
    ) {
        let localPoint = sensor.convert(locationInWindow, from: nil)
        let isNowInside = sensor.bounds.contains(localPoint)
        if isNowInside {
            if !sensor.isPointerInside {
                sensor.mouseEntered(with: event)
            } else {
                sensor.mouseMoved(with: event)
            }
        } else if sensor.isPointerInside {
            sensor.mouseExited(with: event)
        }
    }

    private func deliverButtonPointerTransition(
        to button: VideoWindowCornerClusterNSButton,
        event: NSEvent,
        locationInWindow: NSPoint
    ) {
        let localPoint = button.convert(locationInWindow, from: nil)
        let isNowInside = button.bounds.contains(localPoint)
        if isNowInside {
            if !button.isPointerHovered {
                button.mouseEntered(with: event)
            } else {
                button.mouseMoved(with: event)
            }
        } else if button.isPointerHovered {
            button.mouseExited(with: event)
        }
    }

    private func deliverPlayerPointerTransition(
        to player: AVSampleBufferPlayerNSView,
        event: NSEvent,
        locationInWindow: NSPoint
    ) {
        let playerID = ObjectIdentifier(player)
        let localPoint = player.convert(locationInWindow, from: nil)
        let isNowInside = player.bounds.contains(localPoint)
        let wasInside = hoveredPlayerViewIDs.contains(playerID)
        if isNowInside {
            if !wasInside {
                hoveredPlayerViewIDs.insert(playerID)
                player.mouseEntered(with: event)
            } else {
                player.mouseMoved(with: event)
            }
        } else if wasInside {
            hoveredPlayerViewIDs.remove(playerID)
            player.mouseExited(with: event)
        }
    }

    func dispatchClick(
        in root: NSView,
        window: NSWindow,
        locationInWindow: NSPoint,
        clickCount: Int
    ) throws {
        let hitPoint = root.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
        let targetView = try XCTUnwrap(root.hitTest(hitPoint))
        let downEvent = try makeMouseEvent(
            type: .leftMouseDown,
            location: locationInWindow,
            window: window,
            clickCount: clickCount
        )
        let upEvent = try makeMouseEvent(
            type: .leftMouseUp,
            location: locationInWindow,
            window: window,
            clickCount: clickCount
        )
        targetView.mouseDown(with: downEvent)
        targetView.mouseUp(with: upEvent)
    }

    func sampleContrastingPixels(
        in view: NSView,
        logicalSize: NSSize,
        bgPoint: NSPoint,
        region: NSRect
    ) throws -> Int {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let scaleX = CGFloat(rep.pixelsWide) / max(1.0, logicalSize.width)
        let scaleY = CGFloat(rep.pixelsHigh) / max(1.0, logicalSize.height)
        let bgX = min(max(0, Int((bgPoint.x * scaleX).rounded())), rep.pixelsWide - 1)
        let bgY = min(max(0, Int(((logicalSize.height - bgPoint.y) * scaleY).rounded())), rep.pixelsHigh - 1)
        let bgColor = try XCTUnwrap(rep.colorAt(x: bgX, y: bgY)?.usingColorSpace(.sRGB))

        let minX = max(0, Int((region.minX * scaleX).rounded(.down)))
        let maxX = min(rep.pixelsWide - 1, Int((region.maxX * scaleX).rounded(.up)))
        let minY = max(0, Int(((logicalSize.height - region.maxY) * scaleY).rounded(.down)))
        let maxY = min(rep.pixelsHigh - 1, Int(((logicalSize.height - region.minY) * scaleY).rounded(.up)))

        var contrastingCount = 0
        for py in minY...maxY {
            for px in minX...maxX {
                guard let pixelColor = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let redDelta = abs(pixelColor.redComponent - bgColor.redComponent)
                let greenDelta = abs(pixelColor.greenComponent - bgColor.greenComponent)
                let blueDelta = abs(pixelColor.blueComponent - bgColor.blueComponent)
                let totalDelta = redDelta + greenDelta + blueDelta
                if totalDelta > 0.12 {
                    contrastingCount += 1
                }
            }
        }
        return contrastingCount
    }

    func assertBothTopCornersHiddenAndHitTestPassThrough(
        window: StandalonePlaybackNSWindow,
        host: NSView,
        frameView: NSView,
        playerView: AVSampleBufferPlayerNSView,
        returnBtn: VideoWindowCornerClusterNSButton,
        closeBtn: VideoWindowCornerClusterNSButton,
        trafficController: StandalonePlaybackTrafficLightsController,
        size: NSSize,
        playState: Bool
    ) throws {
        XCTAssertFalse(trafficController.isTrafficLightsVisible)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let nativeBtn = try XCTUnwrap(window.standardWindowButton(kind))
            XCTAssertTrue(
                nativeBtn.isHidden,
                "Native \(kind) must be hidden in normal watching (isPlaying=\(playState))"
            )
            XCTAssertEqual(nativeBtn.alphaValue, 0.0, accuracy: 0.001)
        }
        let topLeftRegion = NSRect(x: 4, y: size.height - 42, width: 96, height: 38)
        let bgPt = NSPoint(x: 300, y: 260)
        let topLeftContrast = try sampleContrastingPixels(
            in: frameView,
            logicalSize: frameView.bounds.size,
            bgPoint: bgPt,
            region: topLeftRegion
        )
        XCTAssertEqual(topLeftContrast, 0)
        XCTAssertFalse(returnBtn.isChromeVisible)
        XCTAssertFalse(closeBtn.isChromeVisible)
        let topRightRegion = NSRect(x: size.width - 220, y: size.height - 56, width: 216, height: 52)
        let topRightContrast = try sampleContrastingPixels(
            in: host,
            logicalSize: size,
            bgPoint: bgPt,
            region: topRightRegion
        )
        XCTAssertEqual(topRightContrast, 0)
        let topLeftHit = try XCTUnwrap(frameView.hitTest(NSPoint(x: 20, y: size.height - 20)))
        XCTAssertTrue(topLeftHit === playerView || topLeftHit.isDescendant(of: playerView))
        for btn in [returnBtn, closeBtn] {
            let centerInWin = btn.convert(NSPoint(x: btn.bounds.midX, y: btn.bounds.midY), to: nil)
            let hitPt = host.superview?.convert(centerInWin, from: nil) ?? centerInWin
            let hitView = try XCTUnwrap(host.hitTest(hitPt))
            XCTAssertTrue(hitView === playerView || hitView.isDescendant(of: playerView))
        }
    }

    func assertMainBrowserWindowTrafficLightsRemainVisible() throws {
        let mainBrowserWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        mainBrowserWindow.isReleasedWhenClosed = false
        mainBrowserWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer {
            mainBrowserWindow.contentView = nil
            mainBrowserWindow.close()
        }
        WindowConfiguratorNSView.configure(window: mainBrowserWindow)
        WindowConfiguratorNSView.hoistTrafficLights(window: mainBrowserWindow)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let btn = try XCTUnwrap(mainBrowserWindow.standardWindowButton(kind))
            XCTAssertFalse(btn.isHidden)
            XCTAssertEqual(btn.alphaValue, 1.0, accuracy: 0.001)
        }
    }

    /// Controlled comparison of the reverse synthetic interleaving (`playerViewA.mouseMoved` before
    /// `sensor.mouseExited`): because `VideoWindowCornerSensorNSView.mouseExited` calls `super.mouseExited(with:)`,
    /// AppKit's responder chain forwards `mouseExited` up to `NSHostingView`, whose SwiftUI
    /// `.onContinuousHover(.ended)` handler sets `controlsA.isHovered = false`. While `freshMenuA` holds an active
    /// interaction lock, `controlsA.isVisible` stays `true`, and delivering the subsequent interior `mouseMoved`
    /// at the canvas cursor position restores `controlsA.isHovered == true` and the 3-second activity deadline.
    func assertReverseSyntheticHoverInterleavingMechanismAndRecovery(
        hostA: NSView,
        windowA: NSWindow,
        playerViewA: AVSampleBufferPlayerNSView,
        controlsA: MediaControlsVisibility
    ) throws {
        let sensorA = try XCTUnwrap(findSensor(id: "StandalonePlaybackTopRightControls.HoverSensor", in: hostA))
        let canvasEvent = try makeMouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: 300, y: 250),
            window: windowA
        )
        playerViewA.mouseMoved(with: canvasEvent)
        XCTAssertTrue(controlsA.isHovered)

        sensorA.mouseExited(with: canvasEvent)
        XCTAssertFalse(
            controlsA.isHovered,
            "VideoWindowCornerSensorNSView.mouseExited forwards super.mouseExited to NSHostingView (.onContinuousHover(.ended))"
        )
        XCTAssertTrue(
            controlsA.isVisible,
            "Active owned menu lock must keep bottom bar visible even if subview mouseExited forwarded to NSHostingView"
        )

        let recoveryEvent = try makeMouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: 304, y: 250),
            window: windowA
        )
        playerViewA.mouseMoved(with: recoveryEvent)
        XCTAssertTrue(controlsA.isHovered)
        XCTAssertTrue(controlsA.isVisible)
    }
}
