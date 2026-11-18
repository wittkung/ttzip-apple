// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import WebKit
import class TTI18nUI.LocalizationState
import TTMediaKit
import TTZipUI
@testable import TTZipCore
@testable import TTZipPreviewKit
@testable import TTZipApp

@MainActor
final class PreviewKitFullscreenNotificationTests: XCTestCase {

    nonisolated override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            AppLocalizationState.shared.setLanguage(.en)
        }
    }

    // MARK: - Component Interaction & Fullscreen Gesture Triggers

    func testFullscreenButtonCopyMatchesCoreCatalogWhenAppLanguageChanges() {
        let appLocalization = AppLocalizationState.shared
        let previewLocalization = LocalizationState.shared
        let previousLanguage = appLocalization.currentLanguage
        defer { appLocalization.setLanguage(previousLanguage) }

        let key = PreviewWindowActionLocaleKey.fullScreen
        XCTAssertEqual(key.rawValue, L10n.Preview.fullScreen.rawValue)
        for language in TTZipCore.AppLanguage.allCases {
            appLocalization.setLanguage(language)
            XCTAssertEqual(previewLocalization.currentLanguage.bcp47, language.bcp47)
            let expected = TTZipLocalizationManager.shared.string(for: L10n.Preview.fullScreen, language: language)
            XCTAssertNotEqual(expected, key.rawValue)
            XCTAssertEqual(key.fallbackTranslation(for: previewLocalization.currentLanguage), expected)
            XCTAssertEqual(previewLocalization.t(key), expected)
        }
    }

    func testAVSampleBufferPlayerNSViewFKeyTriggersFullscreenCallback() {
        let playerView = AVSampleBufferPlayerNSView(frame: .zero)
        var callbackFired = false
        playerView.onToggleFullScreen = {
            callbackFired = true
        }

        guard let fEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ) else {
            XCTFail("Failed to construct F key event")
            return
        }

        playerView.keyDown(with: fEvent)
        XCTAssertTrue(callbackFired, "onToggleFullScreen callback must be executed on 'f' key")
    }

    func testAVSampleBufferPlayerNSViewDoubleClickTriggersFullscreenCallback() {
        let playerView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var fullscreenFired = false
        playerView.onToggleFullScreen = {
            fullscreenFired = true
        }

        let doubleClickEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 50, y: 120),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        )!

        playerView.mouseUp(with: doubleClickEvent)
        XCTAssertTrue(fullscreenFired, "Double click on player view must trigger onToggleFullScreen")
    }

    func testAVSampleBufferPlayerNSViewCanvasDoubleClickOverridesFullscreenCallback() {
        let playerView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var canvasDoubleClickFired = false
        var defaultFullscreenFired = false

        playerView.onCanvasDoubleClick = {
            canvasDoubleClickFired = true
        }
        playerView.onToggleFullScreen = {
            defaultFullscreenFired = true
        }

        let doubleClickEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 50, y: 120),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        )!

        playerView.mouseUp(with: doubleClickEvent)
        XCTAssertTrue(canvasDoubleClickFired, "Custom onCanvasDoubleClick must execute")
        XCTAssertFalse(defaultFullscreenFired, "Default onToggleFullScreen must be bypassed when onCanvasDoubleClick is provided")
    }

    // MARK: - MediaPreviewView Routing & Configuration

    func testMediaPreviewViewPropertiesAndTypeInvariants() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "PreviewKitFS")
        let testImageURL = tempDir.appendingPathComponent("photo.png")
        let imageView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png")
        XCTAssertEqual(imageView.fileURL, testImageURL)
        XCTAssertEqual(imageView.fileName, "photo.png")
        XCTAssertNil(imageView.isImmersiveFullscreen)

        let testVideoURL = tempDir.appendingPathComponent("clip.mp4")
        let videoView = MediaPreviewView(fileURL: testVideoURL, fileName: "clip.mp4")
        XCTAssertEqual(videoView.fileURL, testVideoURL)
        XCTAssertEqual(videoView.fileName, "clip.mp4")
        XCTAssertNil(videoView.isImmersiveFullscreen)

        let testWebURL = tempDir.appendingPathComponent("page.html")
        let webView = MediaPreviewView(fileURL: testWebURL, fileName: "page.html")
        XCTAssertEqual(webView.fileURL, testWebURL)
        XCTAssertEqual(webView.fileName, "page.html")
        XCTAssertNil(webView.isImmersiveFullscreen)

        let testMdURL = tempDir.appendingPathComponent("notes.md")
        let mdView = MediaPreviewView(fileURL: testMdURL, fileName: "notes.md")
        XCTAssertEqual(mdView.fileURL, testMdURL)
        XCTAssertEqual(mdView.fileName, "notes.md")
        XCTAssertNil(mdView.isImmersiveFullscreen)
    }

    func testMediaPreviewViewImmersiveFullscreenConfiguration() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "PreviewKitFS")
        let testImageURL = tempDir.appendingPathComponent("photo.png")
        let defaultView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png")
        XCTAssertNil(defaultView.isImmersiveFullscreen)

        let immersiveView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png", isImmersiveFullscreen: true)
        XCTAssertEqual(immersiveView.isImmersiveFullscreen, true)

        let windowedView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png", isImmersiveFullscreen: false)
        XCTAssertEqual(windowedView.isImmersiveFullscreen, false)
    }

    // MARK: - AppViewState Media Focus State Machine

    func testAppViewStateFullscreenNotificationHandlingAndStateTransition() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "PreviewKitFS")
        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        XCTAssertFalse(viewModel.showImmersiveMediaBrowser)
        XCTAssertNil(viewModel.immersiveMediaItem)

        let testFileURL = tempDir.appendingPathComponent("focus_sample.pdf")
        try? Data("PDF-1.7".utf8).write(to: testFileURL)

        viewModel.openImmersiveMedia(url: testFileURL, name: "focus_sample.pdf", fileSizeBytes: 1024)
        XCTAssertTrue(viewModel.showImmersiveMediaBrowser)
        XCTAssertTrue(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url, testFileURL)
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, "focus_sample.pdf")
        XCTAssertEqual(viewModel.immersiveMediaItem?.fileSizeBytes, 1024)
        XCTAssertEqual(viewModel.selectedDiskItem?.path, testFileURL.path)

        viewModel.closeImmersiveMedia()
        XCTAssertFalse(viewModel.showImmersiveMediaBrowser)
        XCTAssertFalse(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertNil(viewModel.immersiveMediaItem)
        XCTAssertNil(viewModel.overlayState.immersiveMediaItem)
    }
}

@MainActor
final class WebPreviewOwnershipTests: XCTestCase {
    func testArchiveMHTMLRendersInProductWebWorkspaceWithOfflinePolicy() async throws {
        let mime = [
            "MIME-Version: 1.0",
            "Content-Type: multipart/related; type=\"text/html\"; boundary=\"ttzip-preview-fixture\"",
            "",
            "--ttzip-preview-fixture",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "Content-Location: https://example.invalid/saved.html",
            "",
            "<html><body><h1 id='saved-report'>Archived report</h1></body></html>",
            "--ttzip-preview-fixture--",
            ""
        ].joined(separator: "\r\n")
        let preview = MediaPreviewView(
            fileData: Data(mime.utf8),
            fileName: "saved.mhtml",
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(
                archivePath: "/archives/sample.zip",
                entryPath: "documents/saved.mhtml",
                stagedReadURL: nil,
                fileName: "saved.mhtml"
            )
        )
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 240)
        let host = NSHostingView(rootView: preview.frame(width: bounds.width, height: bounds.height))
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let webView = firstView(in: host, matching: { $0 is WKWebView }) as? WKWebView, !webView.isLoading,
               let csp = try? await renderedArchiveCSP(in: webView), !csp.isEmpty {
                XCTAssertTrue(csp.contains("script-src 'none'"))
                XCTAssertTrue(csp.contains("connect-src 'none'"))
                let padding = try await renderedValue("getComputedStyle(document.body).padding", in: webView)
                XCTAssertEqual(padding, "16px")
                XCTAssertEqual(webView.pageZoom, 1.0)
                XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
                XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
                XCTAssertNotNil(firstView(in: host, matching: { $0.identifier?.rawValue == "TTZipWebPreviewToolbar" }))
                XCTAssertFalse(window.isVisible)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The archived MHTML document must render with the offline content policy")
    }

    func testRenderedHTMLKeepsProductLightDarkAndAuthorStyles() async throws {
        let html = "<html><body><a id='probe'>Link</a><code>Code</code><img width='2000'></body></html>"
        for (name, background, text, link) in [
            (NSAppearance.Name.aqua, "rgb(255, 255, 255)", "rgb(28, 28, 30)", "rgb(9, 105, 218)"),
            (.darkAqua, "rgb(30, 30, 30)", "rgb(229, 229, 231)", "rgb(88, 166, 255)")
        ] {
            try await withRenderedProduct(html, appearance: name) { webView in
                let actual = try await renderedValue("""
                    [getComputedStyle(document.body).backgroundColor, getComputedStyle(document.body).color,
                     getComputedStyle(document.querySelector('a')).color, getComputedStyle(document.body).padding,
                     getComputedStyle(document.querySelector('img')).maxWidth].join('|')
                    """, in: webView)
                XCTAssertEqual(actual, "\(background)|\(text)|\(link)|16px|100%")
                let font = try await renderedValue("getComputedStyle(document.body).fontFamily", in: webView)
                XCTAssertTrue(font.contains("-apple-system"))
                let lineHeight = try await renderedValue("""
                    String(Math.round(parseFloat(getComputedStyle(document.body).lineHeight)
                        / parseFloat(getComputedStyle(document.body).fontSize) * 10))
                    """, in: webView)
                XCTAssertEqual(lineHeight, "16")
                let codeFont = try await renderedValue("getComputedStyle(document.querySelector('code')).fontFamily", in: webView)
                XCTAssertTrue(codeFont.contains("ui-monospace"))
            }
        }
        let styled = "<html><head><style>body{background:#fafafa;color:#222}a{color:#123456}</style></head><body><a id='probe'>Link</a></body></html>"
        try await withRenderedProduct(styled, appearance: .darkAqua) { webView in
            let actual = try await renderedValue("""
                [getComputedStyle(document.body).backgroundColor, getComputedStyle(document.body).color,
                 getComputedStyle(document.querySelector('a')).color].join('|')
                """, in: webView)
            XCTAssertEqual(actual, "rgb(250, 250, 250)|rgb(34, 34, 34)|rgb(18, 52, 86)")
        }
    }

    func testRenderedSVGKeepsProductInsetAndAdapterGeometry() async throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='200'><rect id='probe' width='20' height='10' fill='currentColor'/><svg id='nested' width='30' height='40'/></svg>"
        try await withRenderedProduct(svg, appearance: .darkAqua) { webView in
            let actual = try await renderedValue("""
                [document.querySelector('body > svg').getAttribute('viewBox'),
                 getComputedStyle(document.body).padding, getComputedStyle(document.body).overflow,
                 getComputedStyle(document.querySelector('#probe')).fill,
                 getComputedStyle(document.querySelector('#nested')).width,
                 document.querySelector('#nested').width.baseVal.value + 'x'
                    + document.querySelector('#nested').height.baseVal.value].join('|')
                """, in: webView)
            XCTAssertEqual(actual, "0 0 400 200|16px|auto|rgb(229, 229, 231)|auto|30x40")
            XCTAssertEqual(webView.pageZoom, 1.0)
        }
    }

    private func withRenderedProduct(
        _ content: String,
        appearance: NSAppearance.Name,
        perform: (WKWebView) async throws -> Void
    ) async throws {
        let preview = TTZipWebPreviewView(
            content: content, fileURL: nil, fileName: "preview.html", resourceContext: .inMemory(fileName: "preview.html")
        )
        let bounds = NSRect(x: 0, y: 0, width: 640, height: 480)
        let host = NSHostingView(rootView: preview.frame(width: bounds.width, height: bounds.height))
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        let dark = appearance == .darkAqua ? "true" : "false"
        let ready = "document.querySelector('#probe') !== null && matchMedia('(prefers-color-scheme: dark)').matches === \(dark)"
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let webView = firstView(in: host, matching: { $0 is WKWebView }) as? WKWebView,
               let value = try? await renderedValue("String(\(ready))", in: webView), value == "true" {
                try await perform(webView)
                XCTAssertFalse(window.isVisible)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The product rendered surface must load with the requested appearance")
    }

    private func renderedValue(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { result in
                continuation.resume(with: result.map { $0 as? String ?? "" })
            }
        }
    }

    func testSVGZSourcePreservesDecodedTextAndReadOnlyContexts() async throws {
        let directory = try makeTemporaryDirectory(prefix: "TTZipSVGZSource")
        let fixtureURL = try locatePreviewFixturesRoot().appendingPathComponent("web/sample.svgz")
        let compressed = try Data(contentsOf: fixtureURL)
        let stagedURL = directory.appendingPathComponent("sample.svgz")
        try compressed.write(to: stagedURL)
        guard case .htmlWeb(let svg, let detectedURL) = TTMediaDetector.detectType(url: stagedURL) else {
            return XCTFail("Expected the real SVGZ fixture to resolve as decoded web content")
        }
        XCTAssertTrue(svg.contains("TTMedia 中文"))
        XCTAssertEqual(detectedURL, stagedURL)

        let archiveURL = directory.appendingPathComponent("sample.zip")
        let entryPath = "assets/sample.svgz"
        let contexts: [TTPreviewResourceContext] = [
            .diskFile(url: stagedURL, fileName: "sample.svgz", allowsEditing: true),
            .archiveEntry(
                archiveURL: archiveURL,
                entryPath: entryPath,
                stagedReadURL: stagedURL,
                fileName: "sample.svgz"
            )
        ]

        for context in contexts {
            let editor = TTZipWebPreviewView(
                content: svg, fileURL: stagedURL, fileName: "sample.svgz", resourceContext: context
            ).sourceCodeEditor
            XCTAssertNil(editor.fileURL)
            XCTAssertNil(editor.resourceContext.readableURL)
            XCTAssertTrue(editor.resourceContext.isDerivedRepresentation)
            XCTAssertEqual(editor.resourceContext.archiveEntryIdentity, context.archiveEntryIdentity)
            try await withMountedSourceEditor(editor, expectedText: svg) { _, textView in
                XCTAssertTrue(textView.isSelectable)
                XCTAssertFalse(textView.isEditable)
            }
        }

        XCTAssertEqual(
            contexts.last?.archiveEntryIdentity,
            TTPreviewArchiveEntryIdentity(archiveURL: archiveURL, entryPath: entryPath)
        )
        XCTAssertEqual(try Data(contentsOf: stagedURL), compressed)
    }

    func testArchivedMHTMLSourceDisplaysRawMIMEAndIsReadOnly() async throws {
        let directory = try makeTemporaryDirectory(prefix: "TTZipMHTMLSource")
        let fileName = "sample.mhtml"
        let fixtureURL = try locatePreviewFixturesRoot().appendingPathComponent("web/\(fileName)")
        let bytes = try Data(contentsOf: fixtureURL)
        let rawMIME = try String(contentsOf: fixtureURL, encoding: .utf8)
        let stagedURL = directory.appendingPathComponent(fileName)
        try bytes.write(to: stagedURL)
        guard case .htmlWeb(let content, let url) = TTMediaDetector.detectType(url: stagedURL) else {
            return XCTFail("Expected the saved-page fixture to resolve as web content")
        }
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: directory.appendingPathComponent("sample.zip"),
            entryPath: "documents/\(fileName)", stagedReadURL: stagedURL
        )
        let editor = TTZipWebPreviewView(
            content: content, fileURL: url, fileName: fileName, resourceContext: context
        ).sourceCodeEditor
        try await withMountedSourceEditor(editor, expectedText: rawMIME) { _, textView in
            XCTAssertTrue(textView.isSelectable)
            XCTAssertFalse(textView.isEditable)
        }
        XCTAssertEqual(try Data(contentsOf: stagedURL), bytes)
    }

    func testDiskHTMLSourceSavesUTF8BOMAndRejectsStaleChanges() async throws {
        let directory = try makeTemporaryDirectory(prefix: "TTZipHTMLSource")
        let url = directory.appendingPathComponent("page.html")
        let initial = "<html><body>Original</body></html>\n"
        let edited = "<html><body>Edited 中文</body></html>\n"
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data(initial.utf8)).write(to: url)
        guard case .htmlWeb(let content, let detectedURL) = TTMediaDetector.detectType(url: url) else {
            return XCTFail("Expected the disk file to resolve as web content")
        }
        let editor = TTZipWebPreviewView(
            content: content, fileURL: detectedURL, fileName: url.lastPathComponent,
            resourceContext: .diskFile(url: url)
        ).sourceCodeEditor
        try await withMountedSourceEditor(editor, expectedText: initial) { host, textView in
            XCTAssertFalse(textView.isEditable)
            try await pressAllowEditing(in: host)
            XCTAssertTrue(textView.isEditable)
            textView.insertText(edited, replacementRange: NSRange(location: 0, length: initial.utf16.count))
            try await pressSourceSave(in: host)
            XCTAssertEqual(try Data(contentsOf: url), bom + Data(edited.utf8))

            let externalBytes = bom + Data("<html><body>External update</body></html>\n".utf8)
            try externalBytes.write(to: url, options: .atomic)
            textView.insertText(initial, replacementRange: NSRange(location: 0, length: edited.utf16.count))
            try await pressSourceSave(in: host)
            XCTAssertEqual(try Data(contentsOf: url), externalBytes)
        }
    }

    private func pressAllowEditing(in host: NSView) async throws {
        let mounted = try await mountedView(in: host) {
            ($0 as? NSButton)?.accessibilityIdentifier() == "CodeFloatingAllowEditingButton"
        }
        let button = try XCTUnwrap(mounted as? NSButton)
        XCTAssertTrue(button.accessibilityPerformPress())
        _ = try await mountedView(in: host) { ($0 as? NSTextView)?.isEditable == true }
    }

    private func withMountedSourceEditor(
        _ editor: TTZipCodePreviewView,
        expectedText: String,
        perform: (NSView, NSTextView) async throws -> Void
    ) async throws {
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 240)
        let host = NSHostingView(rootView: editor.frame(width: bounds.width, height: bounds.height))
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        let mounted = try await mountedView(in: host) { ($0 as? NSTextView)?.string == expectedText }
        let textView = try XCTUnwrap(mounted as? NSTextView, "Expected the editor to display the document source")
        try await perform(host, textView)
        XCTAssertFalse(window.isVisible)
    }

    private func pressSourceSave(in host: NSView) async throws {
        let mounted = try await mountedView(in: host) {
            ($0 as? NSButton)?.accessibilityIdentifier() == "CodeFloatingSaveButton"
        }
        let button = try XCTUnwrap(mounted as? NSButton)
        XCTAssertTrue(button.accessibilityPerformPress())
    }

    private func mountedView(in host: NSView, matching predicate: (NSView) -> Bool) async throws -> NSView? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let view = firstView(in: host, matching: predicate) { return view }
            try await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func firstView(in view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = firstView(in: child, matching: predicate) { return match }
        }
        return nil
    }

    private func renderedArchiveCSP(in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let script = """
                document.querySelector('#saved-report')?.textContent === 'Archived report'
                    ? document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.content ?? ''
                    : ''
                """
            webView.evaluateJavaScript(script, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { result in
                continuation.resume(with: result.map { $0 as? String ?? "" })
            }
        }
    }

}


@MainActor
final class TTZipMarkdownPreviewTests: XCTestCase {
    func testArchiveMarkdownRouteRejectsWritingToStagedSource() throws {
        let directory = try makeTemporaryDirectory(prefix: "TTZipArchiveMarkdown")
        let stagedURL = directory.appendingPathComponent("notes.md")
        let initial = "# Archive notes\n"
        try initial.write(to: stagedURL, atomically: true, encoding: .utf8)
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: directory.appendingPathComponent("fixture.zip"),
            entryPath: "docs/notes.md",
            stagedReadURL: stagedURL
        )
        let host = MediaPreviewView(
            previewType: .markdown(initial, stagedURL),
            fileName: "notes.md",
            resourceContext: context
        )

        let preview = try XCTUnwrap(host.resolvedMarkdownPreview)
        XCTAssertEqual(preview.resourceContext, context)
        XCTAssertEqual(preview.fileURL, context.readableURL)
        XCTAssertFalse(preview.canSaveInPlace)
        XCTAssertFalse(preview.saveFile(contentOverride: "# Cannot change archive entry\n"))
        XCTAssertEqual(try String(contentsOf: stagedURL, encoding: .utf8), initial)
    }

    func testArchiveMarkdownRichRouteKeepsDocumentTableAndCodeLayout() throws {
        let directory = try makeTemporaryDirectory(prefix: "TTZipArchiveRichMarkdown")
        let stagedURL = directory.appendingPathComponent("layout.md")
        let markdown = """
        # Rich preview

        Repeated paragraph with [a link](https://example.invalid).
        Repeated paragraph with [a link](https://example.invalid).

        | Header A | Header B | Header C | Header D | Header E |
        | --- | --- | --- | --- | --- |
        | **Bold** | *Italic* | Text | More | Last |

        ~~~swift
        let line = "This code line is deliberately long enough to scroll at this preview width."
        ~~~

        > [!TIP] Read-only preview
        """
        try Data(markdown.utf8).write(to: stagedURL)
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: directory.appendingPathComponent("fixture.zip"),
            entryPath: "docs/layout.md",
            stagedReadURL: stagedURL
        )
        let preview = MediaPreviewView(
            previewType: .markdown(markdown, stagedURL),
            fileName: "layout.md",
            resourceContext: context
        )
        let production = NSHostingView(rootView: preview)
        let productionWindow = mountRichMarkdown(production)
        defer {
            productionWindow.contentView = nil
            productionWindow.close()
        }

        let productionScrolls = richMarkdownScrollViews(in: production)
        XCTAssertEqual(productionScrolls.count, 3, "Expected the document, table, and code scroll views")
        let documentScroll = try XCTUnwrap(productionScrolls.first)
        let tableScroll = try XCTUnwrap(productionScrolls.dropFirst().first)
        let codeScroll = try XCTUnwrap(productionScrolls.dropFirst(2).first)
        let documentBounds = try XCTUnwrap(documentScroll.documentView).bounds.size
        let tableBounds = try XCTUnwrap(tableScroll.documentView).bounds.size
        let codeBounds = try XCTUnwrap(codeScroll.documentView).bounds.size

        // Captured hidden mounted baseline (500x260 borderless window):
        // - documentScroll: viewport (500, 222) below compact toolbar, documentBounds (500, 397)
        // - tableScroll: viewport (452, 61) inside 24pt horizontal padding, documentBounds (654, 61)
        // - codeScroll: viewport (452, 43) inside 24pt horizontal padding, documentBounds (681, 43)
        XCTAssertEqual(documentScroll.contentSize.width, 500, accuracy: 1)
        XCTAssertLessThan(documentScroll.contentSize.height, 260)
        XCTAssertEqual(documentScroll.contentSize.height, 222, accuracy: 1)
        XCTAssertEqual(documentBounds.width, 500, accuracy: 1)
        XCTAssertGreaterThan(documentBounds.height, documentScroll.contentSize.height)
        XCTAssertEqual(documentBounds.height, 397, accuracy: 1)

        XCTAssertEqual(tableScroll.contentSize.width, 452, accuracy: 1)
        XCTAssertGreaterThan(tableBounds.width, tableScroll.contentSize.width)
        XCTAssertEqual(tableBounds.width, 654, accuracy: 1)
        XCTAssertEqual(tableBounds.height, 61, accuracy: 1)
        XCTAssertEqual(tableBounds.height, tableScroll.contentSize.height, accuracy: 1)

        XCTAssertEqual(codeScroll.contentSize.width, 452, accuracy: 1)
        XCTAssertGreaterThan(codeBounds.width, codeScroll.contentSize.width)
        XCTAssertEqual(codeBounds.width, 681, accuracy: 1)
        XCTAssertEqual(codeBounds.height, 43, accuracy: 1)
        XCTAssertEqual(codeBounds.height, codeScroll.contentSize.height, accuracy: 1)
        XCTAssertFalse(productionWindow.isVisible)

        let blocks = TTMarkdownParser.parseDocumentBlocks(markdown)
        XCTAssertEqual(blocks.count, 6)
        let repeatedIDs = blocks.compactMap { block -> String? in
            guard case .paragraph(let text, _) = block, text.hasPrefix("Repeated paragraph") else {
                return nil
            }
            return block.id
        }
        XCTAssertEqual(repeatedIDs.count, 2)
        XCTAssertEqual(Set(repeatedIDs).count, 2)

        let archivePreview = try XCTUnwrap(preview.resolvedMarkdownPreview)
        XCTAssertFalse(archivePreview.canSaveInPlace)
        XCTAssertFalse(archivePreview.saveFile(contentOverride: "Must not overwrite archive content"))
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data(markdown.utf8))
    }

    func testMountedMarkdownScrollResetsWhenSwitchingBetweenDiskAndArchive() async throws {
        let directory = try makeTemporaryDirectory(prefix: "TTZipMarkdownSwitch")
        let staging = directory.appendingPathComponent("TTZipLRUPreviewCache", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let fileName = "notes.md"
        let diskURL = directory.appendingPathComponent(fileName)
        let stagedURL = staging.appendingPathComponent(fileName)
        let archiveURL = directory.appendingPathComponent("notes.zip")
        let diskMarkdown = "# Disk\n\n" + String(repeating: "Disk paragraph.\n\n", count: 20)
        let archiveMarkdown = "# Archive\n\n" + String(repeating: "Archive paragraph.\n\n", count: 30)
        try Data(diskMarkdown.utf8).write(to: diskURL)
        try Data(archiveMarkdown.utf8).write(to: stagedURL)
        try await ArchiveWriter().createArchive(
            outputPath: archiveURL.path, format: .zip, level: .fast, inputPaths: [stagedURL.path]
        )
        let archiveBytes = try Data(contentsOf: archiveURL)

        let diskPreview = MediaPreviewView(
            fileURL: diskURL, fileName: fileName, resourceContext: .diskFile(url: diskURL)
        )
        let archiveContext = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL, entryPath: fileName, stagedReadURL: stagedURL
        )
        var detectedArchiveType: MediaPreviewType?
        let archivePreview = MediaPreviewView(
            fileURL: stagedURL, fileName: fileName, resourceContext: archiveContext,
            onPreviewTypeResolved: { detectedArchiveType = $0 }
        )
        let host = NSHostingView(rootView: diskPreview)
        let window = mountRichMarkdown(host)
        defer {
            window.contentView = nil
            window.close()
        }
        XCTAssertFalse(window.isVisible)

        let diskScroll = try await waitForRichMarkdownScroll(in: host, resource: "initial disk file") { $0 > 500 }
        let diskHeight = try XCTUnwrap(diskScroll.documentView).bounds.height
        XCTAssertEqual(richMarkdownScrollOffset(diskScroll), 0, accuracy: 1)
        XCTAssertTrue(host.rootView.effectiveIsEditable)
        scrollRichMarkdownAwayFromTop(diskScroll)

        host.rootView = archivePreview
        let archiveScroll = try await waitForRichMarkdownScroll(in: host, resource: "staged archive entry") { $0 > diskHeight + 100 }
        XCTAssertEqual(richMarkdownScrollOffset(archiveScroll), 0, accuracy: 1)
        let archiveType = try XCTUnwrap(detectedArchiveType)
        guard case .markdown(let detectedMarkdown, _) = archiveType else {
            return XCTFail("The staged archive entry did not resolve as Markdown")
        }
        XCTAssertEqual(detectedMarkdown, archiveMarkdown)
        XCTAssertEqual(host.rootView.effectiveResourceContext, archiveContext)
        XCTAssertFalse(host.rootView.effectiveIsEditable)
        let resolvedArchive = try XCTUnwrap(MediaPreviewView(
            previewType: archiveType, fileName: fileName, resourceContext: archiveContext
        ).resolvedMarkdownPreview)
        XCTAssertFalse(resolvedArchive.canSaveInPlace)
        XCTAssertFalse(resolvedArchive.saveFile(contentOverride: "Must not overwrite archive content"))
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data(archiveMarkdown.utf8))
        XCTAssertEqual(try Data(contentsOf: archiveURL), archiveBytes)
        scrollRichMarkdownAwayFromTop(archiveScroll)

        host.rootView = diskPreview
        let restoredDisk = try await waitForRichMarkdownScroll(in: host, resource: "restored disk file") { abs($0 - diskHeight) <= 1 }
        XCTAssertEqual(richMarkdownScrollOffset(restoredDisk), 0, accuracy: 1)
        XCTAssertTrue(host.rootView.effectiveIsEditable)
        XCTAssertEqual(try Data(contentsOf: diskURL), Data(diskMarkdown.utf8))
    }

    private func waitForRichMarkdownScroll(
        in host: NSView, resource: String, matchingHeight: (CGFloat) -> Bool
    ) async throws -> NSScrollView {
        let deadline = ContinuousClock.now + .seconds(3)
        var lastHeight: CGFloat?
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let scroll = richMarkdownScrollViews(in: host).first,
               let height = scroll.documentView?.bounds.height {
                lastHeight = height
                if matchingHeight(height) { return scroll }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(nil as NSScrollView?, "Missing layout for \(resource). Last height: \(String(describing: lastHeight))")
    }

    private func richMarkdownScrollOffset(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        if clip.isFlipped { return clip.bounds.minY }
        return (scroll.documentView?.frame.maxY ?? 0) - clip.bounds.maxY
    }

    private func scrollRichMarkdownAwayFromTop(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        let delta: CGFloat = clip.isFlipped ? 96 : -96
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta))
        scroll.reflectScrolledClipView(clip)
        XCTAssertGreaterThan(richMarkdownScrollOffset(scroll), 60)
    }

    private func mountRichMarkdown(_ view: NSView) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 260)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func richMarkdownScrollViews(in view: NSView) -> [NSScrollView] {
        var scrolls: [NSScrollView] = []
        if let scroll = view as? NSScrollView {
            scrolls.append(scroll)
        }
        return scrolls + view.subviews.flatMap { richMarkdownScrollViews(in: $0) }
    }

    func testDiskMarkdownRoutePreservesBOMAndRejectsStaleSave() throws {
        let directory = try makeTemporaryDirectory(prefix: "TTZipDiskMarkdown")
        let url = directory.appendingPathComponent("notes.md")
        let initial = (1...8).map { "## Section \($0)\nContent line \($0)" }.joined(separator: "\n\n") + "\n"
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data(initial.utf8)).write(to: url)
        let host = MediaPreviewView(
            previewType: .markdown(initial, url),
            fileName: "notes.md",
            fileURL: url,
            resourceContext: .diskFile(url: url)
        )

        let preview = try XCTUnwrap(host.resolvedMarkdownPreview)
        XCTAssertTrue(preview.canSaveInPlace)
        XCTAssertEqual(preview.sourceEncoding, .utf8BOM)
        XCTAssertEqual(preview.currentSavedBaselineContent, initial)

        let firstEdit = initial.replacingOccurrences(of: "Content line 2", with: "Updated line 2")
        XCTAssertTrue(preview.saveFile(contentOverride: firstEdit))
        XCTAssertEqual(preview.currentSavedBaselineContent, firstEdit)
        XCTAssertEqual(try Data(contentsOf: url), bom + Data(firstEdit.utf8))

        let secondEdit = firstEdit.replacingOccurrences(of: "Content line 6", with: "Updated line 6")
        XCTAssertTrue(preview.saveFile(contentOverride: secondEdit))
        XCTAssertEqual(preview.currentSavedBaselineContent, secondEdit)
        XCTAssertEqual(try Data(contentsOf: url), bom + Data(secondEdit.utf8))

        let external = bom + Data("# External edit\n".utf8)
        try external.write(to: url, options: .atomic)
        XCTAssertFalse(preview.saveFile(contentOverride: "# Stale edit\n"))
        XCTAssertEqual(preview.currentSavedBaselineContent, secondEdit)
        XCTAssertEqual(try Data(contentsOf: url), external)
    }
}
