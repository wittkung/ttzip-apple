// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
@testable import TTMediaKit
import XCTest

@MainActor
final class CodeFloatingToolsInteractionTests: XCTestCase {
    private static var subtitleSource: String {
        let opening = "1\n00:00:01,000 --> 00:00:03,000\n中文正文 Visible subtitle\n\n"
        let body = (2...80).map { index in
            let suffix = index == 80 ? "tail selection" : "remains visible"
            return "\(index)\n00:00:04,000 --> 00:00:06,000\n中文字幕 line \(index) \(suffix)\n"
        }.joined(separator: "\n")
        return opening + body
    }

    func testFloatingReadingToolsFunctionalControlsAndPopoverState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-floating-controls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("editable.swift")
        let initial = "let answer = 42\nprint(answer)\n"
        try Data(initial.utf8).write(to: file)

        let driver = FloatingToolsTestDriver()
        driver.state = .popoverExpanded
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DrivenFloatingToolsContainer(driver: driver, source: initial, file: file))
        host.sizingOptions = []
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        resize(host, window: window, width: 640)

        let editor = try await waitForEditor(in: host, source: initial, requireViewport: true, mode: .black)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertTrue(scrollView.rulersVisible, "Line number gutter must be visible by default")
        XCTAssertEqual(editor.font?.pointSize ?? 0, CodeFloatingReadingToolsOverlay.defaultFontSize, accuracy: 0.1)

        for mode in [TTTextReadingBackgroundMode.white, .fluidTransparent, .black] {
            driver.mode = mode
            for _ in 0..<4 {
                flushPendingHostLayout(host)
                await Task.yield()
            }
            let expectedBg = TTTextReadingPalette.resolve(mode: mode, isDarkAppearance: true).nsCanvasBackgroundColor
            XCTAssertEqual(editor.backgroundColor, expectedBg)
        }

        let container = CodeTextEditorContainerView(
            initialText: initial,
            fileURL: file,
            fileName: file.lastPathComponent,
            isReadOnly: false,
            resourceContext: .diskFile(url: file, fileName: file.lastPathComponent, allowsEditing: true)
        )
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertEqual(container.copyPreviewToPasteboard(pasteboard), initial)
        XCTAssertEqual(pasteboard.string(forType: .string), initial)
        let updated = "let answer = 100\nprint(answer)\n"
        XCTAssertTrue(container.saveFile(contentOverride: updated))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), updated)
    }

    /// Verifies real production button clicks (`Aa`, `A+`, `A-`, `#`, theme) and narrow `240pt` Inspector popover fit.
    func testRealFloatingToolsButtonActionsAndNarrow240ptFit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-d3-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("alpha.swift")
        try Data(Self.subtitleSource.utf8).write(to: fileA)

        let controls = MediaControlsVisibility()
        let fileDriver = RealToolsFileSwitchDriver(fileURL: fileA, fileName: "alpha.swift", text: Self.subtitleSource)
        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: 640, height: 380),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: RealToolsHarnessView(driver: fileDriver, controls: controls).frame(width: 640, height: 380)
        )
        host.sizingOptions = []
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.setContentSize(NSSize(width: 640, height: 380))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 380)

        let editor = try await waitForEditor(in: host, source: Self.subtitleSource, requireViewport: true, mode: .black)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertFalse(controls.hasActiveInteractionLock)
        XCTAssertNil(findButton(id: "CodeFloatingFontIncreaseButton", in: host))

        let aaButton = try XCTUnwrap(findButton(id: "CodeFloatingAaToolsButton", in: host))
        XCTAssertFalse(aaButton.isTransparent, "Production Aa button must be a visible control, never a transparent test bridge")
        XCTAssertFalse(aaButton.isHidden)

        // Disabled/hidden controls must never fire on mouseDown -> mouseUp sequence.
        aaButton.isEnabled = false
        try dispatchMouseSequence(on: aaButton, in: host, window: window, releaseInside: true, expectEnabled: false)
        XCTAssertFalse(controls.hasActiveInteractionLock, "Disabled Aa button must not fire action")
        aaButton.isEnabled = true

        aaButton.isHidden = true
        try dispatchMouseSequence(on: aaButton, in: host, window: window, releaseInside: true, expectHidden: true)
        XCTAssertFalse(controls.hasActiveInteractionLock, "Hidden Aa button must not fire action")
        aaButton.isHidden = false

        // Press inside then drag outside and release outside must cancel the click (zero action).
        try dragOutCancelVisibleButtonViaHitTest(aaButton, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertFalse(controls.hasActiveInteractionLock, "Pressing inside Aa then dragging out before mouseUp must cancel and not open popover")
        XCTAssertNil(findButton(id: "CodeFloatingFontIncreaseButton", in: host))

        // Press inside and release inside must trigger action exactly once.
        try clickVisibleButtonViaHitTest(aaButton, in: host, window: window)
        for _ in 0..<6 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertTrue(controls.hasActiveInteractionLock, "Opening Aa popover must acquire interaction lock")

        try await exerciseLivePopoverTypographyAndThemeControls(
            editor: editor,
            scrollView: scrollView,
            host: host,
            window: window
        )

        window.setContentSize(NSSize(width: 240, height: 380))
        host.rootView = RealToolsHarnessView(driver: fileDriver, controls: controls).frame(width: 240, height: 380)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 380)
        for _ in 0..<6 {
            flushPendingHostLayout(host)
            await Task.yield()
        }

        try assertNarrow240ptPopoverGeometry(scrollView: scrollView, host: host)
    }

    /// Verifies local Escape dismissal, two-window isolation against unowned (`windowNumber == 0`) events,
    /// and idempotent interaction-lock cleanup on file switch, disappear, and reappear.
    func testPopoverEscapeDismissalAndLockLifecycleOnFileSwitchAndDisappear() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-d3-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("alpha.swift")
        let fileB = dir.appendingPathComponent("beta.swift")
        try Data(Self.subtitleSource.utf8).write(to: fileA)
        try Data("let beta = 42\n".utf8).write(to: fileB)

        let controls = MediaControlsVisibility()
        let fileDriver = RealToolsFileSwitchDriver(fileURL: fileA, fileName: "alpha.swift", text: Self.subtitleSource)
        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: 640, height: 380),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: RealToolsHarnessView(driver: fileDriver, controls: controls).frame(width: 640, height: 380)
        )
        host.sizingOptions = []
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.setContentSize(NSSize(width: 640, height: 380))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 380)

        _ = try await waitForEditor(in: host, source: Self.subtitleSource, requireViewport: true, mode: .black)

        let aaButton = try XCTUnwrap(findButton(id: "CodeFloatingAaToolsButton", in: host))
        try clickVisibleButtonViaHitTest(aaButton, in: host, window: window)
        for _ in 0..<6 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertTrue(controls.hasActiveInteractionLock)

        try await assertUnownedZeroWindowAndSecondWindowEscapeIsolation(
            windowA: window,
            hostA: host,
            controlsA: controls,
            fileB: fileB
        )

        let escEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        NSApplication.shared.sendEvent(escEvent)
        for _ in 0..<6 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertFalse(controls.hasActiveInteractionLock, "First Esc must release the popover interaction lock")
        XCTAssertNil(
            findButton(id: "CodeFloatingFontIncreaseButton", in: host),
            "First Esc must close the Aa popover card"
        )

        let aaReopen = try XCTUnwrap(findButton(id: "CodeFloatingAaToolsButton", in: host))
        try clickVisibleButtonViaHitTest(aaReopen, in: host, window: window)
        for _ in 0..<6 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertTrue(controls.hasActiveInteractionLock)

        fileDriver.fileURL = fileB
        fileDriver.fileName = "beta.swift"
        fileDriver.text = "let beta = 42\n"
        for _ in 0..<8 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertFalse(controls.hasActiveInteractionLock, "Switching files must dismiss popover and release lock")

        let aaBeforeDisappear = try XCTUnwrap(findButton(id: "CodeFloatingAaToolsButton", in: host))
        try clickVisibleButtonViaHitTest(aaBeforeDisappear, in: host, window: window)
        for _ in 0..<6 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertTrue(controls.hasActiveInteractionLock)

        window.contentView = nil
        flushPendingHostLayout(host)
        await Task.yield()
        XCTAssertFalse(controls.hasActiveInteractionLock, "Disappearing view must never leave a dangling interaction lock")

        window.contentView = host
        for _ in 0..<6 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        let isCardOpenAfterReappear = findButton(id: "CodeFloatingFontIncreaseButton", in: host) != nil
        XCTAssertEqual(
            isCardOpenAfterReappear,
            controls.hasActiveInteractionLock,
            "On reappear, popover card state and interaction lock state must be consistent"
        )
    }

    private func assertUnownedZeroWindowAndSecondWindowEscapeIsolation(
        windowA: NSWindow,
        hostA: NSView,
        controlsA: MediaControlsVisibility,
        fileB: URL
    ) async throws {
        let controlsB = MediaControlsVisibility()
        let driverB = RealToolsFileSwitchDriver(fileURL: fileB, fileName: "beta.swift", text: "let beta = 42\n")
        let windowB = NSWindow(
            contentRect: NSRect(x: -16_000, y: -15_000, width: 640, height: 380),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        windowB.isReleasedWhenClosed = false
        let hostB = NSHostingView(
            rootView: RealToolsHarnessView(driver: driverB, controls: controlsB).frame(width: 640, height: 380)
        )
        hostB.sizingOptions = []
        windowB.contentView = hostB
        defer {
            windowB.contentView = nil
            windowB.close()
        }
        windowB.setContentSize(NSSize(width: 640, height: 380))
        hostB.frame = NSRect(x: 0, y: 0, width: 640, height: 380)
        _ = try await waitForEditor(in: hostB, source: "let beta = 42\n", requireViewport: true, mode: .black)

        let aaB = try XCTUnwrap(findButton(id: "CodeFloatingAaToolsButton", in: hostB))
        try clickVisibleButtonViaHitTest(aaB, in: hostB, window: windowB)
        for _ in 0..<6 {
            flushPendingHostLayout(hostB)
            await Task.yield()
        }
        XCTAssertTrue(controlsA.hasActiveInteractionLock)
        XCTAssertTrue(controlsB.hasActiveInteractionLock)

        // 1. Unowned Escape event (`windowNumber: 0` on non-key windows) must be rejected by both windows.
        let unownedEsc = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        NSApplication.shared.sendEvent(unownedEsc)
        for _ in 0..<4 {
            flushPendingHostLayout(hostA)
            flushPendingHostLayout(hostB)
            await Task.yield()
        }
        XCTAssertTrue(controlsA.hasActiveInteractionLock, "Unowned 0-window Escape must not close window A's popover")
        XCTAssertTrue(controlsB.hasActiveInteractionLock, "Unowned 0-window Escape must not close window B's popover")

        // 2. Escape targeted at window B must close ONLY window B's popover and leave window A's popover open.
        let escForB = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowB.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        NSApplication.shared.sendEvent(escForB)
        for _ in 0..<6 {
            flushPendingHostLayout(hostA)
            flushPendingHostLayout(hostB)
            await Task.yield()
        }
        XCTAssertFalse(controlsB.hasActiveInteractionLock, "Escape targeted at window B must close window B's popover")
        XCTAssertNil(findButton(id: "CodeFloatingFontIncreaseButton", in: hostB))
        XCTAssertTrue(controlsA.hasActiveInteractionLock, "Escape targeted at window B must never close window A's popover")
        XCTAssertNotNil(findButton(id: "CodeFloatingFontIncreaseButton", in: hostA))
    }

    private func exerciseLivePopoverTypographyAndThemeControls(
        editor: LargeTextEditorTextView,
        scrollView: NSScrollView,
        host: NSView,
        window: NSWindow
    ) async throws {
        let fontInc = try XCTUnwrap(findButton(id: "CodeFloatingFontIncreaseButton", in: host))
        let initialPt = try XCTUnwrap(editor.font?.pointSize)

        try dragOutCancelVisibleButtonViaHitTest(fontInc, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertEqual(
            editor.font?.pointSize ?? 0,
            initialPt,
            accuracy: 0.05,
            "Pressing A+ and dragging outside before mouseUp must cancel and keep font size unchanged"
        )

        try clickVisibleButtonViaHitTest(fontInc, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertEqual(editor.font?.pointSize ?? 0, initialPt + 1.0, accuracy: 0.05)

        let fontDec = try XCTUnwrap(findButton(id: "CodeFloatingFontDecreaseButton", in: host))
        try clickVisibleButtonViaHitTest(fontDec, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertEqual(editor.font?.pointSize ?? 0, initialPt, accuracy: 0.05)

        let lineNumBtn = try XCTUnwrap(findButton(id: "CodeFloatingLineNumbersToggle", in: host))
        XCTAssertTrue(scrollView.rulersVisible)
        try clickVisibleButtonViaHitTest(lineNumBtn, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertFalse(scrollView.rulersVisible)
        try clickVisibleButtonViaHitTest(lineNumBtn, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertTrue(scrollView.rulersVisible)

        let softWrapBtn = try XCTUnwrap(findButton(id: "CodeFloatingSoftWrapToggle", in: host))
        XCTAssertEqual(editor.textContainer?.widthTracksTextView, true, "Soft wrap must default to true")
        XCTAssertFalse(editor.isHorizontallyResizable)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        try clickVisibleButtonViaHitTest(softWrapBtn, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertEqual(editor.textContainer?.widthTracksTextView, false)
        XCTAssertTrue(editor.isHorizontallyResizable)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        try clickVisibleButtonViaHitTest(softWrapBtn, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertEqual(editor.textContainer?.widthTracksTextView, true)
        XCTAssertFalse(editor.isHorizontallyResizable)
        XCTAssertFalse(scrollView.hasHorizontalScroller)

        let whiteThemeBtn = try XCTUnwrap(findButton(id: "CodeFloatingThemeButton_white", in: host))
        try clickVisibleButtonViaHitTest(whiteThemeBtn, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertEqual(
            editor.backgroundColor,
            TTTextReadingPalette.resolve(mode: .white, isDarkAppearance: true).nsCanvasBackgroundColor
        )
        let blackThemeBtn = try XCTUnwrap(findButton(id: "CodeFloatingThemeButton_black", in: host))
        try clickVisibleButtonViaHitTest(blackThemeBtn, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertTrue(
            blackThemeBtn.accessibilityPerformPress(),
            "Visible NSButton must also support direct accessibilityPerformPress() on the same control"
        )
    }

    private func clickVisibleButtonViaHitTest(_ button: NSButton, in host: NSView, window: NSWindow) throws {
        try dispatchMouseSequence(on: button, in: host, window: window, releaseInside: true)
    }

    private func dragOutCancelVisibleButtonViaHitTest(_ button: NSButton, in host: NSView, window: NSWindow) throws {
        try dispatchMouseSequence(on: button, in: host, window: window, releaseInside: false)
    }

    private func dispatchMouseSequence(
        on button: NSButton,
        in host: NSView,
        window: NSWindow,
        releaseInside: Bool,
        expectEnabled: Bool = true,
        expectHidden: Bool = false
    ) throws {
        XCTAssertFalse(button.isTransparent, "Visible production button must not be transparent")
        XCTAssertEqual(button.isHidden, expectHidden)
        XCTAssertEqual(button.isEnabled, expectEnabled)
        let centerInWindow = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let pointInHostSuperview = host.superview?.convert(centerInWindow, from: nil) ?? centerInWindow
        if !expectHidden {
            let hitView = try XCTUnwrap(
                host.hitTest(pointInHostSuperview),
                "Host hitTest at button center must resolve a real visible view"
            )
            XCTAssertTrue(
                hitView === button || hitView.isDescendant(of: button),
                "Host hitTest at \(centerInWindow) must resolve the visible NSButton itself, got \(type(of: hitView))"
            )
        }
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

    private func assertNarrow240ptPopoverGeometry(scrollView: NSScrollView, host: NSView) throws {
        XCTAssertEqual(CodeFloatingReadingToolsOverlay.resolvedPopoverWidth(forAvailableWidth: 240), 220.0, accuracy: 0.1)
        XCTAssertEqual(
            CodeFloatingReadingToolsOverlay.resolvedPopoverTrailingPadding(
                forAvailableWidth: 240,
                bottomTrailingReservedWidth: 34.0
            ),
            10.0,
            accuracy: 0.1
        )
        XCTAssertEqual(scrollView.frame.width, 240.0, accuracy: 0.5)
        XCTAssertEqual(scrollView.frame.height, 380.0, accuracy: 0.5)

        let requiredButtonIDs = [
            "CodeFloatingAaToolsButton",
            "CodeFloatingCopyButton",
            "CodeFloatingFontDecreaseButton",
            "CodeFloatingFontIncreaseButton",
            "CodeFloatingSoftWrapToggle",
            "CodeFloatingLineNumbersToggle",
            "CodeFloatingThemeButton_black",
            "CodeFloatingThemeButton_white",
            "CodeFloatingThemeButton_fluidTransparent"
        ]
        for requiredID in requiredButtonIDs {
            let btn = try XCTUnwrap(findButton(id: requiredID, in: host), "Missing \(requiredID) at 240pt width")
            let rectInHost = host.convert(btn.bounds, from: btn)
            XCTAssertGreaterThanOrEqual(
                btn.bounds.height,
                27.5,
                "\(requiredID) must keep >= 28pt hit height at 240pt width"
            )
            XCTAssertGreaterThanOrEqual(
                rectInHost.minX,
                0.0,
                "\(requiredID) must not overflow left edge of 240pt Inspector"
            )
            XCTAssertLessThanOrEqual(
                rectInHost.maxX,
                240.5,
                "\(requiredID) must not overflow right edge of 240pt Inspector"
            )
        }
    }

    private func findButton(id: String, in root: NSView) -> NSButton? {
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

    private func resize<Content: View>(_ host: NSHostingView<Content>, window: NSWindow, width: CGFloat) {
        let size = NSSize(width: width, height: 320)
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    private func waitForEditor<Content: View>(
        in host: NSHostingView<Content>,
        source: String,
        requireViewport: Bool,
        mode: TTTextReadingBackgroundMode? = nil
    ) async throws -> LargeTextEditorTextView {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            flushPendingHostLayout(host)
            if let editor = findEditor(in: host), editor.string == source {
                let hasViewport = !editor.visibleRect.isEmpty && editor.frame.width > 0 && editor.frame.height > 0
                let matchesPalette = mode.map {
                    editor.backgroundColor == TTTextReadingPalette.resolve(mode: $0, isDarkAppearance: true).nsCanvasBackgroundColor
                } ?? true
                if (!requireViewport || hasViewport) && matchesPalette {
                    return editor
                }
            }
            await Task.yield()
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw XCTUnwrapFailure.missingEditor
    }

    private func flushPendingHostLayout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    private func findEditor(in root: NSView) -> LargeTextEditorTextView? {
        if let editor = root as? LargeTextEditorTextView {
            return editor
        }
        for child in root.subviews {
            if let editor = findEditor(in: child) {
                return editor
            }
        }
        return nil
    }

    private enum XCTUnwrapFailure: Error {
        case missingEditor
    }
}

@MainActor
private final class FloatingToolsTestDriver: ObservableObject {
    @Published var state: TTTextFloatingToolsPresentationState? = .quietReading
    @Published var mode: TTTextReadingBackgroundMode = .black
}

private struct DrivenFloatingToolsContainer: View {
    @ObservedObject var driver: FloatingToolsTestDriver
    let source: String
    let file: URL

    var body: some View {
        CodeTextEditorContainerView(
            initialText: source,
            fileURL: file,
            fileName: file.lastPathComponent,
            isReadOnly: false,
            resourceContext: .diskFile(url: file, fileName: file.lastPathComponent, allowsEditing: true),
            readingBackgroundMode: $driver.mode,
            floatingToolsState: $driver.state
        )
        .environment(\.isImmersiveFullscreen, true)
        .environment(\.previewBottomTrailingReservedWidth, 34.0)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
private final class RealToolsFileSwitchDriver: ObservableObject {
    @Published var fileURL: URL
    @Published var fileName: String
    @Published var text: String
    @Published var mode: TTTextReadingBackgroundMode = .black

    init(fileURL: URL, fileName: String, text: String) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.text = text
    }
}

private struct RealToolsHarnessView: View {
    @ObservedObject var driver: RealToolsFileSwitchDriver
    let controls: MediaControlsVisibility

    var body: some View {
        CodeTextEditorContainerView(
            initialText: driver.text,
            fileURL: driver.fileURL,
            fileName: driver.fileName,
            isReadOnly: false,
            resourceContext: .diskFile(url: driver.fileURL, fileName: driver.fileName, allowsEditing: true),
            readingBackgroundMode: $driver.mode
        )
        .environment(\.isImmersiveFullscreen, false)
        .environment(\.previewBottomTrailingReservedWidth, 34.0)
        .environment(\.mediaControlsVisibility, controls)
        .environment(\.colorScheme, .dark)
    }
}
