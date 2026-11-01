// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import CryptoKit
import TTI18nCore
import TTMediaKit
import TTZipUI
import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class EbookBoundaryAndVFSRenderingTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        EPUBArchiveUnpacker.register()
    }

    // MARK: - 1. Multi-Level TOC Title Overwrite Regression

    func testMultiLevelTocDoesNotOverwriteMainChapterTitleWithSubAnchorChildren() async throws {
        let tempDir = try makeTempDir(prefix: "EPUBTocOverwrite")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let epubURL = try await createMultiLevelTocEpub(in: tempDir, named: "MultiLevelTocBook.epub")
        let bookModel = try XCTUnwrap(EPUBArchiveUnpacker.unpackAndParseEPUB(at: epubURL))
        defer { EPUBArchiveUnpacker.cleanupTempDir(at: bookModel.extractDir) }

        XCTAssertEqual(bookModel.chapters.count, 3)
        XCTAssertEqual(bookModel.chapters[0].title, "Chapter 1: Main Title")
        XCTAssertEqual(bookModel.chapters[1].title, "Chapter 2: Deep Intro")
        XCTAssertEqual(bookModel.chapters[2].title, "Chapter 3: Encoded Path")

        let ch2FragmentURL = try XCTUnwrap(URL(string: bookModel.chapters[1].fileURL.absoluteString + "#sec2"))
        XCTAssertEqual(
            InteractiveEPUBReaderView.resolveChapterIndex(matching: ch2FragmentURL, in: bookModel.chapters),
            1
        )
        let readerView = InteractiveEPUBReaderView(bookModel: bookModel)
        XCTAssertEqual(readerView.resolveChapterIndex(matching: ch2FragmentURL), 1)
    }

    // MARK: - 2. Cold-Cache VFS & Nested Archive EPUB Opening

    func testColdCacheVfsNestedEpubUnpackingAndChapterAssetLoading() async throws {
        let tempDir = try makeTempDir(prefix: "EPUBColdVfs")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let innerEpubURL = try await createMultiLevelTocEpub(in: tempDir, named: "InnerSample.epub")
        let outerZipURL = tempDir.appendingPathComponent("OuterBundle.zip")

        try await ArchiveWriter().createArchive(
            outputPath: outerZipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [innerEpubURL.path]
        )

        let vfsProvider = TTZipArchiveVfsProvider.shared
        let outerArchiveId = vfsProvider.registerArchive(archivePath: outerZipURL.path, password: nil)
        defer { vfsProvider.unregisterArchive(archiveId: outerArchiveId) }

        let innerVfsURL = vfsProvider.makeVfsURL(archiveId: outerArchiveId, entryPath: "InnerSample.epub")
        XCTAssertNil(vfsProvider.cachedData(for: innerVfsURL.absoluteString))

        let unpackedBook = await EPUBArchiveUnpacker.unpackAndParseEPUBAsync(at: innerVfsURL)
        let bookModel = try XCTUnwrap(unpackedBook)
        defer { EPUBArchiveUnpacker.cleanupTempDir(at: bookModel.extractDir) }

        XCTAssertEqual(bookModel.title, "Multi-Level TOC Test Book")
        XCTAssertEqual(bookModel.chapters.count, 3)
        XCTAssertEqual(bookModel.chapters[0].title, "Chapter 1: Main Title")

        let ch1URL = bookModel.chapters[0].fileURL
        let rawLoadedHTML = await EPUBChapterContentLoaderActor.shared.loadChapter(at: ch1URL, customCSS: "<style>body{}</style>")
        let loadedHTML = try XCTUnwrap(rawLoadedHTML)
        XCTAssertTrue(loadedHTML.contains("Chapter 1 Body Content"))
        XCTAssertTrue(loadedHTML.contains("data:image/jpeg;base64,"))
        XCTAssertTrue(loadedHTML.contains("/* inlined: ../styles/book.css */"))
    }

    // MARK: - 3A. CBR Magic-Header-Only Format Identification Boundary

    func testCBRMagicHeaderOnlyFormatIdentificationBoundary() async throws {
        for archiveComicExt in ["cbz", "cbr", "cb7", ".CBZ", ".CBR"] {
            let tax = DocumentEntityTaxonomy.classify(extension: archiveComicExt, path: "/comics/issue1.\(archiveComicExt)")
            XCTAssertEqual(tax, .physicalContainer)
            XCTAssertTrue(tax.isNavigableContainer)
            XCTAssertTrue(tax.isExtractableContainer)
        }

        for ebookExt in ["epub", "mobi", "azw", "azw3", "fb2", "ibooks"] {
            let tax = DocumentEntityTaxonomy.classify(extension: ebookExt, path: "/books/novel.\(ebookExt)")
            XCTAssertEqual(tax, .compoundDocument)
            XCTAssertFalse(tax.isNavigableContainer)
        }

        // Format-identification boundary only (not counted as CBR archive browsing):
        // Synthetic 10-byte RAR5 magic header proves TTZipEbookReaderService rejects RAR bytes cleanly.
        let ebookService = TTZipEbookReaderService.shared
        let rarMagicBytes = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00, 0x00, 0x00])
        let cbrProbe = try await ebookService.probe(data: rarMagicBytes, fileName: "Episode1.cbr")
        XCTAssertEqual(cbrProbe, .unknown)
        do {
            _ = try await ebookService.inspect(data: rarMagicBytes, fileName: "Episode1.cbr")
            XCTFail("Expected TTZipEbookReaderService.inspect to reject RAR-backed .cbr")
        } catch {
            // Expected boundary: RAR-backed .cbr is routed through TTZip's unified archive reader, not UniFFIEbookService.
        }
    }

    // MARK: - 3B. Real CBZ & Decompressible RAR5 CBR Archive Browsing + Comic Page Extraction

    func testValidCBZAndRealCBRArchiveBrowsingAndComicPageExtraction() async throws {
        let tempDir = try makeTempDir(prefix: "RealComicArchives")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let page1PNG = try makeSolidColorPNGData(color: .systemRed, size: NSSize(width: 24, height: 32))
        let page2PNG = try makeSolidColorPNGData(color: .systemBlue, size: NSSize(width: 24, height: 32))
        try await verifyRealCBZComicArchive(in: tempDir, page1PNG: page1PNG, page2PNG: page2PNG)
        try await verifyRealCBRComicArchive(in: tempDir, page1PNG: page1PNG)
    }

    // MARK: - 4. Honest EBook Inspection Banner TTI18n & VFS Checksum

    func testEBookInspectionModeHonestBannerAndVFSChecksum() async throws {
        let placeholderMeta = EBookMetadata(
            url: URL(fileURLWithPath: "/tmp/sample.mobi"),
            title: "Sample Book",
            formatName: "MOBI",
            fileSizeDescription: "1.2 MB",
            excerptText: EBookReaderPreviewView.legacyPlaceholderExcerpt,
            coverImage: nil
        )
        let placeholderView = EBookReaderPreviewView(metadata: placeholderMeta)
        XCTAssertEqual(
            placeholderView.effectiveInspectionNotice,
            EBookPreviewLocalization.text(.inspectionModeSummary)
        )

        let enBanner = EBookInspectionBannerModel.resolve(for: placeholderMeta, language: .en)
        let zhHansBanner = EBookInspectionBannerModel.resolve(for: placeholderMeta, language: .zhHans)
        let zhHantBanner = EBookInspectionBannerModel.resolve(for: placeholderMeta, language: .zhHant)
        XCTAssertTrue(enBanner.badgeTitle.contains("Inspection Mode"))
        XCTAssertTrue(zhHansBanner.badgeTitle.contains("检视模式"))
        XCTAssertTrue(zhHantBanner.badgeTitle.contains("檢視模式"))
        XCTAssertTrue(zhHansBanner.summaryText.contains("SHA-256"))
        XCTAssertTrue(zhHantBanner.summaryText.contains("SHA-256"))

        for key in EBookPreviewLocaleKey.allCases {
            XCTAssertFalse(key.fallbackTranslation(for: .en).isEmpty)
            XCTAssertFalse(key.fallbackTranslation(for: .zhHans).isEmpty)
            XCTAssertFalse(key.fallbackTranslation(for: .zhHant).isEmpty)
        }
        for key in HTMLWebPreviewLocaleKey.allCases {
            XCTAssertFalse(key.fallbackTranslation(for: .en).isEmpty)
            XCTAssertFalse(key.fallbackTranslation(for: .zhHans).isEmpty)
            XCTAssertFalse(key.fallbackTranslation(for: .zhHant).isEmpty)
        }

        let unstyledRep = HTMLWKWebViewRepresentable(content: "<html><head></head><body><h1>Hello</h1></body></html>", fileURL: nil)
        let unstyledPrepared = unstyledRep.preparedHTMLContent(unstyledRep.content)
        XCTAssertTrue(unstyledPrepared.contains("data-ttmedia-default-theme"))
        XCTAssertTrue(unstyledPrepared.contains("@media (prefers-color-scheme: dark)"))

        let authorStyledHTML = "<html><head><style>body { background-color: #fafafa; color: #222222; }</style></head><body><p>Styled</p></body></html>"
        let authorRep = HTMLWKWebViewRepresentable(content: authorStyledHTML, fileURL: nil)
        let authorPrepared = authorRep.preparedHTMLContent(authorStyledHTML)
        XCTAssertTrue(HTMLWKWebViewRepresentable.hasExplicitAuthorColorPalette(in: authorStyledHTML))
        XCTAssertFalse(authorPrepared.contains("@media (prefers-color-scheme: dark)"))

        let transparentCSS = EPUBNativeWKWebView.buildCustomCSS(fontSize: 17, fontFamilyCSS: "serif", readerTheme: "transparent")
        XCTAssertTrue(transparentCSS.contains("@media (prefers-color-scheme: dark)"))
        XCTAssertTrue(transparentCSS.contains("filter: none !important;"))

        try await verifyVfsEBookSHA256Computation()
    }

    // MARK: - 5. PreviewLRUCacheManager Path Traversal & 0o700 Permission Enforcement

    func testPreviewLRUCacheManagerBlocksKeyAndFilenameTraversalAndEnforces0700Permissions() async throws {
        let rawCacheRoot = try makeTempDir(prefix: "IsolatedLRUCacheTraversal")
        defer { try? FileManager.default.removeItem(at: rawCacheRoot) }
        let cacheManager = PreviewLRUCacheManager(customCacheDir: rawCacheRoot)

        let cacheRoot = rawCacheRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = cacheRoot.path.hasSuffix("/") ? cacheRoot.path : cacheRoot.path + "/"

        let adversarialCases: [(key: String, filename: String)] = [
            ("../../escape", "../../outside.txt"),
            ("..", "sub/../../evil.sh"),
            ("normal_key", "../../../etc/passwd"),
            ("slash/key:name\\..", "..\\..\\win_escape.exe"),
            ("null\0key", "bad\0../../file.png"),
            (".", "..")
        ]

        for (rawKey, rawFilename) in adversarialCases {
            let target = try XCTUnwrap(cacheManager.targetURL(forKey: rawKey, filename: rawFilename))
            let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath().path
            let resolvedKeyDir = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path

            XCTAssertTrue(
                resolvedKeyDir.hasPrefix(rootPrefix),
                "Key directory for (\(rawKey), \(rawFilename)) must stay inside cache root, got: \(resolvedKeyDir)"
            )
            let keyDirPrefix = resolvedKeyDir.hasSuffix("/") ? resolvedKeyDir : resolvedKeyDir + "/"
            XCTAssertTrue(
                resolvedTarget.hasPrefix(keyDirPrefix),
                "Target file URL for (\(rawKey), \(rawFilename)) must stay inside its key directory, got: \(resolvedTarget)"
            )
            XCTAssertNotEqual(target.lastPathComponent, "..")
            XCTAssertNotEqual(target.lastPathComponent, ".")

            let keyDirAttrs = try FileManager.default.attributesOfItem(atPath: resolvedKeyDir)
            let keyPerms = (keyDirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(keyPerms & 0o777, 0o700, "Cache key subdirectory must enforce 0o700 permissions")
        }

        let rootAttrs = try FileManager.default.attributesOfItem(atPath: cacheRoot.path)
        let rootPerms = (rootAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(rootPerms & 0o777, 0o700, "Cache root directory must enforce 0o700 permissions")
        await cacheManager.purgeAll()
    }

    func testPreviewLRUCacheManagerRejectsWhenPrimaryAndFallbackDirsAreOutOfBoundsSymlinks() async throws {
        let cacheRoot = try makeTempDir(prefix: "IsolatedLRUCacheSymlinkDirs")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cacheManager = PreviewLRUCacheManager(customCacheDir: cacheRoot)

        let outsideDir = try makeTempDir(prefix: "OutsideSymlinkTarget")
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let rawKey = "symlink_test_key"
        let rawFilename = "preview.png"
        let primaryKey = PreviewLRUCacheManager.sanitizeKey(rawKey)
        let fallbackKey = PreviewLRUCacheManager.deterministicCacheKey(archivePath: rawKey, subpath: rawFilename)

        let primaryDir = cacheRoot.appendingPathComponent(primaryKey, isDirectory: true)
        let fallbackDir = cacheRoot.appendingPathComponent(fallbackKey, isDirectory: true)
        try? FileManager.default.removeItem(at: primaryDir)
        try? FileManager.default.removeItem(at: fallbackDir)

        // Replace BOTH the primary key directory and the deterministic fallback directory with out-of-bounds symlinks
        try FileManager.default.createSymbolicLink(at: primaryDir, withDestinationURL: outsideDir)
        try FileManager.default.createSymbolicLink(at: fallbackDir, withDestinationURL: outsideDir)
        defer {
            try? FileManager.default.removeItem(at: primaryDir)
            try? FileManager.default.removeItem(at: fallbackDir)
        }

        let rejectedTarget = cacheManager.targetURL(forKey: rawKey, filename: rawFilename)
        XCTAssertNil(
            rejectedTarget,
            "targetURL must explicitly reject (return nil) when both primary and fallback directories are out-of-bounds symlinks"
        )
        XCTAssertNil(
            cacheManager.existingCachedURL(forKey: rawKey, filename: rawFilename),
            "existingCachedURL must also return nil when directories are out-of-bounds symlinks"
        )
        await cacheManager.purgeAll()
    }

    func testInspectorAndCacheRejectDirectoryWithOnlyOutOfBoundsSymlink() async throws {
        let cacheRoot = try makeTempDir(prefix: "IsolatedLRUCacheSymlinkFile")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cacheManager = PreviewLRUCacheManager(customCacheDir: cacheRoot)

        let outsideDir = try makeTempDir(prefix: "OutsideSymlinkFileDir")
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outsideFile = outsideDir.appendingPathComponent("secret_outside.png")
        try Data("OUTSIDE_SECRET_PAYLOAD".utf8).write(to: outsideFile)

        let fakeArchivePath = outsideDir.appendingPathComponent("nonexistent_archive.zip").path
        let subpath = "images/requested_preview.png"
        let filename = "requested_preview.png"
        let hash = PreviewLRUCacheManager.deterministicCacheKey(archivePath: fakeArchivePath, subpath: subpath)

        let targetURL = try XCTUnwrap(cacheManager.targetURL(forKey: hash, filename: filename))
        let keyDir = targetURL.deletingLastPathComponent()

        // Plant ONLY out-of-bounds symlinks inside the cache key directory (both matching name and another name)
        let matchingSymlink = keyDir.appendingPathComponent(filename)
        let otherSymlink = keyDir.appendingPathComponent("first_non_hidden_symlink.png")
        try? FileManager.default.removeItem(at: matchingSymlink)
        try? FileManager.default.removeItem(at: otherSymlink)
        try FileManager.default.createSymbolicLink(at: matchingSymlink, withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: otherSymlink, withDestinationURL: outsideFile)

        let regMatching = await cacheManager.register(key: hash, fileURL: matchingSymlink, expectedFilename: filename, requireNonEmpty: true)
        XCTAssertNil(regMatching, "register must return nil for an out-of-bounds symlink even when filename matches")

        let regOther = await cacheManager.register(key: hash, fileURL: otherSymlink)
        XCTAssertNil(regOther, "register must return nil for an out-of-bounds symlink")

        let resolvedFromCache = await cacheManager.resolveAndRegisterExtractedPreview(
            forKey: hash,
            filename: filename,
            subpath: subpath
        )
        XCTAssertNil(
            resolvedFromCache,
            "resolveAndRegisterExtractedPreview must return nil when directory contains only out-of-bounds symlinks"
        )

        let inspectorURL = await ExplorerItemInspectorView.resolveVirtualPreviewURL(
            archivePath: fakeArchivePath,
            subpath: subpath,
            cacheManager: cacheManager
        )
        XCTAssertNil(
            inspectorURL,
            "ExplorerItemInspectorView must refuse to display any preview when cache directory only contains out-of-bounds symlinks"
        )
        let cachedAfter = await cacheManager.cachedURL(forKey: hash, expectedFilename: filename)
        XCTAssertNil(cachedAfter)
        await cacheManager.purgeAll()
    }

    func testInspectorAndCacheRejectDirectoryWithOnlyOtherEntryFile() async throws {
        let cacheRoot = try makeTempDir(prefix: "IsolatedLRUCacheWrongEntry")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cacheManager = PreviewLRUCacheManager(customCacheDir: cacheRoot)

        let tempDir = try makeTempDir(prefix: "WrongEntryCacheDir")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeArchivePath = tempDir.appendingPathComponent("missing_archive.zip").path
        let subpath = "docs/target_contract.pdf"
        let filename = "target_contract.pdf"
        let hash = PreviewLRUCacheManager.deterministicCacheKey(archivePath: fakeArchivePath, subpath: subpath)

        let targetURL = try XCTUnwrap(cacheManager.targetURL(forKey: hash, filename: filename))
        let keyDir = targetURL.deletingLastPathComponent()

        // 1. Negative control: populate directory ONLY with a regular non-empty file belonging to a DIFFERENT entry
        let wrongEntryURL = keyDir.appendingPathComponent("other_unrelated_entry.pdf")
        try Data("WRONG_ENTRY_CONTENT_SHOULD_NOT_BE_DISPLAYED".utf8).write(to: wrongEntryURL)

        let regWrong = await cacheManager.register(
            key: hash,
            fileURL: wrongEntryURL,
            expectedFilename: filename,
            requireNonEmpty: true
        )
        XCTAssertNil(regWrong, "register must reject candidate whose filename does not match expectedFilename")

        let resolvedWrong = await cacheManager.resolveAndRegisterExtractedPreview(
            forKey: hash,
            filename: filename,
            subpath: subpath
        )
        XCTAssertNil(
            resolvedWrong,
            "resolveAndRegisterExtractedPreview must reject directory containing only another entry's file"
        )

        let inspectorURL = await ExplorerItemInspectorView.resolveVirtualPreviewURL(
            archivePath: fakeArchivePath,
            subpath: subpath,
            cacheManager: cacheManager
        )
        XCTAssertNil(
            inspectorURL,
            "ExplorerItemInspectorView must refuse to display another entry's file when target entry does not exist"
        )

        // 2. Positive control: per F4 failure cleanup contract, rejecting an uncommitted staging reservation
        // removes the key directory; re-acquire a valid staging directory and verify the genuine entry succeeds.
        let positiveTargetURL = try XCTUnwrap(cacheManager.targetURL(forKey: hash, filename: filename))
        try Data("GENUINE_TARGET_CONTRACT_PDF".utf8).write(to: positiveTargetURL)
        let verifiedURL = await ExplorerItemInspectorView.resolveVirtualPreviewURL(
            archivePath: fakeArchivePath,
            subpath: subpath,
            cacheManager: cacheManager
        )
        XCTAssertEqual(verifiedURL, positiveTargetURL.standardizedFileURL)
        await cacheManager.purgeAll()
    }

    // MARK: - 6. Multi-Consumer Reference-Counted VFS & EPUB Session Leases

    func testMultiConsumerEPUBSessionReferenceCountedLeasesSurviveSingleRelease() async throws {
        let tempDir = try makeTempDir(prefix: "EPUBLeaseRef")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let epubURL = try await createMultiLevelTocEpub(in: tempDir, named: "SharedLeaseBook.epub")
        let vfsProvider = TTZipArchiveVfsProvider.shared

        // Consumer 1 opens the EPUB (e.g. Right Inspector preview)
        let model1 = try XCTUnwrap(EPUBArchiveUnpacker.unpackAndParseEPUB(at: epubURL))
        let (archiveId, _) = try XCTUnwrap(vfsProvider.parseVfsUri(model1.extractDir.absoluteString))
        XCTAssertEqual(vfsProvider.sessionReferenceCount(archiveId: archiveId), 1)

        // Consumer 2 opens the same EPUB concurrently (e.g. QuickLook modal / fullscreen transition)
        let unpackedModel2 = await EPUBArchiveUnpacker.unpackAndParseEPUBAsync(at: epubURL)
        let model2 = try XCTUnwrap(unpackedModel2)
        XCTAssertEqual(model1.extractDir, model2.extractDir)
        XCTAssertEqual(vfsProvider.sessionReferenceCount(archiveId: archiveId), 2)

        // Consumer 1 disappears and releases its lease
        EPUBArchiveUnpacker.releaseSession(for: epubURL)
        XCTAssertEqual(
            vfsProvider.sessionReferenceCount(archiveId: archiveId),
            1,
            "Session must remain alive with refCount == 1 while Consumer 2 still holds a lease"
        )
        XCTAssertTrue(vfsProvider.isSessionActive(archiveId: archiveId))

        // Consumer 2 must still be able to read chapters and inline images/CSS via VFS and customDataProvider
        let ch1Data = try await vfsProvider.readEntryData(archiveId: archiveId, entryPath: "EPUB/text/ch1.xhtml")
        XCTAssertNotNil(ch1Data, "readEntryData must succeed for Consumer 2 after Consumer 1 released its lease")

        let coverVfsURL = vfsProvider.makeVfsURL(archiveId: archiveId, entryPath: "EPUB/images/cover.jpg")
        let coverDataViaProvider = await EPUBChapterContentLoaderActor.customDataProvider?(coverVfsURL)
        XCTAssertNotNil(coverDataViaProvider, "customDataProvider must still resolve cover image for Consumer 2")

        let rawRenderedCh1 = await EPUBChapterContentLoaderActor.shared.loadChapter(
            at: model2.chapters[0].fileURL,
            customCSS: "<style>body{}</style>",
            baseDirectory: model2.extractDir
        )
        let renderedCh1 = try XCTUnwrap(rawRenderedCh1)
        XCTAssertTrue(renderedCh1.contains("Chapter 1 Body Content"))
        XCTAssertTrue(renderedCh1.contains("data:image/jpeg;base64,"))

        // Consumer 2 finishes and releases the final lease -> session is torn down
        EPUBArchiveUnpacker.releaseSession(for: epubURL)
        XCTAssertEqual(vfsProvider.sessionReferenceCount(archiveId: archiveId), 0)
        XCTAssertFalse(vfsProvider.isSessionActive(archiveId: archiveId))

        let postReleaseData = try await vfsProvider.readEntryData(archiveId: archiveId, entryPath: "EPUB/text/ch1.xhtml")
        XCTAssertNil(postReleaseData, "Session must be closed after final consumer releases its lease")
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createMultiLevelTocEpub(in directory: URL, named name: String) async throws -> URL {
        let buildDir = directory.appendingPathComponent("build_\(UUID().uuidString)", isDirectory: true)
        let metaInfDir = buildDir.appendingPathComponent("META-INF", isDirectory: true)
        let epubDir = buildDir.appendingPathComponent("EPUB", isDirectory: true)
        let textDir = epubDir.appendingPathComponent("text", isDirectory: true)
        let imgDir = epubDir.appendingPathComponent("images", isDirectory: true)
        let stylesDir = epubDir.appendingPathComponent("styles", isDirectory: true)

        for dir in [metaInfDir, textDir, imgDir, stylesDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try "application/epub+zip".write(
            to: buildDir.appendingPathComponent("mimetype"),
            atomically: true,
            encoding: .utf8
        )
        try writeEpubPackageAndToc(metaInfDir: metaInfDir, epubDir: epubDir)
        try writeEpubChaptersAndAssets(textDir: textDir, imgDir: imgDir, stylesDir: stylesDir)

        let outURL = directory.appendingPathComponent(name)
        try await ArchiveWriter().createArchive(
            outputPath: outURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [
                buildDir.appendingPathComponent("mimetype").path,
                metaInfDir.path,
                epubDir.path
            ]
        )
        return outURL
    }

    private func writeEpubPackageAndToc(metaInfDir: URL, epubDir: URL) throws {
        let containerXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try containerXml.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let opfXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="pub-id" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:multi-level-toc-test</dc:identifier>
            <dc:title>Multi-Level TOC Test Book</dc:title>
            <dc:language>en</dc:language>
            <meta name="cover" content="cover-img"/>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="cover-img" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
            <item id="css" href="styles/book.css" media-type="text/css"/>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch3" href="text/Chapter 3.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="ch1" linear="yes"/>
            <itemref idref="ch2" linear="yes"/>
            <itemref idref="ch3" linear="yes"/>
          </spine>
        </package>
        """
        try opfXml.write(to: epubDir.appendingPathComponent("package.opf"), atomically: true, encoding: .utf8)

        let ncxXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="np-1" playOrder="1">
              <navLabel><text>Chapter 1: Main Title</text></navLabel>
              <content src="text/ch1.xhtml"/>
              <navPoint id="np-1-1" playOrder="2">
                <navLabel><text>Section 1.1</text></navLabel>
                <content src="text/ch1.xhtml#sec1"/>
              </navPoint>
              <navPoint id="np-1-2" playOrder="3">
                <navLabel><text>Section 1.2</text></navLabel>
                <content src="text/ch1.xhtml#sec2"/>
                <navPoint id="np-2-nested" playOrder="4">
                  <navLabel><text>Chapter 2: Deep Intro</text></navLabel>
                  <content src="text/ch2.xhtml#intro"/>
                </navPoint>
                <navPoint id="np-2-sub" playOrder="5">
                  <navLabel><text>Section 2.2</text></navLabel>
                  <content src="text/ch2.xhtml#sec2"/>
                </navPoint>
              </navPoint>
            </navPoint>
            <navPoint id="np-3" playOrder="6">
              <navLabel><text>Chapter 3: Encoded Path</text></navLabel>
              <content src="text/Chapter%203.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """
        try ncxXml.write(to: epubDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
    }

    private func writeEpubChaptersAndAssets(textDir: URL, imgDir: URL, stylesDir: URL) throws {
        let ch1Html = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>Ch1</title>
          <link rel="stylesheet" type="text/css" href="../styles/book.css"/>
        </head>
        <body>
          <h1>Chapter 1 Body Content</h1>
          <img src="../images/cover.jpg" alt="Cover"/>
          <h2 id="sec1">Section 1.1</h2>
          <h2 id="sec2">Section 1.2</h2>
        </body>
        </html>
        """
        try ch1Html.write(to: textDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let ch2Html = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Ch2</title></head>
        <body><h1 id="intro">Chapter 2</h1><h2 id="sec2">Details</h2></body>
        </html>
        """
        try ch2Html.write(to: textDir.appendingPathComponent("ch2.xhtml"), atomically: true, encoding: .utf8)

        let ch3Html = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Ch3</title></head>
        <body><h1>Chapter 3</h1></body>
        </html>
        """
        try ch3Html.write(to: textDir.appendingPathComponent("Chapter 3.xhtml"), atomically: true, encoding: .utf8)

        let validJpegBytes = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01,
            0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xD9
        ])
        try validJpegBytes.write(to: imgDir.appendingPathComponent("cover.jpg"))
        try "body { color: #222; }".write(to: stylesDir.appendingPathComponent("book.css"), atomically: true, encoding: .utf8)
    }

    private func verifyRealCBZComicArchive(in tempDir: URL, page1PNG: Data, page2PNG: Data) async throws {
        let p1URL = tempDir.appendingPathComponent("page_01.png")
        let p2URL = tempDir.appendingPathComponent("page_02.png")
        try page1PNG.write(to: p1URL)
        try page2PNG.write(to: p2URL)

        let cbzURL = tempDir.appendingPathComponent("RealComicIssue.cbz")
        try await ArchiveWriter().createArchive(
            outputPath: cbzURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [p1URL.path, p2URL.path]
        )

        // 1. EbookReaderService metadata + page resource extraction
        let ebookService = TTZipEbookReaderService.shared
        let cbzProbe = try await ebookService.probe(url: cbzURL)
        XCTAssertEqual(cbzProbe, .cbz)
        let cbzMeta = try await ebookService.inspect(url: cbzURL)
        XCTAssertEqual(cbzMeta.format, .cbz)
        XCTAssertEqual(cbzMeta.totalChapters, 2)
        let cbzSpine = try await ebookService.spine(url: cbzURL)
        XCTAssertEqual(cbzSpine.count, 2)
        let extractedPage1 = try await ebookService.resource(url: cbzURL, href: cbzSpine[0].href)
        XCTAssertEqual(extractedPage1.data, page1PNG)
        XCTAssertNotNil(NSImage(data: extractedPage1.data))

        // 2. Unified ArchiveReader + TTZipArchiveVfsProvider browsing and extraction
        let entries = try await ArchiveReader().listEntries(archivePath: cbzURL.path)
        XCTAssertEqual(entries.map(\.path).sorted(), ["page_01.png", "page_02.png"])
        let vfs = TTZipArchiveVfsProvider.shared
        let archiveId = vfs.registerArchive(archivePath: cbzURL.path, password: nil)
        defer { vfs.unregisterArchive(archiveId: archiveId) }
        let vfsPage2 = try await XCTUnwrapAsync(await vfs.readEntryData(archiveId: archiveId, entryPath: "page_02.png"))
        XCTAssertEqual(vfsPage2, page2PNG)
        let decodedImg2 = try XCTUnwrap(NSImage(data: vfsPage2))
        XCTAssertEqual(Int(decodedImg2.size.width), 24)
        XCTAssertEqual(Int(decodedImg2.size.height), 32)
    }

    private func verifyRealCBRComicArchive(in tempDir: URL, page1PNG: Data) async throws {
        let cbrURL = tempDir.appendingPathComponent("RealRar5Comic.cbr")
        let rar5Bytes = buildStoredRar5Archive(fileName: "page_01.png", fileData: page1PNG)
        try rar5Bytes.write(to: cbrURL)

        // 1. Browse real RAR5 .cbr entries through unified ArchiveReader
        let entries = try await ArchiveReader().listEntries(archivePath: cbrURL.path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, "page_01.png")
        XCTAssertEqual(entries.first?.uncompressedSize, Int64(page1PNG.count))

        // 2. Extract comic page from real RAR5 .cbr via TTZipArchiveVfsProvider and decode NSImage
        let vfs = TTZipArchiveVfsProvider.shared
        let archiveId = vfs.registerArchive(archivePath: cbrURL.path, password: nil)
        defer { vfs.unregisterArchive(archiveId: archiveId) }
        let extractedRarPage = try await XCTUnwrapAsync(await vfs.readEntryData(archiveId: archiveId, entryPath: "page_01.png"))
        XCTAssertEqual(extractedRarPage, page1PNG)
        let decodedRarImage = try XCTUnwrap(NSImage(data: extractedRarPage))
        XCTAssertEqual(Int(decodedRarImage.size.width), 24)
        XCTAssertEqual(Int(decodedRarImage.size.height), 32)
    }

    private func verifyVfsEBookSHA256Computation() async throws {
        let tempDir = try makeTempDir(prefix: "EBookVfsSha")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = Data("Synthetic MOBI payload for VFS SHA-256 verification".utf8)
        let mobiFile = tempDir.appendingPathComponent("book.mobi")
        try payload.write(to: mobiFile)

        let zipURL = tempDir.appendingPathComponent("library.zip")
        try await ArchiveWriter().createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [mobiFile.path]
        )

        let vfs = TTZipArchiveVfsProvider.shared
        let archiveId = vfs.registerArchive(archivePath: zipURL.path, password: nil)
        defer { vfs.unregisterArchive(archiveId: archiveId) }
        let vfsMobiURL = vfs.makeVfsURL(archiveId: archiveId, entryPath: "book.mobi")

        let expectedHex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let actualHex = await EBookReaderPreviewView.computeSHA256Hex(for: vfsMobiURL)
        XCTAssertEqual(actualHex, expectedHex)
    }

    private func makeSolidColorPNGData(color: NSColor, size: NSSize) throws -> Data {
        let width = Int(size.width)
        let height = Int(size.height)
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func buildStoredRar5Archive(fileName: String, fileData: Data) -> Data {
        var archive = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])

        // 1. Main Archive Header (type = 1, flags = 0, archive_flags = 0)
        let mainBody = Data([0x01, 0x00, 0x00])
        appendRar5Block(to: &archive, headerBody: mainBody, dataArea: nil)

        // 2. File Header (type = 2, HFL_DATA = 0x02, FHFL_CRC32 = 0x04, method = 0 Store)
        let nameBytes = Data(fileName.utf8)
        var fileBody = Data()
        fileBody.append(contentsOf: encodeRar5Vint(2)) // header_type = HEAD_FILE
        fileBody.append(contentsOf: encodeRar5Vint(0x0002)) // header_flags = HFL_DATA
        fileBody.append(contentsOf: encodeRar5Vint(UInt64(fileData.count))) // data_size
        fileBody.append(contentsOf: encodeRar5Vint(0x0004)) // file_flags = FHFL_CRC32
        fileBody.append(contentsOf: encodeRar5Vint(UInt64(fileData.count))) // unpacked_size
        fileBody.append(contentsOf: encodeRar5Vint(0x20)) // attributes
        appendUInt32LE(&fileBody, crc32IEEE(fileData)) // data_crc32
        fileBody.append(contentsOf: encodeRar5Vint(0)) // compression_info = Store (method 0)
        fileBody.append(contentsOf: encodeRar5Vint(1)) // host_os = Unix
        fileBody.append(contentsOf: encodeRar5Vint(UInt64(nameBytes.count))) // name_len
        fileBody.append(nameBytes)
        appendRar5Block(to: &archive, headerBody: fileBody, dataArea: fileData)

        // 3. End of Archive Header (type = 5, flags = 0, endarc_flags = 0)
        let endBody = Data([0x05, 0x00, 0x00])
        appendRar5Block(to: &archive, headerBody: endBody, dataArea: nil)
        return archive
    }

    private func appendRar5Block(to archive: inout Data, headerBody: Data, dataArea: Data?) {
        var crcInput = Data(encodeRar5Vint(UInt64(headerBody.count)))
        crcInput.append(headerBody)
        appendUInt32LE(&archive, crc32IEEE(crcInput))
        archive.append(crcInput)
        if let dataArea {
            archive.append(dataArea)
        }
    }

    private func encodeRar5Vint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func crc32IEEE(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var c = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            crc = (crc >> 8) ^ c
        }
        return ~crc
    }

    private func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?) async throws -> T {
        let value = try await expression()
        return try XCTUnwrap(value)
    }
}
