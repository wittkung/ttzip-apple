// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import XCTest
@testable import TTZipUI

@MainActor
final class OmnibarFieldEditorFocusTests: XCTestCase {
    func testFocusRequestedBeforeWindowAttachmentMakesTailVisible() throws {
        let field = makeLongPathField()
        field.setFocusRequested(true)
        XCTAssertNil(field.window)
        let window = makeWindow(containing: field)
        defer { window.close() }
        field.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (field.stringValue as NSString).length, length: 0))
        let manager = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        manager.ensureLayout(for: container)
        XCTAssertGreaterThan(manager.numberOfGlyphs, 0)
        let lastGlyph = manager.boundingRect(
            forGlyphRange: NSRange(location: manager.numberOfGlyphs - 1, length: 1), in: container
        ).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        XCTAssertTrue(editor.visibleRect.intersects(lastGlyph), "The path suffix must actually be visible, not only stored in stringValue")
    }

    func testRepeatedUpdatesAndLayoutPreserveUserSelection() throws {
        let field = makeLongPathField()
        let window = makeWindow(containing: field)
        defer { window.close() }
        field.setFocusRequested(true)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let userSelection = NSRange(location: 7, length: 9)
        editor.setSelectedRange(userSelection)
        editor.scrollRangeToVisible(userSelection)
        for _ in 0..<3 {
            field.setFocusRequested(true)
            field.needsLayout = true
            field.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), userSelection)
        field.setFocusRequested(false)
        XCTAssertFalse(window.firstResponder === editor)
        field.setFocusRequested(true)
        let resumed = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(resumed.selectedRange(), NSRange(location: (field.stringValue as NSString).length, length: 0))
    }

    private func makeLongPathField() -> OmnibarTextField.CustomNSTextField {
        let field = OmnibarTextField.CustomNSTextField(frame: NSRect(x: 12, y: 12, width: 220, height: 24))
        field.isBordered = false
        field.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = "/Users/tester/Documents/video_dev/daily/last-subdirectory"
        return field
    }

    private func makeWindow(containing field: NSTextField) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        return window
    }
}
