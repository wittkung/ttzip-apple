// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import PDFKit
import QuickLookUI
import SwiftUI
import TTMediaKit
import TTZipUI
@testable import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class TTMediaKitPreviewIntegrationTests: XCTestCase {

    func testArchiveImageUsesTTZipZoomCanvas() throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        ))
        let fallbackURL = try makeTemporaryDirectory().appendingPathComponent("photo.png")
        let preview = MediaPreviewView(
            fileData: png,
            fileName: "photo.png",
            fileURL: fallbackURL,
            showsFloatingFullScreenButton: false,
            sourceArchivePath: "/archives/sample.zip",
            archiveSubpath: "images/photo.png"
        )
        let host = NSHostingView(rootView: preview)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(containsTTZipScrollConfigurator(in: host))
    }

    func testArchiveImageSwitchUpdatesMountedCanvasAndPreservesStagedBytes() async throws {
        let directory = try makeTemporaryDirectory()
        var resolved: MediaPreviewType?
        let (previewA, stagedURLA, pngA) = try makeArchiveImagePreview(
            in: directory, named: "alpha.png",
            color: NSColor(srgbRed: 0.92, green: 0.12, blue: 0.12, alpha: 1.0),
            onResolved: { resolved = $0 }
        )
        let inspector = UIHierarchyInspector(rootView: previewA)

        try await verifyMountedArchiveImage(
            in: inspector, resolved: { resolved }, url: stagedURLA, png: pngA, isRed: true
        )

        resolved = nil
        let (previewB, stagedURLB, pngB) = try makeArchiveImagePreview(
            in: directory, named: "bravo.png",
            color: NSColor(srgbRed: 0.12, green: 0.28, blue: 0.92, alpha: 1.0),
            onResolved: { resolved = $0 }
        )
        inspector.updateRootView(previewB)

        try await verifyMountedArchiveImage(
            in: inspector, resolved: { resolved }, url: stagedURLB, png: pngB, isRed: false
        )

        inspector.updateRootView(EmptyView())
        XCTAssertEqual(try Data(contentsOf: stagedURLA), pngA)
        XCTAssertEqual(try Data(contentsOf: stagedURLB), pngB)
    }

    private func makeArchiveImagePreview(
        in directory: URL,
        named fileName: String,
        color: NSColor,
        onResolved: @escaping (MediaPreviewType) -> Void
    ) throws -> (MediaPreviewView, URL, Data) {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let data = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url)
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: directory.appendingPathComponent("photos.zip"),
            entryPath: "images/\(fileName)",
            stagedReadURL: url
        )
        let preview = MediaPreviewView(
            fileData: data, fileName: fileName, fileURL: url,
            showsFloatingFullScreenButton: false, resourceContext: context,
            onPreviewTypeResolved: onResolved
        )
        XCTAssertTrue(preview.effectiveIsFromArchive)
        XCTAssertFalse(preview.effectiveIsEditable)
        XCTAssertEqual(preview.effectiveResourceContext.readOnlyReason, .archiveEntry)
        return (preview, url, data)
    }

    private func verifyMountedArchiveImage(
        in inspector: UIHierarchyInspector,
        resolved: () -> MediaPreviewType?,
        url: URL,
        png: Data,
        isRed: Bool
    ) async throws {
        let view = inspector.hostingView
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            view.layoutSubtreeIfNeeded()
            if case .image(let image) = resolved(),
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let sample = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) {
                    let delta = isRed
                        ? sample.redComponent - max(sample.greenComponent, sample.blueComponent)
                        : sample.blueComponent - max(sample.redComponent, sample.greenComponent)
                    if sample.alphaComponent > 0.9 && delta > 0.35 {
                        let resource = TTMediaDetector.imagePreviewResource(for: image)
                        XCTAssertEqual(resource.pixelWidth, 64)
                        XCTAssertEqual(resource.pixelHeight, 64)
                        XCTAssertTrue(
                            resource.source == .fileURL(url)
                                || resource.source == .memoryData(png, suggestedName: url.lastPathComponent),
                            "Resolved image must retain the current staged file or its exact in-memory bytes"
                        )
                        XCTAssertTrue(containsTTZipScrollConfigurator(in: view))
                        XCTAssertFalse(inspector.window.isVisible)
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(isRed ? "red" : "blue") archive image render in hosted preview")
    }

    func testZoomCanvasDoesNotRescaleACompositedViewportImage() {
        let viewport = CGSize(width: 800, height: 600)
        XCTAssertEqual(
            ImagePreviewView.zoomCanvasSize(viewportSize: viewport, scale: 3.0, isHighResLoaded: true),
            viewport,
            "High-res composited viewport image must stay at viewport dimensions without secondary scale enlargement"
        )
        XCTAssertEqual(
            ImagePreviewView.zoomCanvasSize(viewportSize: viewport, scale: 3.0, isHighResLoaded: false),
            CGSize(width: 2400, height: 1800)
        )
    }

    private func containsTTZipScrollConfigurator(in view: NSView) -> Bool {
        view is TTZipUI.SmartScrollerConfiguratorView
            || view.subviews.contains { containsTTZipScrollConfigurator(in: $0) }
    }

    func testArchiveDOCXMountsNativeQuickLookAndReleasesBothPreviewLeases() async throws {
        let directory = try makeTemporaryDirectory()
        let fileName = "report.docx"
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: directory.appendingPathComponent("source.zip"),
            entryPath: "documents/\(fileName)",
            stagedReadURL: nil
        )
        var stagedURL: URL?
        let inspector = UIHierarchyInspector(rootView: MediaPreviewView(
            fileData: try makeQuickLookDOCX(in: directory, named: fileName),
            fileName: fileName,
            isImmersiveFullscreen: true,
            showsFloatingFullScreenButton: false,
            resourceContext: context,
            onPreviewTypeResolved: {
                if case .quickLook(let url) = $0 { stagedURL = url }
            }
        ))
        defer { inspector.updateRootView(EmptyView()) }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while firstDescendant(ofType: QLPreviewView.self, in: inspector.hostingView) == nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            inspector.hostingView.layoutSubtreeIfNeeded()
        }
        let staged = try XCTUnwrap(stagedURL)
        let preview = try XCTUnwrap(firstDescendant(ofType: QLPreviewView.self, in: inspector.hostingView))
        XCTAssertEqual(preview.previewItem?.previewItemURL, staged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 2)
        XCTAssertFalse(inspector.window.isVisible)

        inspector.updateRootView(EmptyView())
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: staged), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    private func makeQuickLookDOCX(in directory: URL, named fileName: String) throws -> Data {
        let parts = [
            "[Content_Types].xml": """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Override PartName="/word/document.xml"
                        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Target="word/document.xml"
                            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"/>
            </Relationships>
            """,
            "word/document.xml": """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body><w:p><w:r><w:t>Quick Look fixture</w:t></w:r></w:p></w:body>
            </w:document>
            """,
        ]
        for (path, contents) in parts {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", fileName] + parts.keys.sorted()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return try Data(contentsOf: directory.appendingPathComponent(fileName))
    }

    func testArchivePDFMountsProductToolbarAndPDFDocument() async throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var pageBounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &pageBounds, nil))
        for _ in 0..<2 {
            writer.beginPDFPage(nil)
            writer.fill(CGRect(x: 30, y: 40, width: 60, height: 70))
            writer.endPDFPage()
        }
        writer.closePDF()

        let preview = MediaPreviewView(
            fileData: data as Data,
            fileName: "report.pdf",
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(
                archivePath: "/archives/sample.zip",
                entryPath: "documents/report.pdf",
                stagedReadURL: nil,
                fileName: "report.pdf"
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

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let toolbar = firstDescendant(ofType: PDFToolbarStateProbeNSView.self, in: host),
               toolbar.identifier?.rawValue == "TTZipPDFToolbar",
               toolbar.layoutTier == .compact,
               let document = firstDescendant(ofType: PDFView.self, in: host)?.document {
                XCTAssertEqual(toolbar.currentPageOneBased, 1)
                XCTAssertEqual(toolbar.totalPages, 2)
                XCTAssertEqual(document.pageCount, 2)
                XCTAssertFalse(window.isVisible)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The archive PDF must load into PDFKit with the compact TTZip toolbar")
    }

    func testEncryptedArchivePDFMountsSecureUnlockField() async throws {
        let data = try makeEncryptedGridPDF()
        let preview = MediaPreviewView(
            fileData: data,
            fileName: "locked.pdf",
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(
                archivePath: "/archives/sample.zip",
                entryPath: "documents/locked.pdf",
                stagedReadURL: nil
            )
        )
        try await verifyHostedPreview(preview, expectation: "a secure PDF password field") { host, _ in
            firstDescendant(ofType: NSSecureTextField.self, in: host) != nil
                && firstDescendant(ofType: PDFView.self, in: host) == nil
        }
    }

    func testUnlockedPDFGridDisplaysThreeRenderedPages() async throws {
        let data = try makeEncryptedGridPDF()
        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: nil, data: data)
        XCTAssertEqual(loader.phase, .locked)
        XCTAssertFalse(loader.unlock(withPassword: "incorrect"))
        XCTAssertNotNil(loader.unlockError)
        XCTAssertEqual(loader.phase, .locked)
        XCTAssertTrue(loader.unlock(withPassword: "fixture-password"))
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertNil(loader.unlockError)
        XCTAssertEqual(loader.totalPages, 3)
        loader.selectPage(index: 1)

        let bounds = NSRect(x: 0, y: 0, width: 450, height: 250)
        let grid = TTZipPDFPageGrid(
            document: try XCTUnwrap(loader.document),
            sourceURL: nil,
            sourceData: data,
            inputIdentity: try XCTUnwrap(loader.loadedIdentity),
            unlockPassword: loader.unlockedPassword,
            currentPageIndex: Binding(
                get: { loader.currentPageIndex },
                set: { loader.selectPage(index: $0) }
            ),
            onThumbnailRendered: { loader.recordThumbnailRendered(elapsedMs: $0) }
        )
        let host = NSHostingView(rootView: grid.frame(width: bounds.width, height: bounds.height))
        host.frame = bounds
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var samples: [NSColor] = []
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if loader.latestStageMetrics?.thumbnailStageMs != nil,
               let content = firstDescendant(ofType: NSScrollView.self, in: host)?.documentView {
                samples = try gridPageSamples(in: content)
                if matchesFixturePageColors(samples) {
                    XCTAssertEqual(loader.currentPageIndex, 1)
                    XCTAssertFalse(window.isVisible)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("""
            Three independently rendered PDF pages must appear in a single row after unlock.
            Thumbnail stage: \(String(describing: loader.latestStageMetrics?.thumbnailStageMs)).
            Samples: \(samples).
            """)
    }

    private func makeEncryptedGridPDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var pageBounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let options = [
            kCGPDFContextUserPassword as String: "fixture-password",
            kCGPDFContextOwnerPassword as String: "fixture-owner"
        ]
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &pageBounds, options as CFDictionary))
        for color in [NSColor.red, NSColor.green, NSColor.blue] {
            writer.beginPDFPage(nil)
            writer.setFillColor(color.cgColor)
            writer.fill(pageBounds)
            writer.endPDFPage()
        }
        writer.closePDF()
        return data as Data
    }

    private func gridPageSamples(in view: NSView) throws -> [NSColor] {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return [] }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return (0..<3).compactMap { page in
            bitmap.colorAt(
                x: bitmap.pixelsWide * (2 * page + 1) / 6,
                y: bitmap.pixelsHigh / 2
            )?.usingColorSpace(.sRGB)
        }
    }

    private func matchesFixturePageColors(_ samples: [NSColor]) -> Bool {
        guard samples.count == 3, samples.allSatisfy({ $0.alphaComponent > 0.9 }) else { return false }
        let left = samples[0]
        let middle = samples[1]
        let right = samples[2]
        return left.redComponent - max(left.greenComponent, left.blueComponent) > 0.35
            && middle.greenComponent - max(middle.redComponent, middle.blueComponent) > 0.35
            && right.blueComponent - max(right.redComponent, right.greenComponent) > 0.35
    }

    func testStructuredDocumentRoutesRenderReadOnlyPreviews() async throws {
        let directory = try makeTemporaryDirectory()
        let docxURL = directory.appendingPathComponent("report.docx")
        let attributed = NSAttributedString(string: "Selectable DOCX content")
        let docx = MediaPreviewView(
            previewType: .docxDocument(attributed, docxURL),
            fileName: docxURL.lastPathComponent,
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(
                archivePath: "/archives/sample.zip",
                entryPath: "documents/report.docx",
                stagedReadURL: nil
            )
        )
        try await verifyHostedPreview(docx, expectation: "selectable, read-only DOCX text") { host, _ in
            guard let text = firstDescendant(ofType: NSTextView.self, in: host) else { return false }
            return text.string == attributed.string && text.isSelectable && !text.isEditable
        }

        let slide = TTMediaOfficeOutlineItem(slideNumber: 1, title: "Quarterly results", bulletPoints: ["Adjusted revenue"])
        let deck = OfficePresentationModel(fileName: "results.pptx", outline: .init(title: "Results", slides: [slide]))
        let presentation = MediaPreviewView(
            previewType: .officePresentation(deck),
            fileName: deck.fileName,
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(
                archivePath: "/archives/sample.zip",
                entryPath: "documents/results.pptx",
                stagedReadURL: nil
            )
        )
        try await verifyHostedPreview(presentation, expectation: "the TTZip filter and original slide outline") { host, snapshot in
            firstDescendant(ofType: NSTextField.self, in: host) != nil
                && snapshot == .presentation(slideCount: 1, firstTitle: "Quarterly results", firstBulletPoints: ["Adjusted revenue"])
        }

        try await verifyEBookInspectionRoutes(in: directory)
    }

    func testPresentationFilterResetsWhenOutlineChangesAtSameURL() async throws {
        let presentation = PresentationFixture(url: try makeTemporaryDirectory().appendingPathComponent("outline.pptx"))
        let initial: TTZipStructuredDocumentPreviewPreference.Snapshot =
            .presentation(slideCount: 2, firstTitle: "Budget", firstBulletPoints: [])
        let filtered: TTZipStructuredDocumentPreviewPreference.Snapshot =
            .presentation(slideCount: 1, firstTitle: "Roadmap", firstBulletPoints: [])
        let replacement: TTZipStructuredDocumentPreviewPreference.Snapshot =
            .presentation(slideCount: 2, firstTitle: "Summary", firstBulletPoints: [])
        enum Stage { case initial, filtering, replacement }
        var stage = Stage.initial

        try await verifyHostedPreview(
            PresentationFixtureView(fixture: presentation),
            expectation: "the same-URL replacement outline with its filter cleared"
        ) { host, snapshot in
            if stage == .initial, snapshot == initial,
               let field = firstDescendant(ofType: NSTextField.self, in: host) {
                field.stringValue = "roadmap"
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                stage = .filtering
            } else if stage == .filtering, snapshot == filtered {
                presentation.model = presentation.makeModel(titles: ["Summary", "Next steps"])
                stage = .replacement
            }
            return stage == .replacement && snapshot == replacement
        }
    }

    @Observable
    fileprivate final class PresentationFixture {
        var model: OfficePresentationModel

        init(url: URL) {
            model = OfficePresentationModel(fileName: url.lastPathComponent, outline: .init(title: "Deck", slides: []), fileURL: url)
            model = makeModel(titles: ["Budget", "Roadmap"])
        }

        func makeModel(titles: [String]) -> OfficePresentationModel {
            let slides = titles.enumerated().map { index, title in
                TTMediaOfficeOutlineItem(slideNumber: index + 1, title: title)
            }
            return OfficePresentationModel(fileName: model.fileName, outline: .init(title: "Deck", slides: slides), fileURL: model.fileURL)
        }
    }

    private struct PresentationFixtureView: View {
        let fixture: PresentationFixture

        var body: some View {
            TTZipPresentationPreviewView(model: fixture.model)
        }
    }

    private func verifyEBookInspectionRoutes(in directory: URL) async throws {
        let url = directory.appendingPathComponent("sample.mobi")
        try Data("hello".utf8).write(to: url)
        let metadata = EBookMetadata(
            url: url,
            title: "Fixture ebook",
            formatName: "MOBI",
            fileSizeDescription: "5 bytes",
            excerptText: "",
            coverImage: nil
        )
        let diskBook = MediaPreviewView(
            previewType: .ebook(metadata),
            fileName: url.lastPathComponent,
            showsFloatingFullScreenButton: false,
            resourceContext: .diskFile(url: url)
        )
        let expectedSHA256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let diskBanner = EBookInspectionBannerModel.resolve(for: metadata)
        try await verifyHostedPreview(diskBook, expectation: "the inspection banner, actual SHA-256 and usable reader action") { _, snapshot in
            snapshot == .ebook(banner: diskBanner, checksum: expectedSHA256, externalFileURL: url)
        }

        let unstagedBook = MediaPreviewView(
            previewType: .ebook(metadata),
            fileName: url.lastPathComponent,
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(archivePath: "/archives/sample.zip", entryPath: "sample.mobi", stagedReadURL: nil)
        )
        try await verifyHostedPreview(unstagedBook, expectation: "the unavailable checksum and disabled reader action for an unstaged entry") { _, snapshot in
            snapshot == .ebook(banner: diskBanner, checksum: nil, externalFileURL: nil)
        }
    }

    private final class StructuredDocumentSnapshot {
        var value: TTZipStructuredDocumentPreviewPreference.Snapshot?
    }

    private func verifyHostedPreview<Preview: View>(
        _ preview: Preview,
        expectation: String,
        matches: (NSView, TTZipStructuredDocumentPreviewPreference.Snapshot?) -> Bool
    ) async throws {
        let snapshot = StructuredDocumentSnapshot()
        let bounds = NSRect(x: 0, y: 0, width: 540, height: 580)
        let host = NSHostingView(
            rootView: preview.frame(width: bounds.width, height: bounds.height)
                .onPreferenceChange(TTZipStructuredDocumentPreviewPreference.self) { value in
                    snapshot.value = value
                }
        )
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if matches(host, snapshot.value) {
                XCTAssertFalse(window.isVisible)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(expectation), observed \(String(describing: snapshot.value))")
    }

    private func firstDescendant<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstDescendant(ofType: type, in: child) { return match }
        }
        return nil
    }

    // MARK: - 5. Production Ephemeral Lease Ownership & Fullscreen Handoff

    func testMediaPreviewViewSequentialEphemeralLeaseReleaseAndFullscreenHandoff() throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }

        for index in 0..<12 {
            let wavData = makeMinimalWAVData(tagByte: UInt8(index + 1))
            var stagedURL: URL?
            autoreleasepool {
                let detected = MediaPreviewFactory.detectTypeFromMemory(
                    data: wavData,
                    suggestedName: "downstream_\(index).wav"
                )
                stagedURL = detected.ephemeralMediaURL
                XCTAssertNotNil(stagedURL, "Iteration \(index) must stage ephemeral audio file")
                let view = MediaPreviewView(
                    previewType: detected,
                    fileName: "downstream_\(index).wav"
                )
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 240, height: 180)
                host.layoutSubtreeIfNeeded()
                if let url = stagedURL {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                }
            }
            if let url = stagedURL {
                XCTAssertEqual(
                    TTMediaDetector.activeEphemeralLeaseCount(for: url),
                    0,
                    "MediaPreviewView teardown must release ephemeral lease at iteration \(index)"
                )
            }
        }

        // Verify fullscreen transition via MediaPreviewView.toggleFullScreen() -> AppViewState.openImmersiveMedia()
        let fullscreenData = makeMinimalWAVData(tagByte: 0x7F)
        let appState = AppViewState()
        var fullscreenStagedURL: URL?
        autoreleasepool {
            let detected = MediaPreviewFactory.detectTypeFromMemory(
                data: fullscreenData,
                suggestedName: "fullscreen_handoff.wav"
            )
            fullscreenStagedURL = detected.ephemeralMediaURL
            let previewView = MediaPreviewView(
                previewType: detected,
                fileName: "fullscreen_handoff.wav"
            )
            previewView.toggleFullScreen()
            if let url = fullscreenStagedURL {
                appState.openImmersiveMedia(url: url, name: "fullscreen_handoff.wav")
            }
        }
        let handoffURL = try XCTUnwrap(fullscreenStagedURL)
        XCTAssertGreaterThanOrEqual(
            TTMediaDetector.activeEphemeralLeaseCount(for: handoffURL),
            1,
            "Fullscreen transition must keep ephemeral media lease active after inline view teardown"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoffURL.path))

        appState.closeImmersiveMedia()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: handoffURL), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))
    }

    // MARK: - 6. Archive Media Independent Player Multi-Consumer Lease & Last-Consumer Cleanup

    func testArchiveMediaIndependentPlayerMultiConsumerLeaseIsolationAndLastConsumerCleanup() async throws {
        let sandboxDir = try makeTemporaryDirectory()
        let cache = PreviewLRUCacheManager(
            customCacheDir: sandboxDir,
            maxStagedFiles: 1,
            maxCacheSizeBytesOverride: 64
        )
        let keyA = PreviewLRUCacheManager.deterministicCacheKey(
            archivePath: "/Volumes/Archive/bundle.zip",
            subpath: "media/clipA.mp4"
        )
        let urlA = try XCTUnwrap(cache.targetURL(forKey: keyA, filename: "clipA.mp4"))
        try FileManager.default.createDirectory(
            at: urlA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 48).write(to: urlA)
        await cache.register(key: keyA, fileURL: urlA)

        // 1. Main window acquires lease
        let mainWindowConsumerID = UUID()
        let mainLease = await cache.acquireLease(forKey: keyA, consumerID: mainWindowConsumerID)
        let countAfterMain = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countAfterMain, 1)

        // 2. Failed standalone player open acquires then immediately rolls back without affecting main window
        let failedPlayerConsumerID = UUID()
        let rawFailedPlayerLease = await cache.acquireIndependentPlayerLease(
            forFileURL: urlA,
            consumerID: failedPlayerConsumerID
        )
        let failedPlayerLease = try XCTUnwrap(rawFailedPlayerLease)
        let countDuringFailedAttempt = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countDuringFailedAttempt, 2)
        await cache.releaseLease(failedPlayerLease)
        let countAfterRollback = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countAfterRollback, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))

        // 3. Standalone player acquires independent consumer lease before main window switches/closes
        let standalonePlayerConsumerID = UUID()
        let standaloneLease = await cache.cloneLease(from: mainLease, newConsumerID: standalonePlayerConsumerID)
        let countWithBoth = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countWithBoth, 2)

        // 4. Main window switches selection / closes and stages another entry under strict quota (maxStagedFiles: 1)
        await cache.releaseLease(mainLease, reclaimImmediatelyIfIdle: true)
        let countAfterMainRelease = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countAfterMainRelease, 1)

        let keyB = PreviewLRUCacheManager.deterministicCacheKey(
            archivePath: "/Volumes/Archive/bundle.zip",
            subpath: "media/clipB.mp4"
        )
        let urlB = try XCTUnwrap(cache.targetURL(forKey: keyB, filename: "clipB.mp4"))
        try FileManager.default.createDirectory(
            at: urlB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x42, count: 48).write(to: urlB)
        await cache.register(key: keyB, fileURL: urlB)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: urlA.path),
            "Active standalone player lease must protect archive-extracted media file from eviction and main window release"
        )

        // 5. Last consumer (standalone player) closes and triggers immediate reclamation
        await cache.releaseLease(standaloneLease, reclaimImmediatelyIfIdle: true)
        let finalCount = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(finalCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: urlA.path),
            "Last consumer exit with reclaimImmediatelyIfIdle must delete the archive-extracted temporary file"
        )
    }

    func testArchiveTextMountsReadOnlyNativeEditorThroughProductRoute() async throws {
        let directory = try makeTemporaryDirectory()
        let fileName = "source.txt"
        let stagedURL = directory.appendingPathComponent(fileName)
        let source = "Preview this archive entry.\n"
        let bytes = Data(source.utf8)
        try bytes.write(to: stagedURL)
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: directory.appendingPathComponent("source.zip"),
            entryPath: "documents/\(fileName)",
            stagedReadURL: stagedURL
        )
        let inspector = UIHierarchyInspector(rootView: MediaPreviewView(
            fileData: bytes,
            fileName: fileName,
            showsFloatingFullScreenButton: false,
            resourceContext: context
        ))
        defer { inspector.updateRootView(EmptyView()) }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while firstDescendant(ofType: NSTextView.self, in: inspector.hostingView)?.string != source,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            inspector.hostingView.layoutSubtreeIfNeeded()
        }
        let editor = try XCTUnwrap(firstDescendant(ofType: NSTextView.self, in: inspector.hostingView))
        XCTAssertEqual(editor.string, source)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(inspector.window.isVisible)
        XCTAssertEqual(try Data(contentsOf: stagedURL), bytes)
    }

    private func makeMinimalWAVData(tagByte: UInt8) -> Data {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.append(contentsOf: [0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
        data.append(contentsOf: [0x44, 0xAC, 0x00, 0x00, 0x88, 0x58, 0x01, 0x00])
        data.append(contentsOf: [0x02, 0x00, 0x10, 0x00])
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: [0x04, 0x00, 0x00, 0x00, tagByte, 0x00, tagByte, 0x00])
        return data
    }
}
