// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import WebKit
@testable import TTMediaKit

@MainActor
final class EPUBRealPageReadingAndThemeTests: XCTestCase {

    override func tearDown() {
        EPUBChapterContentLoaderActor.customDataProvider = nil
        super.tearDown()
    }

    // MARK: - 1. Multi-Page Chapter Stepping & Chapter Boundary Invariant

    func testHorizontalAutoPaginationAndStrictPageStepping() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-realpage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ch0URL = tempDir.appendingPathComponent("ch0.xhtml")
        let ch1URL = tempDir.appendingPathComponent("ch1.xhtml")
        try Self.makeRichChapterXHTML(title: "Chapter 1", paragraphCount: 26).write(to: ch0URL, atomically: true, encoding: .utf8)
        try Self.makeRichChapterXHTML(title: "Chapter 2", paragraphCount: 20).write(to: ch1URL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2)
        XCTAssertEqual(controller.layoutMode, .paginated, "Default layout mode must be horizontal auto-pagination")

        let harness = try makeTestHarness(
            chapterURL: ch0URL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 380, height: 280)
        )
        defer { harness.cleanup() }

        let ch0Ready = await waitUntil(timeout: 6.0) {
            controller.totalPagesInChapter >= 3 && controller.currentChapterIndex == 0
        }
        XCTAssertTrue(ch0Ready, "Chapter 0 must paginate into at least 3 pages")
        let totalCh0Pages = controller.totalPagesInChapter
        XCTAssertEqual(controller.currentPageIndex, 0)

        // Stepping within chapter: page 0 -> 1 -> 2
        for expectedPage in 1..<totalCh0Pages {
            try sendArrow(124, to: harness)
            XCTAssertEqual(controller.currentChapterIndex, 0, "In-chapter keys must not skip chapters")
            let scrolled = await waitUntil(timeout: 2.0) {
                await Self.queryScrollPageIndex(in: harness.webView) == expectedPage
            }
            XCTAssertTrue(scrolled, "WKWebView must scroll to page \(expectedPage)")
            guard scrolled else { return }
        }

        // At last page of Chapter 0, next arrow must cross chapter boundary to Chapter 1 Page 0
        var requestedTransition: (Int, EPUBBoundaryLanding)?
        controller.onRequestChapterIndexChange = { idx, landing in
            requestedTransition = (idx, landing)
        }
        try sendArrow(124, to: harness)
        XCTAssertEqual(controller.currentChapterIndex, 1)
        XCTAssertEqual(requestedTransition?.0, 1)
        XCTAssertEqual(requestedTransition?.1, .firstPage)

        harness.updateChapter(url: ch1URL, chapterIndex: 1)
        let ch1Ready = await waitUntil(timeout: 6.0) {
            !controller.isChapterTransitionInFlight && controller.currentChapterIndex == 1 && controller.totalPagesInChapter >= 2
        }
        XCTAssertTrue(ch1Ready, "Chapter 1 must load and paginate into >= 2 pages")
        XCTAssertEqual(controller.currentPageIndex, 0)

        // At first page of Chapter 1, left arrow must transition backward to Chapter 0 Last Page
        try sendArrow(123, to: harness)
        XCTAssertEqual(controller.currentChapterIndex, 0)

        harness.updateChapter(url: ch0URL, chapterIndex: 0, landing: .lastPage)
        let landedLast = await waitUntil(timeout: 6.0) {
            !controller.isChapterTransitionInFlight
                && controller.currentChapterIndex == 0
                && controller.currentPageIndex == controller.totalPagesInChapter - 1
        }
        XCTAssertTrue(landedLast, "Backward transition must land strictly on last page of previous chapter")
    }

    // MARK: - 2. Window Resize & Font Size Change Reading Anchor Preservation

    func testWindowResizeAndFontSizeChangePreservesReadingLocation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chapterURL = tempDir.appendingPathComponent("anchor.xhtml")
        try Self.makeRichChapterXHTML(title: "Anchor Test", paragraphCount: 30).write(to: chapterURL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 1)
        let harness = try makeTestHarness(
            chapterURL: chapterURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 380, height: 280)
        )
        defer { harness.cleanup() }

        let ready = await waitUntil(timeout: 6.0) {
            controller.totalPagesInChapter >= 3
        }
        XCTAssertTrue(ready)

        try sendArrow(124, to: harness)
        let pageReady = await waitUntil(timeout: 2.0) {
            await Self.queryScrollPageIndex(in: harness.webView) == 1
        }
        XCTAssertTrue(pageReady)
        let originalAnchorBlock = controller.anchorBlockIndex
        let originalCharOffset = controller.anchorCharOffset

        harness.updateTypography(fontSize: 24.0, fontStyle: "serif", theme: "light")
        let repaginatedFont = await waitUntil(timeout: 4.0) {
            let fontSize = await Self.evalDouble("parseFloat(getComputedStyle(document.body).fontSize)", in: harness.webView)
            return abs(fontSize - 32) < 0.5
                && controller.anchorBlockIndex == originalAnchorBlock
                && controller.anchorCharOffset == originalCharOffset
        }
        XCTAssertTrue(repaginatedFont, "Wait for actual 24pt DOM typography and preserved anchor")

        harness.resizeViewport(to: NSSize(width: 560, height: 320))
        let repaginatedResize = await waitUntil(timeout: 4.0) {
            let height = await Self.evalDouble("parseFloat(document.body.style.height)", in: harness.webView)
            return abs(height - 320) < 1
                && controller.anchorBlockIndex == originalAnchorBlock
                && controller.anchorCharOffset == originalCharOffset
        }
        XCTAssertTrue(repaginatedResize, "Wait for actual resized pagination, not an already-true page bound")
    }

    // MARK: - 3. Vertical Scrolling Mode & Arrow Key Focus Routing

    func testVerticalScrollingModeAndKeyRouting() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chapterURL = tempDir.appendingPathComponent("scroll.xhtml")
        try Self.makeRichChapterXHTML(title: "Vertical Scroll", paragraphCount: 22).write(to: chapterURL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2)
        controller.setLayoutMode(.scrolling)
        XCTAssertEqual(controller.layoutMode, .scrolling)

        let harness = try makeTestHarness(
            chapterURL: chapterURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 400, height: 300)
        )
        defer { harness.cleanup() }

        let ready = await waitUntil(timeout: 6.0) {
            let exists = await Self.evalString("document.getElementById('p0') !== null", in: harness.webView)
            return exists == "true" || exists == "1"
        }
        XCTAssertTrue(ready, "Rich chapter HTML with p0 must be loaded")

        // Make reading area first responder
        harness.window.makeFirstResponder(harness.webView)
        TTPreviewKeyboardOwnershipCoordinator.shared.setReaderFocusState(
            instanceID: controller.instanceID,
            isFocused: true,
            source: .readingArea
        )

        let stateFocused = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(
            windowNumber: harness.window.windowNumber,
            instanceID: controller.instanceID
        )
        XCTAssertTrue(stateFocused.ownsVerticalArrowKeys, "Reader must own vertical arrows when reading area has focus")

        // Vertical scroll step
        var verticalStepTriggered = false
        controller.onRequestVerticalScroll = { isDown in
            verticalStepTriggered = true
        }
        let scrollOutcome = controller.handleVerticalArrow(isDownArrow: true)
        XCTAssertTrue(scrollOutcome)
        XCTAssertTrue(verticalStepTriggered)

        // Simulate focus moving to external file list: keys must pass through
        let externalView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        harness.window.contentView?.addSubview(externalView)
        harness.window.makeFirstResponder(externalView)
        TTPreviewKeyboardOwnershipCoordinator.shared.handleWindowMouseDown(
            in: harness.window,
            locationInWindow: NSPoint(x: 10, y: 10)
        )

        let stateExternal = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(
            windowNumber: harness.window.windowNumber,
            instanceID: controller.instanceID
        )
        XCTAssertFalse(stateExternal.ownsVerticalArrowKeys, "Must not hijack vertical arrows when focus is on file list")
        XCTAssertFalse(stateExternal.ownsHorizontalArrowKeys, "Must not hijack horizontal arrows when focus is on file list")
    }

    // MARK: - 4. Dark Theme DOM Styling & Author Class Preservation

    func testNightThemeComputedStylesAndAuthorClassPreservation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chapterURL = tempDir.appendingPathComponent("theme.xhtml")
        try Self.makeStylingVerificationXHTML().write(to: chapterURL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 1)
        let harness = try makeTestHarness(
            chapterURL: chapterURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 440, height: 320)
        )
        defer { harness.cleanup() }

        let ready = await waitUntil(timeout: 6.0) {
            let el = await Self.evalString("document.getElementById('test-link') ? 'ok' : ''", in: harness.webView) ?? ""
            return el == "ok"
        }
        XCTAssertTrue(ready, "Chapter HTML must finish loading before theme switch")

        // Switch to night theme
        harness.updateTypography(fontSize: 17.0, fontStyle: "serif", theme: "dark")

        let themed = await waitUntil(timeout: 3.0) {
            let cls = await Self.evalString("document.body.className", in: harness.webView) ?? ""
            return cls.contains("theme-dark")
        }
        XCTAssertTrue(themed, "document.body must receive theme-dark class")

        // 1. Verify body background color is dark
        let bodyBg = await Self.evalString("getComputedStyle(document.body).backgroundColor", in: harness.webView) ?? ""
        XCTAssertTrue(bodyBg.contains("28, 28, 30") || bodyBg.contains("rgb(28") || bodyBg.contains("#1c1c1e"), "Night theme body background must be dark, got: \(bodyBg)")

        // 2. Verify link color is readable (blue accent #6cb6ff / rgb(108, 182, 255))
        let linkColor = await Self.evalString("getComputedStyle(document.getElementById('test-link')).color", in: harness.webView) ?? ""
        XCTAssertTrue(linkColor.contains("108, 182, 255"), "Link color must be readable accent in dark theme, got: \(linkColor)")

        // 3. Verify author custom class attributes are NOT wiped
        let authorBoxClass = await Self.evalString("document.getElementById('author-box').className", in: harness.webView) ?? ""
        XCTAssertTrue(authorBoxClass.contains("author-callout-card"), "Author custom classes must be preserved, got: \(authorBoxClass)")

        await assertIllustrationsPreserved(in: harness.webView)

        // 6. Author CSS class with near-black text must be lifted to a readable colour
        let lifted = await waitUntil(timeout: 3.0) {
            let color = await Self.evalString("getComputedStyle(document.getElementById('author-dark')).color", in: harness.webView) ?? ""
            return color.contains("229, 229, 231")
        }
        XCTAssertTrue(lifted, "Author CSS near-black text must be lifted for night readability")
        let inlineLifted = await Self.evalString("getComputedStyle(document.getElementById('inline-dark')).color", in: harness.webView) ?? ""
        XCTAssertTrue(inlineLifted.contains("229, 229, 231"), "Author inline black text must be lifted too, got: \(inlineLifted)")

        // 7. Chromatic author emphasis must NOT be flattened by the contrast pass
        let accentColor = await Self.evalString("getComputedStyle(document.getElementById('accent-span')).color", in: harness.webView) ?? ""
        XCTAssertTrue(accentColor.contains("204, 0, 0"), "Chromatic emphasis colours must survive the dark contrast pass, got: \(accentColor)")

        // 8. Switching back to light must restore the author's original colour (no leftover inline override)
        harness.updateTypography(fontSize: 17.0, fontStyle: "serif", theme: "light")
        let restored = await waitUntil(timeout: 3.0) {
            let color = await Self.evalString("getComputedStyle(document.getElementById('author-dark')).color", in: harness.webView) ?? ""
            return color.contains("17, 17, 17")
        }
        XCTAssertTrue(restored, "Leaving dark mode must restore author colours instead of leaving lifted overrides behind")
        let priority = await Self.evalString(
            "document.getElementById('inline-dark').style.getPropertyPriority('color')", in: harness.webView
        )
        XCTAssertEqual(priority, "important", "Restoring author colour must preserve inline priority")
        let svgColor = await Self.evalString(
            "getComputedStyle(document.getElementById('svg-shape')).color", in: harness.webView
        )
        XCTAssertEqual(svgColor, "rgb(0, 0, 0)", "Text contrast rules must not recolour SVG descendants")
    }

    // MARK: - 5. Reading Position & Progress Persistence Across Reopen

    func testProgressLabelAndUserDefaultsRoundTrip() {
        let storageKey = "TTMedia_EPUB_Progress_TestBook"
        let savedDict: [String: Any] = [
            "chapterIndex": 3,
            "pageIndex": 4,
            "overallProgress": 0.68
        ]
        UserDefaults.standard.set(savedDict, forKey: storageKey)
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }

        guard let loaded = UserDefaults.standard.dictionary(forKey: storageKey),
              let chapter = loaded["chapterIndex"] as? Int,
              let page = loaded["pageIndex"] as? Int,
              let progress = loaded["overallProgress"] as? Double else {
            XCTFail("Failed to load saved progress")
            return
        }

        XCTAssertEqual(chapter, 3)
        XCTAssertEqual(page, 4)
        XCTAssertEqual(progress, 0.68, accuracy: 0.001)

        let label = EPUBPaginationLocalization.chapterPageAndProgressIndicator(
            chapterIndex: chapter,
            totalChapters: 6,
            pageIndex: page,
            totalPages: 8,
            progressRatio: progress
        )
        XCTAssertTrue(label.contains("4/6"))
        XCTAssertTrue(label.contains("5/8"))
        XCTAssertTrue(label.contains("68%"))
    }

    // MARK: - 6. Backward Page Stepping, Vertical Scrolling Boundaries & Progress Indicator

    func testBackwardArrowStepsPageByPageWithinChapterWithoutChangingChapter() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-backward-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chapterURL = tempDir.appendingPathComponent("backward.xhtml")
        try Self.makeRichChapterXHTML(title: "Backward", paragraphCount: 30).write(to: chapterURL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2)
        let harness = try makeTestHarness(
            chapterURL: chapterURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 380, height: 280)
        )
        defer { harness.cleanup() }

        let ready = await waitUntil(timeout: 6.0) {
            controller.isPaginationReady && controller.totalPagesInChapter >= 3
        }
        XCTAssertTrue(ready)
        let total = controller.totalPagesInChapter

        _ = controller.handleHorizontalArrow(isRightArrow: true)
        _ = controller.handleHorizontalArrow(isRightArrow: true)
        let reachedPageTwo = await waitUntil(timeout: 2.0) { controller.currentPageIndex == 2 }
        XCTAssertTrue(reachedPageTwo)

        let backOne = controller.handleHorizontalArrow(isRightArrow: false)
        XCTAssertEqual(backOne, .turnedPageInChapter(chapterIndex: 0, pageIndex: 1, totalPages: total))
        let scrolledBack = await waitUntil(timeout: 2.0) {
            await Self.queryScrollPageIndex(in: harness.webView) == 1
        }
        XCTAssertTrue(scrolledBack, "Left arrow must scroll back exactly one column")
        XCTAssertEqual(controller.currentChapterIndex, 0, "In-chapter backward stepping must not change chapter")

        let backTwo = controller.handleHorizontalArrow(isRightArrow: false)
        XCTAssertEqual(backTwo, .turnedPageInChapter(chapterIndex: 0, pageIndex: 0, totalPages: total))
        XCTAssertEqual(controller.currentChapterIndex, 0)

        // First page of the first chapter clamps instead of wrapping.
        XCTAssertEqual(
            controller.handleHorizontalArrow(isRightArrow: false),
            .clampedAtBookStart(chapterIndex: 0, pageIndex: 0)
        )
    }

    func testVerticalScrollMovesBodyAndNeverCrossesChapterAtBoundaries() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-vscroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chapterURL = tempDir.appendingPathComponent("vscroll.xhtml")
        try Self.makeRichChapterXHTML(title: "Vertical", paragraphCount: 30).write(to: chapterURL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2)
        controller.setLayoutMode(.scrolling)
        let harness = try makeTestHarness(
            chapterURL: chapterURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 400, height: 300)
        )
        defer { harness.cleanup() }

        let ready = await waitUntil(timeout: 6.0) {
            controller.isPaginationReady && controller.totalPagesInChapter >= 2
        }
        XCTAssertTrue(ready, "Scrolling mode must still measure a page count for the indicator")

        harness.window.makeFirstResponder(harness.webView)
        TTPreviewKeyboardOwnershipCoordinator.shared.setReaderFocusState(
            instanceID: controller.instanceID, isFocused: true, source: .readingArea
        )
        XCTAssertTrue(
            TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(
                windowNumber: harness.window.windowNumber, instanceID: controller.instanceID
            ).ownsVerticalArrowKeys
        )

        let before = await Self.evalDouble("window.scrollY || 0", in: harness.webView)
        try sendArrow(125, to: harness)
        let movedDown = await waitUntil(timeout: 2.0) {
            await Self.evalDouble("window.scrollY || 0", in: harness.webView) > before
        }
        XCTAssertTrue(movedDown, "Down arrow must scroll the chapter body in continuous mode")

        // Jump to the very bottom, then press Down again: it must clamp, not switch chapters.
        _ = await Self.evalString("window.scrollTo(0, document.documentElement.scrollHeight); 'ok'", in: harness.webView)
        _ = await waitUntil(timeout: 2.0) {
            let maxY = await Self.evalDouble("Math.max(0, document.documentElement.scrollHeight - window.innerHeight)", in: harness.webView)
            let y = await Self.evalDouble("window.scrollY || 0", in: harness.webView)
            return maxY > 0 && y >= maxY - 4
        }
        XCTAssertTrue(controller.handleVerticalArrow(isDownArrow: true))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(controller.currentChapterIndex, 0, "Bottom boundary must not auto-advance the chapter")
        XCTAssertEqual(controller.currentPageIndex, controller.totalPagesInChapter - 1)

        // Same at the top: Up must not jump back to the previous chapter.
        _ = await Self.evalString("window.scrollTo(0, 0); 'ok'", in: harness.webView)
        _ = await waitUntil(timeout: 2.0) {
            await Self.evalDouble("window.scrollY || 0", in: harness.webView) <= 4
        }
        XCTAssertTrue(controller.handleVerticalArrow(isDownArrow: false))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(controller.currentChapterIndex, 0, "Top boundary must not auto-advance the chapter")
    }

    func testPageIndicatorAndEstimatedOverallProgressAdvanceWithPageTurns() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chapterURL = tempDir.appendingPathComponent("progress.xhtml")
        try Self.makeRichChapterXHTML(title: "Progress", paragraphCount: 28).write(to: chapterURL, atomically: true, encoding: .utf8)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 7)
        let harness = try makeTestHarness(
            chapterURL: chapterURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 380, height: 280)
        )
        defer { harness.cleanup() }

        let ready = await waitUntil(timeout: 6.0) {
            controller.isPaginationReady && controller.totalPagesInChapter >= 3
        }
        XCTAssertTrue(ready)
        let totalPages = controller.totalPagesInChapter

        func label() -> String {
            EPUBPaginationLocalization.chapterPageAndProgressIndicator(
                chapterIndex: controller.currentChapterIndex,
                totalChapters: controller.totalChapters,
                pageIndex: controller.currentPageIndex,
                totalPages: controller.totalPagesInChapter,
                progressRatio: controller.estimatedOverallBookProgress
            )
        }

        let labelAtFirstPage = label()
        XCTAssertTrue(labelAtFirstPage.contains("1/7"), "Chapter position must be shown, got: \(labelAtFirstPage)")
        XCTAssertTrue(labelAtFirstPage.contains("1/\(totalPages)"), "Chapter page must be shown, got: \(labelAtFirstPage)")
        XCTAssertTrue(
            labelAtFirstPage.contains("Est.") || labelAtFirstPage.contains("全书估算"),
            "Overall progress must be explicitly labelled as an estimate, got: \(labelAtFirstPage)"
        )
        let progressAtFirstPage = controller.estimatedOverallBookProgress

        _ = controller.handleHorizontalArrow(isRightArrow: true)
        let advanced = await waitUntil(timeout: 2.0) { controller.currentPageIndex == 1 }
        XCTAssertTrue(advanced)
        let labelAtSecondPage = label()
        XCTAssertTrue(labelAtSecondPage.contains("2/\(totalPages)"), "Page indicator must follow the turn, got: \(labelAtSecondPage)")
        XCTAssertGreaterThan(
            controller.estimatedOverallBookProgress,
            progressAtFirstPage,
            "Estimated overall progress must grow as pages advance"
        )
    }

    func testLayoutModeRoundTripRestoresPaginationAndScrollOverflow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chapter = directory.appendingPathComponent("roundtrip.xhtml")
        try Self.makeRichChapterXHTML(title: "Modes", paragraphCount: 24)
            .write(to: chapter, atomically: true, encoding: .utf8)
        let controller = EPUBPaginationController()
        let harness = try makeTestHarness(
            chapterURL: chapter, baseDirectory: directory, chapterIndex: 0,
            paginationController: controller, viewportSize: NSSize(width: 380, height: 280)
        )
        defer { harness.cleanup() }
        let initialReady = await waitUntil(timeout: 6) {
            controller.isPaginationReady && controller.totalPagesInChapter >= 3
        }
        XCTAssertTrue(initialReady)
        let initialPages = controller.totalPagesInChapter
        harness.updateLayoutMode(.scrolling)
        let scrollingReady = await waitUntil(timeout: 4) {
            let rootHeight = await Self.evalString("document.documentElement.style.height", in: harness.webView)
            let verticalExtent = await Self.evalDouble("document.documentElement.scrollHeight", in: harness.webView)
            return rootHeight == "" && verticalExtent > 280
        }
        XCTAssertTrue(scrollingReady, "Continuous mode must remove pagination height locks")
        harness.updateLayoutMode(.paginated)
        let paginationRestored = await waitUntil(timeout: 4) {
            let rootHeight = await Self.evalString("document.documentElement.style.height", in: harness.webView)
            let overflow = await Self.evalString("document.documentElement.style.overflowY", in: harness.webView)
            return rootHeight == "280px" && overflow == "hidden"
                && controller.totalPagesInChapter == initialPages
        }
        XCTAssertTrue(paginationRestored, "Mode round trip must restore the measured pagination")
    }

    // MARK: - 7. Layout Preference, Readiness Gate & Stable Book Identity

    func testLayoutPreferenceDefaultsToPaginatedAndPreservesExplicitScrolling() {
        XCTAssertEqual(EPUBReadingLayoutPreference.resolve(stored: nil), .paginated)
        XCTAssertEqual(EPUBReadingLayoutPreference.resolve(stored: ""), .paginated)
        XCTAssertEqual(EPUBReadingLayoutPreference.resolve(stored: "legacy-unknown-value"), .paginated)
        XCTAssertEqual(EPUBReadingLayoutPreference.resolve(stored: "scrolling"), .scrolling)
        XCTAssertEqual(EPUBReadingLayoutPreference.resolve(stored: "paginated"), .paginated)

        let fresh = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 3)
        XCTAssertEqual(fresh.layoutMode, .paginated, "No stored preference must default to pagination")
        XCTAssertFalse(fresh.isPaginationReady, "A fresh controller has not measured any layout yet")
        XCTAssertEqual(fresh.totalPagesInChapter, 1, "Unmeasured chapter reports the placeholder page count")
    }

    func testUnmeasuredPlaceholderPageDoesNotCrossChapterButRealSinglePageChapterDoes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-single-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let shortURL = tempDir.appendingPathComponent("short.xhtml")
        try Self.makeSinglePageChapterXHTML(title: "Short Chapter").write(to: shortURL, atomically: true, encoding: .utf8)

        // (A) Before any layout measurement the placeholder `1` must never be read as "single page".
        let unmeasured = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2)
        XCTAssertEqual(unmeasured.handleHorizontalArrow(isRightArrow: true), .deferredUntilPaginationReady)
        XCTAssertEqual(unmeasured.currentChapterIndex, 0, "Unmeasured placeholder must not cross the chapter boundary")
        XCTAssertEqual(unmeasured.handleHorizontalArrow(isRightArrow: false), .deferredUntilPaginationReady)
        XCTAssertEqual(unmeasured.currentChapterIndex, 0)

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2)
        let harness = try makeTestHarness(
            chapterURL: shortURL,
            baseDirectory: tempDir,
            chapterIndex: 0,
            paginationController: controller,
            viewportSize: NSSize(width: 380, height: 280)
        )
        defer { harness.cleanup() }

        let measured = await waitUntil(timeout: 6.0) {
            controller.isPaginationReady && controller.totalPagesInChapter == 1
        }
        XCTAssertTrue(measured, "Short chapter must finish layout and measure exactly one page")
        XCTAssertEqual(controller.currentPageIndex, 0)

        // (B) A genuinely single-page chapter (measured) must cross the boundary.
        let cross = controller.handleHorizontalArrow(isRightArrow: true)
        XCTAssertEqual(cross, .transitionedChapter(fromChapter: 0, toChapter: 1, landing: .firstPage))

        // (C) Starting the next chapter's load re-enters the unmeasured state and blocks further crossing.
        controller.beginChapterLoad(chapterIndex: 1)
        XCTAssertFalse(controller.isPaginationReady)
        XCTAssertEqual(controller.handleHorizontalArrow(isRightArrow: true), .deferredUntilPaginationReady)
        XCTAssertEqual(controller.currentChapterIndex, 1, "A loading chapter must not be skipped again")
    }

    func testRestoreReadingPositionKeepsAnchorWhenChapterIndexDoesNotChange() {
        let controller = EPUBPaginationController(initialChapterIndex: 2, totalChapters: 5)
        let landing = EPUBBoundaryLanding.preserveAnchor(progressRatio: 0.42, anchorBlockIndex: 9, anchorCharOffset: 137)
        controller.restoreReadingPosition(chapterIndex: 2, landing: landing)

        XCTAssertEqual(controller.currentChapterIndex, 2)
        XCTAssertEqual(controller.pendingLanding, landing, "Restore must not be swallowed by the same-chapter fast path")
        XCTAssertFalse(controller.isPaginationReady)
        XCTAssertEqual(controller.handleHorizontalArrow(isRightArrow: true), .deferredUntilPaginationReady)

        controller.didSynchronizeWebViewPagination(
            chapterIndex: 2,
            pageIndex: 4,
            totalPages: 9,
            anchorBlockIndex: 9,
            anchorCharOffset: 137,
            readingDirectionRaw: "ltr"
        )
        XCTAssertTrue(controller.isPaginationReady)
        XCTAssertEqual(controller.currentPageIndex, 5, "Restore page 4, then replay the one queued right key exactly once")
    }

    func testStaleBookGenerationSnapshotCannotOverwriteNewBookState() {
        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 4)
        controller.didSynchronizeWebViewPagination(
            chapterIndex: 0, pageIndex: 2, totalPages: 6, anchorBlockIndex: 3, readingDirectionRaw: "ltr"
        )
        XCTAssertEqual(controller.totalPagesInChapter, 6)
        let staleGeneration = controller.bookGeneration

        // Switching books bumps the generation and resets readiness.
        controller.configureBook(totalChapters: 4, initialChapterIndex: 0)
        XCTAssertEqual(controller.bookGeneration, staleGeneration + 1)
        XCTAssertFalse(controller.isPaginationReady)

        controller.didSynchronizeWebViewPagination(
            chapterIndex: 0,
            pageIndex: 5,
            totalPages: 9,
            anchorBlockIndex: 8,
            readingDirectionRaw: "ltr",
            bookGeneration: staleGeneration
        )
        XCTAssertEqual(controller.totalPagesInChapter, 1, "Stale generation must be ignored")
        XCTAssertFalse(controller.isPaginationReady)

        controller.didSynchronizeWebViewPagination(
            chapterIndex: 0,
            pageIndex: 1,
            totalPages: 3,
            anchorBlockIndex: 2,
            readingDirectionRaw: "ltr",
            bookGeneration: controller.bookGeneration
        )
        XCTAssertEqual(controller.totalPagesInChapter, 3, "Current generation must be applied")
        XCTAssertTrue(controller.isPaginationReady)
    }

    func testStableBookIdentityIgnoresTransientExtractionPaths() {
        let diskIdentity = "/Users/reader/Books/novel.epub"
        let archiveIdentityA = "ttzip-vfs://archive-aaa/OEBPS/novel.epub"
        let archiveIdentityB = "ttzip-vfs://archive-bbb/OEBPS/novel.epub"
        let ephemeralIdentity = "/tmp/TTZipEphemeralEPUB/9f2c1a.epub"

        let disk = InteractiveEPUBReaderView.stableBookDigest(for: diskIdentity)
        XCTAssertEqual(disk, InteractiveEPUBReaderView.stableBookDigest(for: diskIdentity), "Same book must map to the same key")
        XCTAssertNotEqual(disk, InteractiveEPUBReaderView.stableBookDigest(for: archiveIdentityA))
        XCTAssertNotEqual(
            InteractiveEPUBReaderView.stableBookDigest(for: archiveIdentityA),
            InteractiveEPUBReaderView.stableBookDigest(for: archiveIdentityB),
            "Different archives must not collide even with identical entry names"
        )
        XCTAssertNotEqual(
            InteractiveEPUBReaderView.stableBookDigest(for: ephemeralIdentity),
            InteractiveEPUBReaderView.stableBookDigest(for: archiveIdentityA),
            "Progress keys must never be derived from the transient spool path"
        )
        XCTAssertFalse(disk.contains("/"), "Digest must be usable inside a UserDefaults key")
        XCTAssertFalse(disk.contains(":"))
    }

}
