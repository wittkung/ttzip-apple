// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import ObjectiveC.runtime
import SwiftUI
import TTMediaKit
import TTZipUI
import XCTest
@testable import TTZipApp
@testable import TTZipPreviewKit

@MainActor
final class CodeReadingToolsMouseTests: XCTestCase {
    private static var subtitleSource: String {
        (1...80).map { "\($0)\n00:00:01,000 --> 00:00:03,000\n中文正文 Visible subtitle\n" }.joined(separator: "\n")
    }

    override func setUp() async throws {
        try await super.setUp()
        guard IsolatedTestPreferencesHarness.installedByDiscoveryBootstrap,
              UserDefaults.standard === IsolatedTestPreferencesHarness.sharedDefaults else {
            throw NSError(domain: "CodeReadingToolsMouseTests.preferenceIsolation", code: 1)
        }
    }

    func testRealFloatingToolsButtonActionsAndNarrowInspectorFit() async throws {
        let dir = try makeTemporaryDirectory(prefix: "CodeReadingToolsMouse")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("alpha.swift")
        try Data(Self.subtitleSource.utf8).write(to: fileA)

        let preferences = TTTextReadingPreferenceStore.shared
        let originalMode = preferences.mode
        let originalWrap = preferences.isSoftWrapEnabled
        let storedMode = UserDefaults.standard.object(forKey: preferences.storageKey)
        let storedWrap = UserDefaults.standard.object(forKey: preferences.softWrapStorageKey)
        defer {
            preferences.mode = originalMode
            preferences.isSoftWrapEnabled = originalWrap
            UserDefaults.standard.set(storedMode, forKey: preferences.storageKey)
            UserDefaults.standard.set(storedWrap, forKey: preferences.softWrapStorageKey)
        }
        preferences.mode = .black
        preferences.isSoftWrapEnabled = true
        let controls = MediaControlsVisibility()
        let preview = TTZipCodePreviewView(
            text: Self.subtitleSource, fileURL: fileA, fileName: "alpha.swift",
            resourceContext: .diskFile(url: fileA, fileName: "alpha.swift"), pasteboard: NSPasteboard.withUniqueName()
        )
        .environment(\.previewBottomTrailingReservedWidth, 34)
        .environment(\.mediaControlsVisibility, controls)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 8)
        let (window, host) = makeHost(preview.frame(width: 640, height: 380))
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await waitForEditor(in: host)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertFalse(controls.hasActiveInteractionLock)
        XCTAssertNil(findButton(id: "CodeFloatingFontIncreaseButton", in: host))

        let aaButton = try XCTUnwrap(findButton(id: "CodeFloatingAaToolsButton", in: host))
        XCTAssertFalse(aaButton.isTransparent, "Production Aa button must be a visible control, never a transparent test bridge")
        XCTAssertFalse(aaButton.isHidden)

        try assertInactiveButtonDoesNotOpenTools(aaButton, controls: controls, host: host, window: window)

        try dragOutCancelVisibleButtonViaHitTest(aaButton, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertFalse(controls.hasActiveInteractionLock, "Pressing inside Aa then dragging out before mouseUp must cancel and not open popover")
        XCTAssertNil(findButton(id: "CodeFloatingFontIncreaseButton", in: host))

        try clickVisibleButtonViaHitTest(aaButton, in: host, window: window)
        for _ in 0..<6 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        XCTAssertTrue(controls.hasActiveInteractionLock, "Opening Aa popover must acquire interaction lock")

        try await exerciseTypographyControls(
            editor: editor,
            scrollView: scrollView,
            host: host,
            window: window
        )

        for inspectorWidth in [CGFloat(240), 220] {
            window.setContentSize(NSSize(width: inspectorWidth, height: 380))
            host.rootView = preview.frame(width: inspectorWidth, height: 380)
            host.frame = NSRect(x: 0, y: 0, width: inspectorWidth, height: 380)
            for _ in 0..<6 {
                flushPendingHostLayout(host)
                await Task.yield()
            }
            try assertNarrowPopoverGeometry(inspectorWidth: inspectorWidth, scrollView: scrollView, host: host)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testStandaloneAutoHideAllowsTabShiftTabRevealFocusHoldSpaceAndTwoStageEscape() async throws {
        let dir = try makeTemporaryDirectory(prefix: "CodeReadingToolsKeyboardReveal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let srtURL = dir.appendingPathComponent("synthetic.srt")
        try Data(Self.subtitleSource.utf8).write(to: srtURL)

        let preferences = TTTextReadingPreferenceStore.shared
        let originalMode = preferences.mode
        defer { preferences.mode = originalMode }
        preferences.mode = .black

        let controls = MediaControlsVisibility(inactivityDuration: .milliseconds(80))
        var returnCount = 0
        let archiveCtx = TTPreviewResourceContext.archiveEntry(
            archivePath: dir.appendingPathComponent("sample.zip").path,
            entryPath: srtURL.lastPathComponent, stagedReadURL: srtURL, fileName: srtURL.lastPathComponent
        )
        let item = ImmersiveMediaItem(url: srtURL, name: srtURL.lastPathComponent, resourceContext: archiveCtx)
        let host = StandalonePreviewWindowContent.makeHostingView(
            item: item, controls: controls, onReturn: { returnCount += 1 }, onClose: {}
        )
        let (window, restoreHooks) = try mountKeyableStandaloneHost(host, size: NSSize(width: 640, height: 380))
        defer {
            restoreHooks()
            window.contentView = nil
            window.close()
        }

        let editor = try await waitForEditor(in: host)
        XCTAssertFalse(editor.isEditable)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: 120))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        flushPendingHostLayout(host)
        let baselineScrollBounds = scrollView.contentView.bounds
        let baselineScrollFrame = scrollView.frame
        let baselineOrigin = editor.textContainerOrigin
        XCTAssertGreaterThan(baselineScrollBounds.minY, 100)

        try await assertAutoHideRemovesVisualAndMouseTargetButKeepsFocusAnchors(
            controls: controls, host: host, window: window
        )
        try await assertKeyboardTabCycleFocusHoldAndPopoverEscape(
            editor: editor, controls: controls, host: host, window: window, returnCount: { returnCount }
        )

        XCTAssertEqual(scrollView.frame, baselineScrollFrame)
        XCTAssertEqual(scrollView.contentView.bounds, baselineScrollBounds)
        XCTAssertEqual(editor.textContainerOrigin, baselineOrigin)
        XCTAssertFalse(window.isVisible)
    }

    private func assertAutoHideRemovesVisualAndMouseTargetButKeepsFocusAnchors(
        controls: MediaControlsVisibility, host: NSView, window: NSWindow
    ) async throws {
        controls.recordMouseMove(at: CGPoint(x: 240, y: 200))
        try await waitUntil(in: host) { controls.isVisible }

        try await waitUntil(in: host) { !controls.isVisible }

        let aaButton = try XCTUnwrap(findButton(id: "CodeFloatingAaToolsButton", in: host))
        let copyButton = try XCTUnwrap(findButton(id: "CodeFloatingCopyButton", in: host))
        try await waitUntil(in: host) { countGlassEffectViews(in: host) == 0 }
        XCTAssertEqual(try nonCanvasPixelCount(for: aaButton, in: host), 0)
        let aaCenterInWindow = aaButton.convert(NSPoint(x: aaButton.bounds.midX, y: aaButton.bounds.midY), to: nil)
        let aaPointInSuper = host.superview?.convert(aaCenterInWindow, from: nil) ?? aaCenterInWindow
        let hitView = try XCTUnwrap(host.hitTest(aaPointInSuper))
        XCTAssertFalse(
            hitView === aaButton || hitView.isDescendant(of: aaButton)
                || hitView === copyButton || hitView.isDescendant(of: copyButton),
            "Auto-hidden floating buttons must pass mouse hit-testing through to the document"
        )
        try dispatchMouseSequence(on: aaButton, in: host, window: window, releaseInside: true, expectHitTestable: false)
        XCTAssertNil(findButton(id: "CodeFloatingFontIncreaseButton", in: host))
    }

    private func assertKeyboardTabCycleFocusHoldAndPopoverEscape(
        editor: NSTextView, controls: MediaControlsVisibility, host: NSView,
        window: NSWindow, returnCount: () -> Int
    ) async throws {
        let aaButton = try XCTUnwrap(findButton(id: "CodeFloatingAaToolsButton", in: host))
        let copyButton = try XCTUnwrap(findButton(id: "CodeFloatingCopyButton", in: host))
        window.recalculateKeyViewLoop()

        XCTAssertTrue(window.makeFirstResponder(editor))
        try sendKey(keyCode: 48, characters: "\t", to: window, host: host)
        XCTAssertTrue(window.firstResponder === aaButton, "Tab from text body must focus Aa")
        try await waitUntil(in: host) { controls.isVisible && ((try? self.nonCanvasPixelCount(for: aaButton, in: host)) ?? 0) > 12 }

        try await Task.sleep(for: .milliseconds(160))
        flushPendingHostLayout(host)
        XCTAssertTrue(controls.isVisible, "Keyboard focus on Aa must prevent inactivity auto-hide")

        try sendKey(keyCode: 48, characters: "\t", to: window, host: host)
        XCTAssertTrue(window.firstResponder === copyButton, "Second Tab must focus Copy")
        try sendKey(keyCode: 48, characters: "\u{19}", modifiers: [.shift], to: window, host: host)
        XCTAssertTrue(window.firstResponder === aaButton, "Shift-Tab from Copy must focus Aa")
        try sendKey(keyCode: 48, characters: "\u{19}", modifiers: [.shift], to: window, host: host)
        XCTAssertTrue(window.firstResponder === editor, "Shift-Tab from Aa must return focus to text body")
        try sendKey(keyCode: 48, characters: "\t", to: window, host: host)
        XCTAssertTrue(window.firstResponder === aaButton, "Tab from text body must focus Aa again")

        try sendKey(keyCode: 49, characters: " ", sendKeyUp: true, to: window, host: host)
        try await waitUntil(in: host) { self.findButton(id: "CodeFloatingFontIncreaseButton", in: host) != nil }
        let fontInc = try XCTUnwrap(findButton(id: "CodeFloatingFontIncreaseButton", in: host))
        XCTAssertTrue(controls.hasActiveInteractionLock)
        XCTAssertTrue(window.makeFirstResponder(fontInc))

        try sendKey(keyCode: 53, characters: "\u{1b}", to: window, host: host)
        try await waitUntil(in: host) { self.findButton(id: "CodeFloatingFontIncreaseButton", in: host) == nil }
        XCTAssertFalse(controls.hasActiveInteractionLock)
        XCTAssertEqual(returnCount(), 0, "First Escape must close Aa popover before leaving standalone preview")
        XCTAssertTrue(window.firstResponder === aaButton, "Dismissing popover from inside must restore focus to Aa")

        try sendKey(keyCode: 53, characters: "\u{1b}", to: window, host: host)
        flushPendingHostLayout(host)
        XCTAssertEqual(returnCount(), 1, "Second Escape with popover closed must trigger standalone return")
    }

    private func waitUntil(in host: NSView, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            flushPendingHostLayout(host)
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        flushPendingHostLayout(host)
        XCTAssertTrue(condition())
    }

    private func mountKeyableStandaloneHost(_ host: NSView, size: NSSize) throws -> (NSWindow, () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -16_000, y: -16_000), size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        let fka = try XCTUnwrap(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isFullKeyboardAccessEnabled)))
        let keyW = try XCTUnwrap(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow)))
        let isKeyW = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow)))
        let fkaImp = imp_implementationWithBlock({ (_: AnyObject) in true } as @convention(block) (AnyObject) -> Bool)
        let keyWImp = imp_implementationWithBlock({ [weak window] (_: AnyObject) in window } as @convention(block) (AnyObject) -> NSWindow?)
        let isKeyWImp = imp_implementationWithBlock({ [weak window] (w: NSWindow) in w === window } as @convention(block) (NSWindow) -> Bool)
        let origFka = method_setImplementation(fka, fkaImp)
        let origKeyW = method_setImplementation(keyW, keyWImp)
        let origIsKeyW = method_setImplementation(isKeyW, isKeyWImp)
        return (window, {
            method_setImplementation(fka, origFka)
            method_setImplementation(keyW, origKeyW)
            method_setImplementation(isKeyW, origIsKeyW)
            imp_removeBlock(fkaImp)
            imp_removeBlock(keyWImp)
            imp_removeBlock(isKeyWImp)
        })
    }

    private func sendKey(
        keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [],
        sendKeyUp: Bool = false, to window: NSWindow, host: NSView
    ) throws {
        let now = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: now,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        if sendKeyUp, let up = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: now + 0.01,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) {
            NSApplication.shared.postEvent(up, atStart: false)
        }
        if keyCode == 53 {
            NSApplication.shared.sendEvent(down)
        } else {
            window.sendEvent(down)
        }
        while let queued = NSApplication.shared.nextEvent(matching: .keyUp, until: nil, inMode: .default, dequeue: true) {
            window.sendEvent(queued)
        }
        flushPendingHostLayout(host)
    }

    private func nonCanvasPixelCount(for view: NSView, in host: NSView) throws -> Int {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scaleX = Double(bitmap.pixelsWide) / Double(host.bounds.width)
        let scaleY = Double(bitmap.pixelsHigh) / Double(host.bounds.height)
        let bg = try XCTUnwrap(bitmap.colorAt(x: Int(40.0 * scaleX), y: Int(40.0 * scaleY))?.usingColorSpace(.sRGB))
        let unflipped = view.convert(view.bounds, to: nil)
        let topDown = NSRect(x: unflipped.minX, y: host.bounds.height - unflipped.maxY, width: unflipped.width, height: unflipped.height)
        var diff = 0
        for py in max(0, Int(Double(topDown.minY) * scaleY))..<min(bitmap.pixelsHigh, Int(Double(topDown.maxY) * scaleY)) {
            for px in max(0, Int(Double(topDown.minX) * scaleX))..<min(bitmap.pixelsWide, Int(Double(topDown.maxX) * scaleX)) {
                guard let c = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.10 {
                    diff += 1
                }
            }
        }
        return diff
    }

    private func makeHost<Content: View>(_ preview: Content) -> (NSWindow, NSHostingView<Content>) {
        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: 640, height: 380),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: preview)
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 640, height: 380))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 380)
        return (window, host)
    }

    private func assertInactiveButtonDoesNotOpenTools(
        _ aaButton: NSButton, controls: MediaControlsVisibility, host: NSView, window: NSWindow
    ) throws {
        // Disabled/hidden controls must never fire on mouseDown -> mouseUp sequence.
        aaButton.isEnabled = false
        try dispatchMouseSequence(on: aaButton, in: host, window: window, releaseInside: true, expectEnabled: false)
        XCTAssertFalse(controls.hasActiveInteractionLock, "Disabled Aa button must not fire action")
        aaButton.isEnabled = true

        aaButton.isHidden = true
        try dispatchMouseSequence(on: aaButton, in: host, window: window, releaseInside: true, expectHidden: true)
        XCTAssertFalse(controls.hasActiveInteractionLock, "Hidden Aa button must not fire action")
        aaButton.isHidden = false
    }

    private func exerciseTypographyControls(
        editor: NSTextView,
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

        try await exerciseWrapAndThemeControls(editor: editor, scrollView: scrollView, host: host, window: window)
    }

    private func exerciseWrapAndThemeControls(
        editor: NSTextView, scrollView: NSScrollView, host: NSView, window: NSWindow
    ) async throws {
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
            TTZipTextReadingAppearance.resolve(mode: .white, isDarkAppearance: true).nsCanvasBackgroundColor
        )
        let systemForcesOpaqueDark = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        try assertFloatingClusterSurfaceContrast(
            in: host,
            expectDarkSurface: systemForcesOpaqueDark,
            expectCopySuccess: false
        )
        let copyBtn = try XCTUnwrap(findButton(id: "CodeFloatingCopyButton", in: host))
        try clickVisibleButtonViaHitTest(copyBtn, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        try assertFloatingClusterSurfaceContrast(
            in: host,
            expectDarkSurface: systemForcesOpaqueDark,
            expectCopySuccess: true
        )
        let blackThemeBtn = try XCTUnwrap(findButton(id: "CodeFloatingThemeButton_black", in: host))
        try clickVisibleButtonViaHitTest(blackThemeBtn, in: host, window: window)
        for _ in 0..<4 {
            flushPendingHostLayout(host)
            await Task.yield()
        }
        try assertFloatingClusterSurfaceContrast(in: host, expectDarkSurface: true, expectCopySuccess: true)
        XCTAssertTrue(
            blackThemeBtn.accessibilityPerformPress(),
            "Visible NSButton must also support direct accessibilityPerformPress() on the same control"
        )
    }

    private func assertFloatingClusterSurfaceContrast(
        in host: NSView,
        expectDarkSurface: Bool,
        expectCopySuccess: Bool
    ) throws {
        XCTAssertEqual(TTZipCodeReadingTools.clusterCapsuleCornerRadius, 14.0, accuracy: 0.01)
        let restingIDs = expectCopySuccess
            ? ["CodeFloatingAllowEditingButton"]
            : ["CodeFloatingAllowEditingButton", "CodeFloatingCopyButton"]
        for buttonID in restingIDs {
            let button = try XCTUnwrap(
                findButton(id: buttonID, in: host) as? TTZipCodeToolNSButton,
                "Expected TTZipCodeToolNSButton for \(buttonID)"
            )
            let fg = try XCTUnwrap(button.visualStyle.foregroundColor.usingColorSpace(.sRGB))
            let hoverBg = try XCTUnwrap(button.visualStyle.hoverBackgroundColor.usingColorSpace(.sRGB))
            if expectDarkSurface {
                XCTAssertGreaterThan(fg.redComponent, 0.95, "\(buttonID) must use light foreground on dark/opaque surface")
                XCTAssertGreaterThan(hoverBg.redComponent, 0.95, "\(buttonID) must use light hover tint on dark/opaque surface")
            } else {
                XCTAssertLessThan(fg.redComponent, 0.15, "\(buttonID) must use dark ink foreground on light glass surface")
                XCTAssertLessThan(fg.greenComponent, 0.15, "\(buttonID) must use dark ink foreground on light glass surface")
                XCTAssertLessThan(hoverBg.redComponent, 0.05, "\(buttonID) must use dark hover tint on light glass surface")
            }
        }
        try assertSelectedClusterButtonContrast(
            in: host,
            expectDarkSurface: expectDarkSurface,
            expectCopySuccess: expectCopySuccess
        )
        XCTAssertEqual(
            countHudWindowVisualEffectViews(in: host),
            0,
            "Compact cluster must not use legacy dark .hudWindow NSVisualEffectView backdrop"
        )
        XCTAssertLessThanOrEqual(
            countGlassEffectViews(in: host),
            1,
            "Compact cluster must not stack multiple NSGlassEffectView instances"
        )
    }

    private func assertSelectedClusterButtonContrast(
        in host: NSView,
        expectDarkSurface: Bool,
        expectCopySuccess: Bool
    ) throws {
        let copyButton = try XCTUnwrap(
            findButton(id: "CodeFloatingCopyButton", in: host) as? TTZipCodeToolNSButton
        )
        XCTAssertEqual(
            copyButton.visualStyle.symbolName,
            expectCopySuccess ? "checkmark" : "doc.on.doc"
        )
        let selectedIDs = expectCopySuccess
            ? ["CodeFloatingAaToolsButton", "CodeFloatingCopyButton"]
            : ["CodeFloatingAaToolsButton"]
        for buttonID in selectedIDs {
            let button = try XCTUnwrap(
                findButton(id: buttonID, in: host) as? TTZipCodeToolNSButton,
                "Expected selected TTZipCodeToolNSButton for \(buttonID)"
            )
            let fg = try XCTUnwrap(button.visualStyle.foregroundColor.usingColorSpace(.sRGB))
            let bg = try XCTUnwrap(button.visualStyle.backgroundColor.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(bg.alphaComponent, 0.15, "\(buttonID) must keep selected green tint cue")
            XCTAssertGreaterThan(bg.greenComponent, bg.redComponent, "\(buttonID) selected tint must be bamboo green")
            if expectDarkSurface {
                XCTAssertGreaterThan(fg.greenComponent, 0.50, "\(buttonID) must preserve bamboo-green glyph on dark surface")
                XCTAssertGreaterThan(fg.greenComponent, fg.redComponent, "\(buttonID) must preserve bamboo-green glyph on dark surface")
            } else {
                XCTAssertLessThan(fg.redComponent, 0.15, "\(buttonID) selected glyph must use readable dark ink on light glass")
                XCTAssertLessThan(fg.greenComponent, 0.15, "\(buttonID) selected glyph must not use low-contrast bamboo green on light glass")
                XCTAssertGreaterThan(fg.alphaComponent, 0.95, "\(buttonID) selected dark ink glyph must keep high opacity")
            }
        }
    }

    private func countHudWindowVisualEffectViews(in root: NSView) -> Int {
        let selfCount = (root as? NSVisualEffectView)?.material == .hudWindow ? 1 : 0
        return root.subviews.reduce(selfCount) { $0 + countHudWindowVisualEffectViews(in: $1) }
    }

    private func countGlassEffectViews(in root: NSView) -> Int {
        let selfCount = String(describing: type(of: root)).contains("GlassEffect") ? 1 : 0
        return root.subviews.reduce(selfCount) { $0 + countGlassEffectViews(in: $1) }
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
        expectHidden: Bool = false,
        expectHitTestable: Bool = true
    ) throws {
        XCTAssertFalse(button.isTransparent, "Visible production button must not be transparent")
        XCTAssertEqual(button.isHidden, expectHidden)
        XCTAssertEqual(button.isEnabled, expectEnabled)
        let centerInWindow = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let pointInHostSuperview = host.superview?.convert(centerInWindow, from: nil) ?? centerInWindow
        if !expectHidden && expectHitTestable {
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

    private func assertNarrowPopoverGeometry(inspectorWidth: CGFloat, scrollView: NSScrollView, host: NSView) throws {
        let viewport = host.convert(scrollView.bounds, from: scrollView)
        XCTAssertEqual(viewport.width, inspectorWidth - 16, accuracy: 0.5)
        let cardWidth = TTZipCodeReadingTools.resolvedPopoverWidth(forAvailableWidth: viewport.width)
        let trailing = TTZipCodeReadingTools.resolvedPopoverTrailingPadding(
            forAvailableWidth: viewport.width, bottomTrailingReservedWidth: 34
        )
        XCTAssertLessThanOrEqual(cardWidth + trailing, viewport.width, "Aa card overflows the preview at \(inspectorWidth)pt")

        let requiredButtonIDs = [
            "CodeFloatingAllowEditingButton",
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
            let btn = try XCTUnwrap(findButton(id: requiredID, in: host), "Missing \(requiredID) at \(inspectorWidth)pt width")
            let rectInHost = host.convert(btn.bounds, from: btn)
            XCTAssertGreaterThanOrEqual(
                btn.bounds.height,
                27.5,
                "\(requiredID) must keep >= 28pt hit height at \(inspectorWidth)pt width"
            )
            XCTAssertGreaterThanOrEqual(
                rectInHost.minX,
                viewport.minX - 0.5,
                "\(requiredID) must not overflow left edge of the \(inspectorWidth)pt Inspector"
            )
            XCTAssertLessThanOrEqual(
                rectInHost.maxX,
                viewport.maxX + 0.5,
                "\(requiredID) must not overflow right edge of the \(inspectorWidth)pt Inspector"
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

    private func waitForEditor(in host: NSView) async throws -> NSTextView {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            flushPendingHostLayout(host)
            if let editor = findEditor(in: host), editor.string == Self.subtitleSource,
               !editor.visibleRect.isEmpty { return editor }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw NSError(domain: "CodeReadingToolsMouseTests", code: 1)
    }

    private func flushPendingHostLayout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    private func findEditor(in root: NSView) -> NSTextView? {
        if let editor = root as? NSTextView { return editor }
        for child in root.subviews {
            if let editor = findEditor(in: child) { return editor }
        }
        return nil
    }
}
