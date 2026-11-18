// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import TTMediaKit
import TTZipCore
import TTZipUI
import TTZipBenchmarkKit
import os
@testable import TTZipPreviewKit
@testable import TTZipApp

final class CodeSyntaxPreviewTests: XCTestCase {

    func testThreeBackgroundPalettesLegibilityAndFluidTransparencyAcrossLightAndDarkAppearances() {
        let blackInLight = TTZipTextReadingAppearance.resolve(mode: .black, isDarkAppearance: false)
        let blackInDark = TTZipTextReadingAppearance.resolve(mode: .black, isDarkAppearance: true)
        XCTAssertEqual(blackInLight, blackInDark)
        XCTAssertTrue(blackInLight.drawsOpaqueBackground)
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

        let whiteInLight = TTZipTextReadingAppearance.resolve(mode: .white, isDarkAppearance: false)
        let whiteInDark = TTZipTextReadingAppearance.resolve(mode: .white, isDarkAppearance: true)
        XCTAssertEqual(whiteInLight, whiteInDark)
        XCTAssertTrue(whiteInLight.drawsOpaqueBackground)
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

        let fluidLight = TTZipTextReadingAppearance.resolve(mode: .fluidTransparent, isDarkAppearance: false)
        let fluidDark = TTZipTextReadingAppearance.resolve(mode: .fluidTransparent, isDarkAppearance: true)

        XCTAssertFalse(fluidLight.drawsOpaqueBackground)
        XCTAssertFalse(fluidDark.drawsOpaqueBackground)
        XCTAssertEqual(fluidLight.nsCanvasBackgroundColor.alphaComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(fluidDark.nsCanvasBackgroundColor.alphaComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(fluidLight.nsGutterBackgroundColor.alphaComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(fluidDark.nsGutterBackgroundColor.alphaComponent, 0.0, accuracy: 0.001)

        XCTAssertLessThan(TTTextReadingPalette.relativeLuminance(of: fluidLight.nsForegroundColor), 0.1)
        XCTAssertGreaterThan(TTTextReadingPalette.relativeLuminance(of: fluidDark.nsForegroundColor), 0.8)
    }

    private static let aaButtonID = "CodeFloatingAaToolsButton"
    private static let increaseFontID = "CodeFloatingFontIncreaseButton"

    @MainActor
    func testArchivedCodeRouteKeepsViewportStableWhenOpeningReadingTools() async throws {
        let source = (0..<300).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let stagedURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
        let sourceBytes = Data(source.utf8)
        try sourceBytes.write(to: stagedURL)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let bounds = NSRect(x: 0, y: 0, width: 240, height: 380)
        let preview = MediaPreviewView(
            fileData: sourceBytes,
            fileName: "Archived.swift",
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(
                archivePath: "/archives/source.zip",
                entryPath: "Sources/Archived.swift",
                stagedReadURL: stagedURL,
                fileName: "Archived.swift"
            )
        )
        let (window, host) = hostCodePreview(
            preview.environment(\.previewBottomTrailingReservedWidth, 34), size: bounds.size
        )
        defer {
            window.contentView = nil
            window.close()
        }

        let mountedEditor = await mountedView(in: host) { ($0 as? NSScrollView)?.documentView is NSTextView }
        let editor = try XCTUnwrap(mountedEditor as? NSScrollView)
        let textView = try XCTUnwrap(editor.documentView as? NSTextView)
        XCTAssertEqual(textView.string, source)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(editor.convert(editor.bounds, to: host), bounds)
        XCTAssertEqual(editor.contentView.bounds.minY, 0)
        let firstGlyphOrigin = textView.textContainerOrigin

        let toggle = try await mountedButton(Self.aaButtonID, in: host)
        let copy = try await mountedButton("CodeFloatingCopyButton", in: host)
        XCTAssertGreaterThanOrEqual(bounds.maxX - copy.convert(copy.bounds, to: host).maxX, 34)

        editor.contentView.scroll(to: NSPoint(x: 0, y: 140))
        editor.reflectScrolledClipView(editor.contentView)
        let scrolledBounds = editor.contentView.bounds
        XCTAssertGreaterThan(scrolledBounds.minY, 0)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        _ = try await mountedButton(Self.increaseFontID, in: host)
        try assertNarrowReadingToolsReachable(in: host)
        XCTAssertEqual(editor.convert(editor.bounds, to: host), bounds)
        XCTAssertEqual(editor.contentView.bounds, scrolledBounds)
        XCTAssertEqual(textView.textContainerOrigin, firstGlyphOrigin)
        XCTAssertEqual(try Data(contentsOf: stagedURL), sourceBytes)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testCodeReadingToolsChangeFontAndLineNumbersThroughVisibleControls() async throws {
        let source = "let answer = 42\nprint(answer)\n"
        let controls = MediaControlsVisibility()
        let (window, host) = hostCodePreview(codePreview(source, name: "Alpha.swift", controls: controls))
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await mountedCodeEditor(in: host)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(editor.string, source)
        XCTAssertTrue(scrollView.rulersVisible)
        XCTAssertEqual(try XCTUnwrap(editor.font?.pointSize), 12.5, accuracy: 0.05)
        XCTAssertFalse(controls.hasActiveInteractionLock)
        XCTAssertNil(button(Self.increaseFontID, in: host))

        let toggle = try await mountedButton(Self.aaButtonID, in: host)
        XCTAssertFalse(toggle.isTransparent)
        toggle.isEnabled = false
        XCTAssertFalse(toggle.accessibilityPerformPress())
        toggle.isEnabled = true
        toggle.isHidden = true
        XCTAssertFalse(toggle.accessibilityPerformPress())
        toggle.isHidden = false
        XCTAssertFalse(controls.hasActiveInteractionLock)

        try await openReadingTools(in: host, controls: controls)
        let increase = try await mountedButton(Self.increaseFontID, in: host)
        XCTAssertTrue(increase.accessibilityPerformPress())
        await assertPreviewUpdate(in: host) { editor.font?.pointSize == 13.5 }

        let decrease = try await mountedButton("CodeFloatingFontDecreaseButton", in: host)
        XCTAssertTrue(decrease.accessibilityPerformPress())
        await assertPreviewUpdate(in: host) { editor.font?.pointSize == 12.5 }

        let lineNumbers = try await mountedButton("CodeFloatingLineNumbersToggle", in: host)
        XCTAssertTrue(lineNumbers.accessibilityPerformPress())
        await assertPreviewUpdate(in: host) { !scrollView.rulersVisible }
        XCTAssertTrue(lineNumbers.accessibilityPerformPress())
        await assertPreviewUpdate(in: host) { scrollView.rulersVisible }
        XCTAssertEqual(editor.string, source)
        XCTAssertTrue(controls.hasActiveInteractionLock)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testCodeReadingToolsChangeThemeAndSoftWrapThroughVisibleControls() async throws {
        let defaults = UserDefaults.standard
        guard IsolatedTestPreferencesHarness.installedByDiscoveryBootstrap,
              defaults === IsolatedTestPreferencesHarness.sharedDefaults else {
            XCTFail("Code reading preferences must use the isolated test domain")
            return
        }

        let preferences = TTTextReadingPreferenceStore.shared
        let originalMode = preferences.mode
        let originalWrap = preferences.isSoftWrapEnabled
        let storedMode = defaults.object(forKey: preferences.storageKey)
        let storedWrap = defaults.object(forKey: preferences.softWrapStorageKey)
        defer {
            preferences.mode = originalMode
            preferences.isSoftWrapEnabled = originalWrap
            defaults.set(storedMode, forKey: preferences.storageKey)
            defaults.set(storedWrap, forKey: preferences.softWrapStorageKey)
        }

        let controls = MediaControlsVisibility()
        let source = "let line = \"\(String(repeating: "long code line ", count: 32))\"\n"
        let preview = codePreview(source, name: "Options.swift", controls: controls).environment(\.colorScheme, .dark)
        let (window, host) = hostCodePreview(preview)
        defer {
            window.contentView = nil
            window.close()
        }
        let editor = try await mountedCodeEditor(in: host)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        try await openReadingTools(in: host, controls: controls)

        let modes = TTTextReadingBackgroundMode.allCases.filter { $0 != originalMode } + [originalMode]
        for mode in modes {
            let theme = try await mountedButton("CodeFloatingThemeButton_\(mode.rawValue)", in: host)
            XCTAssertTrue(theme.accessibilityPerformPress())
            let palette = TTZipTextReadingAppearance.resolve(mode: mode, isDarkAppearance: true)
            await assertPreviewUpdate(in: host) {
                editor.backgroundColor == palette.nsCanvasBackgroundColor
                    && editor.drawsBackground == palette.drawsOpaqueBackground
            }
            XCTAssertEqual(defaults.string(forKey: preferences.storageKey), mode.rawValue)
        }

        let softWrap = try await mountedButton("CodeFloatingSoftWrapToggle", in: host)
        for wraps in [!originalWrap, originalWrap] {
            XCTAssertTrue(softWrap.accessibilityPerformPress())
            await assertPreviewUpdate(in: host) {
                editor.textContainer?.widthTracksTextView == wraps
                    && editor.isHorizontallyResizable == !wraps
                    && scrollView.hasHorizontalScroller == !wraps
            }
            XCTAssertEqual(defaults.object(forKey: preferences.softWrapStorageKey) as? Bool, wraps)
        }
        XCTAssertEqual(editor.string, source)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testCodeReadingToolsEscapeAndPreviewLifecycleReleaseLock() async throws {
        let controlsA = MediaControlsVisibility()
        let controlsB = MediaControlsVisibility()
        let (windowA, hostA) = hostCodePreview(codePreview("let alpha = 1\n", name: "Alpha.swift", controls: controlsA))
        let (windowB, hostB) = hostCodePreview(codePreview("let beta = 2\n", name: "Beta.swift", controls: controlsB))
        defer {
            windowA.contentView = nil
            windowB.contentView = nil
            windowA.close()
            windowB.close()
        }
        try await openReadingTools(in: hostA, controls: controlsA)
        try await openReadingTools(in: hostB, controls: controlsB)
        XCTAssertFalse(windowA.isKeyWindow)
        XCTAssertFalse(windowB.isKeyWindow)
        XCTAssertGreaterThan(windowA.windowNumber, 0)
        XCTAssertGreaterThan(windowB.windowNumber, 0)

        try sendEscape(windowNumber: 0)
        XCTAssertTrue(controlsA.hasActiveInteractionLock)
        XCTAssertTrue(controlsB.hasActiveInteractionLock)

        try sendEscape(windowNumber: windowB.windowNumber)
        await assertReadingToolsClosed(in: hostB, controls: controlsB)
        XCTAssertTrue(controlsA.hasActiveInteractionLock)
        XCTAssertNotNil(button(Self.increaseFontID, in: hostA))

        try sendEscape(windowNumber: windowA.windowNumber)
        await assertReadingToolsClosed(in: hostA, controls: controlsA)

        try await openReadingTools(in: hostA, controls: controlsA)
        let replacement = "let gamma = 3\n"
        hostA.rootView = codePreview(replacement, name: "Gamma.swift", controls: controlsA)
        await assertReadingToolsClosed(in: hostA, controls: controlsA)
        let editor = try await mountedCodeEditor(in: hostA)
        XCTAssertEqual(editor.string, replacement)

        try await openReadingTools(in: hostA, controls: controlsA)
        windowA.contentView = nil
        XCTAssertFalse(controlsA.hasActiveInteractionLock)
        windowA.contentView = hostA
        _ = try await mountedButton(Self.aaButtonID, in: hostA)
        await assertReadingToolsClosed(in: hostA, controls: controlsA)
        try await openReadingTools(in: hostA, controls: controlsA)
        XCTAssertFalse(windowA.isVisible)
        XCTAssertFalse(windowB.isVisible)
    }

    @MainActor
    func testCodePreviewCopiesSavedText() async throws {
        let source = "let value = 1\n"
        let saved = "let value = 2\n"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let fileName = fileURL.lastPathComponent
        let preview = TTZipCodePreviewView(
            text: source,
            fileURL: fileURL,
            fileName: fileName,
            resourceContext: .diskFile(url: fileURL, fileName: fileName, allowsEditing: true),
            pasteboard: pasteboard
        )
        let (window, host) = hostCodePreview(preview, size: NSSize(width: 260, height: 240))
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await mountedCodeEditor(in: host)
        XCTAssertFalse(editor.isEditable)
        let allowEditing = try await mountedButton("CodeFloatingAllowEditingButton", in: host)
        XCTAssertTrue(allowEditing.accessibilityPerformPress())
        await assertPreviewUpdate(in: host) { editor.isEditable }
        editor.insertText(saved, replacementRange: NSRange(location: 0, length: source.utf16.count))
        let save = try await mountedButton("CodeFloatingSaveButton", in: host)
        let targetURL = fileURL.standardizedFileURL
        let savedBytes = Data(saved.utf8)
        let notifications = OSAllocatedUnfairLock(initialState: [Data?]())
        let observer = NotificationCenter.default.addObserver(
            forName: .ttMediaFileContentDidChange, object: nil, queue: nil
        ) { notification in
            guard notification.object as? URL == targetURL else { return }
            let bytes = try? Data(contentsOf: targetURL)
            notifications.withLock { $0.append(bytes) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(save.accessibilityPerformPress())
        XCTAssertEqual(try Data(contentsOf: fileURL), savedBytes)
        XCTAssertEqual(notifications.withLock { $0 }, [savedBytes])

        let copy = try await mountedButton("CodeFloatingCopyButton", in: host)
        XCTAssertTrue(copy.accessibilityPerformPress())
        XCTAssertEqual(pasteboard.string(forType: .string), saved)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testTruncatedCodePreviewCopiesTheCompleteBoundedTextWithoutAllowingSave() async throws {
        let source = String(repeating: "let value = 1234567890 // 中文🚀\n", count: 65_000)
        let (bounded, truncated) = TTTextPreviewBytePolicy.truncateForPreview(source)
        XCTAssertTrue(truncated)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
        let bytes = Data(source.utf8)
        try bytes.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let preview = TTZipCodePreviewView(
            text: source, fileURL: fileURL, fileName: fileURL.lastPathComponent,
            resourceContext: .diskFile(url: fileURL), pasteboard: pasteboard
        )
        let (window, host) = hostCodePreview(preview)
        defer {
            window.contentView = nil
            window.close()
        }
        let editor = try await mountedCodeEditor(in: host)
        XCTAssertFalse(editor.isEditable)
        XCTAssertLessThan(editor.string.utf8.count, bounded.utf8.count)
        XCTAssertNil(button("CodeFloatingAllowEditingButton", in: host))
        XCTAssertNil(button("CodeFloatingSaveButton", in: host))
        let copy = try await mountedButton("CodeFloatingCopyButton", in: host)
        XCTAssertTrue(copy.accessibilityPerformPress())
        XCTAssertEqual(pasteboard.string(forType: .string), bounded)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testCodeReadingToolsLanguageLabelsFollowSyntaxPolicy() {
        for name in ["script.command", "script.sh", "script.bash", "script.zsh", "script.fish"] {
            for compact in [false, true] {
                XCTAssertEqual(TTZipCodeReadingTools.resolveLanguageName(for: name, isCompact: compact), "Shell")
            }
        }
        for name in ["script.commend", "script", "notes.txt"] {
            XCTAssertEqual(
                TTZipCodeReadingTools.resolveLanguageName(for: name, isCompact: true),
                TextAndDocumentPreviewLocalization.text(.plainTextLabel)
            )
        }
        XCTAssertEqual(TTZipCodeReadingTools.resolveLanguageName(for: "main.mm", isCompact: true), "C++")
        XCTAssertEqual(TTZipCodeReadingTools.resolveLanguageName(for: "Info.plist", isCompact: true), "XML")
    }

    @MainActor
    private func assertNarrowReadingToolsReachable(in host: NSView) throws {
        let buttonIDs = [
            Self.aaButtonID,
            "CodeFloatingCopyButton",
            "CodeFloatingFontDecreaseButton",
            Self.increaseFontID,
            "CodeFloatingSoftWrapToggle",
            "CodeFloatingLineNumbersToggle",
            "CodeFloatingThemeButton_black",
            "CodeFloatingThemeButton_white",
            "CodeFloatingThemeButton_fluidTransparent",
        ]
        for id in buttonIDs {
            let control = try XCTUnwrap(button(id, in: host), "Missing \(id) in the 240pt preview")
            let rect = control.convert(control.bounds, to: host)
            XCTAssertGreaterThanOrEqual(control.bounds.height, 27.5, id)
            XCTAssertTrue(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect), id)
            let center = host.convert(NSPoint(x: rect.midX, y: rect.midY), to: host.superview)
            let hit = try XCTUnwrap(host.hitTest(center), id)
            XCTAssertTrue(hit === control || hit.isDescendant(of: control), id)
            XCTAssertTrue(control.isEnabled, id)
            XCTAssertFalse(control.isTransparent, id)
        }
    }

    @MainActor
    private func codePreview(_ source: String, name: String, controls: MediaControlsVisibility) -> some View {
        TTZipCodePreviewView(
            text: source, fileURL: nil, fileName: name, resourceContext: .inMemory(fileName: name)
        )
        .environment(\.mediaControlsVisibility, controls)
    }

    @MainActor
    private func hostCodePreview<Content: View>(
        _ preview: Content,
        size: NSSize = NSSize(width: 640, height: 380)
    ) -> (NSWindow, NSHostingView<Content>) {
        let bounds = NSRect(origin: NSPoint(x: -16_000, y: -16_000), size: size)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: preview)
        host.sizingOptions = []
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        return (window, host)
    }

    @MainActor
    private func mountedCodeEditor(in host: NSView) async throws -> NSTextView {
        let editor = await mountedView(in: host) { $0 is NSTextView }
        return try XCTUnwrap(editor as? NSTextView)
    }

    @MainActor
    private func button(_ id: String, in host: NSView) -> NSButton? {
        firstView(in: host) { ($0 as? NSButton)?.accessibilityIdentifier() == id } as? NSButton
    }

    @MainActor
    private func mountedButton(_ id: String, in host: NSView) async throws -> NSButton {
        let control = await mountedView(in: host) { ($0 as? NSButton)?.accessibilityIdentifier() == id }
        return try XCTUnwrap(control as? NSButton, id)
    }

    @MainActor
    private func openReadingTools(in host: NSView, controls: MediaControlsVisibility) async throws {
        let toggle = try await mountedButton(Self.aaButtonID, in: host)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        _ = try await mountedButton(Self.increaseFontID, in: host)
        XCTAssertTrue(controls.hasActiveInteractionLock)
    }

    @MainActor
    private func assertReadingToolsClosed(in host: NSView, controls: MediaControlsVisibility) async {
        await assertPreviewUpdate(in: host) {
            !controls.hasActiveInteractionLock && button(Self.increaseFontID, in: host) == nil
        }
    }

    @MainActor
    private func sendEscape(windowNumber: Int) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        NSApplication.shared.sendEvent(event)
    }

    @MainActor
    private func assertPreviewUpdate(
        in host: NSView,
        file: StaticString = #filePath,
        line: UInt = #line,
        matching predicate: () -> Bool
    ) async {
        let observed = await mountedView(in: host) { $0 === host && predicate() }
        XCTAssertNotNil(observed, "Code preview did not update", file: file, line: line)
    }

    @MainActor
    private func mountedView(in host: NSView, matching predicate: (NSView) -> Bool) async -> NSView? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            host.layoutSubtreeIfNeeded()
            if let view = firstView(in: host, matching: predicate) { return view }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return nil
    }

    @MainActor
    private func firstView(in view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = firstView(in: child, matching: predicate) { return match }
        }
        return nil
    }

    // MARK: - 1. Streaming Tokenizer Tests with Priority Viewport
    
    func testStreamingTokenizerYieldsPriorityBatchFirst() async {
        let code = """
        import SwiftUI
        import AppKit
        
        // Priority header
        public struct MainView: View {
            let message: String = "Hello TTZip"
            let count: Int = 100
        }
        
        // Extended body content
        func computeValue() -> Int {
            return 42
        }
        """
        
        let priorityRange = NSRange(location: 0, length: 60)
        let stream = await BackgroundSyntaxTokenizer.shared.tokenizeStream(
            text: code,
            ext: "swift",
            priorityRange: priorityRange,
            batchSize: 10
        )
        
        var batches: [TokenSpanBatch] = []
        for await batch in stream {
            batches.append(batch)
        }
        
        XCTAssertFalse(batches.isEmpty, "Stream must yield at least one batch")
        let firstBatch = batches[0]
        XCTAssertTrue(firstBatch.isPriorityViewport, "First batch must be marked as priority viewport")
        XCTAssertEqual(firstBatch.batchIndex, 0)
        
        // Verify all priority spans are within the priority range
        for span in firstBatch.spans {
            let intersection = NSIntersectionRange(span.range, priorityRange)
            XCTAssertGreaterThan(intersection.length, 0, "Span in priority batch must intersect priorityRange")
        }
    }
    
    // MARK: - 2. Large File (>2MB) Tokenization & Batch Chunking Performance
    
    func testLargeFileProgressiveTokenizationUnderMemoryBudget() async {
        // Generate a 2.5 MB Swift code file with repeating functions
        var largeCode = "// TTZip High-Performance Syntax Engine Benchmark File\nimport Foundation\nimport TTZipCore\n\n"
        let template = """
        public struct ItemRecord%d: Sendable {
            public let id: Int = %d
            public let title: String = "Item title for index %d"
            // Computed checksum
            public func compute() -> Int {
                let multiplier = 42
                return self.id * multiplier
            }
        }
        
        """
        
        for i in 0..<10_000 {
            largeCode += String(format: template, i, i, i)
        }
        
        XCTAssertGreaterThan(largeCode.utf8.count, 2 * 1024 * 1024, "Code payload must exceed 2MB")
        
        let start = CACurrentMediaTime()
        let priorityRange = NSRange(location: 0, length: 1500)
        let stream = await BackgroundSyntaxTokenizer.shared.tokenizeStream(
            text: largeCode,
            ext: "swift",
            priorityRange: priorityRange,
            batchSize: 2000
        )
        
        var totalTokens = 0
        var batchCount = 0
        var firstBatchTime: Double = 0
        
        for await batch in stream {
            if batchCount == 0 {
                firstBatchTime = CACurrentMediaTime() - start
            }
            batchCount += 1
            totalTokens += batch.spans.count
        }
        let totalTime = CACurrentMediaTime() - start
        
        XCTAssertGreaterThan(totalTokens, 10000, "Should extract large volume of tokens")
        XCTAssertGreaterThan(batchCount, 1, "Should produce multiple batches for large files")
        XCTAssertLessThan(firstBatchTime, 10.0, "First priority batch must arrive rapidly under parallel load")
        XCTAssertLessThan(totalTime, 12.0, "Total tokenization for 2.5MB source must complete in under parallel load")
    }
    
    // MARK: - 3. Multi-Language Tokenizer Matrix Tests
    
    func testMultiLanguageTokenizationCategories() async {
        let languages: [(ext: String, code: String, expectedCategories: [ColorCategory])] = [
            ("rs", "fn main() {\n    let x: i32 = 42;\n    // Rust comment\n    let s = \"Rust string\";\n}", [.keyword, .type, .number, .comment, .string]),
            ("py", "def process_data(count: int) -> str:\n    # Python comment\n    message = 'Hello Python'\n    return 100", [.keyword, .type, .comment, .string, .number]),
            ("cpp", "#include <iostream>\nint calculate(int value) {\n    // C++ comment\n    const char* str = \"text\";\n    return 42;\n}", [.type, .comment, .string, .number]),
            ("swift", "import Foundation\nfunc calculate(value: Int) -> String {\n    // Swift comment\n    let name = \"TTZip\"\n    return name\n}", [.keyword, .type, .comment, .string]),
            ("ts", "interface Config {\n    id: number;\n    // TS comment\n    name: string;\n}", [.keyword, .type, .comment]),
            ("js", "const calculate = (val) => {\n    // JS comment\n    const name = \"TTZip\";\n    return 123;\n};", [.keyword, .comment, .string, .number])
        ]
        
        for lang in languages {
            let fullRange = NSRange(location: 0, length: (lang.code as NSString).length)
            let tokens = await BackgroundSyntaxTokenizer.shared.tokenize(
                text: lang.code,
                ext: lang.ext,
                targetRange: fullRange
            )
            
            XCTAssertFalse(tokens.isEmpty, "Language .\(lang.ext) should yield tokens")
            let foundCategories = Set(tokens.map { $0.colorType })
            for expected in lang.expectedCategories {
                XCTAssertTrue(
                    foundCategories.contains(expected),
                    "Language .\(lang.ext) must detect category \(expected)"
                )
            }
        }
    }
    
    // MARK: - 4. Read-Only Source Encoding

    @MainActor
    func testUTF16AndUTF32DiskCodePreviewsRemainReadOnly() async throws {
        let source = "编码保护测试 🚀\nLine 2\n"
        let fixtures: [(Data, String.Encoding)] = [
            (Data([0xFF, 0xFE]), .utf16LittleEndian),
            (Data([0xFF, 0xFE, 0x00, 0x00]), .utf32LittleEndian)
        ]
        for (bom, encoding) in fixtures {
            let bytes = bom + (try XCTUnwrap(source.data(using: encoding)))
            try await assertReadOnlyEncodedPreview(source: source, bytes: bytes)
        }
    }

    @MainActor
    private func assertReadOnlyEncodedPreview(source: String, bytes: Data) async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try bytes.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let context = TTPreviewResourceContext.diskFile(url: fileURL)
        XCTAssertTrue(context.isEditableInPlace)
        let preview = TTZipCodePreviewView(
            text: source, fileURL: fileURL, fileName: fileURL.lastPathComponent,
            resourceContext: context
        )
        let (window, host) = hostCodePreview(preview)
        defer {
            window.contentView = nil
            window.close()
        }

        let editor = try await mountedCodeEditor(in: host)
        XCTAssertEqual(editor.string, source)
        XCTAssertFalse(editor.isEditable)
        XCTAssertNil(button("CodeFloatingAllowEditingButton", in: host))
        XCTAssertNil(button("CodeFloatingSaveButton", in: host))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        XCTAssertFalse(window.isVisible)
    }
    
    // MARK: - 5. Large Code File Edit & Save Invariant
    
    @MainActor
    func testLargeFileAtomicSaveWithoutTruncation() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "CodeSyntax")
        let largeFileURL = tempDirURL.appendingPathComponent("huge_source.swift")
        let largeContent = String(repeating: "let item_value_record = 12345\n", count: 80_000)
        try largeContent.write(to: largeFileURL, atomically: true, encoding: .utf8)
        
        let fileSize = try FileManager.default.attributesOfItem(atPath: largeFileURL.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 2 * 1024 * 1024, "File size must exceed 2MB")
        
        let loadedContent = try XCTUnwrap(MediaPreviewView.readTextContent(from: largeFileURL))
        XCTAssertFalse(loadedContent.contains("TTZip Large File Notice"))
        XCTAssertEqual(loadedContent.utf8.count, largeContent.utf8.count)
        
        // Simulate edit and atomic rewrite
        let modifiedContent = "// Modified Header\n" + loadedContent
        try modifiedContent.write(to: largeFileURL, atomically: true, encoding: .utf8)
        
        let reloadedContent = try XCTUnwrap(MediaPreviewView.readTextContent(from: largeFileURL))
        XCTAssertTrue(reloadedContent.hasPrefix("// Modified Header\n"))
    }

    @MainActor
    func testImmersiveAutoHiddenCodePreviewSupportsKeyboardCopyAndPreservesViewport() async throws {
        let source = (1...80).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let controls = MediaControlsVisibility(inactivityDuration: .milliseconds(80))
        let preview = TTZipCodePreviewView(
            text: source, fileURL: nil, fileName: "Sample.swift",
            resourceContext: .inMemory(fileName: "Sample.swift"), pasteboard: pasteboard
        )
        .environment(\.isImmersiveFullscreen, true)
        .environment(\.mediaControlsVisibility, controls)
        let (window, host) = hostCodePreview(preview)
        defer {
            window.contentView = nil
            window.close()
        }

        let mounted = await mountedView(in: host) {
            guard let tv = $0 as? NSTextView else { return false }
            return tv.string == source && tv.frame.height > 400
        }
        let editor = try XCTUnwrap(mounted as? NSTextView)
        XCTAssertFalse(editor.isEditable)
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: 140))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let scrolledBounds = scrollView.contentView.bounds
        let baselineOrigin = editor.textContainerOrigin
        XCTAssertGreaterThan(scrolledBounds.minY, 100)

        controls.recordMouseMove(at: CGPoint(x: 180, y: 180))
        XCTAssertTrue(controls.isVisible)
        await assertPreviewUpdate(in: host) { !controls.isVisible }

        let aaButton = try XCTUnwrap(button(Self.aaButtonID, in: host))
        let copyButton = try XCTUnwrap(button("CodeFloatingCopyButton", in: host))
        window.recalculateKeyViewLoop()
        XCTAssertTrue(window.makeFirstResponder(editor))
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === aaButton)
        await assertPreviewUpdate(in: host) { controls.isVisible }

        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === copyButton)
        copyButton.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), source)
        XCTAssertEqual(scrollView.contentView.bounds, scrolledBounds)
        XCTAssertEqual(editor.textContainerOrigin, baselineOrigin)
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(window.isVisible)
    }
}
