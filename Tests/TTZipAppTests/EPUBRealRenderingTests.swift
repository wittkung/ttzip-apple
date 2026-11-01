// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import WebKit
import TTZipUI
import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class EPUBRealRenderingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            EPUBArchiveUnpacker.register()
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            EPUBArchiveUnpacker.register()
        }
    }
    
    @MainActor
    func testEPUBParserIsRegisteredAtAppLaunch() async throws {
        // App launch natively bootstraps subsystems
        EPUBArchiveUnpacker.register()
        
        XCTAssertNotNil(TTMediaBackgroundDetector.epubParser, "EPUBArchiveUnpacker.register() should eagerly configure the EPUB parser")
        
        // Also verify that passing an unparseable URL behaves gracefully via the closure
        let nonEpubURL = URL(fileURLWithPath: "/tmp/nonexistent_test.epub")
        let model = await TTMediaBackgroundDetector.epubParser?(nonEpubURL)
        XCTAssertNil(model)
    }

    @MainActor
    func testRealDeviceHegelEPUBUnpackingAndParsing() async throws {
        let hegelPath = "/Users/tester/Downloads/hegel-philosophy-of-spirit.epub"
        let fileURL = URL(fileURLWithPath: hegelPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        
        EPUBArchiveUnpacker.register()
        XCTAssertNotNil(TTMediaBackgroundDetector.epubParser)
        
        // 1. Unpack & Parse
        guard let bookModel = EPUBArchiveUnpacker.unpackAndParseEPUB(at: fileURL) else {
            XCTFail("Failed to unpack and parse real Hegel EPUB")
            return
        }
        
        XCTAssertGreaterThan(bookModel.chapters.count, 0, "Hegel EPUB must contain chapters")
        
        // 2. Async detection
        let asyncType = await MediaPreviewFactory.detectTypeAsync(url: fileURL)
        switch asyncType {
        case .epubBook(let model):
            XCTAssertGreaterThan(model.chapters.count, 0)
            XCTAssertFalse(model.title.isEmpty)
        default:
            XCTFail("Expected .epubBook for Hegel EPUB, got \(asyncType)")
        }
    }

    // MARK: - Test 1: Full Factory Routing & Capability Matrix Conformance

    func testEPUBFullMatrixAndFactoryRouting() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "EPUB")
        let epubURL = try await createRealisticEpub(in: tempDirURL, named: "StandardBook.epub")
        let epubData = try Data(contentsOf: epubURL)

        // 1. Matrix metadata capability
        let descriptor = PreviewCapabilityMatrix.descriptor(for: "epub")
        XCTAssertNotNil(descriptor)
        XCTAssertTrue(descriptor?.capabilities.contains(.visualRender) ?? false)
        XCTAssertTrue(descriptor?.capabilities.contains(.documentPagination) ?? false)
        XCTAssertEqual(descriptor?.primaryMode, .visualRender)

        // 2. Synchronous detectType MUST NOT fall back to hexViewer
        let syncType = MediaPreviewFactory.detectType(url: epubURL)
        switch syncType {
        case .ebook(let meta):
            XCTAssertEqual(meta.formatName, "EPUB")
            XCTAssertEqual(meta.title, "StandardBook")
        default:
            XCTFail("Expected .ebook for synchronous detectType(url:), got: \(syncType)")
        }

        // 3. Asynchronous detectTypeAsync MUST parse into .epubBook
        let asyncType = await MediaPreviewFactory.detectTypeAsync(url: epubURL)
        switch asyncType {
        case .epubBook(let model):
            XCTAssertEqual(model.chapters.count, 2)
            XCTAssertEqual(model.chapters[0].title, "Cover")
            XCTAssertEqual(model.chapters[1].title, "Chapter 1")
            XCTAssertTrue(model.chapters[0].fileURL.absoluteString.contains("cover.xhtml"))
        default:
            XCTFail("Expected .epubBook for asynchronous detectTypeAsync(url:), got: \(asyncType)")
        }

        // 4. In-memory detectTypeFromMemory MUST NOT fall back to hexViewer
        let memType = MediaPreviewFactory.detectTypeFromMemory(
            data: epubData,
            suggestedName: "StandardBook.epub",
            sourceURL: epubURL
        )
        switch memType {
        case .epubBook(let model):
            XCTAssertGreaterThanOrEqual(model.chapters.count, 1)
        case .ebook(let meta):
            XCTAssertEqual(meta.formatName, "EPUB")
        default:
            XCTFail("Expected .epubBook or .ebook for detectTypeFromMemory, got: \(memType)")
        }
    }

    // MARK: - Test 2: All Ebook Formats Matrix Classification & Zero Hex Fallthrough

    func testAllEbookFormatsClassificationAndZeroHexFallthrough() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "EPUB")
        let expectedEbookExts = [
            "epub", "mobi", "azw", "azw3", "fb2", "cbz", "cbr", "ibooks"
        ]
        XCTAssertGreaterThanOrEqual(PreviewCapabilityMatrix.ebookExtensions.count, 8)

        for ext in expectedEbookExts {
            XCTAssertTrue(PreviewCapabilityMatrix.ebookExtensions.contains(ext), "Missing ebook format: \(ext)")
            let mockURL = tempDirURL.appendingPathComponent("book_\(ext).\(ext)")
            let mockData = Data("sample book payload for \(ext)".utf8)
            try mockData.write(to: mockURL)

            // Sync detection
            let syncType = MediaPreviewFactory.detectType(url: mockURL)
            switch syncType {
            case .ebook(let meta):
                XCTAssertEqual(meta.formatName.lowercased(), ext)
            case .epubBook:
                break
            case .unsupported(let reason) where (ext == "cbz" || ext == "cbr") && reason.contains("Archive loaded"):
                break
            default:
                XCTFail("Extension .\(ext) sync failed to detect as ebook, fell through to: \(syncType)")
            }

            // Async detection
            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: mockURL)
            switch asyncType {
            case .ebook(let meta):
                XCTAssertEqual(meta.formatName.lowercased(), ext)
            case .epubBook:
                break
            case .unsupported(let reason) where (ext == "cbz" || ext == "cbr") && reason.contains("Archive loaded"):
                break
            default:
                XCTFail("Extension .\(ext) async failed to detect as ebook, fell through to: \(asyncType)")
            }

            // In-Memory detection (Must not fall through to .hexViewer)
            let memType = MediaPreviewFactory.detectTypeFromMemory(data: mockData, suggestedName: "book.\(ext)")
            switch memType {
            case .ebook(let meta):
                XCTAssertEqual(meta.formatName.lowercased(), ext)
            case .epubBook:
                break
            default:
                XCTFail("Extension .\(ext) in-memory fell through to \(memType) instead of .ebook/.epubBook")
            }

            XCTAssertEqual(MediaPreviewFactory.iconName(for: "book.\(ext)"), "book.closed.fill")
        }
    }

    // MARK: - Test 3: BaseURL Normalization & Relative Image Asset Resolution (Anti-White-Screen)

    func testEPUBBaseURLNormalizationAndRelativeAssetResolution() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "EPUB")
        let epubURL = try await createRealisticEpub(in: tempDirURL, named: "CoverAssetTest.epub")
        guard let bookModel = EPUBArchiveUnpacker.unpackAndParseEPUB(at: epubURL) else {
            XCTFail("Failed to unpack realistic EPUB")
            return
        }

        XCTAssertFalse(bookModel.chapters.isEmpty)
        let coverChapter = bookModel.chapters[0]
        let coverVfsURL = coverChapter.fileURL

        // 1. Verify baseURL calculation does NOT append "%2F"
        let parentURL = coverVfsURL.deletingLastPathComponent()
        let parentStr = parentURL.absoluteString
        let resolvedBaseURL = URL(string: parentStr.hasSuffix("/") ? parentStr : parentStr + "/") ?? parentURL

        XCTAssertFalse(resolvedBaseURL.absoluteString.contains("%2F"), "resolvedBaseURL must not contain escaped %2F")
        XCTAssertTrue(resolvedBaseURL.absoluteString.hasSuffix("/"), "resolvedBaseURL must have trailing slash for directory resolution")

        // 2. Simulate WebKit relative path resolution for "../images/cover.jpg"
        let relativeImagePath = "../images/cover.jpg"
        let resolvedImageURL = URL(string: relativeImagePath, relativeTo: resolvedBaseURL)?.absoluteURL
        XCTAssertNotNil(resolvedImageURL)

        guard let imageVfsURL = resolvedImageURL else { return }

        // The resolved URL must target OEBPS/images/cover.jpg, NOT OEBPS/text/images/cover.jpg
        XCTAssertTrue(imageVfsURL.absoluteString.contains("OEBPS/images/cover.jpg"), "Relative jump ../ must resolve to OEBPS/images/cover.jpg, got: \(imageVfsURL.absoluteString)")
        XCTAssertFalse(imageVfsURL.absoluteString.contains("text/images"), "Must not falsely contain intermediate text/ folder")

        // 3. Load resource via TTZipArchiveVfsProvider
        let resource = try await TTZipArchiveVfsProvider.shared.loadResource(uri: imageVfsURL.absoluteString)
        XCTAssertNotNil(resource, "Resource request for relative cover image must succeed via VFS")
        XCTAssertEqual(resource?.mimeType, "image/jpeg")
        XCTAssertGreaterThan(resource?.data.count ?? 0, 10)
    }

    // MARK: - Test 3: UTF-8 BOM EPUB Tolerance

    func testEPUBWithUtf8BomResolution() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "EPUB")
        let bomEpubURL = try await createRealisticEpub(in: tempDirURL, named: "BomSample.epub", injectBOM: true)
        let bookModel = EPUBArchiveUnpacker.unpackAndParseEPUB(at: bomEpubURL)

        XCTAssertNotNil(bookModel, "EPUB parser must gracefully parse container.xml and OPF with UTF-8 BOM")
        XCTAssertEqual(bookModel?.chapters.count, 2)
    }

    // MARK: - Test 4: Percent Encoding in Chapter Paths (Anti-Double-Encoding)

    func testEPUBChapterPathWithPercentEncoding() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "EPUB")
        let archivePath = tempDirURL.appendingPathComponent("EncodingTest.epub").path
        let provider = TTZipArchiveVfsProvider.shared

        // Pass path that already has percent encoding: "OEBPS/Text/Chapter%201.xhtml"
        let vfsURL1 = provider.vfsURL(archivePath: archivePath, entryPath: "OEBPS/Text/Chapter%201.xhtml")
        XCTAssertFalse(vfsURL1.absoluteString.contains("%2520"), "makeVfsURL must not double-encode %20 to %2520")
        XCTAssertTrue(vfsURL1.absoluteString.contains("Chapter%201.xhtml"))

        // Pass plain path with space: "OEBPS/Text/Chapter 1.xhtml"
        let vfsURL2 = provider.vfsURL(archivePath: archivePath, entryPath: "OEBPS/Text/Chapter 1.xhtml")
        XCTAssertFalse(vfsURL2.absoluteString.contains("%2520"))
        XCTAssertTrue(vfsURL2.absoluteString.contains("Chapter%201.xhtml"))

        // Both representations should yield identical normalized entryPath
        let parsed1 = provider.parseVfsUri(vfsURL1.absoluteString)
        let parsed2 = provider.parseVfsUri(vfsURL2.absoluteString)
        XCTAssertEqual(parsed1?.entryPath, "OEBPS/Text/Chapter 1.xhtml")
        XCTAssertEqual(parsed2?.entryPath, "OEBPS/Text/Chapter 1.xhtml")
    }

    // MARK: - Test 5: Headless EPUBNativeWKWebView Coordinator Lifecycle

    func testEPUBNativeWKWebViewMountAndCoordinatorLifecycle() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "EPUB")
        let epubURL = try await createRealisticEpub(in: tempDirURL, named: "LifecycleTest.epub")
        guard let bookModel = EPUBArchiveUnpacker.unpackAndParseEPUB(at: epubURL) else {
            XCTFail("Failed to unpack EPUB")
            return
        }

        let chapterURL = bookModel.chapters[0].fileURL
        let baseDir = tempDirURL

        let view = EPUBNativeWKWebView(
            chapterURL: chapterURL,
            baseDirectory: baseDir,
            fontSize: 16.0,
            fontStyle: "sans",
            readerTheme: "light"
        )

        let coordinator = view.makeCoordinator()
        let config = WKWebViewConfiguration()
        let vfsHandler = TTZipVfsSchemeHandler(provider: TTZipArchiveVfsProvider.shared)
        config.setURLSchemeHandler(vfsHandler, forURLScheme: TTZipVfsSchemeHandler.scheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = coordinator

        // Load chapter via background actor
        let customCSS = "body { margin: 0; }"
        let loadedHTML = await EPUBChapterContentLoaderActor.shared.loadChapter(at: chapterURL, customCSS: customCSS)
        XCTAssertNotNil(loadedHTML, "loadChapter must successfully read and inject CSS into cover.xhtml")
        XCTAssertTrue((loadedHTML?.contains("data:image/jpeg;base64") ?? false) || (loadedHTML?.contains("cover.jpg") ?? false),
                      "loadChapter must inline cover image as data URI or retain valid image source")
    }

    // MARK: - Synthetic Realistic EPUB Builder Helper

    private func createRealisticEpub(in directory: URL, named name: String, injectBOM: Bool = false) async throws -> URL {
        let buildDir = directory.appendingPathComponent("epub_build_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let metaInfDir = buildDir.appendingPathComponent("META-INF")
        let oebpsDir = buildDir.appendingPathComponent("OEBPS")
        let textDir = oebpsDir.appendingPathComponent("text")
        let imgDir = oebpsDir.appendingPathComponent("images")
        let stylesDir = oebpsDir.appendingPathComponent("styles")

        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)

        // 1. mimetype (uncompressed)
        try "application/epub+zip".write(to: buildDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)

        // 2. container.xml
        let bomPrefix = injectBOM ? "\u{FEFF}" : ""
        let containerXml = """
        \(bomPrefix)<?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try containerXml.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        // 3. content.opf
        let opfXml = """
        \(bomPrefix)<?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="pub-id" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:ttzip-test-epub</dc:identifier>
            <dc:title>Realistic TTZip Publication</dc:title>
            <dc:language>en</dc:language>
            <meta name="cover" content="cover-image"/>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="cover-image" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
            <item id="style" href="styles/style.css" media-type="text/css"/>
            <item id="cover-page" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="cover-page" linear="yes"/>
            <itemref idref="ch1" linear="yes"/>
          </spine>
        </package>
        """
        try opfXml.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // 4. toc.ncx
        let ncxXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="np-cover" playOrder="1">
              <navLabel><text>Cover</text></navLabel>
              <content src="text/cover.xhtml"/>
            </navPoint>
            <navPoint id="np-1" playOrder="2">
              <navLabel><text>Chapter 1</text></navLabel>
              <content src="text/ch1.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """
        try ncxXml.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        // 5. Realistic cover.xhtml (Zero text, only relative image - EXACT replication of issue)
        let coverXhtml = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>Cover</title>
          <link rel="stylesheet" type="text/css" href="../styles/style.css"/>
        </head>
        <body style="margin:0; padding:0; text-align:center;">
          <div>
            <img src="../images/cover.jpg" alt="Cover Image" style="max-width:100%; height:auto;"/>
          </div>
        </body>
        </html>
        """
        try coverXhtml.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)

        // 6. ch1.xhtml (Body chapter)
        let ch1Xhtml = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>Chapter 1</title>
          <link rel="stylesheet" type="text/css" href="../styles/style.css"/>
        </head>
        <body>
          <h1>Chapter 1: Industrial Systems</h1>
          <p>This chapter contains standard text rendered cleanly.</p>
        </body>
        </html>
        """
        try ch1Xhtml.write(to: textDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        // 7. Dummy Valid JPEG bytes
        let validJpegBytes = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01,
            0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06,
            0xFF, 0xD9
        ])
        try validJpegBytes.write(to: imgDir.appendingPathComponent("cover.jpg"))

        // 8. Style CSS
        try "body { font-family: -apple-system, sans-serif; }".write(
            to: stylesDir.appendingPathComponent("style.css"),
            atomically: true,
            encoding: .utf8
        )

        // 9. Pack into ZIP (.epub)
        let outEpubURL = directory.appendingPathComponent(name)
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: outEpubURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [
                buildDir.appendingPathComponent("mimetype").path,
                metaInfDir.path,
                oebpsDir.path
            ]
        )

        return outEpubURL
    }
}
