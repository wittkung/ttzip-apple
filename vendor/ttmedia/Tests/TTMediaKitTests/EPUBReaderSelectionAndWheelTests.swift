// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import WebKit
@testable import TTMediaKit

@MainActor
extension EPUBRealPageReadingAndThemeTests {
    func testPaginatedDOMWheelIsCancelledWithoutChangingPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chapter = directory.appendingPathComponent("chapter.xhtml")
        try Self.makeRichChapterXHTML(title: "Wheel", paragraphCount: 24)
            .write(to: chapter, atomically: true, encoding: .utf8)
        let controller = EPUBPaginationController()
        let harness = try makeTestHarness(
            chapterURL: chapter, baseDirectory: directory, chapterIndex: 0,
            paginationController: controller, viewportSize: NSSize(width: 380, height: 280)
        )
        defer { harness.cleanup() }
        let ready = await waitUntil(timeout: 6) { controller.isPaginationReady && controller.totalPagesInChapter > 1 }
        XCTAssertTrue(ready)
        let cancelled = await Self.evalString("""
        (function(){var event = new WheelEvent('wheel', {deltaX: 180, cancelable: true, bubbles: true});
        document.dispatchEvent(event);return event.defaultPrevented ? 'cancelled' : 'allowed';})();
        """, in: harness.webView)
        XCTAssertEqual(cancelled, "cancelled")
        XCTAssertEqual(controller.currentPageIndex, 0)
        let overflow = await Self.evalString("getComputedStyle(document.documentElement).overflowX", in: harness.webView)
        XCTAssertEqual(overflow, "hidden")
    }

    func testAnnotationHighlightMatchesAnchoredTextAndDoesNotMarkDifferentQuote() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chapter = directory.appendingPathComponent("chapter.xhtml")
        try "<html><body><p>Alpha 中文 Omega</p></body></html>".write(to: chapter, atomically: true, encoding: .utf8)
        let controller = EPUBPaginationController()
        let harness = try makeTestHarness(
            chapterURL: chapter, baseDirectory: directory, chapterIndex: 0,
            paginationController: controller, viewportSize: NSSize(width: 380, height: 280)
        )
        defer { harness.cleanup() }
        let ready = await waitUntil(timeout: 6) { controller.isPaginationReady }
        XCTAssertTrue(ready)
        let note = EPUBReaderAnnotation(
            id: "stable-note", anchor: EPUBReaderAnchor(chapterIndex: 0, blockIndex: 0, characterOffset: 6, chapterRatio: 0),
            quote: "中文", note: "Note"
        )
        let json = try XCTUnwrap(String(data: JSONEncoder().encode([note]), encoding: .utf8))
        let marked = await Self.evalString(
            EPUBReaderAnnotationScripts.highlight(json: json) + ";document.querySelector('mark').textContent", in: harness.webView
        )
        XCTAssertEqual(marked, "中文")
        let text = await Self.evalString("document.querySelector('p').textContent", in: harness.webView)
        XCTAssertEqual(text, "Alpha 中文 Omega")
    }
}
