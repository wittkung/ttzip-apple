// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import WebKit
import XCTest
@testable import TTMediaKit

@MainActor
final class MHTMLRenderingTests: XCTestCase {
    private var retainedObjects: [AnyObject] = []

    override func tearDown() {
        for webView in retainedObjects.compactMap({ $0 as? WKWebView }) {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        retainedObjects.removeAll()
        super.tearDown()
    }

    func testMultipartSnapshotRendersDecodedHTMLWithEmbeddedCSSAndCIDImage() async throws {
        let mime = Self.multipartSnapshot
        let preview = TTMediaDetector.detectTypeFromMemory(
            data: Data(mime.utf8), suggestedName: "snapshot.mhtml"
        )
        guard case .htmlWeb(let source, let fileURL) = preview else {
            return XCTFail("MHTML snapshots must route to the rendered HTML preview")
        }
        XCTAssertEqual(source, mime, "The source pane must retain the original MIME payload")
        let webView = makeWebView(content: source, fileURL: fileURL)
        try await waitUntil(webView, condition: "document.getElementById('snapshot-title') !== null")
        try await waitUntil(
            webView,
            condition: "document.getElementById('snapshot-image').naturalWidth === 1"
        )

        let title = try await evaluateString("document.title", in: webView)
        let heading = try await evaluateString("document.getElementById('snapshot-title').textContent", in: webView)
        let spacing = try await evaluateString(
            "getComputedStyle(document.getElementById('snapshot-title')).letterSpacing", in: webView
        )
        let imageURL = try await evaluateString("document.getElementById('snapshot-image').src", in: webView)
        let scriptResult = try await evaluateString("document.body.dataset.executed || 'blocked'", in: webView)
        XCTAssertEqual(title, "Saved snapshot")
        XCTAssertEqual(heading, "Café preview")
        XCTAssertEqual(spacing, "7px", "The archived stylesheet must apply without fetching its original URL")
        XCTAssertTrue(imageURL.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(scriptResult, "blocked", "Page scripts must not mutate the shared DOM")
        XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        try await assertNormalHTMLLayout(in: webView)
    }

    func testPlainHTMLContainingInlineSVGKeepsDocumentLayout() async throws {
        let html = """
        <!DOCTYPE html>
        <html><head><title>HTML with icon</title></head><body>
        <h1 id="snapshot-title">The page surrounds the icon</h1>
        <svg id="inline-icon" xmlns="http://www.w3.org/2000/svg" width="24" height="24">
          <rect width="24" height="24" fill="blue"/>
        </svg>
        <p id="after-icon">Content continues after the icon.</p>
        </body></html>
        """
        let webView = makeWebView(content: html, fileURL: nil)
        try await waitUntil(webView, condition: "document.getElementById('after-icon') !== null")
        let title = try await evaluateString("document.title", in: webView)
        XCTAssertEqual(title, "HTML with icon")
        try await assertNormalHTMLLayout(in: webView)
    }

    func testMalformedMultipartFallsBackToLiteralSourceWithoutExecutingMarkup() async throws {
        let mime = """
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="missing-close"

        --missing-close
        Content-Type: text/html; charset="utf-8"

        <h1 id="must-stay-literal">Undecodable &amp; incomplete</h1>
        <script>document.body.dataset.executed = 'yes';</script>
        """
        XCTAssertTrue(MHTMLMimeBoundaryGuard.isMultipartMHTML(text: mime))
        let summary = try XCTUnwrap(MHTMLMimeBoundaryGuard.inspectMHTMLSource(text: mime))
        XCTAssertNil(summary.renderedHTML, "A missing closing boundary must prevent partial HTML rendering")
        let webView = makeWebView(content: mime, fileURL: nil)
        try await waitUntil(webView, condition: "document.querySelector('pre') !== null")

        let literalSource = try await evaluateString("document.querySelector('pre').textContent", in: webView)
        let interpretedMarkup = try await evaluateString(
            "document.getElementById('must-stay-literal') === null ? 'absent' : 'present'", in: webView
        )
        let scriptElements = try await evaluateString("String(document.scripts.length)", in: webView)
        let scriptResult = try await evaluateString("document.body.dataset.executed || 'blocked'", in: webView)
        XCTAssertEqual(literalSource, mime, "Fallback must preserve MIME and literal entity spelling")
        XCTAssertEqual(interpretedMarkup, "absent")
        XCTAssertEqual(scriptElements, "0", "Fallback must escape script tags along with all other source markup")
        XCTAssertEqual(scriptResult, "blocked")
        XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func testLegacyInspectionSummaryDecodesWithoutRenderedHTMLField() throws {
        let legacyJSON = """
        {
          "is_multipart_mhtml": true,
          "boundary": "legacy-boundary",
          "content_type": "multipart/related",
          "subject": "Legacy snapshot",
          "snapshot_content_location": "https://example.test/snapshot",
          "part_count_estimate": 2,
          "recommended_language": "mime",
          "raw_mime_source": "Original MIME source"
        }
        """
        let summary = try JSONDecoder().decode(MHTMLInspectionSummary.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(summary.renderedHTML)
        XCTAssertTrue(summary.isMultipartMHTML)
        XCTAssertEqual(summary.boundary, "legacy-boundary")
        XCTAssertEqual(summary.partCountEstimate, 2)
        XCTAssertEqual(summary.rawMimeSource, "Original MIME source")
    }

    func testOptInLocalMHTMLSnapshotRendersWithoutCopyingFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TTMEDIA_MHTML_REGRESSION_FILE"], !path.isEmpty else {
            throw XCTSkip("Set TTMEDIA_MHTML_REGRESSION_FILE to verify a local saved webpage")
        }
        let fileURL = URL(fileURLWithPath: path)
        let rawSource = try String(contentsOf: fileURL, encoding: .utf8)
        let preview = TTMediaDetector.detectType(url: fileURL)
        guard case .htmlWeb(let source, let sourceURL) = preview else {
            return XCTFail("The supplied MHTML file must route to rendered HTML")
        }
        XCTAssertTrue(source == rawSource, "The original saved webpage must remain available as source")
        let webView = makeWebView(content: source, fileURL: sourceURL)
        try await waitUntil(
            webView,
            condition: "document.readyState === 'complete' && document.title.length > 0 && document.body.children.length > 0",
            timeout: 15
        )
        let title = try await evaluateString("document.title", in: webView)
        let body = try await evaluateString("document.body.innerText", in: webView)
        XCTAssertFalse(title.isEmpty)
        XCTAssertFalse(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(body.contains("Content-Transfer-Encoding:"), "MIME framing must not appear as rendered text")
        XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        if let expectedTitle = environment["TTMEDIA_MHTML_EXPECTED_TITLE"] {
            XCTAssertTrue(title == expectedTitle, "Rendered title must match the opt-in expectation")
        }
        if let expectedBody = environment["TTMEDIA_MHTML_EXPECTED_BODY_SUBSTRING"] {
            XCTAssertTrue(body.contains(expectedBody), "Rendered body must contain the opt-in expectation")
        }
    }

    func testValid300KiBMultipartSnapshotRendersOfflineAndBudgetNegativeControlFallsBack() async throws {
        let fillerText = String(repeating: "Archived paragraph segment for 300KiB payload verification. ", count: 5200)
        let mime300KiB = """
        From: <Saved by Blink>
        Subject: Large 300KiB Snapshot
        MIME-Version: 1.0
        Content-Type: multipart/related; type="text/html"; boundary="large-snapshot-boundary"

        --large-snapshot-boundary
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: 8bit
        Content-Location: https://example.test/large/index.html

        <!DOCTYPE html>
        <html><head><title>Large 300KiB Snapshot</title>
        <link rel="stylesheet" href="cid:large-style@example.test"></head><body>
        <h1 id="large-title">Large Saved Page</h1>
        <p id="large-filler">\(fillerText)</p>
        <img id="large-image" src="cid:large-img@example.test">
        </body></html>
        --large-snapshot-boundary
        Content-Type: text/css; charset="utf-8"
        Content-ID: <large-style@example.test>

        #large-title { letter-spacing: 5px; }
        --large-snapshot-boundary
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-ID: <large-img@example.test>

        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
        --large-snapshot-boundary--
        """
        XCTAssertGreaterThan(mime300KiB.utf8.count, 300 * 1024)
        XCTAssertLessThan(mime300KiB.utf8.count, 8 * 1024 * 1024)

        let preview = TTMediaDetector.detectTypeFromMemory(
            data: Data(mime300KiB.utf8), suggestedName: "large_300k.mhtml"
        )
        guard case .htmlWeb(let source, let fileURL) = preview else {
            return XCTFail("300 KiB MHTML snapshot must route to .htmlWeb")
        }
        let webView = makeWebView(content: source, fileURL: fileURL)
        try await waitUntil(webView, condition: "document.getElementById('large-title') !== null")
        try await waitUntil(webView, condition: "document.getElementById('large-image').naturalWidth === 1")

        let title = try await evaluateString("document.title", in: webView)
        let spacing = try await evaluateString(
            "getComputedStyle(document.getElementById('large-title')).letterSpacing", in: webView
        )
        XCTAssertEqual(title, "Large 300KiB Snapshot")
        XCTAssertEqual(spacing, "5px")

        // Budget negative control: explicit byte ceiling smaller than input must leave renderedHTML nil
        let budgetConstrained = try XCTUnwrap(
            MHTMLMimeBoundaryGuard.inspectMHTMLSource(data: Data(mime300KiB.utf8), maxBytes: 64 * 1024)
        )
        XCTAssertTrue(budgetConstrained.isMultipartMHTML)
        XCTAssertNil(budgetConstrained.renderedHTML, "Input exceeding maxBytes budget must not render partial HTML")
    }

    func testStandaloneSVGRootOpeningTagScopeAndNestedSVGSizing() async throws {
        // SVG-1: Root <svg> has width="400" height="200" (no root viewBox) and quoted '>' in data-label,
        // while child <symbol> has viewBox="0 0 10 10", child <rect> has width="50" height="20",
        // and nested <svg id="nested-svg" width="30" height="40"> has its own authored dimensions.
        let svgWithChildSymbolAndNestedSVG = """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- comment mentioning viewBox="0 0 999 999" width="999" height="999" -->
        <svg xmlns="http://www.w3.org/2000/svg" data-label="a > b" width="400px" height="200">
          <defs>
            <symbol id="sym" viewBox="0 0 10 10"><rect width="10" height="10"/></symbol>
          </defs>
          <rect id="child-rect" x="0" y="0" width="50" height="20" fill="red"/>
          <svg id="nested-svg" x="10" y="10" width="30" height="40">
            <rect width="30" height="40" fill="green"/>
          </svg>
        </svg>
        """
        let preview = TTMediaDetector.detectTypeFromMemory(
            data: Data(svgWithChildSymbolAndNestedSVG.utf8), suggestedName: "scoped.svg"
        )
        guard case .htmlWeb(let source, let fileURL) = preview else {
            return XCTFail("Expected .htmlWeb for standalone SVG")
        }
        let webView = makeWebView(content: source, fileURL: fileURL)
        try await waitUntil(webView, condition: "document.querySelector('body > svg') !== null")

        let rootViewBox = try await evaluateString(
            "document.querySelector('body > svg').getAttribute('viewBox') || 'none'", in: webView
        )
        let nestedStyleWidth = try await evaluateString(
            "getComputedStyle(document.getElementById('nested-svg')).width", in: webView
        )
        let nestedBaseDims = try await evaluateString(
            "document.getElementById('nested-svg').width.baseVal.value + 'x' + document.getElementById('nested-svg').height.baseVal.value",
            in: webView
        )
        XCTAssertEqual(rootViewBox, "0 0 400 200", "Root <svg> must synthesize viewBox from its own width/height despite child <symbol viewBox>")
        XCTAssertEqual(nestedStyleWidth, "auto", "Nested <svg> must not be matched by body > svg { width: 100% !important }")
        XCTAssertEqual(nestedBaseDims, "30x40", "Nested <svg> must preserve its authored 30x40 user-unit dimensions")

        // Negative control 1: Root <svg width="400"> missing height (child <rect height="20">) must NOT synthesize viewBox from child
        let svgMissingRootHeight = """
        <svg xmlns="http://www.w3.org/2000/svg" width="400">
          <rect width="400" height="20" fill="blue"/>
        </svg>
        """
        let wvMissingHeight = makeWebView(content: svgMissingRootHeight, fileURL: nil)
        try await waitUntil(wvMissingHeight, condition: "document.querySelector('body > svg') !== null")
        let missingViewBox = try await evaluateString(
            "document.querySelector('body > svg').getAttribute('viewBox') || 'none'", in: wvMissingHeight
        )
        XCTAssertEqual(missingViewBox, "none", "Root <svg> missing height must not borrow height from child <rect>")

        // Negative control 2: Root <svg width="400pt" height="200px"> with physical unit 'pt' must NOT equate pt with px
        let svgMixedPtUnit = """
        <svg xmlns="http://www.w3.org/2000/svg" width="400pt" height="200px">
          <rect width="100" height="100"/>
        </svg>
        """
        let wvMixedUnit = makeWebView(content: svgMixedPtUnit, fileURL: nil)
        try await waitUntil(wvMixedUnit, condition: "document.querySelector('body > svg') !== null")
        let mixedUnitViewBox = try await evaluateString(
            "document.querySelector('body > svg').getAttribute('viewBox') || 'none'", in: wvMixedUnit
        )
        XCTAssertEqual(mixedUnitViewBox, "none", "Root <svg> with physical 'pt' unit must not synthesize a user-unit viewBox")

        // Ordinary integer + fractional user-coordinate dimensions: width="400" height="200.5px"
        let svgFractionalDims = """
        <svg xmlns="http://www.w3.org/2000/svg" width="400" height="200.5px">
          <rect width="100" height="100"/>
        </svg>
        """
        let wvFractional = makeWebView(content: svgFractionalDims, fileURL: nil)
        try await waitUntil(wvFractional, condition: "document.querySelector('body > svg') !== null")
        let fractionalViewBox = try await evaluateString(
            "document.querySelector('body > svg').getAttribute('viewBox') || 'none'", in: wvFractional
        )
        XCTAssertEqual(fractionalViewBox, "0 0 400 200.5", "Integer and fractional finite dimensions must serialize without loss")

        // Huge finite Double dimension (width="1e100" height="1") routed through production detector + WKWebView:
        // Must not trap on Int(1e100) overflow or clamp to Int.max (proves non-crashing DOM envelope load, not visible pixel output).
        let svgHugeFiniteDims = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1e100" height="1">
          <rect width="1" height="1"/>
        </svg>
        """
        let hugePreview = TTMediaDetector.detectTypeFromMemory(
            data: Data(svgHugeFiniteDims.utf8), suggestedName: "huge-finite.svg"
        )
        guard case .htmlWeb(let hugeSource, let hugeURL) = hugePreview else {
            return XCTFail("Expected .htmlWeb for standalone SVG with huge finite width")
        }
        let wvHugeFinite = makeWebView(content: hugeSource, fileURL: hugeURL)
        try await waitUntil(wvHugeFinite, condition: "document.querySelector('body > svg') !== null")
        let hugeViewBox = try await evaluateString(
            "document.querySelector('body > svg').getAttribute('viewBox') || 'none'", in: wvHugeFinite
        )
        XCTAssertEqual(hugeViewBox, "0 0 \(String(1e100)) 1", "Huge finite Double must serialize safely without Int overflow trap or Int.max clamping")

        // Negative control 3: Non-finite (1e400 -> +inf, NaN) or non-positive (0, -10) dimensions must be rejected
        for invalidAttr in ["width=\"1e400\" height=\"100\"", "width=\"NaN\" height=\"100\"", "width=\"0\" height=\"100\"", "width=\"-10\" height=\"100\""] {
            let svgInvalidDim = "<svg xmlns=\"http://www.w3.org/2000/svg\" \(invalidAttr)><rect width=\"10\" height=\"10\"/></svg>"
            let wvInvalid = makeWebView(content: svgInvalidDim, fileURL: nil)
            try await waitUntil(wvInvalid, condition: "document.querySelector('body > svg') !== null")
            let invalidViewBox = try await evaluateString(
                "document.querySelector('body > svg').getAttribute('viewBox') || 'none'", in: wvInvalid
            )
            XCTAssertEqual(invalidViewBox, "none", "Non-finite or non-positive dimension (\(invalidAttr)) must not synthesize viewBox")
        }
    }

    func testStandaloneSVGWithInternalDOCTYPEPreambleRoutesFromMemoryWithoutExpandingEntities() async throws {
        // SVG-2 positive control through production detectTypeFromMemory (where fileURL is nil):
        let svgWithInternalSubset = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" [
          <!ENTITY custom_entity "EXPANDED_SECRET_VALUE">
        ]>
        <svg id="root-vector" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 60">
          <rect width="120" height="60" fill="purple"/>
          <text id="entity-probe">&custom_entity;</text>
        </svg>
        """
        let preview = TTMediaDetector.detectTypeFromMemory(
            data: Data(svgWithInternalSubset.utf8), suggestedName: "illustrator_export.svg", sourceURL: nil
        )
        guard case .htmlWeb(let content, let url) = preview else {
            return XCTFail("Expected .htmlWeb from detectTypeFromMemory for SVG with DOCTYPE internal subset")
        }
        XCTAssertNil(url, "Memory detection without sourceURL produces nil fileURL")
        let webView = makeWebView(content: content, fileURL: url)
        try await waitUntil(webView, condition: "document.getElementById('root-vector') !== null")

        let bodyDisplay = try await evaluateString("getComputedStyle(document.body).display", in: webView)
        let probeText = try await evaluateString(
            "document.getElementById('entity-probe').textContent || ''", in: webView
        )
        XCTAssertEqual(bodyDisplay, "flex", "Standalone SVG with DOCTYPE internal subset and nil fileURL must use the SVG flex envelope")
        XCTAssertFalse(probeText.contains("EXPANDED_SECRET_VALUE"), "DOCTYPE preamble boundary scanner must never expand custom XML entities")

        // Negative control: HTML document with DOCTYPE and inline <svg> must still use normal block layout
        let htmlWithDoctypeAndInlineSVG = """
        <!DOCTYPE html>
        <html><body><p id="lead">Text before icon</p><svg id="inline-svg" width="16" height="16"><circle cx="8" cy="8" r="6"/></svg></body></html>
        """
        let htmlPreview = TTMediaDetector.detectTypeFromMemory(
            data: Data(htmlWithDoctypeAndInlineSVG.utf8), suggestedName: "doc.html", sourceURL: nil
        )
        guard case .htmlWeb(let htmlSource, let htmlURL) = htmlPreview else {
            return XCTFail("Expected .htmlWeb for HTML document")
        }
        let htmlWebView = makeWebView(content: htmlSource, fileURL: htmlURL)
        try await waitUntil(htmlWebView, condition: "document.getElementById('lead') !== null")
        let htmlBodyDisplay = try await evaluateString("getComputedStyle(document.body).display", in: htmlWebView)
        XCTAssertEqual(htmlBodyDisplay, "block", "HTML document with inline SVG must remain in normal block layout")
    }

    private func assertNormalHTMLLayout(in webView: WKWebView) async throws {
        let bodyDisplay = try await evaluateString("getComputedStyle(document.body).display", in: webView)
        let svgWidth = try await evaluateString(
            "getComputedStyle(document.getElementById('inline-icon')).width", in: webView
        )
        let trailingText = try await evaluateString("document.getElementById('after-icon').textContent", in: webView)
        XCTAssertEqual(bodyDisplay, "block", "An inline SVG must not select the standalone SVG flex envelope")
        XCTAssertEqual(svgWidth, "24px", "An inline icon must preserve its authored dimensions")
        XCTAssertEqual(trailingText, "Content continues after the icon.")
    }

    private func makeWebView(content: String, fileURL: URL?) -> WKWebView {
        let representable = HTMLWKWebViewRepresentable(content: content, fileURL: fileURL)
        let coordinator = representable.makeCoordinator()
        let configuration = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: configuration)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration
        )
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        retainedObjects.append(coordinator)
        retainedObjects.append(webView)
        representable.loadHTML(in: webView, coordinator: coordinator)
        return webView
    }

    private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { result in
                switch result {
                case .success(let value):
                    do {
                        continuation.resume(returning: try XCTUnwrap(value as? String))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func waitUntil(_ webView: WKWebView, condition: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ready = try? await evaluateString("(\(condition)) ? 'ready' : 'waiting'", in: webView), ready == "ready" {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for the saved webpage to render")
        throw RenderingError.timedOut
    }

    private enum RenderingError: Error {
        case timedOut
    }

    private static let multipartSnapshot = """
    From: <Saved by Blink>
    Subject: Saved snapshot
    MIME-Version: 1.0
    Content-Type: multipart/related; type="text/html"; boundary="snapshot-boundary"

    --snapshot-boundary
    Content-Type: text/html; charset="utf-8"
    Content-Transfer-Encoding: quoted-printable
    Content-Location: https://example.test/archive/index.html

    <!DOCTYPE html>
    <html><head><title>Saved snapshot</title>
    <link rel=3D"stylesheet" href=3D"styles/snapshot.css"></head><body>
    <h1 id=3D"snapshot-title">Caf=C3=A9 pre=
    view</h1>
    <img id=3D"snapshot-image" src=3D"cid:snapshot-image@example.test">
    <svg id=3D"inline-icon" xmlns=3D"http://www.w3.org/2000/svg" width=3D"24" height=3D"24">
      <rect width=3D"24" height=3D"24" fill=3D"blue"/>
    </svg>
    <p id=3D"after-icon">Content continues after the icon.</p>
    <script>document.body.dataset.executed =3D 'yes';</script>
    </body></html>
    --snapshot-boundary
    Content-Type: text/css; charset="utf-8"
    Content-Transfer-Encoding: quoted-printable
    Content-Location: https://example.test/archive/styles/snapshot.css

    #snapshot-title { letter-spacing: 7px; color: rgb(12, 34, 56); }
    --snapshot-boundary
    Content-Type: image/png
    Content-Transfer-Encoding: base64
    Content-ID: <snapshot-image@example.test>
    Content-Location: https://example.test/archive/image.png

    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
    --snapshot-boundary--
    """
}
