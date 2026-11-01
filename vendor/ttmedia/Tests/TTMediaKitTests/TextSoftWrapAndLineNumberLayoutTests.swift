// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTI18nCore
@testable import TTMediaKit
import XCTest

@MainActor
final class TextSoftWrapAndLineNumberLayoutTests: XCTestCase {
    private var savedSharedMode: TTTextReadingBackgroundMode = .fluidTransparent
    private var savedSharedSoftWrap: Bool = true

    override func setUp() async throws {
        try await super.setUp()
        savedSharedMode = TTTextReadingPreferenceStore.shared.mode
        savedSharedSoftWrap = TTTextReadingPreferenceStore.shared.isSoftWrapEnabled
        TTTextReadingPreferenceStore.shared.resetToDefault()
    }

    override func tearDown() async throws {
        TTTextReadingPreferenceStore.shared.mode = savedSharedMode
        TTTextReadingPreferenceStore.shared.isSoftWrapEnabled = savedSharedSoftWrap
        try await super.tearDown()
    }

    private static let mixedLongLineCorpus: String = [
        "第一行超长中文段落：在窄窗口与宽窗口下验证自动换行开启时按可用宽度折行展示，关闭时保持单行并提供横向滚动且绝不截断行尾字符【行尾锚点-CJK-END】",
        "let secondLineSuperLongSwiftDeclaration = \"English & code super-long logical line verifying widthTracksTextView, horizontal scrolling reachability, and zero buffer newline insertion [ASCII-TAIL-END]\"",
        "",
        "\t\t\tlet fourthLineWithTabs = [\"tab_indent_1\", \"tab_indent_2\", \"tab_indent_3\", \"tab_indent_4\", \"TAB-TAIL-END\"]",
        "第五行结尾短行 End of line 5"
    ].joined(separator: "\n")

    // MARK: - 1. Default Enabled, Shared Preference Store & Localization

    func testDefaultSoftWrapPreferenceAndSharedPersistenceAcrossTxtAndCode() {
        let suiteName = "ttmedia.test.softwrap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TTTextReadingPreferenceStore(defaults: defaults)
        XCTAssertTrue(
            store.isSoftWrapEnabled,
            "Soft wrap must default to true when no prior user selection exists"
        )
        XCTAssertEqual(
            TTTextReadingPreferenceStore.defaultSoftWrapEnabled,
            true
        )

        store.isSoftWrapEnabled = false
        XCTAssertEqual(
            defaults.object(forKey: TTTextReadingPreferenceStore.softWrapUserDefaultsKey) as? Bool,
            false
        )

        let reloadedStore = TTTextReadingPreferenceStore(defaults: defaults)
        XCTAssertFalse(
            reloadedStore.isSoftWrapEnabled,
            "Persisted soft wrap selection must survive store re-initialization"
        )

        reloadedStore.resetToDefault()
        XCTAssertTrue(reloadedStore.isSoftWrapEnabled)
        XCTAssertEqual(
            defaults.object(forKey: TTTextReadingPreferenceStore.softWrapUserDefaultsKey) as? Bool,
            true
        )

        // Verify TXT and code containers share the same single preference owner.
        TTTextReadingPreferenceStore.shared.isSoftWrapEnabled = true
        let txtContainer = CodeTextEditorContainerView(
            initialText: "plain text",
            fileURL: nil,
            fileName: "notes.txt"
        )
        let swiftContainer = CodeTextEditorContainerView(
            initialText: "let x = 1",
            fileURL: nil,
            fileName: "main.swift"
        )
        XCTAssertTrue(txtContainer.activeSoftWrapEnabled)
        XCTAssertTrue(swiftContainer.activeSoftWrapEnabled)

        txtContainer.activeSoftWrapBinding.wrappedValue = false
        XCTAssertFalse(TTTextReadingPreferenceStore.shared.isSoftWrapEnabled)
        XCTAssertFalse(swiftContainer.activeSoftWrapEnabled)

        // Verify localized labels and tooltips across English, Simplified Chinese, and Traditional Chinese.
        XCTAssertEqual(TextAndDocumentPreviewLocaleKey.softWrapLabel.fallbackTranslation(for: .en), "Soft Wrap")
        XCTAssertEqual(TextAndDocumentPreviewLocaleKey.softWrapLabel.fallbackTranslation(for: .zhHans), "自动换行")
        XCTAssertEqual(TextAndDocumentPreviewLocaleKey.softWrapLabel.fallbackTranslation(for: .zhHant), "自動換行")
        XCTAssertTrue(TextAndDocumentPreviewLocaleKey.disableSoftWrapHelp.fallbackTranslation(for: .zhHans).contains("关闭自动换行"))
        XCTAssertTrue(TextAndDocumentPreviewLocaleKey.enableSoftWrapHelp.fallbackTranslation(for: .zhHans).contains("开启自动换行"))
    }

    // MARK: - 2. Real NSTextView Layout Reflow & Horizontal Scroll Reachability

    func testRealNSTextViewSoftWrapToggleReflowAndHorizontalScrollReachability() async throws {
        let driver = SoftWrapTestDriver(
            text: Self.mixedLongLineCorpus,
            fileName: "notes.txt",
            isEditable: false
        )
        let (window, host) = makeOffscreenHost(
            width: 280,
            height: 320,
            rootView: SoftWrapHarnessView(driver: driver)
        )
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await waitForMountedEditor(in: host, expectedText: Self.mixedLongLineCorpus)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let container = try XCTUnwrap(editor.textContainer)
        let layoutManager = try XCTUnwrap(editor.layoutManager)
        let ruler = try XCTUnwrap(scrollView.verticalRulerView as? LineNumberRulerView)

        // 1. Default soft wrap ON in narrow 280pt viewport.
        XCTAssertTrue(driver.isSoftWrapEnabled)
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertFalse(editor.isHorizontallyResizable)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        // The line-number ruler overlays the clip view, so the text only owns the width left over.
        let rulerReservedWidth = ruler.ruleThickness
        let wrappedViewportWidth = scrollView.contentSize.width - rulerReservedWidth
        XCTAssertEqual(editor.frame.width, wrappedViewportWidth, accuracy: 1.0)

        let wrappedUsedRect = layoutManager.usedRect(for: container)
        XCTAssertLessThanOrEqual(
            wrappedUsedRect.width,
            container.containerSize.width + 1.0,
            "When soft wrap is ON, text layout width must fit inside the viewport container width"
        )
        let wrappedPlacements = ruler.visibleLogicalLineNumberPlacements(
            in: NSRect(x: 0, y: 0, width: 80, height: 2000)
        )
        XCTAssertEqual(wrappedPlacements.map(\.lineNumber), [1, 2, 3, 4, 5])
        XCTAssertGreaterThanOrEqual(wrappedPlacements[0].visualFragmentCount, 3, "Long CJK line must wrap into >= 3 visual lines at 280pt")
        XCTAssertGreaterThanOrEqual(wrappedPlacements[1].visualFragmentCount, 3, "Long English/code line must wrap into >= 3 visual lines at 280pt")

        // 2. Toggle soft wrap OFF via the live floating popover button (`CodeFloatingSoftWrapToggle`).
        let softWrapButton = try XCTUnwrap(findButton(id: "CodeFloatingSoftWrapToggle", in: host))
        XCTAssertEqual(softWrapButton.accessibilityValue() as? String, TextAndDocumentPreviewLocalization.text(.softWrapStateOn))
        XCTAssertTrue(softWrapButton.accessibilityPerformPress())
        flushLayoutCycles(host, count: 6)

        XCTAssertFalse(driver.isSoftWrapEnabled)
        XCTAssertFalse(container.widthTracksTextView)
        XCTAssertTrue(editor.isHorizontallyResizable)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertEqual(softWrapButton.accessibilityValue() as? String, TextAndDocumentPreviewLocalization.text(.softWrapStateOff))

        let unwrappedUsedRect = layoutManager.usedRect(for: container)
        XCTAssertGreaterThan(
            unwrappedUsedRect.width,
            wrappedViewportWidth * 2.2,
            "When soft wrap is OFF, long lines must expand horizontally well beyond the 280pt viewport"
        )
        XCTAssertGreaterThanOrEqual(
            editor.frame.width,
            unwrappedUsedRect.maxX + editor.textContainerInset.width * 2.0 - 1.0,
            "NSTextView frame width must encompass the full unwrapped line width without clipping"
        )
        XCTAssertLessThan(
            unwrappedUsedRect.height,
            wrappedUsedRect.height * 0.65,
            "Unwrapping must reduce total vertical used height"
        )

        // Verify tail glyph reachability via horizontal scrolling without truncation.
        try assertUnwrappedTailGlyphReachableByHorizontalScroll(
            editor: editor,
            scrollView: scrollView,
            layoutManager: layoutManager,
            container: container,
            tailMarker: "[ASCII-TAIL-END]"
        )

        // 3. Toggle soft wrap back ON and verify the horizontal origin rests against the ruler
        //    and the width tracks the ruler-aware viewport again.
        XCTAssertTrue(softWrapButton.accessibilityPerformPress())
        flushLayoutCycles(host, count: 6)
        XCTAssertTrue(driver.isSoftWrapEnabled)
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertFalse(editor.isHorizontallyResizable)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.x,
            -rulerReservedWidth,
            accuracy: 0.5,
            "Soft wrap must rest the document's left edge against the ruler's right edge"
        )
        XCTAssertEqual(editor.frame.width, scrollView.contentSize.width - rulerReservedWidth, accuracy: 1.0)
    }

    // MARK: - 2b. Line-Number Ruler Must Not Cover Leading Glyphs

    func testLineNumberRulerDoesNotCoverLeadingGlyphsOrClipTextTail() async throws {
        let text = """
        Conflicting hello.txt content created on disk to trigger ForensicCollisionPanel
        second logical line used by the ruler overlap regression
        """
        let driver = SoftWrapTestDriver(
            text: text,
            fileName: "hello.txt",
            isEditable: false
        )
        let (window, host) = makeOffscreenHost(
            width: 420,
            height: 240,
            rootView: SoftWrapHarnessView(driver: driver)
        )
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await waitForMountedEditor(in: host, expectedText: text)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let container = try XCTUnwrap(editor.textContainer)
        let layoutManager = try XCTUnwrap(editor.layoutManager)
        let ruler = try XCTUnwrap(scrollView.verticalRulerView as? LineNumberRulerView)
        XCTAssertTrue(scrollView.rulersVisible, "The line-number ruler must be visible for this regression")

        let clip = scrollView.contentView
        let reserved = ruler.ruleThickness
        XCTAssertGreaterThan(reserved, 0, "The line-number ruler must reserve a gutter band")

        // The document's left edge must rest exactly at the ruler's right edge, otherwise the
        // leading characters of every line are painted underneath the gutter.
        XCTAssertEqual(
            clip.bounds.origin.x,
            -reserved,
            accuracy: 0.5,
            "The clip view must keep AppKit's ruler-aware resting origin"
        )

        let firstGlyph = layoutManager.boundingRect(
            forGlyphRange: layoutManager.glyphRange(
                forCharacterRange: NSRange(location: 0, length: 1),
                actualCharacterRange: nil
            ),
            in: container
        )
        let firstGlyphScreenX = screenX(
            firstGlyph.minX + editor.textContainerOrigin.x + editor.frame.origin.x,
            scrollView: scrollView
        )
        XCTAssertGreaterThanOrEqual(
            firstGlyphScreenX,
            reserved,
            "The leading glyph must be painted to the right of the line-number gutter"
        )

        // The whole soft-wrapped text must stay inside the visible region.
        let used = layoutManager.usedRect(for: container)
        let textRightScreenX = screenX(
            used.maxX + editor.textContainerOrigin.x + editor.frame.origin.x,
            scrollView: scrollView
        )
        let visibleRightScreenX = screenX(
            clip.bounds.origin.x + clip.bounds.width,
            scrollView: scrollView
        )
        XCTAssertLessThanOrEqual(
            textRightScreenX,
            visibleRightScreenX + 0.5,
            "Soft-wrapped text must not be clipped at the trailing edge"
        )
    }

    // MARK: - 3. Logical Line Numbers Across Wrapped Continuation Lines, Empty Lines & Window Widths

    func testLogicalLineNumbersWithWrappedContinuationLinesAndEmptyLines() async throws {
        let driver = SoftWrapTestDriver(
            text: Self.mixedLongLineCorpus,
            fileName: "sample.swift",
            isEditable: false
        )
        let (window, host) = makeOffscreenHost(
            width: 260,
            height: 360,
            rootView: SoftWrapHarnessView(driver: driver)
        )
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await waitForMountedEditor(in: host, expectedText: Self.mixedLongLineCorpus)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let ruler = try XCTUnwrap(scrollView.verticalRulerView as? LineNumberRulerView)
        let fullRulerProbe = NSRect(x: 0, y: 0, width: ruler.bounds.width, height: 2000)

        let narrowPlacements = ruler.visibleLogicalLineNumberPlacements(in: fullRulerProbe)
        XCTAssertEqual(
            narrowPlacements.map(\.lineNumber),
            [1, 2, 3, 4, 5],
            "Continuation lines must never fabricate extra line numbers; empty line 3 must keep line number 3"
        )
        let line1 = narrowPlacements[0]
        let line2 = narrowPlacements[1]
        let line3Empty = narrowPlacements[2]
        let line4Tab = narrowPlacements[3]
        let singleFragHeight = line1.rectInRuler.height
        XCTAssertGreaterThan(line1.visualFragmentCount, 2)
        XCTAssertGreaterThan(line2.visualFragmentCount, 2)
        XCTAssertEqual(line3Empty.visualFragmentCount, 1, "Empty logical line must occupy exactly 1 visual fragment")
        XCTAssertGreaterThanOrEqual(
            line2.rectInRuler.minY - line1.rectInRuler.minY,
            CGFloat(line1.visualFragmentCount) * singleFragHeight - 2.0,
            "Logical line 2 number must align with the true glyph fragment below all wrapped continuation lines of line 1"
        )
        XCTAssertGreaterThanOrEqual(
            line3Empty.rectInRuler.minY - line2.rectInRuler.minY,
            CGFloat(line2.visualFragmentCount) * singleFragHeight - 2.0
        )
        XCTAssertGreaterThan(line4Tab.rectInRuler.minY, line3Empty.rectInRuler.minY)

        // Resize to wide 720pt window: wrapped fragment count decreases and line 2 moves up accordingly.
        resizeOffscreenHost(host, window: window, width: 720, height: 360)
        flushLayoutCycles(host, count: 6)
        let widePlacements = ruler.visibleLogicalLineNumberPlacements(in: fullRulerProbe)
        XCTAssertEqual(widePlacements.map(\.lineNumber), [1, 2, 3, 4, 5])
        XCTAssertLessThan(widePlacements[0].visualFragmentCount, line1.visualFragmentCount)
        XCTAssertLessThan(widePlacements[1].rectInRuler.minY, line2.rectInRuler.minY)

        // Verify ruler bitmap rendering produces non-background glyph pixels at logical line 1 and line 2 positions,
        // and does NOT draw a line number in the middle continuation band of line 1.
        resizeOffscreenHost(host, window: window, width: 260, height: 360)
        flushLayoutCycles(host, count: 6)
        try assertRulerBitmapDrawsOnlyAtLogicalLineStarts(ruler: ruler, line1: line1, line2: line2)
    }

    // MARK: - 4. Zero Buffer Mutation, Byte Identity, Save, Undo, Find, Selection & IME Marked Text

    func testZeroBufferMutationByteIdentitySaveUndoFindSelectionAndIMEMarkedText() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-softwrap-bytes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("editable_code.swift")
        let originalBytes = Data(Self.mixedLongLineCorpus.utf8)
        try originalBytes.write(to: fileURL)

        let driver = SoftWrapTestDriver(
            text: Self.mixedLongLineCorpus,
            fileName: fileURL.lastPathComponent,
            fileURL: fileURL,
            isEditable: true
        )
        let (window, host) = makeOffscreenHost(
            width: 280,
            height: 320,
            rootView: SoftWrapHarnessView(driver: driver)
        )
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await waitForMountedEditor(in: host, expectedText: Self.mixedLongLineCorpus)
        let coordinator = try XCTUnwrap(editor.chunkCoordinator)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.allowsUndo)

        // Set selection and search highlights before toggling soft wrap.
        let targetSelection = NSRange(location: 10, length: 12)
        editor.setSelectedRange(targetSelection)
        coordinator.updateSearchHighlights(query: "fourthLineWithTabs", in: editor)
        XCTAssertEqual(coordinator.searchMatchRanges.count, 1)

        // Toggle soft wrap ON -> OFF -> ON and verify zero buffer newline mutation.
        driver.isSoftWrapEnabled = false
        flushLayoutCycles(host, count: 5)
        XCTAssertEqual(editor.string, Self.mixedLongLineCorpus)
        XCTAssertEqual(Data(editor.string.utf8), originalBytes)
        XCTAssertEqual(editor.selectedRange(), targetSelection)
        XCTAssertEqual(coordinator.searchMatchRanges.count, 1)

        driver.isSoftWrapEnabled = true
        flushLayoutCycles(host, count: 5)
        XCTAssertEqual(editor.string, Self.mixedLongLineCorpus)
        XCTAssertEqual(Data(editor.string.utf8), originalBytes)
        XCTAssertEqual(editor.selectedRange(), targetSelection)

        // Verify copyPreviewToPasteboard and saveFile write exact UTF-8 bytes without fabricating '\n'.
        let container = CodeTextEditorContainerView(
            initialText: Self.mixedLongLineCorpus,
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            isReadOnly: false,
            resourceContext: .diskFile(url: fileURL, fileName: fileURL.lastPathComponent, allowsEditing: true),
            softWrapEnabled: .constant(true)
        )
        let pb = NSPasteboard.withUniqueName()
        XCTAssertEqual(container.copyPreviewToPasteboard(pb), Self.mixedLongLineCorpus)
        XCTAssertTrue(container.saveFile(contentOverride: editor.string))
        let savedDiskBytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(savedDiskBytes, originalBytes, "Saving after soft wrap toggles must not insert any newline bytes")

        // Verify active IME marked text composition is preserved across soft-wrap toggle.
        try verifyIMEMarkedTextSurvivesSoftWrapToggle(editor: editor, driver: driver, host: host)
    }

    // MARK: - 5. Viewport Anchor Preservation, Zero Remount & Markdown Source Passthrough

    func testViewportAnchorPreservationNoRemountAndMarkdownSourcePassthrough() async throws {
        let multiLineCode = (1...90).map { idx in
            "func logicalFunctionLine_\(idx)() -> String { return \"Line \(idx) long body content for soft wrap anchor verification in viewport\" }"
        }.joined(separator: "\n")

        let driver = SoftWrapTestDriver(
            text: multiLineCode,
            fileName: "anchor.swift",
            isEditable: false
        )
        let (window, host) = makeOffscreenHost(
            width: 300,
            height: 240,
            rootView: SoftWrapHarnessView(driver: driver)
        )
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await waitForMountedEditor(in: host, expectedText: multiLineCode)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let coordinator = try XCTUnwrap(editor.chunkCoordinator)
        let initialGeneration = coordinator.documentGeneration

        // Scroll down past the first screenful of text.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 620))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        flushLayoutCycles(host, count: 4)
        let anchorBefore = try XCTUnwrap(coordinator.captureViewportAnchor(in: editor, scrollView: scrollView))
        XCTAssertFalse(anchorBefore.wasAtTop)
        // The threshold is derived from the live layout, because the ruler reservation narrows the
        // wrap width and therefore shifts how many characters fit into one screenful.
        XCTAssertGreaterThan(
            anchorBefore.characterIndex,
            try firstScreenCharacterBudget(editor: editor),
            "The captured anchor must sit beyond the first screenful of text"
        )

        // Toggle soft wrap ON -> OFF -> ON, resize window 300 -> 680 -> 300: must not remount and must preserve anchor region.
        driver.isSoftWrapEnabled = false
        flushLayoutCycles(host, count: 5)
        XCTAssertEqual(coordinator.documentGeneration, initialGeneration, "Soft wrap toggle must never remount or re-tokenize")
        let anchorUnwrapped = try XCTUnwrap(coordinator.captureViewportAnchor(in: editor, scrollView: scrollView))
        XCTAssertFalse(anchorUnwrapped.wasAtTop)
        XCTAssertLessThan(abs(anchorUnwrapped.characterIndex - anchorBefore.characterIndex), 220)

        driver.isSoftWrapEnabled = true
        flushLayoutCycles(host, count: 5)
        XCTAssertEqual(coordinator.documentGeneration, initialGeneration)
        let anchorRewrapped = try XCTUnwrap(coordinator.captureViewportAnchor(in: editor, scrollView: scrollView))
        XCTAssertLessThan(abs(anchorRewrapped.characterIndex - anchorBefore.characterIndex), 220)

        resizeOffscreenHost(host, window: window, width: 680, height: 240)
        flushLayoutCycles(host, count: 5)
        XCTAssertEqual(coordinator.documentGeneration, initialGeneration, "Window resize must never remount document")

        // Verify MarkdownRichPreviewView source mode inherits soft wrap preference from TTTextReadingPreferenceStore.
        try await assertMarkdownSourceModePassthrough(in: window)
    }

    // MARK: - Helpers

    // MARK: - Helpers

    /// Converts a document-space X coordinate into scroll-view space.
    private func screenX(_ documentX: CGFloat, scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        return documentX - clip.bounds.origin.x + clip.frame.origin.x
    }

    /// Number of characters that fit into the first screenful of the editor's visible viewport.
    private func firstScreenCharacterBudget(editor: LargeTextEditorTextView) throws -> Int {
        let manager = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        let probeWidth = min(container.containerSize.width, editor.bounds.width)
        let glyphRange = manager.glyphRange(
            forBoundingRect: NSRect(x: 0, y: 0, width: probeWidth, height: editor.visibleRect.height),
            in: container
        )
        return manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).length
    }

    private func assertUnwrappedTailGlyphReachableByHorizontalScroll(
        editor: LargeTextEditorTextView,
        scrollView: NSScrollView,
        layoutManager: NSLayoutManager,
        container: NSTextContainer,
        tailMarker: String
    ) throws {
        let nsString = editor.string as NSString
        let tailRange = nsString.range(of: tailMarker)
        XCTAssertNotEqual(tailRange.location, NSNotFound)
        let tailGlyphRange = layoutManager.glyphRange(forCharacterRange: tailRange, actualCharacterRange: nil)
        let tailRectInContainer = layoutManager.boundingRect(forGlyphRange: tailGlyphRange, in: container)
        let tailRectInTextView = tailRectInContainer.offsetBy(
            dx: editor.textContainerOrigin.x,
            dy: editor.textContainerOrigin.y
        )
        XCTAssertGreaterThan(
            tailRectInTextView.maxX,
            scrollView.contentSize.width,
            "Tail marker must initially lie beyond the 280pt viewport width when unwrapped"
        )

        let maxScrollX = max(0.0, editor.frame.width - scrollView.contentSize.width)
        scrollView.contentView.scroll(to: NSPoint(x: maxScrollX, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let visibleAfterScroll = scrollView.contentView.bounds
        XCTAssertLessThanOrEqual(
            tailRectInTextView.maxX,
            visibleAfterScroll.maxX + 2.0,
            "Scrolling horizontally to the right edge must reveal the full line tail without truncation"
        )
    }

    private func assertRulerBitmapDrawsOnlyAtLogicalLineStarts(
        ruler: LineNumberRulerView,
        line1: LineNumberRulerView.LogicalLineNumberPlacement,
        line2: LineNumberRulerView.LogicalLineNumberPlacement
    ) throws {
        let rep = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
        ruler.cacheDisplay(in: ruler.bounds, to: rep)
        let bg = ruler.readingPalette.nsGutterBackgroundColor.usingColorSpace(.sRGB) ?? .black
        let scaleX = CGFloat(rep.pixelsWide) / max(1.0, ruler.bounds.width)
        let scaleY = CGFloat(rep.pixelsHigh) / max(1.0, ruler.bounds.height)

        func hasInkPixels(inPointBandY pointBandY: ClosedRange<CGFloat>) -> Bool {
            let startY = Int((pointBandY.lowerBound * scaleY).rounded(.down))
            let endY = Int((pointBandY.upperBound * scaleY).rounded(.up))
            let startX = Int((2.0 * scaleX).rounded(.down))
            let endX = max(startX + 1, Int(((ruler.bounds.width - 6.0) * scaleX).rounded(.up)))
            for y in startY...endY where y >= 0 && y < rep.pixelsHigh {
                for x in startX..<endX where x >= 0 && x < rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let diff = abs(c.redComponent - bg.redComponent)
                        + abs(c.greenComponent - bg.greenComponent)
                        + abs(c.blueComponent - bg.blueComponent)
                    if diff > 0.12 { return true }
                }
            }
            return false
        }

        let line1StartBand = line1.rectInRuler.minY...line1.rectInRuler.maxY
        let contLower = line1.rectInRuler.maxY + 3.0
        let contUpper = max(contLower, line2.rectInRuler.minY - 3.0)
        let line1ContinuationBand = contLower...contUpper
        let line2StartBand = line2.rectInRuler.minY...line2.rectInRuler.maxY
        XCTAssertTrue(hasInkPixels(inPointBandY: line1StartBand), "Ruler must draw ink for logical line 1")
        XCTAssertFalse(hasInkPixels(inPointBandY: line1ContinuationBand), "Ruler must NOT draw any fabricated line number on wrapped continuation lines")
        XCTAssertTrue(hasInkPixels(inPointBandY: line2StartBand), "Ruler must draw ink for logical line 2 at its shifted Y offset")
    }

    private func verifyIMEMarkedTextSurvivesSoftWrapToggle(
        editor: LargeTextEditorTextView,
        driver: SoftWrapTestDriver,
        host: NSView
    ) throws {
        let insertionLocation = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: insertionLocation, length: 0))
        let markedString = "中文输入法未上屏组合串"
        editor.setMarkedText(
            markedString,
            selectedRange: NSRange(location: (markedString as NSString).length, length: 0),
            replacementRange: NSRange(location: insertionLocation, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText(), "Editor must hold active IME marked text")

        driver.isSoftWrapEnabled = false
        flushLayoutCycles(host, count: 4)
        XCTAssertTrue(editor.hasMarkedText(), "Toggling soft wrap OFF must not cancel active IME marked text")
        XCTAssertTrue(editor.string.hasSuffix(markedString))

        driver.isSoftWrapEnabled = true
        flushLayoutCycles(host, count: 4)
        XCTAssertTrue(editor.hasMarkedText(), "Toggling soft wrap ON must not cancel active IME marked text")

        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(editor.string.hasSuffix(markedString))
    }

    private func assertMarkdownSourceModePassthrough(in window: NSWindow) async throws {
        let suiteName = "ttmedia.test.md.softwrap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TTTextReadingPreferenceStore(defaults: defaults)
        store.isSoftWrapEnabled = false

        let mdHost = NSHostingView(
            rootView: MarkdownRichPreviewView(
                initialMarkdown: "# Heading\n\n" + Self.mixedLongLineCorpus,
                fileURL: nil,
                fileName: "readme.md",
                initialMode: .source,
                readingPreferenceStore: store
            )
            .frame(width: 300, height: 240)
        )
        mdHost.sizingOptions = []
        window.contentView = mdHost
        window.setContentSize(NSSize(width: 300, height: 240))
        mdHost.frame = NSRect(x: 0, y: 0, width: 300, height: 240)
        flushLayoutCycles(mdHost, count: 8)

        let mdEditor = try XCTUnwrap(findEditor(in: mdHost))
        XCTAssertEqual(mdEditor.textContainer?.widthTracksTextView, false)
        XCTAssertTrue(mdEditor.isHorizontallyResizable)

        store.isSoftWrapEnabled = true
        flushLayoutCycles(mdHost, count: 6)
        XCTAssertEqual(mdEditor.textContainer?.widthTracksTextView, true)
        XCTAssertFalse(mdEditor.isHorizontallyResizable)
    }

    private func makeOffscreenHost<Content: View>(
        width: CGFloat,
        height: CGFloat,
        rootView: Content
    ) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: AnyView(rootView)
        )
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        XCTAssertFalse(window.isVisible, "Offscreen test window must never be visible in foreground")
        return (window, host)
    }

    private func resizeOffscreenHost(
        _ host: NSHostingView<AnyView>,
        window: NSWindow,
        width: CGFloat,
        height: CGFloat
    ) {
        window.setContentSize(NSSize(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        flushLayoutCycles(host, count: 2)
    }

    private func flushLayoutCycles(_ host: NSView, count: Int) {
        for _ in 0..<count {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            if let scroll = findScrollView(in: host) as? CodePreviewScrollView {
                scroll.synchronizeDocumentViewport(force: true)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    private func waitForMountedEditor(
        in host: NSView,
        expectedText: String
    ) async throws -> LargeTextEditorTextView {
        let deadline = ProcessInfo.processInfo.systemUptime + 5.0
        repeat {
            flushLayoutCycles(host, count: 2)
            if let editor = findEditor(in: host),
               editor.string == expectedText,
               editor.frame.width > 0,
               editor.frame.height > 0 {
                return editor
            }
            await Task.yield()
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NSError(domain: "TextSoftWrapAndLineNumberLayoutTests", code: 1)
    }

    private func findEditor(in view: NSView) -> LargeTextEditorTextView? {
        if let editor = view as? LargeTextEditorTextView { return editor }
        for child in view.subviews {
            if let found = findEditor(in: child) { return found }
        }
        return nil
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = findScrollView(in: child) { return found }
        }
        return nil
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
}

@MainActor
@Observable
private final class SoftWrapTestDriver {
    var text: String
    var fileName: String
    var fileURL: URL?
    var isEditable: Bool
    var isSoftWrapEnabled: Bool = TTTextReadingPreferenceStore.defaultSoftWrapEnabled
    var mode: TTTextReadingBackgroundMode = .black
    var state: TTTextFloatingToolsPresentationState? = .popoverExpanded

    init(text: String, fileName: String, fileURL: URL? = nil, isEditable: Bool) {
        self.text = text
        self.fileName = fileName
        self.fileURL = fileURL
        self.isEditable = isEditable
    }
}

private struct SoftWrapHarnessView: View {
    @Bindable var driver: SoftWrapTestDriver

    var body: some View {
        CodeTextEditorContainerView(
            initialText: driver.text,
            fileURL: driver.fileURL,
            fileName: driver.fileName,
            isReadOnly: !driver.isEditable,
            resourceContext: driver.fileURL.map {
                .diskFile(url: $0, fileName: driver.fileName, allowsEditing: driver.isEditable)
            },
            readingBackgroundMode: $driver.mode,
            softWrapEnabled: $driver.isSoftWrapEnabled,
            floatingToolsState: $driver.state
        )
        .environment(\.colorScheme, .dark)
    }
}
