// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import TTZipApp
@testable import TTZipPreviewKit
import TTMediaKit
import TTZipCore

@MainActor
final class StandaloneWindowCloseAndInspectorGeometryTests: XCTestCase {
    func testPortraitPreviewUsesContentWidthWithoutHeightCap() {
        let url = URL(fileURLWithPath: "/tmp/portrait.mp4")
        let height = ExplorerItemInspectorView.computeAdaptivePreviewHeight(
            for: DiskItemInfo(url: url), previewURL: url, resolvedPreviewType: .video(url),
            parsedAspectRatio: 9.0 / 16.0, contentWidth: 540, availableHeight: 500
        )
        XCTAssertEqual(height, 960, accuracy: 0.001)
    }

    func testLandscapePreviewRemainsProportionalAboveOldHeightCap() {
        let url = URL(fileURLWithPath: "/tmp/landscape.mp4")
        let height = ExplorerItemInspectorView.computeAdaptivePreviewHeight(
            for: DiskItemInfo(url: url), previewURL: url, resolvedPreviewType: .video(url),
            parsedAspectRatio: 16.0 / 9.0, contentWidth: 720, availableHeight: 500
        )
        XCTAssertEqual(height, 405, accuracy: 0.001)
    }

    func testInvalidAspectRatioFallsBackToFiniteVideoGeometry() {
        let url = URL(fileURLWithPath: "/tmp/fallback.mp4")
        for ratio in [CGFloat.zero, -1, .nan, .infinity] {
            let height = ExplorerItemInspectorView.computeAdaptivePreviewHeight(
                for: DiskItemInfo(url: url), previewURL: url, resolvedPreviewType: .video(url),
                parsedAspectRatio: ratio, contentWidth: 320, availableHeight: 500
            )
            XCTAssertEqual(height, 180, accuracy: 0.001)
        }
    }

    func testNativeWindowCloseRestoresOnlyRegisteredOrigin() async throws {
        _ = NSApplication.shared
        let manager = StandalonePlaybackWindowManager.shared
        await manager.resetForTesting()
        let origin = AppViewState()
        let unrelated = AppViewState()
        BrowserWindowRegistry.shared.register(origin)
        BrowserWindowRegistry.shared.register(unrelated)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("close-\(UUID()).mp4")
        defer {
            BrowserWindowRegistry.shared.unregister(id: origin.windowID)
            BrowserWindowRegistry.shared.unregister(id: unrelated.windowID)
            try? FileManager.default.removeItem(at: url)
        }
        // The fixture exercises host routing, not successful media decoding.
        try Data([0, 0, 0, 8, 102, 116, 121, 112]).write(to: url)
        let selected = DiskItemInfo(url: url)
        origin.selectionState.select(selected)
        let opened = await manager.openOrFocus(
            item: ImmersiveMediaItem(url: url, name: url.lastPathComponent),
            originBrowserWindowID: origin.windowID, originSelectedItem: selected,
            createAppKitWindow: true
        )
        XCTAssertNotNil(opened)
        let window = try XCTUnwrap(manager.playerWindow)
        let restored = expectation(description: "Native close delegates to origin handoff")
        manager.onReturnToOriginPreview = { session in
            XCTAssertEqual(session.originBrowserWindowID, origin.windowID)
            restored.fulfill()
        }
        window.close()
        await fulfillment(of: [restored], timeout: 3)
        XCTAssertNil(manager.playerWindow)
        XCTAssertFalse(manager.hasActivePlaybackSession)
        XCTAssertEqual(origin.selectionState.selectedDiskItem?.path, url.path)
        XCTAssertNil(unrelated.selectionState.selectedDiskItem)
        XCTAssertTrue(origin.navigationState.isInspectorVisible)
        await manager.resetForTesting()
    }
}

extension StandalonePreviewWindowTests {
    func testCaptureImmersiveAndInspectorComparisonEvidence() async throws {
        let evidenceDir = URL(fileURLWithPath: "/tmp/ttzip-antigravity-preview-windows/d3-evidence")
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)

        let sample = try file("sample.txt")
        let sampleContent = """
        // Line 1: Content-First Full-Window Preview — Body occupies 100% stable viewport!
        // Line 2: MetastudyLine TTZip D3 Acceptance Verification (Liquid Glass Floating Tools)
        // Line 3: Showing/hiding [ Aa ⎘ ] or expanding popover never shifts line 1 or viewport height.
        struct ContentFirstPreviewContract {
            let viewportHeightIsInvariantAcrossAllStates = true
            let hasFullWidthTopHeaderBar = false
            let bottomRightControls = "[ Aa ⎘ ] [ ↙↗ ]"
            let readingBackgrounds = ["black", "white", "fluidTransparent"]
        }

        // Line 11: Glass surface wraps only the compact button cluster [ Aa ··· ⎘ ] and popover card.
        // Line 12: Document body extends right through the bottom-trailing zone behind the floating card.
        // Line 13: Metadata badges (Plain Text, UTF-8, byte/line counts, Read-Only) live inside the Aa popover.
        // Line 14: Theme (.black / .white / .fluidTransparent), Font Size (A- / A+), Line Numbers (#), Copy, Save.
        // Line 15: Esc closes an open popover first before returning to the origin preview on the next Esc.
        // Line 16: First-line position, scrollView.frame, and mid-scroll offset have 0.0pt jump across states.
        // Line 17: Native NSWindow uses .fullSizeContentView + titlebarAppearsTransparent + titleVisibility = .hidden.
        // Line 18: Standard window drag, resize, traffic lights, and Cmd+W close remain completely intact.
        // Line 19: Bottom-right floating cluster [ Aa ··· ⎘ ] [ ↙↗ ] sits over lines 15..22 without occluding line 1.
        // Line 20: Liquid glass is for more immersive content — never a full-width top bar pushing content down.
        """
        try Data(sampleContent.utf8).write(to: sample.url)

        let prefs = TTTextReadingPreferenceStore.shared
        let savedMode = prefs.mode
        defer { prefs.mode = savedMode }

        try await renderStandaloneThreeStateFullWindowPNGs(sample: sample, evidenceDir: evidenceDir)
        try await renderInspectorEvidenceGrid(sample: sample, sampleContent: sampleContent, evidenceDir: evidenceDir)
    }

    private func renderStandaloneThreeStateFullWindowPNGs(
        sample: ImmersiveMediaItem,
        evidenceDir: URL
    ) async throws {
        TTTextReadingPreferenceStore.shared.mode = .black
        let origin = UUID()
        let opened = await manager.open(item: sample, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(opened)

        let states: [(TTTextFloatingToolsPresentationState, String)] = [
            (.quietReading, "state1-quiet-reading-full-window.png"),
            (.controlsVisible, "state2-floating-controls-visible-full-window.png"),
            (.popoverExpanded, "state3-tool-popover-expanded-full-window.png")
        ]

        var baselineScrollHeight: CGFloat?
        for (state, fileName) in states {
            let window = try XCTUnwrap(
                manager.makeConfiguredWindowForActiveSession(
                    item: sample,
                    originWindowID: origin,
                    contentRect: NSRect(x: 120, y: 120, width: 880, height: 560),
                    floatingToolsStateOverride: state
                )
            )
            window.appearance = NSAppearance(named: .darkAqua)
            defer {
                window.delegate = nil
                window.contentView = nil
                window.close()
            }
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
            XCTAssertTrue(window.titlebarAppearsTransparent)
            XCTAssertEqual(window.titleVisibility, .hidden)
            XCTAssertFalse(window.isVisible, "Offscreen capture must never steal the user's active window")

            let contentView = try XCTUnwrap(window.contentView)
            for _ in 0..<10 {
                contentView.needsLayout = true
                contentView.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try? await Task.sleep(nanoseconds: 25_000_000)
            }

            let scrollRects = findScrollViewRects(in: contentView, relativeTo: contentView)
            let primaryScroll = try XCTUnwrap(scrollRects.max(by: { $0.height < $1.height }))
            if let expected = baselineScrollHeight {
                XCTAssertEqual(
                    primaryScroll.height,
                    expected,
                    accuracy: 0.1,
                    "Viewport height must remain 100% invariant in \(state.rawValue)"
                )
            } else {
                baselineScrollHeight = primaryScroll.height
            }

            let frameView = contentView.superview ?? contentView
            frameView.needsLayout = true
            frameView.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let outURL = evidenceDir.appendingPathComponent(fileName)
            try png.write(to: outURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        }
        await manager.close(item: sample, originWindowID: origin)
    }

    private func renderInspectorEvidenceGrid(
        sample: ImmersiveMediaItem,
        sampleContent: String,
        evidenceDir: URL
    ) async throws {
        let prefs = TTTextReadingPreferenceStore.shared
        for (mode, slug, scheme, appName) in [
            (TTTextReadingBackgroundMode.black, "black", ColorScheme.dark, NSAppearance.Name.darkAqua),
            (TTTextReadingBackgroundMode.white, "white", ColorScheme.light, NSAppearance.Name.aqua),
            (TTTextReadingBackgroundMode.fluidTransparent, "transparent", ColorScheme.dark, NSAppearance.Name.darkAqua)
        ] {
            prefs.mode = mode
            for (width, tag) in [(320.0, "standard"), (240.0, "narrow")] {
                let inspectorPreview = ZStack {
                    if mode == .fluidTransparent {
                        Color(nsColor: .init(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1.0))
                    }
                    MediaPreviewView(
                        previewType: .text(sampleContent),
                        fileName: "sample.txt",
                        fileURL: sample.url,
                        isImmersiveFullscreen: false,
                        showsFloatingFullScreenButton: true,
                        isEditable: true,
                        resourceContext: .diskFile(url: sample.url, fileName: "sample.txt", allowsEditing: true)
                    )
                }
                .environment(\.colorScheme, scheme)

                let inspectorPNG = try await renderOffscreenViewToPNG(
                    inspectorPreview,
                    size: NSSize(width: width, height: 380),
                    appearance: appName,
                    outputURL: evidenceDir.appendingPathComponent("inspector-\(slug)-\(tag).png")
                )
                XCTAssertTrue(FileManager.default.fileExists(atPath: inspectorPNG.path))
                if mode == .black && tag == "narrow" {
                    let expandedPNG = try await renderOffscreenViewToPNG(
                        inspectorPreview,
                        size: NSSize(width: width, height: 380),
                        appearance: appName,
                        clickButtonIDBeforeCapture: "CodeFloatingAaToolsButton",
                        outputURL: evidenceDir.appendingPathComponent("inspector-black-narrow-popover-expanded.png")
                    )
                    XCTAssertTrue(FileManager.default.fileExists(atPath: expandedPNG.path))
                }
            }
        }
    }

    private func renderOffscreenViewToPNG<V: View>(
        _ view: V,
        size: NSSize,
        appearance: NSAppearance.Name,
        clickButtonIDBeforeCapture: String? = nil,
        outputURL: URL
    ) async throws -> URL {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if let buttonID = clickButtonIDBeforeCapture {
            let btn = try XCTUnwrap(findButton(id: buttonID, in: host), "Missing button \(buttonID)")
            try clickVisibleButtonViaHitTest(btn, in: host, window: window)
            for _ in 0..<8 {
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputURL)
        return outputURL
    }

    internal func clickVisibleButtonViaHitTest(_ button: NSButton, in host: NSView, window: NSWindow) throws {
        try dispatchMouseSequence(on: button, in: host, window: window, releaseInside: true)
    }

    internal func dragOutCancelVisibleButtonViaHitTest(_ button: NSButton, in host: NSView, window: NSWindow) throws {
        try dispatchMouseSequence(on: button, in: host, window: window, releaseInside: false)
    }

    private func dispatchMouseSequence(on button: NSButton, in host: NSView, window: NSWindow, releaseInside: Bool) throws {
        XCTAssertFalse(button.isTransparent, "Visible production button must not be transparent")
        XCTAssertFalse(button.isHidden, "Visible production button must not be hidden")
        XCTAssertTrue(button.isEnabled, "Visible production button must be enabled")
        let centerInWindow = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let pointInHostSuperview = host.superview?.convert(centerInWindow, from: nil) ?? centerInWindow
        let hitView = try XCTUnwrap(
            host.hitTest(pointInHostSuperview),
            "Host hitTest at button center must resolve a real visible view"
        )
        XCTAssertTrue(
            hitView === button || hitView.isDescendant(of: button),
            "Host hitTest at \(centerInWindow) must resolve the visible NSButton itself, got \(type(of: hitView))"
        )
        let releasePoint = releaseInside
            ? centerInWindow
            : button.convert(NSPoint(x: button.bounds.minX - 60, y: button.bounds.minY - 60), to: nil)
        drainQueuedMouseTrackingEvents()
        let downEvent = try enqueueTrackingSequence(
            in: window,
            downPoint: centerInWindow,
            releasePoint: releasePoint,
            includeDrag: !releaseInside
        )
        let watchdog = makeTrackingWatchdog(windowNumber: window.windowNumber, releasePoint: releasePoint)
        defer {
            watchdog.cancel()
            drainQueuedMouseTrackingEvents()
        }
        button.mouseDown(with: downEvent)
    }

    private func drainQueuedMouseTrackingEvents() {
        while NSApplication.shared.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantPast,
            inMode: .eventTracking,
            dequeue: true
        ) != nil {}
    }

    private func enqueueTrackingSequence(
        in window: NSWindow,
        downPoint: NSPoint,
        releasePoint: NSPoint,
        includeDrag: Bool
    ) throws -> NSEvent {
        let now = ProcessInfo.processInfo.systemUptime
        let downEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: downPoint,
                modifierFlags: [],
                timestamp: now,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1.0
            )
        )
        if includeDrag {
            let dragEvent = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDragged,
                    location: releasePoint,
                    modifierFlags: [],
                    timestamp: now + 0.005,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 1.0
                )
            )
            NSApplication.shared.postEvent(dragEvent, atStart: false)
        }
        let upEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: releasePoint,
                modifierFlags: [],
                timestamp: now + 0.010,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0.0
            )
        )
        NSApplication.shared.postEvent(upEvent, atStart: false)
        return downEvent
    }

    private func makeTrackingWatchdog(windowNumber: Int, releasePoint: NSPoint) -> DispatchSourceTimer {
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + .milliseconds(250))
        watchdog.setEventHandler {
            if let fallbackUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: releasePoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0.0
            ) {
                NSApplication.shared.postEvent(fallbackUp, atStart: true)
            }
        }
        watchdog.resume()
        return watchdog
    }

    internal func sendLocalEscapeKey(windowNumber: Int) {
        guard let esc = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else { return }
        NSApplication.shared.sendEvent(esc)
    }

    internal func findButton(id: String, in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.accessibilityIdentifier() == id {
            return button
        }
        for child in root.subviews {
            if let found = findButton(id: id, in: child) {
                return found
            }
        }
        return nil
    }

    internal func findScrollViewRects(in root: NSView, relativeTo ancestor: NSView) -> [NSRect] {
        var result: [NSRect] = []
        if let scroll = root as? NSScrollView {
            result.append(ancestor.convert(scroll.bounds, from: scroll))
        }
        for child in root.subviews {
            result.append(contentsOf: findScrollViewRects(in: child, relativeTo: ancestor))
        }
        return result
    }

    internal func findStaticTextValues(in root: NSView) -> [String] {
        var result: [String] = []
        if let textField = root as? NSTextField, !textField.isEditable {
            result.append(textField.stringValue)
        }
        for child in root.subviews {
            result.append(contentsOf: findStaticTextValues(in: child))
        }
        return result
    }

    internal func findCornerHoverSensor(id: String, in root: NSView) -> PreviewCornerHoverSensorNSView? {
        if let sensor = root as? PreviewCornerHoverSensorNSView, sensor.accessibilityIdentifier() == id {
            return sensor
        }
        for child in root.subviews {
            if let found = findCornerHoverSensor(id: id, in: child) {
                return found
            }
        }
        return nil
    }

    internal func dispatchPointerMove(in root: NSView, window: NSWindow, locationInWindow: NSPoint) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: locationInWindow,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0.0
            )
        )
        deliverMouseMovedEvent(event, to: root)
    }

    private func deliverMouseMovedEvent(_ event: NSEvent, to view: NSView) {
        if view is PreviewCornerHoverSensorNSView || view is PreviewCornerActionNSButton {
            view.mouseMoved(with: event)
        }
        for child in view.subviews {
            deliverMouseMovedEvent(event, to: child)
        }
    }

    internal func settleOffscreenHost(_ host: NSView, cycles: Int = 4, delayNanoseconds: UInt64 = 15_000_000) async {
        for _ in 0..<cycles {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
    }

    internal func sampleCornerPixels(
        in host: NSView,
        logicalSize: NSSize,
        bgPoint: NSPoint,
        region: NSRect
    ) throws -> Int {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return countContrastingPixels(in: bitmap, logicalSize: logicalSize, bgPoint: bgPoint, region: region)
    }

    internal func assertCornerButtonHiddenThenRevealedBySensorHover(
        in host: NSView,
        window: NSWindow,
        logicalSize: NSSize,
        bgPoint: NSPoint,
        region: NSRect,
        label: String
    ) async throws {
        let idlePixels = try sampleCornerPixels(
            in: host, logicalSize: logicalSize, bgPoint: bgPoint, region: region
        )
        XCTAssertEqual(idlePixels, 0, "\(label) must be hidden by default when pointer is away")

        try dispatchPointerMove(
            in: host,
            window: window,
            locationInWindow: NSPoint(x: logicalSize.width * 0.5, y: logicalSize.height * 0.5)
        )
        await settleOffscreenHost(host, cycles: 3)
        let bodyHoverPixels = try sampleCornerPixels(
            in: host, logicalSize: logicalSize, bgPoint: bgPoint, region: region
        )
        XCTAssertEqual(
            bodyHoverPixels, 0,
            "\(label) must remain hidden when pointer moves inside preview body outside bottom-right sensor"
        )

        try dispatchPointerMove(
            in: host,
            window: window,
            locationInWindow: NSPoint(x: logicalSize.width - 26.0, y: 26.0)
        )
        await settleOffscreenHost(host, cycles: 4)
        let revealedPixels = try sampleCornerPixels(
            in: host, logicalSize: logicalSize, bgPoint: bgPoint, region: region
        )
        XCTAssertGreaterThan(
            revealedPixels, 15,
            "\(label) must visibly render after pointer enters bottom-right sensor zone"
        )

        try dispatchPointerMove(
            in: host,
            window: window,
            locationInWindow: NSPoint(x: logicalSize.width * 0.5, y: logicalSize.height * 0.5)
        )
    }

    func testPreviewCornerButtonsRevealOnDemandAcrossImageAndSharedFormats() async throws {
        try await verifyImagePreviewCornerButtonOnDemandLifecycle()
        try await verifySecondSharedFormatAndStandaloneReturnOnDemandLifecycle()
    }

    private func verifyImagePreviewCornerButtonOnDemandLifecycle() async throws {
        let imageURL = directory.appendingPathComponent("corner-sensor-sample.png")
        let img = NSImage(size: NSSize(width: 640, height: 520), flipped: false) { rect in
            NSColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0).setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let pngData = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try pngData.write(to: imageURL, options: .atomic)

        let preview = MediaPreviewView(
            previewType: .image(img),
            fileName: imageURL.lastPathComponent,
            fileURL: imageURL,
            isImmersiveFullscreen: false,
            showsFloatingFullScreenButton: true
        )
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let size = NSSize(width: 320, height: 260)
        let host = NSHostingView(rootView: preview.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        XCTAssertFalse(window.isVisible, "Offscreen test window must never steal foreground")
        await settleOffscreenHost(host, cycles: 6)

        let button = try XCTUnwrap(
            findButton(id: "PreviewStandaloneExpandButton", in: host) as? PreviewCornerActionNSButton
        )
        let sensor = try XCTUnwrap(
            findCornerHoverSensor(id: "PreviewStandaloneExpandButton.HoverSensor", in: host)
        )
        let cornerRegion = NSRect(x: 280, y: 220, width: 28, height: 28)
        let bgSample = NSPoint(x: 268, y: 234)

        try await assertImageCornerIdleAndSensorReveal(
            host: host, window: window, button: button, sensor: sensor,
            size: size, bgSample: bgSample, cornerRegion: cornerRegion
        )
        try await assertImageCornerHoldCancelDelayAndFocus(
            host: host, window: window, button: button, sensor: sensor,
            size: size, bgSample: bgSample, cornerRegion: cornerRegion
        )
    }

    private func assertImageCornerIdleAndSensorReveal(
        host: NSView,
        window: NSWindow,
        button: PreviewCornerActionNSButton,
        sensor: PreviewCornerHoverSensorNSView,
        size: NSSize,
        bgSample: NSPoint,
        cornerRegion: NSRect
    ) async throws {
        // 1. Initial hidden state & non-blocking hit-test pass-through to image canvas
        XCTAssertFalse(button.isChromeVisible)
        XCTAssertFalse(sensor.isPointerInside)
        XCTAssertEqual(try sampleCornerPixels(in: host, logicalSize: size, bgPoint: bgSample, region: cornerRegion), 0)
        let buttonCenterInWindow = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hitPointInSuper = host.superview?.convert(buttonCenterInWindow, from: nil) ?? buttonCenterInWindow
        let idleHitView = try XCTUnwrap(host.hitTest(hitPointInSuper))
        XCTAssertFalse(idleHitView === button || idleHitView.isDescendant(of: button))
        XCTAssertFalse(idleHitView === sensor || idleHitView.isDescendant(of: sensor))

        // Mutation / Red-gate proof: bypassing `isChromeVisible` gate immediately intercepts hit-test & draws pixels
        button.isChromeVisible = true
        XCTAssertTrue(host.hitTest(hitPointInSuper) === button, "Red-gate proof: removing gate blocks content hit-test")
        XCTAssertGreaterThan(
            try sampleCornerPixels(in: host, logicalSize: size, bgPoint: bgSample, region: cornerRegion), 10,
            "Red-gate proof: removing gate renders button pixels while idle"
        )
        button.isChromeVisible = false
        XCTAssertFalse(host.hitTest(hitPointInSuper) === button)

        // 2. Pointer moving inside image body outside bottom-right sensor keeps button hidden
        for pt in [NSPoint(x: 160, y: 130), NSPoint(x: 294, y: 220), NSPoint(x: 26, y: 26)] {
            try dispatchPointerMove(in: host, window: window, locationInWindow: pt)
            await settleOffscreenHost(host, cycles: 2)
            XCTAssertFalse(sensor.isPointerInside, "Point \(pt) outside bottom-right sensor must not trigger sensor")
            XCTAssertFalse(button.isChromeVisible)
        }

        // 3. Entering bottom-right sensor zone (outside 28x28 button) reveals button
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: size.width - 56, y: 26))
        await settleOffscreenHost(host, cycles: 4)
        XCTAssertTrue(sensor.isPointerInside)
        XCTAssertFalse(button.isPointerHovered)
        XCTAssertTrue(button.isChromeVisible)
        XCTAssertGreaterThan(try sampleCornerPixels(in: host, logicalSize: size, bgPoint: bgSample, region: cornerRegion), 15)
        XCTAssertTrue(host.hitTest(hitPointInSuper) === button)
    }

    private func assertImageCornerHoldCancelDelayAndFocus(
        host: NSView,
        window: NSWindow,
        button: PreviewCornerActionNSButton,
        sensor: PreviewCornerHoverSensorNSView,
        size: NSSize,
        bgSample: NSPoint,
        cornerRegion: NSRect
    ) async throws {
        // 4. Moving from sensor onto button keeps it visible and highlighted, and accepts click
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: size.width - 26, y: 26))
        await settleOffscreenHost(host, cycles: 3)
        XCTAssertTrue(button.isPointerHovered)
        XCTAssertTrue(button.isChromeVisible)
        XCTAssertTrue(button.isChromeHighlighted)

        final class ExpandFlagBox: @unchecked Sendable {
            var triggered = false
        }
        let flagBox = ExpandFlagBox()
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TTZipToggleMediaFocusNotification"), object: nil, queue: .main
        ) { _ in flagBox.triggered = true }
        defer { NotificationCenter.default.removeObserver(token) }
        try clickVisibleButtonViaHitTest(button, in: host, window: window)
        XCTAssertTrue(flagBox.triggered, "Clicking visible expand button must trigger fullscreen notification")

        // 5. Leaving starts grace delay; re-entering before 260ms cancels pending hide task
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 120, y: 140))
        await settleOffscreenHost(host, cycles: 2)
        XCTAssertFalse(sensor.isPointerInside)
        XCTAssertFalse(button.isPointerHovered)
        XCTAssertTrue(button.isChromeVisible, "Button must stay visible during grace delay after leaving corner")
        try? await Task.sleep(nanoseconds: 70_000_000)
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: size.width - 48, y: 26))
        await settleOffscreenHost(host, cycles: 2)
        try? await Task.sleep(nanoseconds: 250_000_000)
        await settleOffscreenHost(host, cycles: 2)
        XCTAssertTrue(button.isChromeVisible, "Re-entering sensor zone must cancel the previous pending hide task")

        // 6. Leaving for the full grace delay hides the button and restores content hit-testing
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 120, y: 140))
        try? await Task.sleep(nanoseconds: 340_000_000)
        await settleOffscreenHost(host, cycles: 4)
        XCTAssertFalse(button.isChromeVisible)
        XCTAssertEqual(try sampleCornerPixels(in: host, logicalSize: size, bgPoint: bgSample, region: cornerRegion), 0)

        // 7. Keyboard Tab focus immediately reveals button, prevents delayed hide while focused, and hides after blur
        XCTAssertTrue(window.makeFirstResponder(button))
        await settleOffscreenHost(host, cycles: 4)
        XCTAssertTrue(button.isChromeVisible, "Keyboard focus must immediately reveal corner button")
        XCTAssertGreaterThan(try sampleCornerPixels(in: host, logicalSize: size, bgPoint: bgSample, region: cornerRegion), 15)
        try? await Task.sleep(nanoseconds: 320_000_000)
        await settleOffscreenHost(host, cycles: 2)
        XCTAssertTrue(button.isChromeVisible, "Focused button must never be hidden by grace timer")
        _ = window.makeFirstResponder(nil)
        try? await Task.sleep(nanoseconds: 340_000_000)
        await settleOffscreenHost(host, cycles: 4)
        XCTAssertFalse(button.isChromeVisible, "Blurring unfocused/unhovered button must hide after grace delay")
    }

    private func verifySecondSharedFormatAndStandaloneReturnOnDemandLifecycle() async throws {
        let sample = try file("corner-shared-format.txt")
        let origin = UUID()
        let opened = await manager.open(item: sample, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(opened)
        defer { Task { await manager.close(item: sample, originWindowID: origin) } }

        var returnCount = 0
        let controls = MediaControlsVisibility()
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let size = NSSize(width: 640, height: 420)
        let host = StandalonePreviewWindowContent.makeHostingView(
            item: sample, controls: controls, onReturn: { returnCount += 1 }, onClose: {}
        )
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        await settleOffscreenHost(host, cycles: 5)

        let returnBtn = try XCTUnwrap(
            findButton(id: "StandalonePreviewReturnButton", in: host) as? PreviewCornerActionNSButton
        )
        let btnCenter = returnBtn.convert(NSPoint(x: returnBtn.bounds.midX, y: returnBtn.bounds.midY), to: nil)
        let hitPt = host.superview?.convert(btnCenter, from: nil) ?? btnCenter

        // Initial hidden & content hit-test pass-through
        XCTAssertFalse(returnBtn.isChromeVisible)
        let idleHit = try XCTUnwrap(host.hitTest(hitPt))
        XCTAssertFalse(idleHit === returnBtn || idleHit.isDescendant(of: returnBtn))

        // Sensor entry + click triggers onReturn; active interaction lock holds button visible when pointer leaves
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: size.width - 26, y: 26))
        await settleOffscreenHost(host, cycles: 4)
        XCTAssertTrue(returnBtn.isChromeVisible)
        try clickVisibleButtonViaHitTest(returnBtn, in: host, window: window)
        XCTAssertEqual(returnCount, 1)

        controls.beginInteraction()
        try dispatchPointerMove(in: host, window: window, locationInWindow: NSPoint(x: 200, y: 200))
        try? await Task.sleep(nanoseconds: 320_000_000)
        await settleOffscreenHost(host, cycles: 3)
        XCTAssertTrue(returnBtn.isChromeVisible, "Active popover/menu interaction lock must hold return button visible")

        controls.endInteraction()
        try? await Task.sleep(nanoseconds: 340_000_000)
        await settleOffscreenHost(host, cycles: 4)
        XCTAssertFalse(returnBtn.isChromeVisible, "Releasing interaction lock must hide return button after grace delay")
    }
}

internal actor StandalonePreviewCommitGate {
    nonisolated let arrived = XCTestExpectation(description: "Resources acquired before commit")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            arrived.fulfill()
        }
    }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
