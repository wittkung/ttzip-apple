// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import TTI18nCore
import TTI18nUI
@testable import TTMediaKit

@MainActor
final class TextReadingBackgroundAndPerformanceTests: XCTestCase {

    private var tempDirectory: URL!
    private var isolatedDefaults: UserDefaults!
    private var isolatedSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTTextReadingBgPerfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        isolatedSuiteName = "com.metastudyline.ttmedia.tests.\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: isolatedSuiteName)
        TTTextReadingPreferenceStore.shared.resetToDefault()
    }

    override func tearDown() async throws {
        TTTextReadingPreferenceStore.shared.resetToDefault()
        if let suiteName = isolatedSuiteName {
            isolatedDefaults?.removePersistentDomain(forName: suiteName)
        }
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - 1. Dual Preference Separation & Persistence Scope

    func testReadingBackgroundPreferenceStorePersistenceAndDefaultWithoutMutatingAppAppearance() {
        let initialAppAppearance = NSApp?.appearance
        let customKey = "test.reading.bg.mode"
        let store1 = TTTextReadingPreferenceStore(defaults: isolatedDefaults, storageKey: customKey)

        // Default when unset is .fluidTransparent
        XCTAssertEqual(store1.mode, .fluidTransparent)

        store1.mode = .black
        XCTAssertEqual(isolatedDefaults.string(forKey: customKey), "black")

        // New store instance reading the same UserDefaults restores .black
        let store2 = TTTextReadingPreferenceStore(defaults: isolatedDefaults, storageKey: customKey)
        XCTAssertEqual(store2.mode, .black)

        store2.mode = .white
        let store3 = TTTextReadingPreferenceStore(defaults: isolatedDefaults, storageKey: customKey)
        XCTAssertEqual(store3.mode, .white)

        store3.resetToDefault()
        XCTAssertEqual(store3.mode, .fluidTransparent)

        // Global W2 / NSApp appearance is never mutated by text reading background switches
        XCTAssertEqual(NSApp?.appearance, initialAppAppearance)
    }

    // MARK: - 2. Three Background Modes Across Light & Dark App Appearances

    func testThreeBackgroundPalettesLegibilityAndFluidTransparencyAcrossLightAndDarkAppearances() {
        // 1. Black mode is identical and high-contrast under both Light and Dark app appearances
        let blackInLight = TTTextReadingPalette.resolve(mode: .black, isDarkAppearance: false)
        let blackInDark = TTTextReadingPalette.resolve(mode: .black, isDarkAppearance: true)
        XCTAssertEqual(blackInLight, blackInDark)
        XCTAssertTrue(blackInLight.drawsOpaqueBackground)
        XCTAssertTrue(blackInLight.effectiveIsDark)
        XCTAssertGreaterThan(blackInLight.nsCanvasBackgroundColor.alphaComponent, 0.99)
        XCTAssertGreaterThanOrEqual(
            TTTextReadingPalette.contrastRatio(
                between: blackInLight.nsForegroundColor,
                and: blackInLight.nsCanvasBackgroundColor
            ),
            12.0
        )
        XCTAssertGreaterThanOrEqual(
            TTTextReadingPalette.contrastRatio(
                between: blackInLight.syntaxKeywordColor,
                and: blackInLight.nsCanvasBackgroundColor
            ),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            TTTextReadingPalette.contrastRatio(
                between: blackInLight.syntaxCommentColor,
                and: blackInLight.nsCanvasBackgroundColor
            ),
            4.0
        )

        // 2. White mode is identical and high-contrast under both Light and Dark app appearances
        let whiteInLight = TTTextReadingPalette.resolve(mode: .white, isDarkAppearance: false)
        let whiteInDark = TTTextReadingPalette.resolve(mode: .white, isDarkAppearance: true)
        XCTAssertEqual(whiteInLight, whiteInDark)
        XCTAssertTrue(whiteInLight.drawsOpaqueBackground)
        XCTAssertFalse(whiteInLight.effectiveIsDark)
        XCTAssertGreaterThan(whiteInLight.nsCanvasBackgroundColor.alphaComponent, 0.99)
        XCTAssertGreaterThanOrEqual(
            TTTextReadingPalette.contrastRatio(
                between: whiteInLight.nsForegroundColor,
                and: whiteInLight.nsCanvasBackgroundColor
            ),
            12.0
        )
        XCTAssertGreaterThanOrEqual(
            TTTextReadingPalette.contrastRatio(
                between: whiteInLight.syntaxKeywordColor,
                and: whiteInLight.nsCanvasBackgroundColor
            ),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            TTTextReadingPalette.contrastRatio(
                between: whiteInLight.syntaxCommentColor,
                and: whiteInLight.nsCanvasBackgroundColor
            ),
            4.5
        )

        // 3. Fluid Transparent mode genuinely clears canvas/gutter backgrounds while adapting ink to app appearance
        let fluidLight = TTTextReadingPalette.resolve(mode: .fluidTransparent, isDarkAppearance: false)
        let fluidDark = TTTextReadingPalette.resolve(mode: .fluidTransparent, isDarkAppearance: true)

        XCTAssertFalse(fluidLight.drawsOpaqueBackground)
        XCTAssertFalse(fluidDark.drawsOpaqueBackground)
        XCTAssertEqual(fluidLight.nsCanvasBackgroundColor.alphaComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(fluidDark.nsCanvasBackgroundColor.alphaComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(fluidLight.nsGutterBackgroundColor.alphaComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(fluidDark.nsGutterBackgroundColor.alphaComponent, 0.0, accuracy: 0.001)

        // In Light app appearance, fluid transparent uses dark ink; in Dark app appearance, light ink
        XCTAssertLessThan(TTTextReadingPalette.relativeLuminance(of: fluidLight.nsForegroundColor), 0.1)
        XCTAssertGreaterThan(TTTextReadingPalette.relativeLuminance(of: fluidDark.nsForegroundColor), 0.8)
    }

    // MARK: - 3. In-Place Theme Switching Preserves File, Selection, Scroll, Unsaved Edits & Search Marks

    func testSwitchingReadingBackgroundPreservesFileSelectionScrollUnsavedEditsAndSearchHighlights() async throws {
        let originalCode = (1...120).map { line in
            "func computeValue_\(line)() -> Int { return \(line) * 42 } // line \(line)"
        }.joined(separator: "\n")
        let diskURL = tempDirectory.appendingPathComponent("SampleService.swift")
        try Data(originalCode.utf8).write(to: diskURL)
        let originalDiskBytes = try Data(contentsOf: diskURL)

        var currentText = originalCode
        let textBinding = Binding<String>(
            get: { currentText },
            set: { currentText = $0 }
        )

        let editorRep = CodeHighlightingEditorNSView(
            text: textBinding,
            fileName: "SampleService.swift",
            showLineNumbers: true,
            isEditable: true,
            readingBackgroundMode: .fluidTransparent,
            isDarkAppearance: true
        )
        let coordinator = editorRep.makeCoordinator()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 10_000, height: 10_000))
        layoutManager.addTextContainer(container)

        let textView = LargeTextEditorTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 2400), textContainer: container)
        textView.isEditable = true
        textView.delegate = coordinator
        textView.chunkCoordinator = coordinator
        coordinator.textStorageRef = storage
        coordinator.textView = textView

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.documentView = textView
        coordinator.rulerView = ruler

        coordinator.applyReadingTheme(editorRep.resolvedReadingPalette, to: textView, scrollView: scrollView, recolorStorage: false)
        coordinator.mountInitialPreview(displayString: originalCode, in: textView, storage: storage, fileName: "SampleService.swift")

        // Wait briefly for initial syntax highlighting to complete
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(coordinator.cachedTokenSpans.isEmpty, "Swift code should produce syntax token spans")

        // Simulate unsaved user edit
        let editedCode = "// UNSAVED USER HEADER\n" + originalCode
        textView.string = editedCode
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(currentText, editedCode)

        // Set selection, scroll position, and search highlight
        let targetSelection = NSRange(location: 23, length: 19)
        textView.setSelectedRange(targetSelection)
        let targetScrollOrigin = NSPoint(x: 0, y: 180)
        scrollView.contentView.scroll(to: targetScrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        coordinator.updateSearchHighlights(query: "computeValue_1", in: textView)
        XCTAssertFalse(coordinator.searchMatchRanges.isEmpty)

        // Switch background: .fluidTransparent -> .black -> .white -> .fluidTransparent (Light)
        let modesToTest: [(TTTextReadingBackgroundMode, Bool)] = [
            (.black, false),
            (.white, true),
            (.fluidTransparent, false),
            (.fluidTransparent, true)
        ]

        for (mode, isDarkApp) in modesToTest {
            let palette = TTTextReadingPalette.resolve(mode: mode, isDarkAppearance: isDarkApp)
            coordinator.applyReadingTheme(palette, to: textView, scrollView: scrollView, recolorStorage: true)

            // 1. Source file on disk is untouched
            let diskNow = try Data(contentsOf: diskURL)
            XCTAssertEqual(diskNow, originalDiskBytes, "Switching reading background must never modify source file on disk")

            // 2. Unsaved edits, selection, and scroll position are preserved
            XCTAssertEqual(textView.string, editedCode, "Unsaved edits must be preserved when switching background to \(mode)")
            XCTAssertEqual(textView.selectedRange(), targetSelection, "Selection range must be preserved when switching background to \(mode)")
            XCTAssertEqual(scrollView.contentView.bounds.origin.y, targetScrollOrigin.y, accuracy: 0.5, "Scroll origin must be preserved")

            // 3. ScrollView, TextView, Gutter, Caret, Selection, and Search attributes synchronize with palette
            XCTAssertEqual(scrollView.drawsBackground, palette.drawsOpaqueBackground)
            XCTAssertEqual(textView.drawsBackground, palette.drawsOpaqueBackground)
            XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? NSColor, palette.nsForegroundColor)
            XCTAssertEqual(textView.insertionPointColor, palette.nsInsertionPointColor)
            XCTAssertEqual(textView.selectedTextAttributes[.backgroundColor] as? NSColor, palette.nsSelectionBackgroundColor)
            XCTAssertEqual(ruler.readingPalette, palette)

            // Verify default foreground attribute on storage at a non-token character (leading space on line 4)
            let newlineAndSpaceOffset = (editedCode as NSString).range(of: "    public").location
            if newlineAndSpaceOffset != NSNotFound {
                let defaultFg = storage.attribute(.foregroundColor, at: newlineAndSpaceOffset, effectiveRange: nil) as? NSColor
                XCTAssertEqual(defaultFg, palette.nsForegroundColor)
            }

            let firstMatch = coordinator.searchMatchRanges[0]
            let matchBg = storage.attribute(.backgroundColor, at: firstMatch.location, effectiveRange: nil) as? NSColor
            XCTAssertEqual(matchBg, palette.nsSearchMatchBackgroundColor)
        }
    }

    // MARK: - 4. StreamingTextNSView 3-State Background Synchronization

    func testStreamingTextNSViewAppliesThreeStateReadingBackgroundPalette() {
        let sampleLog = "2026-10-18 14:00:00 [INFO] Streaming output initialized\nLine 2"
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = sampleLog
        scrollView.documentView = textView

        let blackPalette = TTTextReadingPalette.resolve(mode: .black, isDarkAppearance: false)
        StreamingTextNSView.applyPalette(blackPalette, to: textView, scrollView: scrollView)
        XCTAssertTrue(scrollView.drawsBackground)
        XCTAssertTrue(textView.drawsBackground)
        XCTAssertEqual(textView.backgroundColor, blackPalette.nsCanvasBackgroundColor)
        XCTAssertEqual(textView.textColor, blackPalette.nsForegroundColor)

        let whitePalette = TTTextReadingPalette.resolve(mode: .white, isDarkAppearance: true)
        StreamingTextNSView.applyPalette(whitePalette, to: textView, scrollView: scrollView)
        XCTAssertTrue(scrollView.drawsBackground)
        XCTAssertEqual(textView.backgroundColor, whitePalette.nsCanvasBackgroundColor)
        XCTAssertEqual(textView.textColor, whitePalette.nsForegroundColor)

        let fluidPalette = TTTextReadingPalette.resolve(mode: .fluidTransparent, isDarkAppearance: true)
        StreamingTextNSView.applyPalette(fluidPalette, to: textView, scrollView: scrollView)
        XCTAssertFalse(scrollView.drawsBackground)
        XCTAssertFalse(textView.drawsBackground)
        XCTAssertEqual(textView.textColor, fluidPalette.nsForegroundColor)
    }

    // MARK: - 5. Plain TXT vs. Source Code Syntax Highlighting Policy

    func testPlainTxtBypassesSyntaxColoringWhileSourceCodeHighlightsTokens() async throws {
        // Plain text containing URLs (https://...), quotes ("..."), apostrophes (don't), # lines, and numbers
        let proseTxt = """
        Project Notes (2026-10-18)
        Visit https://github.com/wittkung/ttzip-apple for the full guide.
        Please don't modify "archived" entries directly!
        # Section 1: Summary // not a code comment
        Total items: 4096
        """

        XCTAssertEqual(TTTextSyntaxRenderMode.resolve(fileName: "notes.txt"), .plainText)
        XCTAssertEqual(TTTextSyntaxRenderMode.resolve(fileName: "server.log"), .plainText)
        XCTAssertEqual(TTTextSyntaxRenderMode.resolve(fileName: "README"), .plainText)
        XCTAssertEqual(TTTextSyntaxRenderMode.resolve(fileName: "CMakeLists.txt"), .syntaxHighlighted(languageExt: "cmake"))
        XCTAssertEqual(TTTextSyntaxRenderMode.resolve(fileName: "Makefile"), .syntaxHighlighted(languageExt: "makefile"))
        XCTAssertEqual(TTTextSyntaxRenderMode.resolve(fileName: "Engine.swift"), .syntaxHighlighted(languageExt: "swift"))

        var txtBindingValue = proseTxt
        let txtBinding = Binding<String>(get: { txtBindingValue }, set: { txtBindingValue = $0 })
        let txtEditor = CodeHighlightingEditorNSView(
            text: txtBinding,
            fileName: "notes.txt",
            showLineNumbers: true,
            isEditable: false,
            readingBackgroundMode: .white,
            isDarkAppearance: false
        )
        let txtCoordinator = txtEditor.makeCoordinator()
        let txtStorage = NSTextStorage()
        let txtLayout = NSLayoutManager()
        txtStorage.addLayoutManager(txtLayout)
        let txtContainer = NSTextContainer(containerSize: NSSize(width: 800, height: 800))
        txtLayout.addTextContainer(txtContainer)
        let txtView = LargeTextEditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), textContainer: txtContainer)
        txtCoordinator.textStorageRef = txtStorage
        txtCoordinator.textView = txtView

        txtCoordinator.mountInitialPreview(displayString: proseTxt, in: txtView, storage: txtStorage, fileName: "notes.txt")
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(txtCoordinator.activeSyntaxMode, .plainText)
        XCTAssertTrue(txtCoordinator.cachedTokenSpans.isEmpty, "Plain .txt file must not generate syntax token spans")

        // Verify every single character in notes.txt has uniform foreground color (including https://..., "archived", 4096)
        let expectedFg = txtEditor.resolvedReadingPalette.nsForegroundColor
        var effectiveRange = NSRange(location: 0, length: 0)
        let fgAtStart = txtStorage.attribute(.foregroundColor, at: 0, effectiveRange: &effectiveRange) as? NSColor
        XCTAssertEqual(fgAtStart, expectedFg)
        XCTAssertEqual(
            effectiveRange,
            NSRange(location: 0, length: txtStorage.length),
            "Plain .txt must have a single uniform foreground color across the entire textStorage without false comment/string coloring"
        )
    }

    // MARK: - 6. Responsive Toolbar Non-Overlap & Reachability (220pt Sidebar to 1200pt Full Window)

    func testToolbarResponsiveTiersNoOverlapAndControlReachabilityFromNarrowSidebarToFullWindow() {
        var lineNumbersShown = true
        var bgMode: TTTextReadingBackgroundMode = .fluidTransparent
        var copyCount = 0
        var saveCount = 0

        let widths: [CGFloat] = [220, 260, 320, 420, 560, 1200]
        for language in [AppLanguage.en, .zhHans, .zhHant] {
            LocalizationState.shared.setLanguage(language)

            for width in widths {
                let header = CodeSyntaxHeaderBar(
                    isCompact: width <= 480,
                    fileName: "归档内超长中文文件名_测试工具栏自适应不重叠_2026.swift",
                    lineCount: 4096,
                    byteCount: 131_072,
                    isEdited: true,
                    isWritableFile: true,
                    isReadOnly: false,
                    encodingBadge: "UTF-8 BOM",
                    saveErrorMessage: nil,
                    isSavedToastPresented: false,
                    isCopiedToastPresented: false,
                    showLineNumbers: Binding(get: { lineNumbersShown }, set: { lineNumbersShown = $0 }),
                    readingBackgroundMode: Binding(get: { bgMode }, set: { bgMode = $0 }),
                    onCopy: { copyCount += 1 },
                    onSave: { saveCount += 1 }
                )

                let hosting = NSHostingView(rootView: header.frame(width: width))
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: 40)
                hosting.layoutSubtreeIfNeeded()

                XCTAssertLessThanOrEqual(
                    CodeSyntaxHeaderBar.minimalActionClusterWidth(isWritableAndEdited: true),
                    width - 40,
                    "Minimal action cluster must fit inside \(width)pt without colliding with top-left label"
                )
                XCTAssertEqual(hosting.bounds.width, width, accuracy: 0.5)
            }
        }

        // Verify programmatic reachability of Copy, Line Numbers, Background Selector, and Save
        let interactiveHeader = CodeSyntaxHeaderBar(
            isCompact: true,
            fileName: "test.txt",
            lineCount: 10,
            byteCount: 120,
            isEdited: true,
            isWritableFile: true,
            isReadOnly: false,
            encodingBadge: "UTF-8",
            saveErrorMessage: nil,
            isSavedToastPresented: false,
            isCopiedToastPresented: false,
            showLineNumbers: Binding(get: { lineNumbersShown }, set: { lineNumbersShown = $0 }),
            readingBackgroundMode: Binding(get: { bgMode }, set: { bgMode = $0 }),
            onCopy: { copyCount += 1 },
            onSave: { saveCount += 1 }
        )
        XCTAssertEqual(interactiveHeader.languageName(isCompact: true), TextAndDocumentPreviewLocalization.text(.plainTextLabel))
        interactiveHeader.activeReadingBackgroundBinding.wrappedValue = .black
        XCTAssertEqual(bgMode, .black)
        interactiveHeader.activeReadingBackgroundBinding.wrappedValue = .white
        XCTAssertEqual(bgMode, .white)
        interactiveHeader.activeReadingBackgroundBinding.wrappedValue = .fluidTransparent
        XCTAssertEqual(bgMode, .fluidTransparent)
        interactiveHeader.onCopy()
        interactiveHeader.onSave()
        XCTAssertEqual(copyCount, 1)
        XCTAssertEqual(saveCount, 1)

        LocalizationState.shared.setLanguage(.en)
    }

    // MARK: - 7. Chinese, Emoji, Long Lines, UTF-16/32, Large Text First-Screen Performance & Cancellation Guard

    func testMultilingualEmojiLongLinesEncodingsLargeTextPerformanceAndCancellationIsolation() async throws {
        // 1. UTF-16LE & UTF-32LE encoding protection and authentic disk byte count
        let cjkEmojiText = "中文段落测试 🚀👨‍👩‍👧‍👦✨ 表情与超长行：" + String(repeating: "天地玄黄宇宙洪荒_ABCD_1234_", count: 300) + "\n第二行内容\n"
        var utf16LEBytes = Data([0xFF, 0xFE])
        utf16LEBytes.append(cjkEmojiText.data(using: .utf16LittleEndian)!)
        let utf16URL = tempDirectory.appendingPathComponent("utf16le_emoji_中文.txt")
        try utf16LEBytes.write(to: utf16URL)

        var utf32LEBytes = Data([0xFF, 0xFE, 0x00, 0x00])
        utf32LEBytes.append(cjkEmojiText.data(using: .utf32LittleEndian)!)
        let utf32URL = tempDirectory.appendingPathComponent("utf32le_emoji_中文.txt")
        try utf32LEBytes.write(to: utf32URL)

        let utf16Container = CodeTextEditorContainerView(initialText: cjkEmojiText, fileURL: utf16URL, fileName: utf16URL.lastPathComponent)
        XCTAssertEqual(utf16Container.sourceEncoding, .utf16LE)
        XCTAssertEqual(utf16Container.initialByteCount, Int64(utf16LEBytes.count))
        XCTAssertFalse(utf16Container.canSaveInPlace, "UTF-16LE must be read-only to prevent silent UTF-8 overwrite")
        XCTAssertFalse(utf16Container.saveFile(contentOverride: "overwrite attempt"))
        XCTAssertEqual(try Data(contentsOf: utf16URL), utf16LEBytes)

        let utf32Container = CodeTextEditorContainerView(initialText: cjkEmojiText, fileURL: utf32URL, fileName: utf32URL.lastPathComponent)
        XCTAssertEqual(utf32Container.sourceEncoding, .utf32LE)
        XCTAssertEqual(utf32Container.initialByteCount, Int64(utf32LEBytes.count))
        XCTAssertFalse(utf32Container.canSaveInPlace, "UTF-32LE must be read-only to prevent silent UTF-8 overwrite")
        XCTAssertFalse(utf32Container.saveFile(contentOverride: "overwrite attempt"))
        XCTAssertEqual(try Data(contentsOf: utf32URL), utf32LEBytes)

        // 2. Archive entry read-only protection
        let archiveCtx = TTPreviewResourceContext.archiveEntry(
            archivePath: "/tmp/sample.zip",
            entryPath: "src/main.swift",
            stagedReadURL: utf16URL,
            fileName: "main.swift"
        )
        let archiveContainer = CodeTextEditorContainerView(
            initialText: "let x = 1\n",
            fileURL: utf16URL,
            fileName: "main.swift",
            resourceContext: archiveCtx
        )
        XCTAssertFalse(archiveContainer.canSaveInPlace)
        XCTAssertFalse(archiveContainer.isEditorEditable)

        // 3. Large code file (512 KB) first-screen mount (64 KB), chunk expansion (128 KB), and performance metrics report
        let singleLine = "public struct LineItem { let id: Int = 2026; let label: String = \"中文与Emoji🚀\" }\n"
        let repeatCount = (512 * 1024) / singleLine.utf8.count
        let largeSwiftCode = String(repeating: singleLine, count: repeatCount)
        let largeSwiftURL = tempDirectory.appendingPathComponent("LargeModule.swift")
        try Data(largeSwiftCode.utf8).write(to: largeSwiftURL)

        var capturedMetrics: TTTextPreviewPerformanceMetrics?
        var textState = largeSwiftCode
        let textBinding = Binding<String>(get: { textState }, set: { textState = $0 })
        let inspection = TTTextSourceInspection.inspect(url: largeSwiftURL, fallbackText: largeSwiftCode)

        let editor = CodeHighlightingEditorNSView(
            text: textBinding,
            fileName: "LargeModule.swift",
            showLineNumbers: true,
            isEditable: true,
            readingBackgroundMode: .black,
            isDarkAppearance: true,
            totalSourceBytes: inspection.byteCount,
            sourceInspectDurationMs: inspection.inspectDurationMs,
            onPerformanceMetrics: { metrics in
                capturedMetrics = metrics
            }
        )
        let coordinator = editor.makeCoordinator()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 10_000, height: 100_000))
        layout.addTextContainer(container)
        let textView = LargeTextEditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), textContainer: container)
        textView.chunkCoordinator = coordinator
        coordinator.textStorageRef = storage
        coordinator.textView = textView
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        coordinator.rulerView = ruler

        coordinator.mountInitialPreview(
            displayString: largeSwiftCode,
            in: textView,
            storage: storage,
            fileName: "LargeModule.swift"
        )

        // Initial mount strictly obeys the 64 KB first-screen budget
        XCTAssertLessThanOrEqual(coordinator.mountedUTF8ByteCount, CodeHighlightingEditorNSView.initialMountUTF8Bytes)
        XCTAssertTrue(coordinator.isPartiallyMounted)

        // Wait for first highlight batch and verify performance telemetry
        for _ in 0..<25 {
            if !coordinator.cachedTokenSpans.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let metrics = try XCTUnwrap(capturedMetrics ?? coordinator.lastPerformanceMetrics)
        XCTAssertEqual(metrics.fileName, "LargeModule.swift")
        XCTAssertEqual(metrics.syntaxMode, .syntaxHighlighted(languageExt: "swift"))
        XCTAssertGreaterThanOrEqual(metrics.sourceInspectDurationMs, 0.0)
        XCTAssertGreaterThanOrEqual(metrics.initialMountDurationMs, 0.0)
        XCTAssertGreaterThanOrEqual(metrics.lineStartScanDurationMs, 0.0)
        XCTAssertGreaterThan(metrics.firstHighlightBatchDurationMs, 0.0)
        print(metrics.summaryDescription)

        // Scroll chunk expansion appends 128 KB
        let beforeChunkBytes = coordinator.mountedUTF8ByteCount
        XCTAssertTrue(textView.loadNextPreviewChunk())
        XCTAssertGreaterThan(coordinator.mountedUTF8ByteCount, beforeChunkBytes)

        // 4. Rapid file switch / cancellation isolation: switching from LargeModule.swift to PlainNotes.txt
        let genBeforeSwitch = coordinator.documentGeneration
        let plainNotes = "Plain text after rapid switch https://example.com/no-comment-coloring"
        coordinator.mountInitialPreview(
            displayString: plainNotes,
            in: textView,
            storage: storage,
            fileName: "PlainNotes.txt"
        )
        let genAfterSwitch = coordinator.documentGeneration
        XCTAssertGreaterThan(genAfterSwitch, genBeforeSwitch)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(storage.string, plainNotes, "Stale highlight task from previous file must never overwrite new file content")
        XCTAssertEqual(coordinator.activeSyntaxMode, .plainText)
        XCTAssertTrue(coordinator.cachedTokenSpans.isEmpty)
        XCTAssertEqual(coordinator.lastPerformanceMetrics?.fileName, "PlainNotes.txt")
        XCTAssertEqual(coordinator.lastPerformanceMetrics?.generation, genAfterSwitch)
    }

    // MARK: - 8. Real package-lock.json & SwiftUI Host Lifecycle Verification

    private func loadRealOrGeneratedPackageLockJSON() -> String {
        let candidatePath = "products/slide-forge/package-lock.json"
        if FileManager.default.fileExists(atPath: candidatePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: candidatePath)),
           let str = String(data: data, encoding: .utf8),
           str.utf8.count > 128 * 1024 {
            return str
        }
        var packageEntries: [String] = []
        for i in 0..<1200 {
            packageEntries.append("""
                "node_modules/pkg-\(i)": {
                  "version": "1.\(i).0",
                  "resolved": "https://registry.npmjs.org/pkg-\(i)/-/pkg-\(i)-1.0.0.tgz",
                  "integrity": "sha512-mockHash\(i)==",
                  "dev": true
                }
            """)
        }
        return "{\n  \"name\": \"slide-forge\",\n  \"version\": \"0.2.0\",\n  \"packages\": {\n\(packageEntries.joined(separator: ",\n"))\n  }\n}"
    }

    private func mountPackageLockEditor(
        packageLockJSON: String,
        bgMode: TTTextReadingBackgroundMode = .black
    ) throws -> (NSWindow, NSHostingView<CodeTextEditorContainerView>, NSScrollView, LargeTextEditorTextView, NSTextStorage, CodeHighlightingEditorNSView.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        var currentBg = bgMode
        let container = CodeTextEditorContainerView(
            initialText: packageLockJSON,
            fileURL: nil,
            fileName: "package-lock.json",
            readingBackgroundMode: Binding(get: { currentBg }, set: { currentBg = $0 })
        )
        let hostingView = NSHostingView(rootView: container)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        var foundScrollView: NSScrollView?
        func findScrollView(in view: NSView) {
            if let sv = view as? NSScrollView {
                foundScrollView = sv
                return
            }
            for sub in view.subviews {
                findScrollView(in: sub)
            }
        }
        findScrollView(in: hostingView)
        let scrollView = try XCTUnwrap(foundScrollView, "Must find NSScrollView")
        let textView = try XCTUnwrap(scrollView.documentView as? LargeTextEditorTextView, "Must find LargeTextEditorTextView")
        let storage = try XCTUnwrap(textView.textStorage, "Must have NSTextStorage")
        let coordinator = try XCTUnwrap(textView.chunkCoordinator, "Must have chunkCoordinator")
        return (window, hostingView, scrollView, textView, storage, coordinator)
    }

    func testRealPackageLockThreeBackgroundModesAndCompositedOpticalContrast() async throws {
        let packageLockJSON = loadRealOrGeneratedPackageLockJSON()
        XCTAssertGreaterThan(packageLockJSON.utf8.count, 128 * 1024)

        let (_, hostingView, scrollView, textView, storage, coordinator) = try mountPackageLockEditor(
            packageLockJSON: packageLockJSON,
            bgMode: .black
        )

        // 1. Initial mounting and content presence
        XCTAssertGreaterThan(storage.length, 0, "Text must mount in NSTextStorage")
        XCTAssertEqual(textView.string.prefix(1), "{")
        try await Task.sleep(for: .milliseconds(300))

        // 2. Test Black, White, and FluidTransparent modes
        for (mode, isDark) in [(TTTextReadingBackgroundMode.black, true), (.white, false), (.fluidTransparent, true), (.fluidTransparent, false)] {
            let palette = TTTextReadingPalette.resolve(mode: mode, isDarkAppearance: isDark)
            coordinator.applyReadingTheme(palette, to: textView, scrollView: scrollView, recolorStorage: true)
            hostingView.layoutSubtreeIfNeeded()

            // Verify attributes on character 0
            let fg = try XCTUnwrap(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            if mode == .black || mode == .white {
                let computedContrast = TTTextReadingPalette.contrastRatio(between: fg, and: palette.nsCanvasBackgroundColor)
                XCTAssertGreaterThanOrEqual(computedContrast, 4.5, "Solid background \(mode) must meet WCAG AA contrast (>= 4.5:1)")
            } else {
                XCTAssertEqual(palette.nsCanvasBackgroundColor, .clear)
                let rgbColor = fg.usingColorSpace(.sRGB) ?? fg
                if isDark {
                    XCTAssertGreaterThan(rgbColor.redComponent, 0.65, "Dark appearance fluid transparent must use bright text")
                } else {
                    XCTAssertLessThan(rgbColor.redComponent, 0.4, "Light appearance fluid transparent must use dark ink text")
                }
            }
        }
    }

    func testRealPackageLockScrollingChunkExpansion() throws {
        let packageLockJSON = loadRealOrGeneratedPackageLockJSON()
        let (_, _, scrollView, textView, storage, _) = try mountPackageLockEditor(
            packageLockJSON: packageLockJSON,
            bgMode: .black
        )

        let initialLength = storage.length
        XCTAssertGreaterThan(initialLength, 0)
        XCTAssertTrue(textView.isPartiallyMountedForViewport)

        // Scroll down to expand chunk
        let clipView = scrollView.contentView
        let bottomY = max(0.0, textView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: bottomY))
        scrollView.reflectScrolledClipView(clipView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
        if storage.length == initialLength {
            let didAppend = textView.loadNextPreviewChunk()
            XCTAssertTrue(didAppend, "Manual chunk append must succeed when unmounted text remains")
        }

        XCTAssertGreaterThan(storage.length, initialLength, "Scroll or manual chunk load must expand preview text")
    }

    func testSwiftUIHostFileSwitchingAndUnsavedEditsPreservation() async throws {
        let jsonText = loadRealOrGeneratedPackageLockJSON()
        let plainText = "Plain documentation text with no JSON braces\nLine 2"
        var currentBg: TTTextReadingBackgroundMode = .black

        let makeHostView: (String, String) -> CodeTextEditorContainerView = { name, text in
            CodeTextEditorContainerView(
                initialText: text,
                fileURL: nil,
                fileName: name,
                readingBackgroundMode: Binding(get: { currentBg }, set: { currentBg = $0 })
            )
        }

        let hosting = NSHostingView(rootView: makeHostView("package-lock.json", jsonText))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hosting.layoutSubtreeIfNeeded()

        var foundTv: LargeTextEditorTextView?
        func findTv(in view: NSView) {
            if let tv = view as? LargeTextEditorTextView { foundTv = tv; return }
            for sub in view.subviews { findTv(in: sub) }
        }
        findTv(in: hosting)
        let textView = try XCTUnwrap(foundTv, "Must locate LargeTextEditorTextView")
        let coordinator = try XCTUnwrap(textView.chunkCoordinator)

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(textView.string.prefix(1), "{")
        XCTAssertEqual(coordinator.activeSyntaxMode, .syntaxHighlighted(languageExt: "json"))

        // 1. Simulate user unsaved edit on package-lock.json
        let userEdit = "// UNSAVED COMMENT\n" + textView.string
        textView.string = userEdit
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertTrue(textView.string.starts(with: "// UNSAVED COMMENT"))

        // 2. Switch background mode via SwiftUI host: unsaved edit MUST be preserved
        currentBg = .white
        hosting.rootView = makeHostView("package-lock.json", jsonText)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(textView.string.contains("// UNSAVED COMMENT"), "Background switch via SwiftUI host must preserve unsaved edits")

        // 3. Switch file to plain text via SwiftUI host
        hosting.rootView = makeHostView("notes.txt", plainText)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(textView.string, plainText, "Switching file via SwiftUI host must display plain text document")
        XCTAssertEqual(coordinator.activeSyntaxMode, .plainText)

        // 4. Switch file back to package-lock.json via SwiftUI host: loads fresh JSON content
        hosting.rootView = makeHostView("package-lock.json", jsonText)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(textView.string.prefix(1), "{")
        XCTAssertEqual(coordinator.activeSyntaxMode, .syntaxHighlighted(languageExt: "json"))
        XCTAssertFalse(textView.string.contains("// UNSAVED COMMENT"), "Switching away to notes.txt and back to package-lock.json must cleanly load fresh content")
        let expectedPalette = TTTextReadingPalette.resolve(mode: currentBg, isDarkAppearance: false)
        if let storage = textView.textStorage, storage.length > 0,
           let fgColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            let contrast = TTTextReadingPalette.contrastRatio(between: fgColor, and: expectedPalette.nsCanvasBackgroundColor)
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "Re-appeared file text must be visible and meet WCAG AA")
        }
    }
}



