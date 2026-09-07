// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import AppKit
import TTZipUI
import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

final class MediaPreviewCapabilityMatrixTests: XCTestCase {

    private var tempDirURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCapabilityMatrixTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Test 1: Exhaustive 50+ Extension Matrix Capabilities & Primary Mode

    func testFiftyPlusExtensionsCapabilityAndPrimaryModeMatrix() {
        let testCases: [(
            ext: String,
            expectedCapabilities: PreviewCapabilities,
            expectedPrimary: PreviewPrimaryMode,
            expectedIcon: String
        )] = [
            // 1. Web & Vector Visual Renderers
            ("html", [.visualRender, .sourceCode], .visualRender, "globe"),
            ("htm", [.visualRender, .sourceCode], .visualRender, "globe"),
            ("xhtml", [.visualRender, .sourceCode], .visualRender, "globe"),
            ("mhtml", [.visualRender, .sourceCode], .visualRender, "globe"),
            ("svg", [.visualRender, .sourceCode], .visualRender, "photo.fill"),
            ("svgz", [.visualRender, .sourceCode], .visualRender, "photo.fill"),

            // 2. Markdown Rich Documents
            ("md", [.visualRender, .sourceCode], .visualRender, "doc.text.fill"),
            ("markdown", [.visualRender, .sourceCode], .visualRender, "doc.text.fill"),
            ("mdown", [.visualRender, .sourceCode], .visualRender, "doc.text.fill"),
            ("mkd", [.visualRender, .sourceCode], .visualRender, "doc.text.fill"),

            // 3. Tabular & Spreadsheets
            ("csv", [.structuredData, .sourceCode], .structuredData, "tablecells.fill"),
            ("tsv", [.structuredData, .sourceCode], .structuredData, "tablecells.fill"),
            ("tab", [.structuredData, .sourceCode], .structuredData, "tablecells.fill"),
            ("psv", [.structuredData, .sourceCode], .structuredData, "tablecells.fill"),
            ("ssv", [.structuredData, .sourceCode], .structuredData, "tablecells.fill"),
            ("xlsx", [.structuredData], .structuredData, "tablecells.fill"),
            ("xls", [.structuredData], .structuredData, "tablecells.fill"),
            ("ods", [.structuredData], .structuredData, "tablecells.fill"),

            // 4. Structured Data & Notebooks
            ("json", [.structuredData, .sourceCode], .structuredData, "curlybraces"),
            ("xml", [.structuredData, .sourceCode], .structuredData, "curlybraces"),
            ("plist", [.structuredData, .sourceCode], .structuredData, "doc.text.fill"),
            ("yaml", [.structuredData, .sourceCode], .structuredData, "curlybraces"),
            ("yml", [.structuredData, .sourceCode], .structuredData, "curlybraces"),
            ("toml", [.structuredData, .sourceCode], .structuredData, "curlybraces"),
            ("ipynb", [.structuredData, .sourceCode], .structuredData, "curlybraces"),

            // 5. Source Code & Scripts
            ("swift", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("rs", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("py", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("js", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("tsx", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("c", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("cpp", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("h", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("go", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("java", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("kt", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("sh", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("css", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),
            ("sql", [.sourceCode], .sourceCode, "chevron.left.forwardslash.chevron.right"),

            // 6. Plain Text & Subtitles
            ("txt", [.sourceCode], .sourceCode, "doc.text.fill"),
            ("log", [.sourceCode], .sourceCode, "doc.text.fill"),
            ("ini", [.sourceCode], .sourceCode, "doc.text.fill"),
            ("srt", [.sourceCode], .sourceCode, "captions.bubble.fill"),
            ("vtt", [.sourceCode], .sourceCode, "captions.bubble.fill"),

            // 7. Paginated Documents & Office
            ("pdf", [.visualRender, .documentPagination], .visualRender, "doc.richtext.fill"),
            ("docx", [.visualRender, .documentPagination], .visualRender, "doc.richtext.fill"),
            ("pptx", [.visualRender, .structuredData], .visualRender, "rectangle.inset.filled.and.person.filled"),
            ("epub", [.visualRender, .documentPagination], .visualRender, "book.closed.fill"),
            ("mobi", [.visualRender, .documentPagination], .visualRender, "book.closed.fill"),

            // 8. Raster Images
            ("png", [.visualRender], .visualRender, "photo.fill"),
            ("jpg", [.visualRender], .visualRender, "photo.fill"),
            ("jpeg", [.visualRender], .visualRender, "photo.fill"),
            ("webp", [.visualRender], .visualRender, "photo.fill"),
            ("gif", [.visualRender], .visualRender, "photo.fill"),

            // 9. Continuous Media Streams
            ("mp4", [.mediaPlayback], .mediaPlayback, "film.fill"),
            ("mkv", [.mediaPlayback], .mediaPlayback, "film.fill"),
            ("mov", [.mediaPlayback], .mediaPlayback, "film.fill"),
            ("ts", [.mediaPlayback], .mediaPlayback, "film.fill"),
            ("mp3", [.mediaPlayback], .mediaPlayback, "music.note"),
            ("wav", [.mediaPlayback], .mediaPlayback, "music.note"),
            ("flac", [.mediaPlayback], .mediaPlayback, "music.note"),

            // 10. Archive Containers
            ("zip", [.archiveBrowse], .archiveBrowse, "archivebox.fill"),
            ("7z", [.archiveBrowse], .archiveBrowse, "archivebox.fill"),
            ("tar", [.archiveBrowse], .archiveBrowse, "archivebox.fill"),

            // 11. Compiled Binary
            ("bin", [.hexBinary], .hexBinary, "memorychip.fill"),
            ("wasm", [.hexBinary], .hexBinary, "memorychip.fill"),
            ("dylib", [.hexBinary], .hexBinary, "memorychip.fill")
        ]

        XCTAssertGreaterThanOrEqual(testCases.count, 55, "Test suite must cover 50+ extensions")

        for tc in testCases {
            guard let descriptor = PreviewCapabilityMatrix.descriptor(for: tc.ext) else {
                XCTFail("Missing capability descriptor for extension: \(tc.ext)")
                continue
            }

            XCTAssertEqual(
                descriptor.capabilities,
                tc.expectedCapabilities,
                "Capabilities mismatch for extension .\(tc.ext)"
            )
            XCTAssertEqual(
                descriptor.primaryMode,
                tc.expectedPrimary,
                "Primary mode mismatch for extension .\(tc.ext)"
            )
            XCTAssertEqual(
                descriptor.iconName,
                tc.expectedIcon,
                "Icon mismatch for extension .\(tc.ext)"
            )

            // Direct query methods consistency
            XCTAssertEqual(
                PreviewCapabilityMatrix.capabilities(for: tc.ext),
                tc.expectedCapabilities,
                "Direct capabilities query failed for .\(tc.ext)"
            )
            XCTAssertEqual(
                PreviewCapabilityMatrix.primaryMode(for: tc.ext),
                tc.expectedPrimary,
                "Direct primaryMode query failed for .\(tc.ext)"
            )
            XCTAssertEqual(
                PreviewCapabilityMatrix.iconName(for: tc.ext),
                tc.expectedIcon,
                "Direct iconName query failed for .\(tc.ext)"
            )
        }
    }

    // MARK: - Test 2: Sanitization, Case Insensitivity & Leading Dots

    func testExtensionSanitizationAndCaseInsensitivity() {
        let variations = [
            "SVG", "Svg", "sVg", ".svg", " .svg ", "FILE.SVG", "/path/to/image.svg",
            "JSON", "Json", ".JSON", "DATA.JSON", "config.sample.json",
            "CSV", ".csv", "Report.CSV"
        ]

        for variant in variations {
            let desc = PreviewCapabilityMatrix.descriptor(for: variant)
            XCTAssertNotNil(desc, "Descriptor resolution failed for variant: '\(variant)'")
        }

        // SVG assertions
        XCTAssertTrue(PreviewCapabilityMatrix.isVisualRenderable("SVG"))
        XCTAssertTrue(PreviewCapabilityMatrix.hasSourceCode("SVG"))
        XCTAssertEqual(PreviewCapabilityMatrix.primaryMode(for: "SVG"), .visualRender)

        // JSON assertions
        XCTAssertTrue(PreviewCapabilityMatrix.isStructuredData("JSON"))
        XCTAssertTrue(PreviewCapabilityMatrix.hasSourceCode("JSON"))
        XCTAssertEqual(PreviewCapabilityMatrix.primaryMode(for: "JSON"), .structuredData)

        // Unknown extensions safety
        XCTAssertNil(PreviewCapabilityMatrix.descriptor(for: "nonexistent_ext_xyz"))
        XCTAssertEqual(PreviewCapabilityMatrix.capabilities(for: "nonexistent_ext_xyz"), [])
        XCTAssertNil(PreviewCapabilityMatrix.primaryMode(for: "nonexistent_ext_xyz"))
        XCTAssertEqual(PreviewCapabilityMatrix.iconName(for: "nonexistent_ext_xyz"), "doc.fill")
    }

    // MARK: - Test 3: SVG Dual-Mode Routing Never Defaults to Raw Hex

    func testSVGDualModeRoutingNeverDefaultsToHexViewer() async throws {
        let svgContent = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
          <circle cx="50" cy="50" r="40" stroke="green" stroke-width="4" fill="yellow" />
        </svg>
        """
        let svgURL = tempDirURL.appendingPathComponent("circle.svg")
        try svgContent.write(to: svgURL, atomically: true, encoding: .utf8)

        // 1. Synchronous detectType must return .htmlWeb
        let syncType = MediaPreviewFactory.detectType(url: svgURL)
        if case .htmlWeb(let content, let fileURL) = syncType {
            XCTAssertTrue(content.contains("<circle"), "SVG content missing circle element")
            XCTAssertEqual(fileURL, svgURL)
        } else {
            XCTFail("Synchronous detectType for SVG fell through to \(syncType) instead of .htmlWeb")
        }

        // 2. Asynchronous detectTypeAsync must return .htmlWeb
        let asyncType = await MediaPreviewFactory.detectTypeAsync(url: svgURL)
        if case .htmlWeb(let content, let fileURL) = asyncType {
            XCTAssertTrue(content.contains("<circle"), "SVG content missing circle element")
            XCTAssertEqual(fileURL, svgURL)
        } else {
            XCTFail("Asynchronous detectTypeAsync for SVG fell through to \(asyncType) instead of .htmlWeb")
        }

        // 3. In-memory data detection must return .htmlWeb
        let svgData = Data(svgContent.utf8)
        let memType = MediaPreviewFactory.detectTypeFromMemory(data: svgData, suggestedName: "circle.svg")
        if case .htmlWeb(let content, _) = memType {
            XCTAssertTrue(content.contains("<circle"), "In-memory SVG content missing circle element")
        } else {
            XCTFail("In-memory detectTypeFromMemory for SVG fell through to \(memType) instead of .htmlWeb")
        }

        // 4. Icon name must be photo.fill
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "circle.svg"), "photo.fill")
    }

    // MARK: - Test 4: Tabular Spreadsheets Dual-Mode Routing (CSV, TSV, PSV, SSV)

    func testTabularSpreadsheetFormatsRouting() async throws {
        let formats = [
            ("sample.csv", "id,name,value\n1,Alpha,100\n2,Beta,200"),
            ("sample.tsv", "id\tname\tvalue\n1\tAlpha\t100\n2\tBeta\t200"),
            ("sample.tab", "id\tname\tvalue\n1\tAlpha\t100\n2\tBeta\t200"),
            ("sample.psv", "id|name|value\n1|Alpha|100\n2|Beta|200"),
            ("sample.ssv", "id;name;value\n1;Alpha;100\n2;Beta;200")
        ]

        for (fileName, content) in formats {
            let fileURL = tempDirURL.appendingPathComponent(fileName)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            let syncType = MediaPreviewFactory.detectType(url: fileURL)
            if case .spreadsheetTable(let text, let url) = syncType {
                XCTAssertEqual(url, fileURL)
                XCTAssertTrue(text.contains("Alpha"))
            } else {
                XCTFail("Sync detectType for \(fileName) fell through to \(syncType) instead of .spreadsheetTable")
            }

            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: fileURL)
            if case .spreadsheetTable(let text, let url) = asyncType {
                XCTAssertEqual(url, fileURL)
                XCTAssertTrue(text.contains("Alpha"))
            } else {
                XCTFail("Async detectTypeAsync for \(fileName) fell through to \(asyncType) instead of .spreadsheetTable")
            }

            let data = Data(content.utf8)
            let memType = MediaPreviewFactory.detectTypeFromMemory(data: data, suggestedName: fileName)
            if case .spreadsheetTable(let text, _) = memType {
                XCTAssertTrue(text.contains("Alpha"))
            } else {
                XCTFail("In-memory detectTypeFromMemory for \(fileName) fell through to \(memType) instead of .spreadsheetTable")
            }

            XCTAssertEqual(MediaPreviewFactory.iconName(for: fileName), "tablecells.fill")
        }
    }

    // MARK: - Test 5: Structured Serialization & Notebook Formats (JSON, XML, PLIST, IPYNB, TOML)

    func testStructuredSerializationAndNotebookFormatsRouting() async throws {
        let testFiles = [
            ("data.json", "{\"key\": \"value\", \"count\": 42}"),
            ("config.xml", "<config><item id=\"1\">Value</item></config>"),
            ("info.plist", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>Name</key><string>TTZip</string></dict></plist>"),
            ("notebook.ipynb", "{\"cells\": [], \"metadata\": {}, \"nbformat\": 4, \"nbformat_minor\": 2}"),
            ("Cargo.toml", "[package]\nname = \"ttzip\"\nversion = \"1.0.0\"")
        ]

        for (fileName, content) in testFiles {
            let fileURL = tempDirURL.appendingPathComponent(fileName)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            let syncType = MediaPreviewFactory.detectType(url: fileURL)
            if case .text(let text) = syncType {
                XCTAssertFalse(text.isEmpty)
            } else {
                XCTFail("Sync detectType for \(fileName) fell through to \(syncType) instead of .text")
            }

            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: fileURL)
            if case .text(let text) = asyncType {
                XCTAssertFalse(text.isEmpty)
            } else {
                XCTFail("Async detectTypeAsync for \(fileName) fell through to \(asyncType) instead of .text")
            }

            let data = Data(content.utf8)
            let memType = MediaPreviewFactory.detectTypeFromMemory(data: data, suggestedName: fileName)
            if case .text(let text) = memType {
                XCTAssertFalse(text.isEmpty)
            } else {
                XCTFail("In-memory detectTypeFromMemory for \(fileName) fell through to \(memType) instead of .text")
            }
        }
    }

    // MARK: - Test 6: Visual Renderable Formats Never Default to Raw Hex

    func testVisualRenderableFormatsNeverDefaultToHex() async throws {
        let visualFormats: [(name: String, content: String, verify: (MediaPreviewType) -> Bool)] = [
            ("page.html", "<html><body><h1>Hello</h1></body></html>", { if case .htmlWeb = $0 { return true } else { return false } }),
            ("page.mhtml", "From: <Saved by Web>\nSubject: Test\nContent-Type: text/html\n\n<h1>Test</h1>", { if case .htmlWeb = $0 { return true } else { return false } }),
            ("README.md", "# Title\n\nParagraph text here.", { if case .markdown = $0 { return true } else { return false } }),
            ("vector.svg", "<svg><circle cx='5' cy='5' r='5'/></svg>", { if case .htmlWeb = $0 { return true } else { return false } }),
            ("data.csv", "a,b\n1,2", { if case .spreadsheetTable = $0 { return true } else { return false } })
        ]

        for item in visualFormats {
            let fileURL = tempDirURL.appendingPathComponent(item.name)
            try item.content.write(to: fileURL, atomically: true, encoding: .utf8)

            let syncType = MediaPreviewFactory.detectType(url: fileURL)
            XCTAssertTrue(item.verify(syncType), "Format \(item.name) sync failed check: \(syncType)")

            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: fileURL)
            XCTAssertTrue(item.verify(asyncType), "Format \(item.name) async failed check: \(asyncType)")

            let data = Data(item.content.utf8)
            let memType = MediaPreviewFactory.detectTypeFromMemory(data: data, suggestedName: item.name)
            XCTAssertTrue(item.verify(memType), "Format \(item.name) in-memory failed check: \(memType)")

            // Assert capabilities matrix reports visualRender or structuredData
            let caps = PreviewCapabilityMatrix.capabilities(for: item.name)
            XCTAssertTrue(
                caps.contains(.visualRender) || caps.contains(.structuredData),
                "Capabilities for \(item.name) must contain visualRender or structuredData"
            )
        }
    }
}
