// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTI18nCore
@testable import TTMediaKit
import XCTest

@MainActor
final class CommandShellSyntaxHighlightTests: XCTestCase {
    private var tempDir: URL!
    private var savedSharedMode: TTTextReadingBackgroundMode = .fluidTransparent
    private var savedSharedSoftWrap: Bool = true

    override func setUp() async throws {
        try await super.setUp()
        savedSharedMode = TTTextReadingPreferenceStore.shared.mode
        savedSharedSoftWrap = TTTextReadingPreferenceStore.shared.isSoftWrapEnabled
        TTTextReadingPreferenceStore.shared.resetToDefault()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaCommandHighlightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TTTextReadingPreferenceStore.shared.mode = savedSharedMode
        TTTextReadingPreferenceStore.shared.isSoftWrapEnabled = savedSharedSoftWrap
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// Harmless self-built `.command` script fixture covering shebang, comments,
    /// double/single quoted strings, variables/parameters (`$VAR`, `${VAR}`, `$1`, `$?`),
    /// and shell control/builtin keywords. Never executed.
    private static let harmlessCommandFixture: String = [
        "#!/usr/bin/env zsh",
        "# MetastudyLine read-only .command preview fixture",
        "export APP_ENV=\"staging-cluster\"",
        "readonly RELEASE_TAG='v2.4.0'",
        "",
        "if [ -n \"$1\" ]; then",
        "    for target in $APP_ENV ${BUILD_DIR} $1 $?; do",
        "        echo \"inspecting\"",
        "    done",
        "else",
        "    return 0",
        "fi"
    ].joined(separator: "\n")

    // MARK: - 1. End-to-End .command Preview via Detector & Factory -> Real Attributed Output

    func testCommandFixtureRoutesThroughPreviewFactoryWithShellLanguageAndAttributedTokens() async throws {
        let commandURL = tempDir.appendingPathComponent("harmless_deploy.command")
        let fixtureData = Data(Self.harmlessCommandFixture.utf8)
        try fixtureData.write(to: commandURL, options: .atomic)

        // 1. Capability matrix & read-only detector routing across disk, async, and memory.
        let descriptor = TTMediaCapabilityMatrix.descriptor(for: commandURL.lastPathComponent)
        XCTAssertNotNil(descriptor, ".command must be registered in TTMediaCapabilityMatrix")
        XCTAssertEqual(descriptor?.displayName, "Shell Script")
        XCTAssertEqual(descriptor?.primaryMode, .sourceCode)
        XCTAssertTrue(descriptor?.capabilities.contains(.sourceCode) == true)
        XCTAssertEqual(descriptor?.mimeType, "application/x-sh")
        XCTAssertEqual(descriptor?.isEditableSource, true)
        XCTAssertTrue(TTMediaCapabilityMatrix.textExtensions.contains("command"))

        let syncPreview = TTMediaDetector.detectType(url: commandURL)
        let asyncPreview = await TTMediaDetector.detectTypeAsync(url: commandURL)
        let memoryPreview = TTMediaDetector.detectTypeFromMemory(
            data: fixtureData,
            suggestedName: commandURL.lastPathComponent,
            sourceURL: commandURL
        )

        guard case .text(let syncText) = syncPreview,
              case .text(let asyncText) = asyncPreview,
              case .text(let memoryText) = memoryPreview else {
            return XCTFail(".command fixture must route to read-only .text preview across all detector entry points")
        }
        XCTAssertEqual(syncText, Self.harmlessCommandFixture)
        XCTAssertEqual(asyncText, Self.harmlessCommandFixture)
        XCTAssertEqual(memoryText, Self.harmlessCommandFixture)

        // 2. Render mode & Shell language label resolution.
        let renderMode = TTTextSyntaxRenderMode.resolve(fileName: commandURL.lastPathComponent)
        XCTAssertEqual(renderMode, .syntaxHighlighted(languageExt: "command"))
        XCTAssertEqual(
            CodeSyntaxHeaderBar.resolveLanguageName(for: commandURL.lastPathComponent, isCompact: true),
            "Shell"
        )
        XCTAssertEqual(
            CodeSyntaxHeaderBar.resolveLanguageName(for: commandURL.lastPathComponent, isCompact: false),
            "Shell"
        )

        // 3. Enter through the real TTMediaPreviewFactory and mount in an AppKit window.
        let previewView = TTMediaPreviewFactory.makePreviewView(
            type: syncPreview,
            fileName: commandURL.lastPathComponent,
            fileURL: commandURL
        )
        let (window, _, textView, coordinator) = try await mountFactoryPreview(previewView)
        defer { window.orderOut(nil) }

        let metrics = try XCTUnwrap(coordinator.lastPerformanceMetrics)
        XCTAssertEqual(metrics.fileName, "harmless_deploy.command")
        XCTAssertEqual(metrics.syntaxMode, .syntaxHighlighted(languageExt: "command"))
        XCTAssertFalse(
            coordinator.cachedTokenSpans.isEmpty,
            ".command preview must produce non-empty syntax token spans"
        )

        let storage = try XCTUnwrap(textView.textStorage)
        let palette = coordinator.activeReadingPalette
        let nsText = storage.string as NSString

        // 4. Verify shebang and comment line receive comment token + comment foreground color.
        assertSubstringHighlight(
            in: storage,
            nsText: nsText,
            substring: "#!/usr/bin/env zsh",
            spans: coordinator.cachedTokenSpans,
            expectedCategory: .comment,
            expectedColor: palette.syntaxCommentColor
        )
        assertSubstringHighlight(
            in: storage,
            nsText: nsText,
            substring: "# MetastudyLine read-only .command preview fixture",
            spans: coordinator.cachedTokenSpans,
            expectedCategory: .comment,
            expectedColor: palette.syntaxCommentColor
        )

        // 5. Verify double- and single-quoted strings receive string token + string foreground color.
        for quotedLiteral in ["\"staging-cluster\"", "'v2.4.0'", "\"$1\"", "\"inspecting\""] {
            assertSubstringHighlight(
                in: storage,
                nsText: nsText,
                substring: quotedLiteral,
                spans: coordinator.cachedTokenSpans,
                expectedCategory: .string,
                expectedColor: palette.syntaxStringColor
            )
        }

        // 6. Verify shell variables and parameters ($APP_ENV, ${BUILD_DIR}, $1, $?) receive .type token + color.
        let forLineRange = nsText.range(of: "for target in $APP_ENV ${BUILD_DIR} $1 $?; do")
        XCTAssertNotEqual(forLineRange.location, NSNotFound)
        for shellParam in ["$APP_ENV", "${BUILD_DIR}", "$1", "$?"] {
            let paramRange = nsText.range(of: shellParam, options: [], range: forLineRange)
            XCTAssertNotEqual(paramRange.location, NSNotFound, "Missing \(shellParam) in fixture")
            XCTAssertTrue(
                coordinator.cachedTokenSpans.contains(where: {
                    $0.colorType == .type && NSIntersectionRange($0.range, paramRange).length == paramRange.length
                }),
                "Shell parameter \(shellParam) must be tokenized as .type"
            )
            let appliedColor = storage.attribute(.foregroundColor, at: paramRange.location, effectiveRange: nil) as? NSColor
            XCTAssertEqual(
                appliedColor,
                palette.syntaxTypeColor,
                "Shell parameter \(shellParam) must have syntaxTypeColor in NSTextStorage"
            )
        }

        // 7. Verify shell control & builtin keywords receive .keyword token + keyword color + semibold font.
        let expectedSemiboldFont = NSFont.monospacedSystemFont(ofSize: coordinator.activeFontSize, weight: .semibold)
        for keyword in ["export", "readonly", "if", "then", "for", "in", "do", "done", "else", "return", "fi"] {
            let kwRange = findStandaloneWordRange(word: keyword, in: storage.string)
            XCTAssertNotEqual(kwRange.location, NSNotFound, "Keyword \(keyword) not found in fixture")
            XCTAssertTrue(
                coordinator.cachedTokenSpans.contains(where: {
                    $0.colorType == .keyword && $0.range == kwRange
                }),
                "Shell keyword '\(keyword)' must be tokenized as .keyword"
            )
            let appliedColor = storage.attribute(.foregroundColor, at: kwRange.location, effectiveRange: nil) as? NSColor
            let appliedFont = storage.attribute(.font, at: kwRange.location, effectiveRange: nil) as? NSFont
            XCTAssertEqual(
                appliedColor,
                palette.syntaxKeywordColor,
                "Shell keyword '\(keyword)' must render with syntaxKeywordColor in NSTextStorage"
            )
            XCTAssertEqual(
                appliedFont,
                expectedSemiboldFont,
                "Shell keyword '\(keyword)' must render with semibold code font in NSTextStorage"
            )
        }
    }

    // MARK: - 2. .commend Typo, Extensionless Script & .txt Plain Text Isolation + sh/zsh Non-Regression

    func testCommendTypoExtensionlessAndTxtRemainPlainTextWhileShAndZshShareShellHighlighting() async throws {
        // 1. .commend (typo), extensionless, and .txt must degrade to plain text without renaming or false highlighting.
        let plainCandidates = ["typo_script.commend", "extensionless_script", "notes.txt"]

        for fileName in plainCandidates {
            let fileURL = tempDir.appendingPathComponent(fileName)
            try Data(Self.harmlessCommandFixture.utf8).write(to: fileURL, options: .atomic)

            // Verify file on disk was never silently renamed.
            XCTAssertEqual(fileURL.lastPathComponent, fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            let mode = TTTextSyntaxRenderMode.resolve(fileName: fileName)
            XCTAssertEqual(
                mode,
                .plainText,
                "\(fileName) must resolve to .plainText per unknown/plain-text contract"
            )
            XCTAssertEqual(
                CodeSyntaxHeaderBar.resolveLanguageName(for: fileName, isCompact: true),
                TextAndDocumentPreviewLocalization.text(.plainTextLabel)
            )

            let detected = TTMediaDetector.detectType(url: fileURL)
            let previewView = TTMediaPreviewFactory.makePreviewView(
                type: detected,
                fileName: fileName,
                fileURL: fileURL
            )
            let (window, _, textView, coordinator) = try await mountFactoryPreview(
                previewView,
                waitForHighlightTokens: false
            )
            defer { window.orderOut(nil) }

            XCTAssertTrue(
                coordinator.cachedTokenSpans.isEmpty,
                "\(fileName) must not run lexical syntax highlighting"
            )
            let storage = try XCTUnwrap(textView.textStorage)
            let palette = coordinator.activeReadingPalette
            var distinctColors = Set<NSColor>()
            storage.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                if let color = value as? NSColor {
                    distinctColors.insert(color)
                }
            }
            XCTAssertEqual(
                distinctColors,
                [palette.nsForegroundColor],
                "\(fileName) must keep a single uniform foreground color across NSTextStorage"
            )
        }

        // 2. .sh, .bash, and .zsh share the exact same Shell syntax family highlighting as .command.
        let commandSpans = await BackgroundSyntaxTokenizer.shared.tokenize(
            text: Self.harmlessCommandFixture,
            ext: "command",
            targetRange: NSRange(location: 0, length: Self.harmlessCommandFixture.utf16.count)
        )
        XCTAssertFalse(commandSpans.isEmpty)

        for shellExt in ["sh", "bash", "zsh"] {
            let shellFileName = "script.\(shellExt)"
            XCTAssertEqual(
                TTTextSyntaxRenderMode.resolve(fileName: shellFileName),
                .syntaxHighlighted(languageExt: shellExt)
            )
            XCTAssertEqual(
                CodeSyntaxHeaderBar.resolveLanguageName(for: shellFileName, isCompact: true),
                "Shell"
            )
            let shellSpans = await BackgroundSyntaxTokenizer.shared.tokenize(
                text: Self.harmlessCommandFixture,
                ext: shellExt,
                targetRange: NSRange(location: 0, length: Self.harmlessCommandFixture.utf16.count)
            )
            XCTAssertEqual(
                shellSpans,
                commandSpans,
                ".\(shellExt) and .command must produce identical Shell syntax token spans"
            )
        }
    }

    // MARK: - 3. IME Protection, Default Soft Wrap & Floating Reading Tools Contract Preservation

    func testCommandPreviewPreservesDefaultSoftWrapFloatingToolsAndIMEMarkedTextProtection() async throws {
        let commandURL = tempDir.appendingPathComponent("interactive_check.command")
        try Data(Self.harmlessCommandFixture.utf8).write(to: commandURL, options: .atomic)

        let detected = TTMediaDetector.detectType(url: commandURL)
        let previewView = TTMediaPreviewFactory.makePreviewView(
            type: detected,
            fileName: commandURL.lastPathComponent,
            fileURL: commandURL,
            resourceContext: .diskFile(url: commandURL, fileName: commandURL.lastPathComponent, allowsEditing: true)
        )
        let (window, hostingView, textView, coordinator) = try await mountFactoryPreview(previewView)
        defer { window.orderOut(nil) }

        // 1. Default soft wrap contract preserved.
        XCTAssertTrue(coordinator.activeSoftWrapEnabled, ".command preview must default to soft wrap enabled")
        XCTAssertEqual(textView.textContainer?.widthTracksTextView, true)

        // 2. Floating reading tools ([ Aa ⎘ ]) contract preserved.
        XCTAssertNotNil(
            findButton(in: hostingView, identifier: "CodeFloatingAaToolsButton"),
            "Floating appearance button (Aa) must be mounted on .command preview"
        )
        XCTAssertNotNil(
            findButton(in: hostingView, identifier: "CodeFloatingCopyButton"),
            "Floating copy button (⎘) must be mounted on .command preview"
        )

        // 3. IME marked-text composition protection preserved.
        window.makeFirstResponder(textView)
        let insertionPoint = (textView.string as NSString).length
        textView.setMarkedText(
            "中文输入法候选",
            selectedRange: NSRange(location: 0, length: 7),
            replacementRange: NSRange(location: insertionPoint, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())
        coordinator.highlightSyntaxProgressive(in: textView, fileName: commandURL.lastPathComponent)
        XCTAssertTrue(
            coordinator.needsHighlightAfterMarkedText,
            "Syntax recolor must defer while IME marked text is active"
        )
        XCTAssertTrue(textView.hasMarkedText(), "Marked text must never be clobbered by background highlighting")

        textView.unmarkText()
        XCTAssertFalse(textView.hasMarkedText())
    }

    // MARK: - Helpers

    private func mountFactoryPreview<V: View>(
        _ view: V,
        waitForHighlightTokens: Bool = true
    ) async throws -> (
        window: NSWindow,
        hostingView: NSHostingView<V>,
        textView: LargeTextEditorTextView,
        coordinator: CodeHighlightingEditorNSView.Coordinator
    ) {
        let hostingView = NSHostingView(rootView: view)
        let frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        hostingView.frame = frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        var foundTextView: LargeTextEditorTextView?
        for _ in 0..<60 {
            hostingView.layoutSubtreeIfNeeded()
            if let tv = findTextView(in: hostingView) {
                foundTextView = tv
                if let coord = tv.delegate as? CodeHighlightingEditorNSView.Coordinator {
                    if waitForHighlightTokens {
                        if coord.lastPerformanceMetrics != nil && !coord.cachedTokenSpans.isEmpty {
                            return (window, hostingView, tv, coord)
                        }
                    } else if coord.lastPerformanceMetrics != nil {
                        return (window, hostingView, tv, coord)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let tv = try XCTUnwrap(foundTextView, "Failed to locate mounted LargeTextEditorTextView")
        let coord = try XCTUnwrap(tv.delegate as? CodeHighlightingEditorNSView.Coordinator)
        return (window, hostingView, tv, coord)
    }

    private func findTextView(in root: NSView) -> LargeTextEditorTextView? {
        if let tv = root as? LargeTextEditorTextView { return tv }
        for subview in root.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func findButton(in root: NSView, identifier: String) -> NSButton? {
        if let button = root as? NSButton, button.accessibilityIdentifier() == identifier {
            return button
        }
        for subview in root.subviews {
            if let found = findButton(in: subview, identifier: identifier) {
                return found
            }
        }
        return nil
    }

    private func assertSubstringHighlight(
        in storage: NSTextStorage,
        nsText: NSString,
        substring: String,
        spans: [TokenSpan],
        expectedCategory: ColorCategory,
        expectedColor: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = nsText.range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Substring '\(substring)' not found", file: file, line: line)
        guard range.location != NSNotFound else { return }

        XCTAssertTrue(
            spans.contains(where: {
                $0.colorType == expectedCategory && NSIntersectionRange($0.range, range).length == range.length
            }),
            "Expected '\(substring)' to have token category \(expectedCategory)",
            file: file,
            line: line
        )
        let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(
            color,
            expectedColor,
            "Expected '\(substring)' to have foreground color \(expectedColor) in NSTextStorage",
            file: file,
            line: line
        )
    }

    private func findStandaloneWordRange(word: String, in text: String) -> NSRange {
        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        while searchRange.location < nsText.length {
            let found = nsText.range(of: word, options: [], range: searchRange)
            if found.location == NSNotFound { return found }
            let beforeOK: Bool = {
                guard found.location > 0 else { return true }
                let prev = nsText.character(at: found.location - 1)
                return !isWordChar(prev)
            }()
            let afterOK: Bool = {
                let end = found.location + found.length
                guard end < nsText.length else { return true }
                let next = nsText.character(at: end)
                return !isWordChar(next)
            }()
            if beforeOK && afterOK { return found }
            let nextStart = found.location + found.length
            searchRange = NSRange(location: nextStart, length: nsText.length - nextStart)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    private func isWordChar(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 45
    }
}
