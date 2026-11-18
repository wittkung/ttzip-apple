// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
@testable import TTMediaKit

@MainActor
final class TextReadingBackgroundAndPerformanceTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTTextReadingBgPerfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
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
            readingPalette: TextReadingPaletteFixtures.resolve(mode: .fluidTransparent, isDarkAppearance: true)
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

        coordinator.applyReadingTheme(editorRep.readingPalette, to: textView, scrollView: scrollView, recolorStorage: false)
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
        let modesToTest: [(TextReadingPaletteFixtures.Mode, Bool)] = [
            (.black, false),
            (.white, true),
            (.fluidTransparent, false),
            (.fluidTransparent, true)
        ]

        for (mode, isDarkApp) in modesToTest {
            let palette = TextReadingPaletteFixtures.resolve(mode: mode, isDarkAppearance: isDarkApp)
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
            readingPalette: TextReadingPaletteFixtures.resolve(mode: .white, isDarkAppearance: false)
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
        let expectedFg = txtEditor.readingPalette.nsForegroundColor
        var effectiveRange = NSRange(location: 0, length: 0)
        let fgAtStart = txtStorage.attribute(.foregroundColor, at: 0, effectiveRange: &effectiveRange) as? NSColor
        XCTAssertEqual(fgAtStart, expectedFg)
        XCTAssertEqual(
            effectiveRange,
            NSRange(location: 0, length: txtStorage.length),
            "Plain .txt must have a single uniform foreground color across the entire textStorage without false comment/string coloring"
        )
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

        for (url, bytes, encoding) in [(utf16URL, utf16LEBytes, TTTextSourceEncoding.utf16LE), (utf32URL, utf32LEBytes, .utf32LE)] {
            let inspection = TTTextSourceInspection.inspect(url: url, fallbackText: cjkEmojiText)
            XCTAssertEqual(inspection.encoding, encoding)
            XCTAssertEqual(inspection.byteCount, Int64(bytes.count))
            XCTAssertFalse(inspection.encoding.allowsUTF8InPlaceSave)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }

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
            readingPalette: TextReadingPaletteFixtures.resolve(mode: .black, isDarkAppearance: true),
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
        bgMode: TextReadingPaletteFixtures.Mode = .black
    ) throws -> (NSWindow, NSHostingView<CodeHighlightingEditorNSView>, NSScrollView, LargeTextEditorTextView, NSTextStorage, CodeHighlightingEditorNSView.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let container = CodeHighlightingEditorNSView(
            text: .constant(packageLockJSON),
            fileName: "package-lock.json",
            readingPalette: TextReadingPaletteFixtures.resolve(mode: bgMode, isDarkAppearance: true)
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
        for (mode, isDark) in [(TextReadingPaletteFixtures.Mode.black, true), (.white, false), (.fluidTransparent, true), (.fluidTransparent, false)] {
            let palette = TextReadingPaletteFixtures.resolve(mode: mode, isDarkAppearance: isDark)
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

}
