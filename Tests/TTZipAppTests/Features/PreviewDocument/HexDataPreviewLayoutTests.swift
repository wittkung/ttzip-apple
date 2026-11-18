// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import TTMediaKit
import TTZipCore
import TTZipUI
@testable import TTZipPreviewKit
@testable import TTZipApp

final class HexDataPreviewLayoutTests: XCTestCase {
    @MainActor
    func testProductHexPreviewMountsInSidebarWidths() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "HexPreview")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("fixture.bin")
        let bytes = Data((0..<512).map { UInt8($0 % 256) })
        try bytes.write(to: fileURL)

        let preview = TTZipHexPreviewView(data: bytes, fileURL: fileURL, fileName: "fixture.bin")
        let widths: [CGFloat] = [200, 260, 320, 340, 600]
        for width in widths {
            let bounds = NSRect(x: 0, y: 0, width: width, height: 400)
            let host = NSHostingView(rootView: preview.frame(width: width, height: bounds.height))
            host.sizingOptions = []
            let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }

            let mountedText = try await waitForHexBytes("00 01 02 03", in: host)
            let textView = try XCTUnwrap(mountedText, "Missing Hex bytes at \(width)pt")
            XCTAssertTrue(textView.string.hasPrefix("00000000"))
            XCTAssertFalse(textView.isEditable)
            XCTAssertEqual(host.frame.width, width)
            XCTAssertFalse(window.isVisible)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    @MainActor
    func testProductHexPreviewIdentityChangesWithBytesAndFileName() {
        let fileURL = URL(fileURLWithPath: "/tmp/fixture.bin")
        let first = TTZipHexPreviewView(data: Data([0x01, 0x02, 0x03]), fileURL: fileURL, fileName: "a.bin")
        let changedBytes = TTZipHexPreviewView(data: Data([0x01, 0x02, 0x04]), fileURL: fileURL, fileName: "a.bin")
        let changedName = TTZipHexPreviewView(data: Data([0x01, 0x02, 0x03]), fileURL: fileURL, fileName: "b.bin")
        XCTAssertNotEqual(first.taskIdentityKey, changedBytes.taskIdentityKey)
        XCTAssertNotEqual(first.taskIdentityKey, changedName.taskIdentityKey)
    }

    @MainActor
    func testHexEditorNSViewConfiguredForOuterHorizontalScroll() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "HexPreview")
        let tempFileURL = tempDir.appendingPathComponent("fixture.bin")
        let sampleBytes: [UInt8] = (0..<512).map { UInt8($0 % 256) }
        try Data(sampleBytes).write(to: tempFileURL)
        
        let testData = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        let editor = HexEditorNSView(pageData: testData, startOffset: 0)
        
        let hostingController = NSHostingController(rootView: editor.frame(width: 620, height: 300))
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 620, height: 300)
        hostingController.view.layoutSubtreeIfNeeded()
        
        // Find inner NSScrollView
        func findScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let found = findScrollView(in: sub) { return found }
            }
            return nil
        }
        
        let scrollView = findScrollView(in: hostingController.view)
        XCTAssertNotNil(scrollView, "HexEditorNSView must produce an NSScrollView")
        if let sv = scrollView {
            XCTAssertFalse(sv.hasHorizontalScroller, "Inner NSScrollView must NOT have horizontal scroller to avoid gesture collision with outer ScrollView")
            XCTAssertTrue(sv.hasVerticalScroller, "Inner NSScrollView must retain vertical scroller for pagination browsing")
        }
    }

    @MainActor
    func testArchiveHexPreviewLoadsReadOnlyBytesInNarrowSidebar() async throws {
        let bytes = Data([0x7F, 0x45, 0x4C, 0x46])
        let preview = MediaPreviewView(
            previewType: .hexViewer(bytes, nil),
            fileName: "fixture.bin",
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(
                archivePath: "/archives/sample.zip",
                entryPath: "data/fixture.bin",
                stagedReadURL: nil,
                fileName: "fixture.bin"
            )
        )
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 320)
        let host = NSHostingView(rootView: preview)
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        let mountedText = try await waitForHexBytes("7F 45 4C 46", in: host)
        let textView = try XCTUnwrap(mountedText, "The narrow archive preview must display its in-memory Hex bytes")
        XCTAssertTrue(textView.string.hasPrefix("00000000"))
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(host.frame.width, bounds.width)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    private func waitForHexBytes(
        _ bytes: String,
        in host: NSView,
        matching: (NSTextView) -> Bool = { _ in true }
    ) async throws -> NSTextView? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let textView = hexTextView(in: host), textView.string.contains(bytes), matching(textView) {
                return textView
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @MainActor
    private func hexTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        return view.subviews.lazy.compactMap { self.hexTextView(in: $0) }.first
    }

    @MainActor
    func testChunkAcceptanceRejectsStalePages() {
        let urlA = URL(fileURLWithPath: "/tmp/sample_a.bin")
        let urlB = URL(fileURLWithPath: "/tmp/sample_b.bin")

        // Exact match
        XCTAssertTrue(
            HexChunkAcceptance.accepts(
                isCancelled: false,
                expectedGeneration: 1,
                activeGeneration: 1,
                requestedURL: urlA,
                currentURL: urlA,
                requestedOffset: 0,
                currentOffset: 0
            )
        )

        // Cancelled
        XCTAssertFalse(
            HexChunkAcceptance.accepts(
                isCancelled: true,
                expectedGeneration: 1,
                activeGeneration: 1,
                requestedURL: urlA,
                currentURL: urlA,
                requestedOffset: 0,
                currentOffset: 0
            )
        )

        // Stale generation
        XCTAssertFalse(
            HexChunkAcceptance.accepts(
                isCancelled: false,
                expectedGeneration: 1,
                activeGeneration: 2,
                requestedURL: urlA,
                currentURL: urlA,
                requestedOffset: 0,
                currentOffset: 0
            )
        )

        // URL mismatch
        XCTAssertFalse(
            HexChunkAcceptance.accepts(
                isCancelled: false,
                expectedGeneration: 1,
                activeGeneration: 1,
                requestedURL: urlA,
                currentURL: urlB,
                requestedOffset: 0,
                currentOffset: 0
            )
        )

        // Offset mismatch
        XCTAssertFalse(
            HexChunkAcceptance.accepts(
                isCancelled: false,
                expectedGeneration: 1,
                activeGeneration: 1,
                requestedURL: urlA,
                currentURL: urlA,
                requestedOffset: 0,
                currentOffset: 2048
            )
        )
    }

    @MainActor
    func testProductHexPreviewAppliesExactLegacyAccentPaletteToMountedRuns() async throws {
        let sample = Data([
            0x00, 0x41, 0x80, 0x7F, 0x10, 0x20, 0x30, 0x40,
            0x50, 0xFF, 0x61, 0x00, 0x7E, 0x81, 0x90, 0xA0
        ])
        let preview = TTZipHexPreviewView(data: sample, fileURL: nil, fileName: "palette.bin")
        let bounds = NSRect(x: 0, y: 0, width: 640, height: 320)
        let host = NSHostingView(rootView: preview.frame(width: bounds.width, height: bounds.height))
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        let mountedText = try await waitForHexBytes("00 41 80 7F", in: host)
        let textView = try XCTUnwrap(mountedText)
        let storage = try XCTUnwrap(textView.textStorage)

        let offset = NSColor(red: 0.20, green: 0.70, blue: 0.50, alpha: 1)
        let highByte = NSColor(red: 0.75, green: 0.45, blue: 0.90, alpha: 1)
        XCTAssertEqual(try foregroundColor(in: storage, matching: "00000000"), offset)
        XCTAssertEqual(try foregroundColor(in: storage, matching: "80"), highByte)
        XCTAssertEqual(try foregroundColor(in: storage, matching: "FF"), highByte)
        XCTAssertEqual(try foregroundColor(in: storage, matching: "41"), NSColor.labelColor)
        XCTAssertEqual(try foregroundColor(in: storage, matching: "00 "), NSColor.labelColor.withAlphaComponent(0.32))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testNativeHexEditorRecolorsMountedTextWithoutResettingSelection() async throws {
        let row: [UInt8] = [0x00, 0x41, 0x80, 0x7F, 0x10, 0x20, 0x30, 0x40, 0x50, 0xFF, 0x61, 0, 0, 0, 0, 0]
        let sample = Data(Array(repeating: row, count: 32).joined())
        let editor = HexEditorNSView(pageData: sample, startOffset: 0)
        let bounds = NSRect(x: 0, y: 0, width: 640, height: 120)
        let host = NSHostingView(rootView: editor.frame(width: bounds.width, height: bounds.height))
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        let mountedText = try await waitForHexBytes("00 41 80 7F", in: host)
        let textView = try XCTUnwrap(mountedText)
        let storage = try XCTUnwrap(textView.textStorage)
        let initialString = textView.string

        XCTAssertEqual(try foregroundColor(in: storage, matching: "00000000"), NSColor.secondaryLabelColor)
        XCTAssertEqual(try foregroundColor(in: storage, matching: "80"), NSColor.labelColor)
        let selection = NSRange(location: 9, length: 2)
        textView.setSelectedRange(selection)
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        clipView.scroll(to: NSPoint(x: 0, y: 60))
        let scrollOrigin = clipView.bounds.origin
        XCTAssertGreaterThan(scrollOrigin.y, 0)

        let offset = NSColor.systemOrange
        let highByte = NSColor.systemTeal
        let recoloredEditor = HexEditorNSView(
            pageData: sample,
            startOffset: 0,
            offsetColor: offset,
            highByteColor: highByte
        )
        host.rootView = recoloredEditor.frame(width: bounds.width, height: bounds.height)
        let recoloredText = try await waitForHexBytes("00 41 80 7F", in: host) { view in
            view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == offset
        }

        XCTAssertIdentical(try XCTUnwrap(recoloredText), textView)
        XCTAssertEqual(try foregroundColor(in: storage, matching: "80"), highByte)
        XCTAssertEqual(try foregroundColor(in: storage, matching: "FF"), highByte)
        XCTAssertEqual(textView.string, initialString)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertEqual(clipView.bounds.origin, scrollOrigin)
        XCTAssertFalse(window.isVisible)
    }

    private func foregroundColor(in storage: NSTextStorage, matching substring: String) throws -> NSColor {
        let fullText = storage.string as NSString
        let index = fullText.range(of: substring).location
        let start = try XCTUnwrap(index == NSNotFound ? nil : index, "Missing expected run \(substring)")
        let value = storage.attribute(.foregroundColor, at: start, effectiveRange: nil)
        return try XCTUnwrap(value as? NSColor)
    }
}
