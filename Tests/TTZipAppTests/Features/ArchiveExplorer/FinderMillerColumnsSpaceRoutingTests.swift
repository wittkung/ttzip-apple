// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import XCTest
@testable import TTZipPreviewKit
@testable import TTZipApp

@MainActor
final class FinderMillerColumnsSpaceRoutingTests: XCTestCase {
    func testSpaceActivatesFocusedInspectorControlsWhilePreservingBrowserQuickPreview() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MillerSpaceRouting-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let srtText = "1\n00:00:01,000 --> 00:00:03,000\nKeyboard Space routing\n"
        let srtURL = tempDir.appendingPathComponent("sample.srt")
        try Data(srtText.utf8).write(to: srtURL)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var previewedPaths: [String] = []
        let combined = HStack(spacing: 0) {
            FinderMillerColumnsView(
                rootDirectory: tempDir,
                initialSelectedPath: srtURL.path,
                onPreviewFile: { previewedPaths.append($0) }
            )
            .frame(width: 360, height: 360)
            TTZipCodePreviewView(
                text: srtText,
                fileURL: srtURL,
                fileName: srtURL.lastPathComponent,
                resourceContext: .diskFile(url: srtURL, fileName: srtURL.lastPathComponent, allowsEditing: true),
                pasteboard: pasteboard
            )
            .environment(\.mediaControlsVisibility, MediaControlsVisibility())
            .frame(width: 480, height: 360)
        }

        let (window, host, restoreAppHooks) = try mountKeyableFullKeyboardWindow(rootView: combined)
        defer {
            restoreAppHooks()
            window.contentView = nil
            window.close()
        }

        let editor = try await waitForMountedView(in: host, as: NSTextView.self) { _ in true }
        let aaButton = try await waitForMountedButton(id: "CodeFloatingAaToolsButton", in: host)
        let copyButton = try await waitForMountedButton(id: "CodeFloatingCopyButton", in: host)
        let allowEditingButton = try await waitForMountedButton(id: "CodeFloatingAllowEditingButton", in: host)

        _ = window.makeFirstResponder(nil)
        try dispatchSpaceKey(to: window, modifiers: [.shift], settleHost: host)
        XCTAssertEqual(previewedPaths, [], "Modified Shift+Space must not trigger browser quick preview")

        previewedPaths.removeAll()
        try dispatchSpaceKey(to: window, settleHost: host)
        XCTAssertEqual(previewedPaths, [srtURL.path], "Browser Space must open quick preview when no control owns focus")

        previewedPaths.removeAll()
        XCTAssertTrue(window.makeFirstResponder(aaButton))
        try dispatchSpaceKey(to: window, settleHost: host)
        XCTAssertEqual(previewedPaths, [], "Space on focused Aa must not trigger browser quick preview")
        let fontIncrease = try await waitForMountedButton(id: "CodeFloatingFontIncreaseButton", in: host, attempts: 12)
        XCTAssertFalse(fontIncrease.isHidden, "Space on focused Aa must open the reading tools popover")

        previewedPaths.removeAll()
        XCTAssertTrue(window.makeFirstResponder(copyButton))
        try dispatchSpaceKey(to: window, settleHost: host)
        XCTAssertEqual(previewedPaths, [], "Space on focused Copy must not trigger browser quick preview")
        XCTAssertEqual(pasteboard.string(forType: .string), srtText)

        previewedPaths.removeAll()
        XCTAssertFalse(editor.isEditable)
        XCTAssertTrue(window.makeFirstResponder(allowEditingButton))
        try dispatchSpaceKey(to: window, settleHost: host)
        XCTAssertEqual(previewedPaths, [], "Space on focused Allow Editing must not trigger browser quick preview")
        XCTAssertTrue(editor.isEditable, "Space on focused Allow Editing must enable editing")

        previewedPaths.removeAll()
        _ = window.makeFirstResponder(nil)
        try dispatchSpaceKey(to: window, settleHost: host)
        XCTAssertEqual(previewedPaths, [srtURL.path], "Returning focus to file browsing must restore Space quick preview")
    }

    private func mountKeyableFullKeyboardWindow<V: View>(
        rootView: V
    ) throws -> (NSWindow, NSHostingView<V>, () -> Void) {
        let size = NSSize(width: 840, height: 360)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -16_000, y: -16_000), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        window.makeKey()
        let fkaSelector = #selector(getter: NSApplication.isFullKeyboardAccessEnabled)
        let keyWinSelector = #selector(getter: NSApplication.keyWindow)
        let fkaMethod = try XCTUnwrap(class_getInstanceMethod(NSApplication.self, fkaSelector))
        let keyWinMethod = try XCTUnwrap(class_getInstanceMethod(NSApplication.self, keyWinSelector))
        let trueBlock: @convention(block) (AnyObject) -> Bool = { _ in true }
        let winBlock: @convention(block) (AnyObject) -> NSWindow? = { [weak window] _ in window }
        let origFka = method_setImplementation(fkaMethod, imp_implementationWithBlock(trueBlock))
        let origKeyWin = method_setImplementation(keyWinMethod, imp_implementationWithBlock(winBlock))
        return (window, host, { [weak window] in
            method_setImplementation(fkaMethod, origFka)
            method_setImplementation(keyWinMethod, origKeyWin)
            window?.orderOut(nil)
        })
    }

    private func waitForMountedButton(id: String, in root: NSView, attempts: Int = 40) async throws -> NSButton {
        try await waitForMountedView(in: root, as: NSButton.self, attempts: attempts) {
            $0.accessibilityIdentifier() == id
        }
    }

    private func waitForMountedView<T: NSView>(
        in root: NSView,
        as type: T.Type,
        attempts: Int = 40,
        where predicate: (T) -> Bool
    ) async throws -> T {
        for _ in 0..<attempts {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            if let match = findMountedView(in: root, as: type, where: predicate) {
                return match
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        return try XCTUnwrap(
            findMountedView(in: root, as: type, where: predicate),
            "Timed out waiting for \(T.self)"
        )
    }

    private func findMountedView<T: NSView>(in root: NSView, as type: T.Type, where predicate: (T) -> Bool) -> T? {
        if let typed = root as? T, predicate(typed) { return typed }
        for child in root.subviews {
            if let match = findMountedView(in: child, as: type, where: predicate) { return match }
        }
        return nil
    }

    private func dispatchSpaceKey(
        to window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [],
        settleHost: NSView
    ) throws {
        let now = ProcessInfo.processInfo.systemUptime
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: now,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: now + 0.01,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        NSApplication.shared.postEvent(keyUp, atStart: false)
        NSApplication.shared.sendEvent(keyDown)
        while let queued = NSApplication.shared.nextEvent(matching: .keyUp, until: nil, inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(queued)
        }
        settleHost.needsLayout = true
        settleHost.layoutSubtreeIfNeeded()
    }
}
