// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import WebKit
@testable import TTMediaKit

@MainActor
private final class TestFocusableFileListView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class EPUBPaginationKeyboardAndFirstScreenPerfTests: XCTestCase {

    override func tearDown() {
        EPUBChapterContentLoaderActor.customDataProvider = nil
        super.tearDown()
    }

    // MARK: - 1. Multi-Page In-Chapter Stepping & Cross-Chapter Boundary Transitions (Real WKWebView)

    func testMultiPageChapterSteppingAndCrossChapterBoundariesInRealWKWebView() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-pager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ch0URL = tempDir.appendingPathComponent("ch0.xhtml")
        let ch1URL = tempDir.appendingPathComponent("ch1.xhtml")
        try Self.makeLongChapterXHTML(title: "Chapter 1", paragraphCount: 28).write(to: ch0URL, atomically: true, encoding: .utf8)
        try Self.makeLongChapterXHTML(title: "Chapter 2", paragraphCount: 18).write(to: ch1URL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2)
        let host = try makeHostedEPUBWebView(
            chapterURL: ch0URL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 360, height: 280)
        )
        defer { host.cleanup() }

        let loadedCh0 = await waitUntil(timeout: 6.0) {
            controller.totalPagesInChapter >= 3 && host.coordinator.latestFirstScreenMetrics != nil
        }
        XCTAssertTrue(loadedCh0, "Chapter 0 should paginate into at least 3 pages in 360x280 viewport")
        let ch0TotalPages = controller.totalPagesInChapter
        XCTAssertEqual(controller.currentChapterIndex, 0)
        XCTAssertEqual(controller.currentPageIndex, 0)

        let clampStart = controller.handleHorizontalArrow(isRightArrow: false)
        XCTAssertEqual(clampStart, .clampedAtBookStart(chapterIndex: 0, pageIndex: 0))
        XCTAssertEqual(controller.boundaryNotice, .bookStart)

        for expectedPage in 1..<ch0TotalPages {
            let outcome = controller.handleHorizontalArrow(isRightArrow: true)
            XCTAssertEqual(
                outcome,
                .turnedPageInChapter(chapterIndex: 0, pageIndex: expectedPage, totalPages: ch0TotalPages)
            )
            let scrolled = await waitUntil(timeout: 2.0) {
                await Self.currentScrollPageIndex(in: host.webView) == expectedPage
            }
            XCTAssertTrue(scrolled, "WKWebView should scroll to page column \(expectedPage)")
        }

        var requestedChapterChange: (Int, EPUBBoundaryLanding)?
        controller.onRequestChapterIndexChange = { idx, landing in
            requestedChapterChange = (idx, landing)
        }
        let crossForward = controller.handleHorizontalArrow(isRightArrow: true)
        XCTAssertEqual(crossForward, .transitionedChapter(fromChapter: 0, toChapter: 1, landing: .firstPage))
        XCTAssertEqual(requestedChapterChange?.0, 1)
        XCTAssertEqual(requestedChapterChange?.1, .firstPage)

        host.updateChapter(url: ch1URL, chapterIndex: 1)
        let loadedCh1 = await waitUntil(timeout: 6.0) {
            !controller.isChapterTransitionInFlight && controller.currentChapterIndex == 1 && controller.totalPagesInChapter >= 2
        }
        XCTAssertTrue(loadedCh1, "Chapter 1 should load and paginate into >= 2 pages")
        XCTAssertEqual(controller.currentPageIndex, 0)

        let ch1TotalPages = controller.totalPagesInChapter
        for _ in 1..<ch1TotalPages {
            _ = controller.handleHorizontalArrow(isRightArrow: true)
        }
        XCTAssertEqual(controller.currentPageIndex, ch1TotalPages - 1)
        let clampEnd = controller.handleHorizontalArrow(isRightArrow: true)
        XCTAssertEqual(
            clampEnd,
            .clampedAtBookEnd(chapterIndex: 1, pageIndex: ch1TotalPages - 1, totalPages: ch1TotalPages)
        )
        XCTAssertEqual(controller.boundaryNotice, .bookEnd)

        while controller.currentPageIndex > 0 {
            _ = controller.handleHorizontalArrow(isRightArrow: false)
        }
        let crossBackward = controller.handleHorizontalArrow(isRightArrow: false)
        XCTAssertEqual(crossBackward, .transitionedChapter(fromChapter: 1, toChapter: 0, landing: .lastPage))

        host.updateChapter(url: ch0URL, chapterIndex: 0)
        let landedCh0LastPage = await waitUntil(timeout: 6.0) {
            !controller.isChapterTransitionInFlight
                && controller.currentChapterIndex == 0
                && controller.currentPageIndex == controller.totalPagesInChapter - 1
                && controller.totalPagesInChapter >= 3
        }
        XCTAssertTrue(landedCh0LastPage, "Moving backward from Ch1 P0 must land on the LAST page of Ch0")
        let actualScrollPage = await Self.currentScrollPageIndex(in: host.webView)
        XCTAssertEqual(actualScrollPage, controller.totalPagesInChapter - 1)
    }

    // MARK: - 2. Rapid Key Serialization & RTL / Vertical-RL Direction Semantics

    func testRapidRepeatedKeyPressesAndReadingDirections() {
        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2, readingDirection: .leftToRight)
        controller.didSynchronizeWebViewPagination(
            chapterIndex: 0,
            pageIndex: 0,
            totalPages: 2,
            anchorBlockIndex: 0,
            readingDirectionRaw: "ltr"
        )

        _ = controller.handleHorizontalArrow(isRightArrow: true)
        XCTAssertEqual(controller.currentPageIndex, 1)

        _ = controller.handleHorizontalArrow(isRightArrow: true)
        XCTAssertTrue(controller.isChapterTransitionInFlight)
        XCTAssertEqual(controller.currentChapterIndex, 1)

        _ = controller.handleHorizontalArrow(isRightArrow: true)
        _ = controller.handleHorizontalArrow(isRightArrow: true)

        controller.didSynchronizeWebViewPagination(
            chapterIndex: 1,
            pageIndex: 0,
            totalPages: 4,
            anchorBlockIndex: 0,
            readingDirectionRaw: "ltr"
        )
        XCTAssertFalse(controller.isChapterTransitionInFlight)
        XCTAssertEqual(controller.currentChapterIndex, 1)
        XCTAssertEqual(controller.currentPageIndex, 2)

        controller.setReadingDirection(.rightToLeft)
        _ = controller.handleHorizontalArrow(isRightArrow: false)
        XCTAssertEqual(controller.currentPageIndex, 3)
        _ = controller.handleHorizontalArrow(isRightArrow: true)
        XCTAssertEqual(controller.currentPageIndex, 2)

        controller.setReadingDirection(.verticalRightToLeft)
        _ = controller.handleHorizontalArrow(isRightArrow: false)
        XCTAssertEqual(controller.currentPageIndex, 3)
    }

    // MARK: - 3. Real Focus Transitions, DOM Input, Search Field, Chinese IME & Multi-Window Isolation

    func testKeyboardOwnershipFocusPathsInputIMEGuardAndMultiWindowIsolation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-focus-ime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chURL = tempDir.appendingPathComponent("interactive.xhtml")
        try Self.makeInteractiveChapterWithInputXHTML().write(to: chURL, atomically: true, encoding: .utf8)

        let controllerA = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 1)
        let hostA = try makeSplitWindowEPUBWorkspace(
            chapterURL: chURL,
            baseDirectory: tempDir,
            paginationController: controllerA
        )
        defer { hostA.cleanup() }

        let controllerB = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 1)
        let hostB = try makeSplitWindowEPUBWorkspace(
            chapterURL: chURL,
            baseDirectory: tempDir,
            paginationController: controllerB
        )
        defer { hostB.cleanup() }

        let readyA = await waitUntil(timeout: 6.0) { controllerA.totalPagesInChapter >= 3 }
        let readyB = await waitUntil(timeout: 6.0) { controllerB.totalPagesInChapter >= 3 }
        XCTAssertTrue(readyA && readyB, "Both windows must load and paginate the interactive chapter")

        let coord = TTPreviewKeyboardOwnershipCoordinator.shared
        let winNumA = hostA.window.windowNumber
        let winNumB = hostB.window.windowNumber
        var eventTime: TimeInterval = 100.0
        func nextKeyEvent(isRight: Bool, in window: NSWindow) throws -> NSEvent {
            eventTime += 0.05
            return try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: NSPoint(x: 400, y: 200),
                    modifierFlags: [],
                    timestamp: eventTime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: isRight ? "\u{F703}" : "\u{F702}",
                    charactersIgnoringModifiers: isRight ? "\u{F703}" : "\u{F702}",
                    isARepeat: false,
                    keyCode: isRight ? 124 : 123
                )
            )
        }

        // (A) Initial focus on File List in Window A -> EPUB does NOT own arrow keys
        XCTAssertTrue(hostA.window.makeFirstResponder(hostA.fileListView))
        coord.handleWindowMouseDown(in: hostA.window, locationInWindow: NSPoint(x: 60, y: 200))
        let initialQuery = coord.queryOwnership(windowNumber: winNumA)
        XCTAssertEqual(initialQuery.contractVersion, .v2)
        XCTAssertFalse(initialQuery.ownsHorizontalArrowKeys)
        XCTAssertEqual(initialQuery.focusSource, .none)
        let fileListArrow = try nextKeyEvent(isRight: true, in: hostA.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: fileListArrow), .passThrough)
        XCTAssertEqual(controllerA.currentPageIndex, 0)

        // (B) Reading Area holds firstResponder -> Click outside WITHOUT changing firstResponder -> Arrow keys pass through
        coord.handleWindowMouseDown(in: hostA.window, locationInWindow: NSPoint(x: 450, y: 180))
        XCTAssertTrue(hostA.window.makeFirstResponder(hostA.webView))
        XCTAssertTrue(coord.queryOwnership(windowNumber: winNumA).ownsHorizontalArrowKeys)
        XCTAssertEqual(coord.queryOwnership(windowNumber: winNumA).focusSource, .readingArea)
        let readArrow1 = try nextKeyEvent(isRight: true, in: hostA.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: readArrow1), .consumedByPreviewOwner)
        XCTAssertEqual(controllerA.currentPageIndex, 1)

        // Click outside reader (e.g. SwiftUI file list row/empty space) while window.firstResponder stays on webView
        coord.handleWindowMouseDown(in: hostA.window, locationInWindow: NSPoint(x: 60, y: 200))
        XCTAssertTrue(hostA.window.firstResponder === hostA.webView, "Responder intentionally unchanged to test stale-responder guard")
        XCTAssertFalse(coord.queryOwnership(windowNumber: winNumA).ownsHorizontalArrowKeys, "Stale firstResponder must not override outside-click release")
        XCTAssertFalse(coord.queryOwnership(windowNumber: winNumA).ownsHorizontalArrowKeys, "Repeated ownership query must stay false")
        let staleRespArrow = try nextKeyEvent(isRight: true, in: hostA.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: staleRespArrow), .passThrough)
        XCTAssertEqual(controllerA.currentPageIndex, 1, "Arrow key after outside click must pass through even if responder stayed on webView")

        // Re-acquire via keyboard focus (becomeFirstResponder) -> ownership restored
        XCTAssertTrue(hostA.webView.becomeFirstResponder())
        XCTAssertTrue(coord.queryOwnership(windowNumber: winNumA).ownsHorizontalArrowKeys)
        let kbRefocusArrow = try nextKeyEvent(isRight: true, in: hostA.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: kbRefocusArrow), .consumedByPreviewOwner)
        XCTAssertEqual(controllerA.currentPageIndex, 2)

        // Click outside again without changing responder -> released; then re-click reading area -> ownership restored
        coord.handleWindowMouseDown(in: hostA.window, locationInWindow: NSPoint(x: 60, y: 200))
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: try nextKeyEvent(isRight: false, in: hostA.window)), .passThrough)
        XCTAssertEqual(controllerA.currentPageIndex, 2)
        coord.handleWindowMouseDown(in: hostA.window, locationInWindow: NSPoint(x: 450, y: 180))
        XCTAssertTrue(coord.queryOwnership(windowNumber: winNumA).ownsHorizontalArrowKeys)

        // (C) Toolbar -> Reading Area
        coord.handleWindowMouseDown(in: hostA.window, locationInWindow: NSPoint(x: 60, y: 200))
        XCTAssertTrue(hostA.window.makeFirstResponder(hostA.fileListView))
        XCTAssertFalse(coord.queryOwnership(windowNumber: winNumA).ownsHorizontalArrowKeys)
        coord.handleWindowMouseDown(in: hostA.window, locationInWindow: NSPoint(x: 450, y: 385))
        XCTAssertTrue(coord.queryOwnership(windowNumber: winNumA).ownsHorizontalArrowKeys)
        let afterToolbarArrow = try nextKeyEvent(isRight: false, in: hostA.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: afterToolbarArrow), .consumedByPreviewOwner)
        XCTAssertEqual(controllerA.currentPageIndex, 1)

        // (D) Real DOM <input> Focus Enter & Leave via readerControlWorld WKScriptMessageHandler
        await Self.evalInControlWorld(
            "var inp = document.getElementById('chapter-note'); inp.focus(); true;",
            in: hostA.webView
        )
        let domInputFocused = await waitUntil(timeout: 2.0) {
            coord.queryOwnership(windowNumber: winNumA).isTextInputActive
        }
        XCTAssertTrue(domInputFocused, "Focusing DOM <input> must notify coordinator via readerControlWorld handler")
        let domInputArrow = try nextKeyEvent(isRight: true, in: hostA.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: domInputArrow), .yieldToTextInput)
        XCTAssertEqual(controllerA.currentPageIndex, 1)

        await Self.evalInControlWorld(
            "var inp = document.getElementById('chapter-note'); inp.blur(); true;",
            in: hostA.webView
        )
        let domInputBlurred = await waitUntil(timeout: 2.0) {
            !coord.queryOwnership(windowNumber: winNumA).isTextInputActive
        }
        XCTAssertTrue(domInputBlurred, "Blurring DOM <input> must clear DOM input state")
        let postBlurArrow = try nextKeyEvent(isRight: true, in: hostA.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: postBlurArrow), .consumedByPreviewOwner)
        XCTAssertEqual(controllerA.currentPageIndex, 2)

        // (E) Real AppKit Search Field + Native NSTextInputClient Commit & Cancel (NO override flags!)
        let emptyRange = NSRange(location: NSNotFound, length: 0)
        hostA.searchField.stringValue = "归档"
        XCTAssertTrue(hostA.window.makeFirstResponder(hostA.searchField))
        (hostA.window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 0))
        let searchEditor = try XCTUnwrap(hostA.window.firstResponder as? NSTextInputClient)
        searchEditor.setMarkedText("sou suo", selectedRange: NSRange(location: 7, length: 0), replacementRange: emptyRange)
        XCTAssertTrue(searchEditor.hasMarkedText())
        let searchQuery = coord.queryOwnership(windowNumber: winNumA)
        XCTAssertTrue(searchQuery.isTextInputActive)
        XCTAssertFalse(searchQuery.ownsHorizontalArrowKeys)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: try nextKeyEvent(isRight: true, in: hostA.window)), .yieldToTextInput)
        XCTAssertEqual(controllerA.currentPageIndex, 2)
        // Cancel composition while preserving the existing Chinese archive text.
        searchEditor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: emptyRange)
        searchEditor.unmarkText()
        XCTAssertFalse(searchEditor.hasMarkedText())
        XCTAssertEqual((hostA.window.firstResponder as? NSTextView)?.string, "归档")
        // Commit composition and append the Chinese search text.
        searchEditor.setMarkedText("sou suo", selectedRange: NSRange(location: 7, length: 0), replacementRange: emptyRange)
        searchEditor.insertText("搜索", replacementRange: emptyRange)
        XCTAssertFalse(searchEditor.hasMarkedText())
        XCTAssertEqual((hostA.window.firstResponder as? NSTextView)?.string, "归档搜索")

        // Return focus to Reading Area
        XCTAssertTrue(hostA.window.makeFirstResponder(hostA.webView))
        coord.handleWindowMouseDown(in: hostA.window, locationInWindow: NSPoint(x: 450, y: 180))

        // (F) Native WKWebView text-input pipeline: cancellation, commit and ownership recovery.
        await Self.evalInControlWorld(
            "var inp = document.getElementById('chapter-note'); inp.focus(); inp.setSelectionRange(inp.value.length, inp.value.length); inp.value;",
            in: hostA.webView
        )
        let webInputClient = try XCTUnwrap((hostA.webView as AnyObject) as? NSTextInputClient)
        webInputClient.setMarkedText("zhong wen", selectedRange: NSRange(location: 9, length: 0), replacementRange: emptyRange)
        let markedDelivered = await waitUntil(timeout: 2.0) {
            let val = await Self.evalInControlWorld("document.getElementById('chapter-note').value", in: hostA.webView)
            return val == "笔记zhong wen" && coord.queryOwnership(windowNumber: winNumA).isTextInputActive
        }
        XCTAssertTrue(markedDelivered, "Native WKWebView setMarkedText must deliver composition text and mark input active")
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: try nextKeyEvent(isRight: false, in: hostA.window)), .yieldToTextInput)
        XCTAssertEqual(controllerA.currentPageIndex, 2, "Candidate arrow key during composition must not turn page")

        // Cancel composition: remove the marked Latin text while preserving the existing Chinese note.
        webInputClient.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: emptyRange)
        webInputClient.unmarkText()
        let cancelPreserved = await waitUntil(timeout: 2.0) {
            await Self.evalInControlWorld("document.getElementById('chapter-note').value", in: hostA.webView) == "笔记"
        }
        XCTAssertTrue(cancelPreserved, "Cancelling marked text must preserve existing text '笔记' without deletion")

        // Re-enter marked text and commit Chinese text into the existing note input.
        webInputClient.setMarkedText("zhong wen", selectedRange: NSRange(location: 9, length: 0), replacementRange: emptyRange)
        _ = await waitUntil(timeout: 2.0) {
            await Self.evalInControlWorld("document.getElementById('chapter-note').value", in: hostA.webView) == "笔记zhong wen"
        }
        webInputClient.insertText("中文", replacementRange: emptyRange)
        let commitDelivered = await waitUntil(timeout: 2.0) {
            await Self.evalInControlWorld("document.getElementById('chapter-note').value", in: hostA.webView) == "笔记中文"
        }
        XCTAssertTrue(commitDelivered, "Native WKWebView insertText must commit '中文' into DOM <input> ('笔记中文')")

        // Blur DOM <input> after commit -> keyboard ownership returns to EPUB reader
        await Self.evalInControlWorld("document.getElementById('chapter-note').blur(); 'ok';", in: hostA.webView)
        let ownershipRestored = await waitUntil(timeout: 2.0) {
            let q = coord.queryOwnership(windowNumber: winNumA)
            return !q.isTextInputActive && q.ownsHorizontalArrowKeys
        }
        XCTAssertTrue(ownershipRestored, "After IME commit and input blur, reader must reclaim arrow key ownership")
        let postIMEArrow = try nextKeyEvent(isRight: false, in: hostA.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: postIMEArrow), .consumedByPreviewOwner)
        XCTAssertEqual(controllerA.currentPageIndex, 1)

        // (G) Multi-Window Isolation (Window B file list focused while Window A reader is focused)
        XCTAssertTrue(hostB.window.makeFirstResponder(hostB.fileListView))
        coord.handleWindowMouseDown(in: hostB.window, locationInWindow: NSPoint(x: 60, y: 200))
        XCTAssertFalse(coord.queryOwnership(windowNumber: winNumB).ownsHorizontalArrowKeys)
        let windowBArrow = try nextKeyEvent(isRight: true, in: hostB.window)
        XCTAssertEqual(coord.handleOrBlockOuterHorizontalArrow(event: windowBArrow), .passThrough)
        XCTAssertEqual(controllerB.currentPageIndex, 0)
        XCTAssertEqual(controllerA.currentPageIndex, 1)
    }

    // MARK: - 4. Multi-Block & Single Long Paragraph Anchor Preservation Across Font Size & Resize

    func testAnchorPreservationAcrossFontSizeAndViewportResizeInRealWKWebView() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Part A: Multi-block chapter anchor preservation
        let multiBlockURL = tempDir.appendingPathComponent("multi_block.xhtml")
        try Self.makeLongChapterXHTML(title: "Anchor Preservation", paragraphCount: 30)
            .write(to: multiBlockURL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 1)
        let host = try makeHostedEPUBWebView(
            chapterURL: multiBlockURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 320, height: 300)
        )
        defer { host.cleanup() }

        let initialReady = await waitUntil(timeout: 6.0) { controller.totalPagesInChapter >= 4 }
        XCTAssertTrue(initialReady)

        _ = controller.handleHorizontalArrow(isRightArrow: true)
        _ = controller.handleHorizontalArrow(isRightArrow: true)
        let reachedPage2 = await waitUntil(timeout: 2.0) {
            controller.currentPageIndex == 2 && (controller.anchorBlockIndex ?? 0) > 0
        }
        XCTAssertTrue(reachedPage2)
        let savedAnchor = try XCTUnwrap(controller.anchorBlockIndex)
        let pagesAt17pt = controller.totalPagesInChapter

        host.updateTypography(fontSize: 26.0, fontStyle: "serif", theme: "sepia")
        let relayoutAfterFont = await waitUntil(timeout: 3.0) {
            controller.totalPagesInChapter > pagesAt17pt && controller.currentPageIndex > 2
        }
        XCTAssertTrue(relayoutAfterFont)
        XCTAssertEqual(controller.anchorBlockIndex, savedAnchor)

        // Part B: Single giant paragraph spanning multiple pages (intra-block anchorCharOffset preservation)
        let singleParaURL = tempDir.appendingPathComponent("single_giant_paragraph.xhtml")
        try Self.makeSingleGiantParagraphXHTML().write(to: singleParaURL, atomically: true, encoding: .utf8)

        let singleParaController = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 1)
        let singleParaHost = try makeHostedEPUBWebView(
            chapterURL: singleParaURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: singleParaController,
            viewportSize: NSSize(width: 360, height: 280)
        )
        defer { singleParaHost.cleanup() }

        let giantReady = await waitUntil(timeout: 6.0) {
            singleParaController.totalPagesInChapter >= 5
        }
        XCTAssertTrue(giantReady, "Single giant paragraph should span at least 5 pages")

        // Advance to Page 2 (3rd page of the single <p>)
        _ = singleParaController.handleHorizontalArrow(isRightArrow: true)
        _ = singleParaController.handleHorizontalArrow(isRightArrow: true)
        let giantAtPage2 = await waitUntil(timeout: 2.0) {
            singleParaController.currentPageIndex == 2 && singleParaController.anchorCharOffset > 300
        }
        XCTAssertTrue(giantAtPage2, "Stepping into page 2 of a single long <p> must capture intra-block anchorCharOffset > 300")
        let capturedCharOffset = singleParaController.anchorCharOffset
        let giantPagesAt17 = singleParaController.totalPagesInChapter

        // Increase font size from 17pt to 25pt -> must NOT reset to page 0 of the giant paragraph!
        singleParaHost.updateTypography(fontSize: 25.0, fontStyle: "serif", theme: "dark")
        let giantRelayoutFont = await waitUntil(timeout: 3.0) {
            singleParaController.totalPagesInChapter > giantPagesAt17 && singleParaController.currentPageIndex > 2
        }
        XCTAssertTrue(
            giantRelayoutFont,
            "Changing font size in the middle of a multi-page paragraph must land on the new page for anchorCharOffset (\(singleParaController.currentPageIndex)), never resetting to page 0"
        )
        XCTAssertEqual(singleParaController.anchorCharOffset, capturedCharOffset)

        // Resize viewport from 360x280 to 460x320 -> still preserves intra-block position (> page 0)
        let pagesAt25 = singleParaController.totalPagesInChapter
        singleParaHost.webView.setFrameSize(NSSize(width: 460, height: 320))
        let giantRelayoutResize = await waitUntil(timeout: 3.0) {
            singleParaController.totalPagesInChapter < pagesAt25 && singleParaController.currentPageIndex > 0
        }
        XCTAssertTrue(giantRelayoutResize, "Viewport resize on a single multi-page paragraph must not jump back to page 0")
    }

    // MARK: - 5. VFS & Disk Stage Telemetry + Authenticated Resource Cache & Boundary Guard

    func testVFSMemoryBackedEPUBFirstScreenPerfTelemetryAndBookBoundarySecurity() async throws {
        await EPUBChapterContentLoaderActor.shared.clearAuthenticatedCache()
        let vfsChapterURL = try XCTUnwrap(URL(string: "ttzip-vfs://archive-perf-test/OEBPS/Text/ch1.xhtml"))
        let vfsBaseDir = try XCTUnwrap(URL(string: "ttzip-vfs://archive-perf-test/OEBPS/"))
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let xhtmlWithAssets = """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <link rel="stylesheet" href="../Styles/book.css"/>
        </head>
        <body>
            <img src="../Images/cover.png" alt="in-book"/>
            <img src="ttzip-vfs://other-archive/secret.png" alt="cross-archive"/>
            \( (0..<16).map { "<p id='p\($0)'>Paragraph \($0) with sufficient text to span multiple columns in the VFS EPUB test.</p>" }.joined(separator: "\n") )
        </body>
        </html>
        """

        EPUBChapterContentLoaderActor.customDataProvider = { url in
            switch url.absoluteString {
            case "ttzip-vfs://archive-perf-test/OEBPS/Text/ch1.xhtml":
                return Data(xhtmlWithAssets.utf8)
            case "ttzip-vfs://archive-perf-test/OEBPS/Styles/book.css":
                return Data("body { letter-spacing: 0.2px; }".utf8)
            case "ttzip-vfs://archive-perf-test/OEBPS/Images/cover.png":
                return pngBytes
            default:
                return nil
            }
        }

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 1)
        let host = try makeHostedEPUBWebView(
            chapterURL: vfsChapterURL,
            baseDirectory: vfsBaseDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 360, height: 260)
        )
        defer { host.cleanup() }

        let telemetryReady = await waitUntil(timeout: 6.0) {
            controller.latestFirstScreenMetrics != nil
        }
        XCTAssertTrue(telemetryReady)

        let metrics = try XCTUnwrap(controller.latestFirstScreenMetrics)
        XCTAssertTrue(metrics.isVFSSource)
        XCTAssertGreaterThanOrEqual(metrics.chapterReadMs, 0.0)
        XCTAssertGreaterThanOrEqual(metrics.resourceAuthAndInlineMs, 0.0)
        XCTAssertGreaterThanOrEqual(metrics.webKitLoadToFinishMs, 0.0)
        XCTAssertGreaterThanOrEqual(metrics.firstPaginationLayoutCallbackMs, 0.0)
        XCTAssertGreaterThan(metrics.totalToPaginationCallbackMs, 0.0)
        XCTAssertEqual(metrics.inlinedResourceCount, 2, "Only the 2 in-boundary resources (book.css & cover.png) may be inlined")
    }

    // MARK: - Helpers

    private struct SplitWindowEPUBWorkspace {
        let window: NSWindow
        let fileListView: TestFocusableFileListView
        let searchField: NSSearchField
        let readerContainerView: EPUBReaderFocusContainerView
        let webView: EPUBReaderWKWebView
        let coordinator: EPUBNativeWKWebView.Coordinator

        @MainActor
        func cleanup() {
            EPUBNativeWKWebView.dismantleNSView(webView, coordinator: coordinator)
            window.orderOut(nil)
        }
    }

    private func makeSplitWindowEPUBWorkspace(
        chapterURL: URL,
        baseDirectory: URL,
        paginationController: EPUBPaginationController
    ) throws -> SplitWindowEPUBWorkspace {
        let windowSize = NSSize(width: 720, height: 400)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let rootView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        window.contentView = rootView

        let searchField = NSSearchField(frame: NSRect(x: 10, y: 360, width: 200, height: 28))
        let fileListView = TestFocusableFileListView(frame: NSRect(x: 0, y: 0, width: 220, height: 350))
        let readerContainerView = EPUBReaderFocusContainerView(frame: NSRect(x: 220, y: 0, width: 500, height: 400))
        readerContainerView.readerInstanceID = paginationController.instanceID

        let (webView, coordinator) = makeConfiguredReaderWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 360),
            chapterURL: chapterURL,
            baseDirectory: baseDirectory,
            chapterIndex: 0,
            paginationController: paginationController
        )
        readerContainerView.addSubview(webView)
        rootView.addSubview(searchField)
        rootView.addSubview(fileListView)
        rootView.addSubview(readerContainerView)

        TTPreviewKeyboardOwnershipCoordinator.shared.bindReaderViews(
            instanceID: paginationController.instanceID,
            webView: webView,
            containerView: readerContainerView
        )
        return SplitWindowEPUBWorkspace(
            window: window,
            fileListView: fileListView,
            searchField: searchField,
            readerContainerView: readerContainerView,
            webView: webView,
            coordinator: coordinator
        )
    }

    private struct HostedEPUBWebView {
        let window: NSWindow
        let webView: EPUBReaderWKWebView
        let coordinator: EPUBNativeWKWebView.Coordinator
        let baseDirectory: URL
        let paginationController: EPUBPaginationController

        @MainActor
        func updateChapter(url: URL, chapterIndex: Int) {
            let rep = EPUBNativeWKWebView(
                chapterURL: url,
                baseDirectory: baseDirectory,
                fontSize: Double(coordinator.currentFontSize ?? 17.0),
                fontStyle: coordinator.currentFontStyle ?? "serif",
                readerTheme: coordinator.currentTheme ?? "light",
                chapterIndex: chapterIndex,
                paginationController: paginationController,
                layoutMode: paginationController.layoutMode.rawValue
            )
            coordinator.parent = rep
            let clean = EPUBNativeWKWebView.stripFragment(from: url)
            coordinator.loadChapterURL(
                clean,
                fragment: url.fragment,
                resolvedBaseURL: EPUBNativeWKWebView.resolveBaseURL(for: clean),
                baseDir: baseDirectory,
                fontSize: Double(coordinator.currentFontSize ?? 17.0),
                fontStyle: coordinator.currentFontStyle ?? "serif",
                readerTheme: coordinator.currentTheme ?? "light",
                in: webView
            )
        }

        @MainActor
        func updateTypography(fontSize: Double, fontStyle: String, theme: String) {
            coordinator.currentFontSize = CGFloat(fontSize)
            coordinator.currentFontStyle = fontStyle
            coordinator.currentTheme = theme
            paginationController.prepareAnchorPreservationBeforeRelayout()
            let escaped = EPUBNativeWKWebView.resolveFontFamilyCSS(for: fontStyle)
                .replacingOccurrences(of: "'", with: "\\'")
            coordinator.applyTypographyAndRelayout(
                in: webView,
                fontSize: fontSize,
                escapedFontFamily: escaped,
                readerTheme: theme
            )
        }

        @MainActor
        func cleanup() {
            EPUBNativeWKWebView.dismantleNSView(webView, coordinator: coordinator)
            window.orderOut(nil)
        }
    }

    private func makeConfiguredReaderWebView(
        frame: NSRect,
        chapterURL: URL,
        baseDirectory: URL,
        chapterIndex: Int,
        paginationController: EPUBPaginationController
    ) -> (EPUBReaderWKWebView, EPUBNativeWKWebView.Coordinator) {
        let rep = EPUBNativeWKWebView(
            chapterURL: chapterURL,
            baseDirectory: baseDirectory,
            fontSize: 17.0,
            fontStyle: "serif",
            readerTheme: "light",
            chapterIndex: chapterIndex,
            paginationController: paginationController,
            layoutMode: paginationController.layoutMode.rawValue
        )
        let coordinator = rep.makeCoordinator()
        let config = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: config)
        config.userContentController.add(
            coordinator.inputStateMessageHandler,
            contentWorld: TTWebPreviewContentPolicy.readerControlWorld,
            name: EPUBReaderWebKitPagerBridge.inputStateHandlerName
        )
        let webView = EPUBReaderWKWebView(frame: frame, configuration: config)
        webView.readerInstanceID = paginationController.instanceID
        webView.paginationController = paginationController
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.bindPaginationAndFocusCallbacks(to: webView)
        let clean = EPUBNativeWKWebView.stripFragment(from: chapterURL)
        coordinator.loadChapterURL(
            clean,
            fragment: chapterURL.fragment,
            resolvedBaseURL: EPUBNativeWKWebView.resolveBaseURL(for: clean),
            baseDir: baseDirectory,
            fontSize: 17.0,
            fontStyle: "serif",
            readerTheme: "light",
            in: webView
        )
        return (webView, coordinator)
    }

    private func makeHostedEPUBWebView(
        chapterURL: URL,
        baseDirectory: URL,
        chapterIndex: Int,
        paginationController: EPUBPaginationController,
        viewportSize: NSSize
    ) throws -> HostedEPUBWebView {
        let (webView, coordinator) = makeConfiguredReaderWebView(
            frame: NSRect(origin: .zero, size: viewportSize),
            chapterURL: chapterURL,
            baseDirectory: baseDirectory,
            chapterIndex: chapterIndex,
            paginationController: paginationController
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: viewportSize),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        return HostedEPUBWebView(
            window: window,
            webView: webView,
            coordinator: coordinator,
            baseDirectory: baseDirectory,
            paginationController: paginationController
        )
    }

    private static func currentScrollPageIndex(in webView: WKWebView) async -> Int {
        await withCheckedContinuation { continuation in
            let js = "Math.round((window.scrollX || 0) / Math.max(window.innerWidth || 1, 1))"
            webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { outcome in
                let idx = ((try? outcome.get()) as? NSNumber)?.intValue ?? 0
                continuation.resume(returning: idx)
            }
        }
    }

    @discardableResult
    private static func evalInControlWorld(_ js: String, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { outcome in
                let str = (try? outcome.get()).flatMap { "\($0)" }
                continuation.resume(returning: str)
            }
        }
    }

    private static func makeLongChapterXHTML(title: String, paragraphCount: Int) -> String {
        let paragraphs = (0..<paragraphCount).map { idx in
            "<p id=\"p\(idx)\">[\(title) - Paragraph \(idx)] This is a structured EPUB paragraph designed to test multi-column viewport quantization, page-by-page navigation, cross-chapter boundary transitions, and DOM block anchor preservation across font size and window resize operations.</p>"
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
        <head><meta charset="utf-8"/><title>\(title)</title></head>
        <body>
            <h1>\(title)</h1>
            \(paragraphs)
        </body>
        </html>
        """
    }

    private static func makeInteractiveChapterWithInputXHTML() -> String {
        let paragraphs = (0..<24).map { idx in
            "<p id=\"p\(idx)\">[Interactive Paragraph \(idx)] Multi-column paginated chapter with an embedded annotation input field for testing real DOM focusin/focusout and CJK IME composition events.</p>"
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="zh-Hans">
        <head><meta charset="utf-8"/><title>Interactive Chapter</title></head>
        <body>
            <p><input id="chapter-note" type="text" value="笔记"/></p>
            \(paragraphs)
        </body>
        </html>
        """
    }

    private static func makeSingleGiantParagraphXHTML() -> String {
        let sentences = (0..<90).map { idx in
            "Sentence-\(idx)-Marker: Long continuous discourse inside a single HTML paragraph element spanning multiple CSS columns without intermediate block tags."
        }.joined(separator: " ")
        return """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
        <head><meta charset="utf-8"/><title>Single Giant Paragraph</title></head>
        <body>
            <p id="giant-para">\(sentences)</p>
        </body>
        </html>
        """
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        return await condition()
    }
}
