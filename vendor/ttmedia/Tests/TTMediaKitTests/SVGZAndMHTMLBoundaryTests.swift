// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import WebKit
import XCTest
import zlib
@testable import TTMediaKit

final class SVGZAndMHTMLBoundaryTests: XCTestCase {
    private var retainedWebKitObjects: [AnyObject] = []

    override func tearDown() {
        retainedWebKitObjects.removeAll()
        super.tearDown()
    }

    // MARK: - Test 1: Valid .svgz Disk & Memory Decompression

    func testValidSVGZMemoryAndDiskDecompression() throws {
        let originalSVG = #"<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="40"/></svg>"#
        let gzipData = try Self.makeRealGzipData(from: Data(originalSVG.utf8))

        // Verify valid RFC 1952 Gzip header (1F 8B 08) and minimum 18-byte framing
        XCTAssertGreaterThanOrEqual(gzipData.count, 18)
        XCTAssertEqual(gzipData[0], 0x1F)
        XCTAssertEqual(gzipData[1], 0x8B)
        XCTAssertEqual(gzipData[2], 0x08)

        // 1a. In-memory decompression
        let decompressedFromMemory = try SVGZBoundedDecompressor.decompressSVGZ(data: gzipData)
        XCTAssertEqual(decompressedFromMemory, originalSVG)

        // 1b. Disk file URL decompression
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVGZTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let svgzURL = tempDir.appendingPathComponent("circle.svgz")
        try gzipData.write(to: svgzURL)

        let decompressedFromDisk = try SVGZBoundedDecompressor.decompressSVGZ(from: svgzURL)
        XCTAssertEqual(decompressedFromDisk, originalSVG)
    }

    func testValidSVGZWithOptionalFilenameHeaderDecompression() throws {
        let originalSVG = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2h20v20H2z"/></svg>"#
        let baseGzip = try Self.makeRealGzipData(from: Data(originalSVG.utf8))

        // Inject FNAME (0x08) optional null-terminated filename after 10-byte header
        var gzipWithFName = Data(baseGzip.prefix(10))
        gzipWithFName[3] |= 0x08
        gzipWithFName.append(contentsOf: "icon.svg".utf8)
        gzipWithFName.append(0x00)
        gzipWithFName.append(baseGzip.dropFirst(10))

        let decompressed = try SVGZBoundedDecompressor.decompressSVGZ(data: gzipWithFName)
        XCTAssertEqual(decompressed, originalSVG)
    }

    // MARK: - Test 2: Truncated .svgz Rejection

    func testTruncatedSVGZStreamIsRejected() throws {
        let originalSVG = #"<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="40"/><rect width="80" height="80"/></svg>"#
        let validGzip = try Self.makeRealGzipData(from: Data(originalSVG.utf8))

        // 2a. Chop off the last 4 bytes (truncating the 8-byte CRC32 + ISIZE trailer)
        let choppedTrailer = Data(validGzip.dropLast(4))
        XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: choppedTrailer)) { error in
            guard let svgzError = error as? SVGZDecompressionError else {
                XCTFail("Expected SVGZDecompressionError, got \(error)")
                return
            }
            XCTAssertTrue(
                svgzError == .truncatedStream || svgzError == .corruptedPayloadOrChecksumMismatch,
                "Unexpected error for trailer truncation: \(svgzError)"
            )
        }

        // 2b. Chop off half of the deflate stream
        let halfDeflateCount = 10 + max(1, (validGzip.count - 18) / 2)
        let choppedDeflate = Data(validGzip.prefix(halfDeflateCount))
        XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: choppedDeflate)) { error in
            guard let svgzError = error as? SVGZDecompressionError else {
                XCTFail("Expected SVGZDecompressionError, got \(error)")
                return
            }
            XCTAssertTrue(
                svgzError == .truncatedStream || svgzError == .corruptedPayloadOrChecksumMismatch,
                "Unexpected error for mid-deflate truncation: \(svgzError)"
            )
        }
    }

    // MARK: - Test 3: Corrupted Gzip Payload / Bad CRC32 Rejection

    func testCorruptedDeflateAndBadCRC32AreRejected() throws {
        let originalSVG = #"<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="40"/></svg>"#
        let validGzip = try Self.makeRealGzipData(from: Data(originalSVG.utf8))

        // 3a. Flip bits in the trailer CRC32 (bytes [count - 8 ..< count - 4])
        var badCRCGzip = validGzip
        badCRCGzip[badCRCGzip.count - 8] ^= 0xFF
        XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: badCRCGzip)) { error in
            XCTAssertEqual(error as? SVGZDecompressionError, .corruptedPayloadOrChecksumMismatch)
        }

        // 3b. Flip bits in the trailer ISIZE (bytes [count - 4 ..< count])
        var badISizeGzip = validGzip
        badISizeGzip[badISizeGzip.count - 4] ^= 0x01
        XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: badISizeGzip)) { error in
            XCTAssertEqual(error as? SVGZDecompressionError, .corruptedPayloadOrChecksumMismatch)
        }

        // 3c. Flip bits inside the compressed deflate payload
        var corruptedDeflate = validGzip
        let payloadMidpoint = 10 + (corruptedDeflate.count - 18) / 2
        corruptedDeflate[payloadMidpoint] ^= 0xFF
        corruptedDeflate[payloadMidpoint + 1] ^= 0xAA
        XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: corruptedDeflate)) { error in
            XCTAssertEqual(error as? SVGZDecompressionError, .corruptedPayloadOrChecksumMismatch)
        }

        // 3d. Invalid Gzip magic header
        let invalidMagic = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: invalidMagic)) { error in
            XCTAssertEqual(error as? SVGZDecompressionError, .invalidGzipHeader)
        }
    }

    // MARK: - Test 4: Decompression Bomb / Size Limit & Expansion Ratio Rejection

    func testDecompressionBombAndResourceLimitsAreRejectedMidStream() throws {
        // Construct a highly compressible 256 KB SVG comment payload (~350 bytes compressed -> >700:1 ratio)
        let repeatedComment = String(repeating: "A", count: 256 * 1024)
        let bombSVG = "<svg viewBox=\"0 0 100 100\"><!-- \(repeatedComment) --><circle cx=\"50\" cy=\"50\" r=\"40\"/></svg>"
        let bombGzip = try Self.makeRealGzipData(from: Data(bombSVG.utf8))

        // Compressed payload is tiny (< 1 KB) while uncompressed is > 256 KB
        XCTAssertLessThan(bombGzip.count, 1024)

        // 4a. Reject excessive expansion ratio mid-stream (> 100:1 once output crosses 64 KB)
        XCTAssertThrowsError(
            try SVGZBoundedDecompressor.decompressSVGZ(
                data: bombGzip,
                maxCompressedBytes: 8 * 1024 * 1024,
                maxDecompressedBytes: 16 * 1024 * 1024,
                maxExpansionRatio: 100
            )
        ) { error in
            guard case .excessiveExpansionRatio(let ratio) = error as? SVGZDecompressionError else {
                XCTFail("Expected .excessiveExpansionRatio, got \(error)")
                return
            }
            XCTAssertGreaterThan(ratio, 100)
        }

        // 4b. Reject decompressed size limit exceeded mid-stream when maxDecompressedBytes is 32 KB
        XCTAssertThrowsError(
            try SVGZBoundedDecompressor.decompressSVGZ(
                data: bombGzip,
                maxCompressedBytes: 8 * 1024 * 1024,
                maxDecompressedBytes: 32 * 1024,
                maxExpansionRatio: 10_000
            )
        ) { error in
            XCTAssertEqual(
                error as? SVGZDecompressionError,
                .decompressedSizeLimitExceeded(maxBytes: 32 * 1024)
            )
        }

        // 4c. Reject compressed input exceeding maxCompressedBytes
        XCTAssertThrowsError(
            try SVGZBoundedDecompressor.decompressSVGZ(
                data: bombGzip,
                maxCompressedBytes: 64,
                maxDecompressedBytes: 16 * 1024 * 1024,
                maxExpansionRatio: 100
            )
        ) { error in
            XCTAssertEqual(
                error as? SVGZDecompressionError,
                .compressedPayloadTooLarge(bombGzip.count)
            )
        }
    }

    // MARK: - Test 5: Non-SVG Gzip Rejection

    func testNonSVGGzipPayloadIsRejected() throws {
        let plainText = "hello world"
        let gzipPlainText = try Self.makeRealGzipData(from: Data(plainText.utf8))

        XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: gzipPlainText)) { error in
            XCTAssertEqual(error as? SVGZDecompressionError, .notValidSVGPayload)
        }

        // Also verify invalid UTF-8 inside valid Gzip container throws .invalidUTF8Encoding
        let invalidUTF8Bytes = Data([0xFF, 0xFE, 0x80, 0xC0, 0xAF])
        let gzipInvalidUTF8 = try Self.makeRealGzipData(from: invalidUTF8Bytes)
        XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: gzipInvalidUTF8)) { error in
            XCTAssertEqual(error as? SVGZDecompressionError, .invalidUTF8Encoding)
        }
    }

    // MARK: - Test 6: MHTML MIME Boundary Guard

    func testMHTMLMimeBoundaryGuardDistinguishesMultipartArchiveFromPlainHTML() throws {
        let sampleMHTML = """
        From: <Saved by Blink>
        Snapshot-Content-Location: https://example.com/report
        Subject: Engineering Architecture Report
        Date: Sat, 17 Oct 2026 02:30:00 -0000
        MIME-Version: 1.0
        Content-Type: multipart/related;
        \ttype="text/html";
        \tboundary="----MultipartBoundary--7x9a8b1c2d3e4f--"

        ------MultipartBoundary--7x9a8b1c2d3e4f--
        Content-Type: text/html
        Content-ID: <frame-001@mhtml.blink>
        Content-Transfer-Encoding: quoted-printable
        Content-Location: https://example.com/report

        <!DOCTYPE html>
        <html><body><h1>Saved MHTML Archive</h1><img src=3D"cid:img-001"/></body></html>
        ------MultipartBoundary--7x9a8b1c2d3e4f--
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-Location: https://example.com/logo.png

        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
        ------MultipartBoundary--7x9a8b1c2d3e4f----
        """

        // 6a. Real RFC 2557 multipart/related MHTML is detected in text, Data, and disk URL
        XCTAssertTrue(MHTMLMimeBoundaryGuard.isMultipartMHTML(text: sampleMHTML))
        let mhtmlData = Data(sampleMHTML.utf8)
        XCTAssertTrue(MHTMLMimeBoundaryGuard.isMultipartMHTML(data: mhtmlData))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHTMLTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mhtmlURL = tempDir.appendingPathComponent("archive.mhtml")
        try mhtmlData.write(to: mhtmlURL)
        XCTAssertTrue(MHTMLMimeBoundaryGuard.isMultipartMHTML(at: mhtmlURL))

        // Verify inspection summary & raw MIME source extraction for .code(rawText, language: "mime", fileURL: url)
        let summary = try XCTUnwrap(MHTMLMimeBoundaryGuard.inspectMHTMLSource(text: sampleMHTML))
        XCTAssertTrue(summary.isMultipartMHTML)
        XCTAssertEqual(summary.boundary, "----MultipartBoundary--7x9a8b1c2d3e4f--")
        XCTAssertEqual(summary.subject, "Engineering Architecture Report")
        XCTAssertEqual(summary.snapshotContentLocation, "https://example.com/report")
        XCTAssertEqual(summary.partCountEstimate, 2)
        XCTAssertEqual(summary.recommendedLanguage, "mime")
        XCTAssertEqual(summary.rawMimeSource, sampleMHTML)
        XCTAssertEqual(MHTMLMimeBoundaryGuard.extractRawMimeSource(from: sampleMHTML), sampleMHTML)

        // 6b. Plain HTML snippet (even if saved with .mhtml extension or mentioning MIME text inside body) returns false
        let plainHTML = """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Plain HTML</title></head>
        <body>
          <p>This is a regular HTML page mentioning Content-Type: multipart/related; boundary="xyz" in prose.</p>
        </body>
        </html>
        """
        XCTAssertFalse(MHTMLMimeBoundaryGuard.isMultipartMHTML(text: plainHTML))
        XCTAssertFalse(MHTMLMimeBoundaryGuard.isMultipartMHTML(data: Data(plainHTML.utf8)))
        XCTAssertNil(MHTMLMimeBoundaryGuard.inspectMHTMLSource(text: plainHTML))
        XCTAssertNil(MHTMLMimeBoundaryGuard.extractRawMimeSource(from: plainHTML))
    }

    // MARK: - Test 7: Production TTMediaDetector SVGZ Routing & Source Identity (SVGZ-1)

    @MainActor
    func testProductionDetectorSVGZRoutingAndDecompressedSourceIdentity() throws {
        let originalSVG = """
        <?xml version="1.0" encoding="utf-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
          <rect width="200" height="100" fill="#123456"/>
        </svg>
        """
        let validGzip = try Self.makeRealGzipData(from: Data(originalSVG.utf8))
        // Confirm the Gzip header contains NUL bytes (0x00) within the first 10 bytes
        XCTAssertTrue(validGzip.prefix(10).contains(0x00))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVGZProdRouting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validURL = tempDir.appendingPathComponent("badge.svgz")
        try validGzip.write(to: validURL)

        // 7a. Production disk & memory entry points route valid .svgz to .htmlWeb with decompressed UTF-8 XML
        let diskDetected = TTMediaDetector.detectType(url: validURL)
        guard case .htmlWeb(let decompressedDisk, let assocURL) = diskDetected else {
            return XCTFail("Expected .htmlWeb for valid disk .svgz, got \(diskDetected)")
        }
        XCTAssertEqual(decompressedDisk, originalSVG)
        XCTAssertEqual(assocURL, validURL)

        let memDetected = TTMediaDetector.detectTypeFromMemory(
            data: validGzip, suggestedName: "badge.svgz", sourceURL: validURL
        )
        guard case .htmlWeb(let decompressedMem, _) = memDetected else {
            return XCTFail("Expected .htmlWeb for valid in-memory .svgz, got \(memDetected)")
        }
        XCTAssertEqual(decompressedMem, originalSVG)

        // 7b. Corrupted, bomb, and non-SVG .svgz payloads route to .hexViewer through TTMediaDetector
        let corruptedURL = tempDir.appendingPathComponent("corrupted.svgz")
        var corruptedGzip = validGzip
        corruptedGzip[corruptedGzip.count - 8] ^= 0xFF
        try corruptedGzip.write(to: corruptedURL)
        if case .hexViewer(let sample, _) = TTMediaDetector.detectType(url: corruptedURL) {
            XCTAssertEqual(sample, corruptedGzip)
        } else {
            XCTFail("Corrupted .svgz must route to .hexViewer fallback")
        }

        let repeated = String(repeating: "A", count: 256 * 1024)
        let bombGzip = try Self.makeRealGzipData(
            from: Data("<svg><!-- \(repeated) --></svg>".utf8)
        )
        if case .hexViewer = TTMediaDetector.detectTypeFromMemory(data: bombGzip, suggestedName: "bomb.svgz") {
            // Expected hexViewer fallback
        } else {
            XCTFail("Expansion-ratio bomb .svgz must route to .hexViewer fallback")
        }

        let nonSVGGzip = try Self.makeRealGzipData(from: Data("not an svg document".utf8))
        if case .hexViewer = TTMediaDetector.detectTypeFromMemory(data: nonSVGGzip, suggestedName: "plain.svgz") {
            // Expected hexViewer fallback
        } else {
            XCTFail("Non-SVG gzip with .svgz extension must route to .hexViewer fallback")
        }

        // 7c. SVGZ-1: Source Code pane in HTMLWebRichPreviewView must represent the decompressed UTF-8 XML
        // (read-only, exact decompressed UTF-8 byte count, UTF-8 encoding, no re-read of Gzip container via fileURL or resourceContext),
        // while preserving archive origin identity when previewed from an archive container.
        let diskContext = TTPreviewResourceContext.diskFile(url: validURL, fileName: "badge.svgz", allowsEditing: true)
        let previewViewDisk = HTMLWebRichPreviewView(
            content: decompressedDisk, fileURL: validURL, fileName: "badge.svgz"
        )
        let diskEditor = previewViewDisk.makeSourceCodeEditorView(ambientContext: diskContext)
        XCTAssertEqual(diskEditor.effectiveSourceEncoding, .utf8, "Decompressed .svgz source must report UTF-8, not Gzip binary heuristic")
        XCTAssertFalse(diskEditor.isNonUTF8ReadOnly, "Decompressed .svgz source must not be flagged as non-UTF-8")
        XCTAssertEqual(diskEditor.initialByteCount, Int64(originalSVG.utf8.count), "Source byte count must match decompressed SVG UTF-8 bytes")
        XCTAssertTrue(diskEditor.isReadOnly, "Decompressed .svgz source pane must be read-only")
        XCTAssertFalse(diskEditor.canSaveInPlace, "Decompressed .svgz source must never allow in-place writeback to Gzip file")
        XCTAssertNil(diskEditor.validatedSaveURL)
        XCTAssertNil(diskEditor.resolvedResourceContext.readableURL, "resolvedResourceContext.readableURL must be nil so .task never re-reads Gzip bytes")

        let archiveContainerURL = tempDir.appendingPathComponent("bundle.zip")
        let archiveContext = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveContainerURL,
            entryPath: "assets/badge.svgz",
            stagedReadURL: validURL,
            fileName: "badge.svgz"
        )
        let archiveEditor = previewViewDisk.makeSourceCodeEditorView(ambientContext: archiveContext)
        XCTAssertEqual(archiveEditor.effectiveSourceEncoding, .utf8)
        XCTAssertEqual(archiveEditor.initialByteCount, Int64(originalSVG.utf8.count))
        XCTAssertTrue(archiveEditor.isReadOnly)
        XCTAssertFalse(archiveEditor.canSaveInPlace)
        XCTAssertNil(archiveEditor.resolvedResourceContext.readableURL, "Archive-staged .svgz must not expose staged Gzip URL to text encoding inspector")
        XCTAssertEqual(
            archiveEditor.resolvedResourceContext.archiveEntryIdentity,
            TTPreviewArchiveEntryIdentity(archiveURL: archiveContainerURL, entryPath: "assets/badge.svgz"),
            "Archive authorization identity must be preserved on the derived context"
        )
    }

    // MARK: - Test 8: Shared Root-Element Identity Corpus Across SVGZ, Detector & Standalone Canvas

    @MainActor
    func testSharedRootElementCorpusAcrossSVGZDetectorAndStandaloneEnvelope() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVGZRootCorpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let positive1A = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- <svg2> fake marker in comment -->
        <svg id="root-1a" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="#0055ff"/></svg>
        """
        let positive1D = "\u{FEFF}<?xml version=\"1.0\" encoding=\"UTF-8\"?><!-- preamble --><!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\" [ <!ENTITY custom \"val\"> ]><SVG id=\"root-1d\" xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" data-expr=\"a > b\"><rect width=\"24\" height=\"24\"/></SVG>"

        for (index, payload) in [positive1A, positive1D].enumerated() {
            let expected = payload.hasPrefix("\u{FEFF}") ? String(payload.dropFirst()) : payload
            let gzip = try Self.makeRealGzipData(from: Data(payload.utf8))
            XCTAssertEqual(try SVGZBoundedDecompressor.decompressSVGZ(data: gzip), expected)
            let svgzURL = tempDir.appendingPathComponent("pos-\(index).svgz")
            try gzip.write(to: svgzURL)
            guard case .htmlWeb(let diskText, _) = TTMediaDetector.detectType(url: svgzURL) else {
                return XCTFail("Expected .htmlWeb for positive corpus \(index)")
            }
            XCTAssertEqual(diskText, expected)
            XCTAssertTrue(HTMLWKWebViewRepresentable.isStandaloneSVG(content: payload, fileURL: svgzURL))
        }

        // Empty-content disk .svgz URL load path in HTMLWKWebViewRepresentable must decompress and apply flex envelope
        let url1A = tempDir.appendingPathComponent("pos-0.svgz")
        let wvDiskSVGZ = makeWebView(content: "", fileURL: url1A, size: NSSize(width: 320, height: 240))
        try await waitUntil(wvDiskSVGZ, condition: "document.getElementById('root-1a') !== null")
        let diskSVGZDisplay = try await evaluateString("getComputedStyle(document.body).display", in: wvDiskSVGZ)
        XCTAssertEqual(diskSVGZDisplay, "flex", "Valid disk .svgz with empty initial content must render in standalone SVG flex envelope")

        let negative1BHTMLInline = "<!DOCTYPE html><html><body><p id=\"html-lead\">Doc</p><svg id=\"inline-svg\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><circle r=\"5\"/></svg></body></html>"
        let negative1C1Comment = "<?xml version=\"1.0\"?><!-- <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg> -->"
        let negative1C2Catalog = "<?xml version=\"1.0\"?><catalog data-hint=\"<svg width='10' height='10'>\"><![CDATA[<svg viewBox=\"0 0 10 10\"></svg>]]></catalog>"
        let negative1ESVG2 = "<svg2 xmlns=\"http://www.w3.org/2000/svg\"></svg2>"
        let negativePrefixed = "<svg:svg xmlns:svg=\"http://www.w3.org/2000/svg\"></svg:svg>"

        for (index, payload) in [negative1BHTMLInline, negative1C1Comment, negative1C2Catalog, negative1ESVG2, negativePrefixed].enumerated() {
            let gzip = try Self.makeRealGzipData(from: Data(payload.utf8))
            XCTAssertThrowsError(try SVGZBoundedDecompressor.decompressSVGZ(data: gzip), "Negative sample \(index) must fail SVGZ root check") { error in
                XCTAssertEqual(error as? SVGZDecompressionError, .notValidSVGPayload)
            }
            let spoofedSVGURL = tempDir.appendingPathComponent("neg-\(index).svg")
            try Data(payload.utf8).write(to: spoofedSVGURL)
            XCTAssertFalse(
                HTMLWKWebViewRepresentable.isStandaloneSVG(content: payload, fileURL: spoofedSVGURL),
                "Negative sample \(index) must not bypass root <svg check via .svg extension"
            )
        }

        // Verify 1B (HTML with inline <svg>) saved with .svg or .html extension renders in normal block HTML layout (both non-empty content and empty-content fileURL paths)
        let spoofedHTMLAsSVGURL = tempDir.appendingPathComponent("neg-0.svg")
        let normalHTMLURL = tempDir.appendingPathComponent("normal-inline.html")
        try Data(negative1BHTMLInline.utf8).write(to: normalHTMLURL)
        for targetURL in [spoofedHTMLAsSVGURL, normalHTMLURL] {
            for initialContent in [negative1BHTMLInline, ""] {
                let wvHTML = makeWebView(content: initialContent, fileURL: targetURL, size: NSSize(width: 320, height: 240))
                try await waitUntil(wvHTML, condition: "document.getElementById('html-lead') !== null")
                let bodyDisplay = try await evaluateString("getComputedStyle(document.body).display", in: wvHTML)
                XCTAssertEqual(bodyDisplay, "block", "HTML with inline <svg> must stay in normal block HTML layout (\(targetURL.lastPathComponent))")
            }
        }

        // Verify rejected disk .svgz files (bad CRC, truncated stream, decompression bomb, and non-SVG root 1B) with empty content
        // render explicit read-only <pre> error fallback and NEVER fall back to loadFileURL on the rejected .svgz file.
        try await assertRejectedDiskSVGZNeverFallsBackToLoadFileURL(in: tempDir, validPayload: positive1A, nonSVGPayload: negative1BHTMLInline)
    }

    @MainActor
    private func assertRejectedDiskSVGZNeverFallsBackToLoadFileURL(
        in tempDir: URL,
        validPayload: String,
        nonSVGPayload: String
    ) async throws {
        let validGzip = try Self.makeRealGzipData(from: Data(validPayload.utf8))
        var badCRCGzip = validGzip
        badCRCGzip[badCRCGzip.count - 8] ^= 0xFF
        let truncatedGzip = Data(validGzip.dropLast(4))
        let repeatedComment = String(repeating: "A", count: 256 * 1024)
        let bombGzip = try Self.makeRealGzipData(from: Data("<svg><!-- \(repeatedComment) --></svg>".utf8))
        let nonSVGGzip = try Self.makeRealGzipData(from: Data(nonSVGPayload.utf8))

        let rejectedCases: [(String, Data, String)] = [
            ("bad-crc.svgz", badCRCGzip, "corruptedPayloadOrChecksumMismatch"),
            ("truncated.svgz", truncatedGzip, "truncatedStream"),
            ("bomb.svgz", bombGzip, "excessiveExpansionRatio"),
            ("non-svg-inline.svgz", nonSVGGzip, "notValidSVGPayload")
        ]
        for (fileName, gzipBytes, expectedErrorToken) in rejectedCases {
            let fileURL = tempDir.appendingPathComponent(fileName)
            try gzipBytes.write(to: fileURL)
            let (wv, coord) = makeWebViewWithCoordinator(content: "", fileURL: fileURL, size: NSSize(width: 320, height: 240))
            try await waitUntil(wv, condition: "document.querySelector('body > pre') !== null")
            XCTAssertNil(coord.allowedDocumentURL, "Rejected disk .svgz (\(fileName)) must clear allowedDocumentURL so raw file access is denied")
            XCTAssertNotEqual(wv.url?.isFileURL, true, "Rejected disk .svgz (\(fileName)) must never call loadFileURL on the original .svgz")
            let hasSVG = try await evaluateString("document.querySelector('svg') === null ? 'none' : 'present'", in: wv)
            let bodyDisplay = try await evaluateString("getComputedStyle(document.body).display", in: wv)
            let preText = try await evaluateString("document.querySelector('body > pre').textContent || ''", in: wv)
            XCTAssertEqual(hasSVG, "none", "Rejected disk .svgz (\(fileName)) must not mount any <svg> element")
            XCTAssertEqual(bodyDisplay, "block", "Rejected disk .svgz (\(fileName)) must render in block error fallback mode")
            XCTAssertTrue(preText.contains(expectedErrorToken), "Expected error token \(expectedErrorToken) in fallback <pre>, got: \(preText)")
        }
    }

    // MARK: - Test 9: Non-viewBox Physical Unit SVG Intrinsic Geometry, Scroll & Pixel Verification

    @MainActor
    func testPhysicalUnitNonViewBoxSVGPreservesIntrinsicGeometryScrollAndPixelsAcrossViewports() async throws {
        let svg300x150pt = """
        <svg id="root-svg" xmlns="http://www.w3.org/2000/svg" width="300pt" height="150pt">
          <rect id="bg" x="0" y="0" width="300pt" height="150pt" fill="#0055ff"/>
          <rect id="corner-br" x="285pt" y="135pt" width="15pt" height="15pt" fill="#00cc44"/>
        </svg>
        """

        // 9a. 640x480 viewport: 300pt x 150pt (400px x 200px) fits inside body (608x448) and centers at (120, 140)
        let wv640 = makeWebView(content: svg300x150pt, fileURL: nil, size: NSSize(width: 640, height: 480))
        try await waitUntil(wv640, condition: "document.getElementById('corner-br') !== null")
        let geom640 = try await evaluateString(Self.svgGeometryProbeScript, in: wv640)
        XCTAssertTrue(geom640.contains("\"viewBox\":\"none\""), "Physical unit root <svg> must not fabricate viewBox: \(geom640)")
        XCTAssertTrue(geom640.contains("\"svgW\":400") && geom640.contains("\"svgH\":200"), "300pt x 150pt must preserve 400x200 CSS px: \(geom640)")
        XCTAssertTrue(geom640.contains("\"svgX\":120") && geom640.contains("\"svgY\":140"), "Smaller non-viewBox SVG must center via margin:auto in 640x480: \(geom640)")
        XCTAssertTrue(geom640.contains("\"bodyClientW\":608") && geom640.contains("\"bodyScrollW\":608"), "Non-overflowing 400x200 SVG in 640x480 must not overflow body: \(geom640)")

        let (ratio640, green640) = try await measurePaintedBlueRatioAndGreenCornerCount(in: wv640)
        XCTAssertEqual(ratio640, 2.0, accuracy: 0.05, "Snapshot painted blue pixel bbox must preserve 2:1 aspect ratio in 640x480")
        XCTAssertGreaterThan(green640, 100, "Bottom-right #corner-br green marker must be painted in 640x480")

        // 9b & 9c. Overflowing non-viewBox physical-unit SVGs in 240x240 and 640x480 via document.body scroll owner
        try await assertBodyOverflowScrollReachesFullCornerMarker(svg300x150pt: svg300x150pt)

        // 9d. pageZoom = 1.5 non-regression on 300pt x 150pt
        let wvZoom = makeWebView(content: svg300x150pt, fileURL: nil, size: NSSize(width: 640, height: 480), pageZoom: 1.5)
        try await waitUntil(wvZoom, condition: "document.getElementById('corner-br') !== null")
        let geomZoom = try await evaluateString(Self.svgGeometryProbeScript, in: wvZoom)
        XCTAssertTrue(geomZoom.contains("\"svgW\":400") && geomZoom.contains("\"svgH\":200"), "CSS px intrinsic dimensions must remain 400x200 under pageZoom=1.5: \(geomZoom)")
    }

    @MainActor
    private func assertBodyOverflowScrollReachesFullCornerMarker(svg300x150pt: String) async throws {
        // 9b. 240x240 narrow viewport: html is 240x240 (non-scrolling), document.body is 208x208 client with 432x232 scroll area
        let wv240 = makeWebView(content: svg300x150pt, fileURL: nil, size: NSSize(width: 240, height: 240))
        try await waitUntil(wv240, condition: "document.getElementById('corner-br') !== null")
        let geom240 = try await evaluateString(Self.svgGeometryProbeScript, in: wv240)
        XCTAssertTrue(geom240.contains("\"svgW\":400") && geom240.contains("\"svgH\":200"), "240x240 narrow viewport must not shrink or clip 400x200 non-viewBox SVG: \(geom240)")
        XCTAssertTrue(geom240.contains("\"svgX\":32") && geom240.contains("\"svgY\":32"), "Overflowing axis must start at padding origin 32px: \(geom240)")
        XCTAssertTrue(geom240.contains("\"htmlClientW\":240") && geom240.contains("\"htmlScrollW\":240"), "html element stays fixed at 240x240 while body owns overflow: \(geom240)")
        XCTAssertTrue(geom240.contains("\"bodyClientW\":208") && geom240.contains("\"bodyClientH\":208"), "body client box in 240x240 with 16px html padding must be 208x208: \(geom240)")
        XCTAssertTrue(geom240.contains("\"bodyScrollW\":432") && geom240.contains("\"bodyScrollH\":232"), "document.body scrollWidth/scrollHeight must expose 432x232: \(geom240)")
        XCTAssertTrue(geom240.contains("\"cornerX\":412") && geom240.contains("\"cornerY\":212"), "Initial #corner-br rect before scroll must sit at (412,212,20,20): \(geom240)")

        let scrolled240 = try await evaluateString(Self.scrollBodyToMaxAndMeasureScript, in: wv240)
        XCTAssertTrue(scrolled240.contains("\"maxScrollLeft\":224") && scrolled240.contains("\"maxScrollTop\":24"), "Max body scroll in 240x240 must be (224,24): \(scrolled240)")
        XCTAssertTrue(scrolled240.contains("\"bodyScrollLeft\":224") && scrolled240.contains("\"bodyScrollTop\":24"), "document.body scrollLeft/scrollTop readback must confirm real scroll (224,24): \(scrolled240)")
        XCTAssertTrue(scrolled240.contains("\"htmlScrollLeft\":0") && scrolled240.contains("\"htmlScrollTop\":0"), "documentElement scroll must remain 0: \(scrolled240)")
        XCTAssertTrue(scrolled240.contains("\"cornerX\":188") && scrolled240.contains("\"cornerY\":188") && scrolled240.contains("\"cornerRight\":208") && scrolled240.contains("\"cornerBottom\":208"), "Scrolling body by (224,24) moves #corner-br from (412,212) to (188,188)..(208,208): \(scrolled240)")
        XCTAssertTrue(scrolled240.contains("\"cornerFullyInsideBody\":true"), "Entire 20x20 #corner-br must lie inside body visible rect [16..224]: \(scrolled240)")
        let (_, green240AfterScroll) = try await measurePaintedBlueRatioAndGreenCornerCount(in: wv240)
        XCTAssertGreaterThan(green240AfterScroll, 100, "Scrolled 240x240 snapshot must paint visible green #corner-br pixels")

        // 9c. 600pt x 450pt (800px x 600px) in 640x480: overflows body (608x448) on both axes, scrollable to (224,184)
        let svg600x450pt = """
        <svg id="root-svg" xmlns="http://www.w3.org/2000/svg" width="600pt" height="450pt">
          <rect id="bg" x="0" y="0" width="600pt" height="450pt" fill="#0055ff"/>
          <rect id="corner-br" x="585pt" y="435pt" width="15pt" height="15pt" fill="#00cc44"/>
        </svg>
        """
        let wvLarge = makeWebView(content: svg600x450pt, fileURL: nil, size: NSSize(width: 640, height: 480))
        try await waitUntil(wvLarge, condition: "document.getElementById('corner-br') !== null")
        let geomLarge = try await evaluateString(Self.svgGeometryProbeScript, in: wvLarge)
        XCTAssertTrue(geomLarge.contains("\"svgW\":800") && geomLarge.contains("\"svgH\":600"), "600pt x 450pt must preserve 800x600 CSS px: \(geomLarge)")
        XCTAssertTrue(geomLarge.contains("\"bodyClientW\":608") && geomLarge.contains("\"bodyClientH\":448"), "body client box in 640x480 must be 608x448: \(geomLarge)")
        XCTAssertTrue(geomLarge.contains("\"bodyScrollW\":832") && geomLarge.contains("\"bodyScrollH\":632"), "document.body must expose 832x632 scroll range: \(geomLarge)")
        XCTAssertTrue(geomLarge.contains("\"cornerX\":812") && geomLarge.contains("\"cornerY\":612"), "Initial #corner-br rect in 800x600 SVG must sit at (812,612): \(geomLarge)")

        let scrolledLarge = try await evaluateString(Self.scrollBodyToMaxAndMeasureScript, in: wvLarge)
        XCTAssertTrue(scrolledLarge.contains("\"bodyScrollLeft\":224") && scrolledLarge.contains("\"bodyScrollTop\":184"), "document.body scroll readback in 640x480 must confirm (224,184): \(scrolledLarge)")
        XCTAssertTrue(scrolledLarge.contains("\"cornerX\":588") && scrolledLarge.contains("\"cornerY\":428") && scrolledLarge.contains("\"cornerRight\":608") && scrolledLarge.contains("\"cornerBottom\":448"), "Scrolling body by (224,184) moves #corner-br from (812,612) to (588,428)..(608,448): \(scrolledLarge)")
        XCTAssertTrue(scrolledLarge.contains("\"cornerFullyInsideBody\":true"), "Entire 20x20 #corner-br must lie inside body visible rect [16..624]x[16..464]: \(scrolledLarge)")
        let (_, greenLargeAfterScroll) = try await measurePaintedBlueRatioAndGreenCornerCount(in: wvLarge)
        XCTAssertGreaterThan(greenLargeAfterScroll, 100, "Scrolled 640x480 snapshot of 800x600 SVG must paint visible green #corner-br pixels")
    }

    private static let svgGeometryProbeScript = """
    (function() {
      const docEl = document.documentElement;
      const body = document.body;
      const bodyRect = body.getBoundingClientRect();
      const svg = document.querySelector('body > svg');
      const r = svg.getBoundingClientRect();
      const c = document.getElementById('corner-br').getBoundingClientRect();
      return JSON.stringify({
        viewBox: svg.getAttribute('viewBox') || 'none',
        svgX: Math.round(r.x), svgY: Math.round(r.y),
        svgW: Math.round(r.width), svgH: Math.round(r.height),
        htmlClientW: docEl.clientWidth, htmlClientH: docEl.clientHeight,
        htmlScrollW: docEl.scrollWidth, htmlScrollH: docEl.scrollHeight,
        htmlScrollLeft: Math.round(docEl.scrollLeft), htmlScrollTop: Math.round(docEl.scrollTop),
        bodyX: Math.round(bodyRect.x), bodyY: Math.round(bodyRect.y),
        bodyRight: Math.round(bodyRect.right), bodyBottom: Math.round(bodyRect.bottom),
        bodyClientW: body.clientWidth, bodyClientH: body.clientHeight,
        bodyScrollW: body.scrollWidth, bodyScrollH: body.scrollHeight,
        bodyScrollLeft: Math.round(body.scrollLeft), bodyScrollTop: Math.round(body.scrollTop),
        cornerX: Math.round(c.x), cornerY: Math.round(c.y),
        cornerW: Math.round(c.width), cornerH: Math.round(c.height),
        cornerRight: Math.round(c.right), cornerBottom: Math.round(c.bottom)
      });
    })()
    """

    private static let scrollBodyToMaxAndMeasureScript = """
    (function() {
      const docEl = document.documentElement;
      const body = document.body;
      const maxLeft = body.scrollWidth - body.clientWidth;
      const maxTop = body.scrollHeight - body.clientHeight;
      body.scrollLeft = maxLeft;
      body.scrollTop = maxTop;
      const bodyRect = body.getBoundingClientRect();
      const c = document.getElementById('corner-br').getBoundingClientRect();
      const cx = Math.round(c.x), cy = Math.round(c.y);
      const cw = Math.round(c.width), ch = Math.round(c.height);
      const cRight = Math.round(c.right), cBottom = Math.round(c.bottom);
      const bx = Math.round(bodyRect.x), by = Math.round(bodyRect.y);
      const bRight = Math.round(bodyRect.right), bBottom = Math.round(bodyRect.bottom);
      return JSON.stringify({
        maxScrollLeft: maxLeft, maxScrollTop: maxTop,
        bodyScrollLeft: Math.round(body.scrollLeft), bodyScrollTop: Math.round(body.scrollTop),
        htmlScrollLeft: Math.round(docEl.scrollLeft), htmlScrollTop: Math.round(docEl.scrollTop),
        bodyX: bx, bodyY: by, bodyRight: bRight, bodyBottom: bBottom,
        cornerX: cx, cornerY: cy, cornerW: cw, cornerH: ch,
        cornerRight: cRight, cornerBottom: cBottom,
        cornerFullyInsideBody: (cx >= bx && cy >= by && cRight <= bRight && cBottom <= bBottom)
      });
    })()
    """

    @MainActor
    private func makeWebView(content: String, fileURL: URL?, size: NSSize, pageZoom: Double = 1.0) -> WKWebView {
        makeWebViewWithCoordinator(content: content, fileURL: fileURL, size: size, pageZoom: pageZoom).0
    }

    @MainActor
    private func makeWebViewWithCoordinator(
        content: String,
        fileURL: URL?,
        size: NSSize,
        pageZoom: Double = 1.0
    ) -> (WKWebView, HTMLWKWebViewRepresentable.Coordinator) {
        let representable = HTMLWKWebViewRepresentable(content: content, fileURL: fileURL, pageZoom: pageZoom)
        let coordinator = representable.makeCoordinator()
        let configuration = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: configuration)
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.pageZoom = CGFloat(pageZoom)
        retainedWebKitObjects.append(coordinator)
        retainedWebKitObjects.append(webView)
        representable.loadHTML(in: webView, coordinator: coordinator)
        return (webView, coordinator)
    }

    @MainActor
    private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? String) ?? "")
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private func waitUntil(_ webView: WKWebView, condition: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ready = try? await evaluateString("(\(condition)) ? 'ready' : 'waiting'", in: webView), ready == "ready" {
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Timed out waiting for WebKit condition: \(condition)")
    }

    @MainActor
    private func measurePaintedBlueRatioAndGreenCornerCount(in webView: WKWebView) async throws -> (Double, Int) {
        try await Task.sleep(for: .milliseconds(80))
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            webView.takeSnapshot(with: config) { img, err in
                if let img {
                    continuation.resume(returning: img)
                } else {
                    continuation.resume(throwing: err ?? NSError(domain: "Snapshot", code: -1))
                }
            }
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return (0, 0)
        }
        return Self.scanBlueBBoxAndGreenPixels(
            ptr: ptr, width: cgImage.width, height: cgImage.height,
            bpp: cgImage.bitsPerPixel / 8, bpr: cgImage.bytesPerRow
        )
    }

    private static func scanBlueBBoxAndGreenPixels(
        ptr: UnsafePointer<UInt8>, width: Int, height: Int, bpp: Int, bpr: Int
    ) -> (Double, Int) {
        var minX = width, maxX = -1, minY = height, maxY = -1, greenCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bpr + x * bpp
                let b = Int(ptr[offset]), g = Int(ptr[offset + 1]), r = Int(ptr[offset + 2])
                if b > 180 && r < 50 && g > 40 && g < 160 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                } else if g > 160 && r < 80 && b < 120 {
                    greenCount += 1
                }
            }
        }
        let ratio = (maxX >= minX && maxY >= minY) ? Double(maxX - minX + 1) / Double(maxY - minY + 1) : 0
        return (ratio, greenCount)
    }

    // MARK: - Helper: Real RFC 1952 Gzip Compressor via zlib

    private static func makeRealGzipData(from uncompressed: Data) throws -> Data {
        uncompressed.withUnsafeBytes { rawBuffer -> Data in
            var stream = z_stream()
            if let base = rawBuffer.bindMemory(to: Bytef.self).baseAddress {
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base)
            }
            stream.avail_in = uInt(rawBuffer.count)

            let initStatus = deflateInit2_(
                &stream,
                Z_BEST_COMPRESSION,
                Z_DEFLATED,
                16 + MAX_WBITS,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            XCTAssertEqual(initStatus, Z_OK)
            defer {
                deflateEnd(&stream)
            }

            var compressed = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            var status: Int32 = Z_OK

            while status == Z_OK {
                let chunkSize = chunk.count
                var produced = 0
                chunk.withUnsafeMutableBufferPointer { ptr in
                    stream.next_out = ptr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    produced = chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    compressed.append(contentsOf: chunk.prefix(produced))
                }
            }

            XCTAssertEqual(status, Z_STREAM_END)
            return compressed
        }
    }
}
