// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import Observation
import TTMediaKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp
import struct TTZipApp.ImmersiveMediaBrowserView

@MainActor
final class ImmersiveMediaBrowserTests: XCTestCase {
    
    // MARK: - Test 1: ImmersiveMediaItem Model Integrity
    
    func testImmersiveMediaItemModelIntegrity() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Immersive")
        let sampleURL = tempDirURL.appendingPathComponent("document.pdf")
        let item1 = ImmersiveMediaItem(url: sampleURL, name: "document.pdf", fileSizeBytes: 1024)
        let item2 = ImmersiveMediaItem(url: sampleURL, name: "document.pdf", fileSizeBytes: 1024)
        let item3 = ImmersiveMediaItem(url: sampleURL.appendingPathExtension("backup"), name: "document.pdf.backup", fileSizeBytes: 2048)
        
        XCTAssertEqual(item1, item2, "Identical items must be equal via Hashable/Equatable")
        XCTAssertNotEqual(item1, item3, "Distinct URLs must not be equal")
        XCTAssertEqual(item1.fileSizeBytes, 1024)
        XCTAssertEqual(item1.name, "document.pdf")
        XCTAssertEqual(item1.url, sampleURL)
        
        // Optional fileSizeBytes defaulting
        let itemWithoutSize = ImmersiveMediaItem(url: sampleURL, name: "document.pdf")
        XCTAssertNil(itemWithoutSize.fileSizeBytes)
    }
    
    // MARK: - Test 2: OverlayState State Variables Toggle
    
    func testOverlayStateImmersiveMediaToggle() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Immersive")
        let overlayState = OverlayState()
        XCTAssertFalse(overlayState.showImmersiveMediaBrowser)
        XCTAssertNil(overlayState.immersiveMediaItem)
        
        let sampleURL = tempDirURL.appendingPathComponent("photo.jpg")
        let item = ImmersiveMediaItem(url: sampleURL, name: "photo.jpg", fileSizeBytes: 4096)
        
        overlayState.immersiveMediaItem = item
        overlayState.showImmersiveMediaBrowser = true
        
        XCTAssertTrue(overlayState.showImmersiveMediaBrowser)
        XCTAssertEqual(overlayState.immersiveMediaItem, item)
        
        overlayState.showImmersiveMediaBrowser = false
        overlayState.immersiveMediaItem = nil
        
        XCTAssertFalse(overlayState.showImmersiveMediaBrowser)
        XCTAssertNil(overlayState.immersiveMediaItem)
    }
    
    // MARK: - Test 3: AppViewState Open and Close Actions & Forwarding
    
    func testAppViewStateOpenAndCloseImmersiveMedia() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Immersive")
        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        let sampleURL = tempDirURL.appendingPathComponent("video.mp4")
        try? Data("mock video stream".utf8).write(to: sampleURL)
        
        XCTAssertFalse(viewModel.showImmersiveMediaBrowser)
        XCTAssertNil(viewModel.immersiveMediaItem)
        
        // Open
        viewModel.openImmersiveMedia(url: sampleURL, name: "video.mp4", fileSizeBytes: 17)
        
        XCTAssertTrue(viewModel.showImmersiveMediaBrowser)
        XCTAssertTrue(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url, sampleURL)
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, "video.mp4")
        XCTAssertEqual(viewModel.immersiveMediaItem?.fileSizeBytes, 17)
        XCTAssertEqual(viewModel.selectedDiskItem?.path, sampleURL.path)
        
        // Close
        viewModel.closeImmersiveMedia()
        
        XCTAssertFalse(viewModel.showImmersiveMediaBrowser)
        XCTAssertFalse(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertNil(viewModel.immersiveMediaItem)
        XCTAssertNil(viewModel.overlayState.immersiveMediaItem)
    }
    
    // MARK: - Test 4: Sibling File Navigation Across Directory
    
    func testMediaNavigationPreviousAndNextInDirectory() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Immersive")
        let fileA = tempDirURL.appendingPathComponent("alpha.png")
        let fileB = tempDirURL.appendingPathComponent("bravo.mp4")
        let fileC = tempDirURL.appendingPathComponent("charlie.pdf")
        let ignoredArchive = tempDirURL.appendingPathComponent("delta.zip")
        
        try Data("img".utf8).write(to: fileA)
        try Data("vid".utf8).write(to: fileB)
        try Data("doc".utf8).write(to: fileC)
        try Data("zip".utf8).write(to: ignoredArchive)
        
        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        viewModel.currentDirectory = tempDirURL
        
        // Open the middle file: bravo.mp4
        viewModel.openImmersiveMedia(url: fileB, name: fileB.lastPathComponent)
        await viewModel.waitForMediaScan()
        
        XCTAssertTrue(viewModel.hasPreviousMedia, "bravo.mp4 must have previous media (alpha.png)")
        XCTAssertTrue(viewModel.hasNextMedia, "bravo.mp4 must have next media (charlie.pdf)")
        
        // Navigate Previous -> should reach alpha.png
        viewModel.navigatePreviousMedia()
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, fileA.lastPathComponent)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url.resolvingSymlinksInPath(), fileA.resolvingSymlinksInPath())
        XCTAssertFalse(viewModel.hasPreviousMedia, "alpha.png is first; hasPreviousMedia must be false")
        XCTAssertTrue(viewModel.hasNextMedia, "alpha.png must have next media")
        
        // Navigate Next -> should reach bravo.mp4
        viewModel.navigateNextMedia()
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, fileB.lastPathComponent)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url.resolvingSymlinksInPath(), fileB.resolvingSymlinksInPath())
        
        // Navigate Next -> should reach charlie.pdf (and ignore delta.zip)
        viewModel.navigateNextMedia()
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, fileC.lastPathComponent)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url.resolvingSymlinksInPath(), fileC.resolvingSymlinksInPath())
        XCTAssertTrue(viewModel.hasPreviousMedia, "charlie.pdf must have previous media")
        XCTAssertFalse(viewModel.hasNextMedia, "charlie.pdf is last previewable file; hasNextMedia must be false")
    }
    
    // MARK: - Test 5: ImmersiveMediaBrowserView Instantiation & Hierarchy
    
    func testImmersiveMediaBrowserViewHierarchyRenders() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "Immersive")
        let fileURL = tempDirURL.appendingPathComponent("preview_test.jpg")
        try? Data("jpeg payload".utf8).write(to: fileURL)
        
        let item = ImmersiveMediaItem(url: fileURL, name: "preview_test.jpg", fileSizeBytes: 12)
        var didClose = false
        var didPrev = false
        var didNext = false
        
        let browserView = ImmersiveMediaBrowserView(
            item: item,
            onClose: { didClose = true },
            onNavigatePrevious: { didPrev = true },
            onNavigateNext: { didNext = true }
        )
        
        let hostView = NSHostingView(rootView: browserView)
        hostView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hostView.layoutSubtreeIfNeeded()
        
        XCTAssertNotNil(hostView, "ImmersiveMediaBrowserView must render inside NSHostingView cleanly")
        XCTAssertFalse(didClose)
        XCTAssertFalse(didPrev)
        XCTAssertFalse(didNext)
    }

    // MARK: - Test 6 (U1-001): PreviewHostLayoutClass & Floating Fullscreen Button Policy

    func testHostLayoutClassAndFloatingFullScreenButtonPolicy() throws {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample")
        let dummyImg = NSImage(size: NSSize(width: 64, height: 64))

        // Canvas media types (.image, .video, .audio)
        XCTAssertEqual(MediaPreviewType.image(dummyImg).hostLayoutClass, .canvasMedia)
        XCTAssertEqual(MediaPreviewType.video(dummyURL).hostLayoutClass, .canvasMedia)
        XCTAssertEqual(MediaPreviewType.audio(dummyURL).hostLayoutClass, .canvasMedia)
        XCTAssertTrue(MediaPreviewType.video(dummyURL).isVideoPreview)
        XCTAssertFalse(MediaPreviewType.text("code").isVideoPreview)

        // Structured document types must all use .structuredDocument so top header never occludes toolbars
        let structuredTypes: [MediaPreviewType] = [
            .text("let x = 1"),
            .markdown("# Title", dummyURL),
            .htmlWeb(content: "<html></html>", fileURL: dummyURL),
            .spreadsheetTable("a,b\n1,2", dummyURL),
            .pdf(dummyURL),
            .pdfData(Data(), dummyURL),
            .docxDocument(NSAttributedString(string: "doc"), dummyURL),
            .hexViewer(Data([0x00, 0x01]), dummyURL),
            .quickLook(dummyURL),
            .unsupported("Unsupported")
        ]
        for pType in structuredTypes {
            XCTAssertEqual(
                pType.hostLayoutClass,
                .structuredDocument,
                "Expected .structuredDocument for \(pType)"
            )
        }

        // Floating fullscreen button must only appear on .image / .quickLook when non-immersive
        let imagePreview = MediaPreviewView(previewType: .image(dummyImg), fileName: "pic.png", showsFloatingFullScreenButton: true)
        XCTAssertTrue(imagePreview.effectiveShowsFloatingFullScreenButton)

        let textPreview = MediaPreviewView(previewType: .text("hello"), fileName: "note.txt", showsFloatingFullScreenButton: true)
        XCTAssertFalse(textPreview.effectiveShowsFloatingFullScreenButton, "Text toolbar must not be occluded by floating button")

        let csvPreview = MediaPreviewView(previewType: .spreadsheetTable("a,b", dummyURL), fileName: "data.csv", showsFloatingFullScreenButton: true)
        XCTAssertFalse(csvPreview.effectiveShowsFloatingFullScreenButton, "Spreadsheet toolbar must not be occluded by floating button")

        let pdfPreview = MediaPreviewView(previewType: .pdf(dummyURL), fileName: "doc.pdf", showsFloatingFullScreenButton: true)
        XCTAssertFalse(pdfPreview.effectiveShowsFloatingFullScreenButton, "PDF toolbar must not be occluded by floating button")
    }

    // MARK: - Test 7 (U1-003): Adaptive Preview Height by Detected Type & .ts Disambiguation

    func testAdaptivePreviewHeightDistinguishesTypeScriptFromMPEGTS() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "U1003_TS")

        // 1. TypeScript .ts source file
        let tsCodeURL = tempDir.appendingPathComponent("component.ts")
        try Data("export interface Props {\n  readonly title: string;\n}\n".utf8).write(to: tsCodeURL)
        let tsCodeItem = DiskItemInfo(url: tsCodeURL)

        let tsCodeHeight = ExplorerItemInspectorView.computeAdaptivePreviewHeight(
            for: tsCodeItem,
            previewURL: tsCodeURL,
            contentWidth: 280,
            availableHeight: 700
        )
        // Structured document height is min(560, max(320, 700 * 0.62 = 434)) == 434
        XCTAssertEqual(tsCodeHeight, 434.0, accuracy: 0.5, "TypeScript .ts file must receive structured document height")
        XCTAssertEqual(TTMediaDetector.inferHostLayoutClass(url: tsCodeURL, fileName: "component.ts"), .structuredDocument)

        // 2. MPEG-TS .ts video stream (4 packets of 188 bytes starting with 0x47 sync byte)
        let mpegTSURL = tempDir.appendingPathComponent("broadcast.ts")
        var mpegData = Data(repeating: 0x00, count: 188 * 4)
        for i in 0..<4 {
            mpegData[i * 188] = 0x47
        }
        try mpegData.write(to: mpegTSURL)
        let mpegTSItem = DiskItemInfo(url: mpegTSURL)

        let mpegTSHeight = ExplorerItemInspectorView.computeAdaptivePreviewHeight(
            for: mpegTSItem,
            previewURL: mpegTSURL,
            contentWidth: 280,
            availableHeight: 700
        )
        // Controls overlay the canvas; no artificial 44-point letterbox is reserved.
        XCTAssertEqual(mpegTSHeight, 157.5, accuracy: 0.5, "MPEG-TS .ts stream must receive full-width 16:9 video height")
        XCTAssertEqual(TTMediaDetector.inferHostLayoutClass(url: mpegTSURL, fileName: "broadcast.ts"), .canvasMedia)
        XCTAssertGreaterThan(tsCodeHeight, mpegTSHeight + 150.0, "TypeScript code height must be significantly taller than 16:9 video height")

        // 3. CSV / JSON / Hex structured documents also receive document height (not 220pt fallback)
        let csvURL = tempDir.appendingPathComponent("metrics.csv")
        try Data("col1,col2\n10,20\n".utf8).write(to: csvURL)
        let csvHeight = ExplorerItemInspectorView.computeAdaptivePreviewHeight(
            for: DiskItemInfo(url: csvURL),
            previewURL: csvURL,
            contentWidth: 280,
            availableHeight: 700
        )
        XCTAssertEqual(csvHeight, 434.0, accuracy: 0.5)
    }

    // MARK: - Test 8 (U1-009 & F4): Archive Source, Read-Only Editability, and Cache Lease Continuity

    func testF4ArchiveContinuityAcrossImmersiveFullscreenAndNavigation() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "F4Immersive")
        let archivePath = tempDir.appendingPathComponent("bundle.zip").path

        let entryA = ArchiveEntry(
            path: "docs/alpha.txt",
            uncompressedSize: 64,
            isDirectory: false,
            isEncrypted: false
        )
        let entryB = ArchiveEntry(
            path: "docs/bravo.md",
            uncompressedSize: 128,
            isDirectory: false,
            isEncrypted: false
        )

        let keyA = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archivePath, subpath: entryA.path)
        let keyB = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archivePath, subpath: entryB.path)

        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        viewModel.explorerState.currentArchivePath = archivePath
        viewModel.explorerState.currentEntries = [entryA, entryB]

        var compA = URLComponents(url: URL(fileURLWithPath: archivePath), resolvingAgainstBaseURL: false)!
        compA.queryItems = [URLQueryItem(name: "subpath", value: entryA.path)]
        let virtualItemA = DiskItemInfo(
            path: compA.url!.absoluteString,
            name: "alpha.txt",
            displayName: "alpha.txt",
            isDirectory: false,
            isArchive: false,
            sizeText: "64 B",
            rawSizeBytes: 64,
            kindText: "Text",
            modificationDate: nil
        )

        viewModel.openImmersiveMedia(for: virtualItemA)

        XCTAssertTrue(viewModel.overlayState.showImmersiveMediaBrowser)
        guard let activeA = viewModel.overlayState.immersiveMediaItem else {
            XCTFail("Expected active immersiveMediaItem for entryA")
            return
        }
        XCTAssertEqual(activeA.sourceArchivePath, archivePath)
        XCTAssertEqual(activeA.archiveSubpath, "docs/alpha.txt")
        XCTAssertEqual(activeA.resourceCacheKey, keyA)
        XCTAssertFalse(activeA.isEditable, "Archive-backed item must be strictly read-only")
        XCTAssertTrue(activeA.isFromArchive)
        XCTAssertTrue(activeA.resolvedResourceContext.isArchiveEntry)
        XCTAssertFalse(activeA.resolvedResourceContext.isEditableInPlace)
        XCTAssertEqual(activeA.resolvedResourceContext.readOnlyReason, .archiveEntry)
        XCTAssertEqual(activeA.resolvedResourceContext.archiveIdentity?.archivePath, archivePath)
        XCTAssertEqual(activeA.resolvedResourceContext.archiveIdentity?.entryPath, "docs/alpha.txt")
        XCTAssertEqual(viewModel.activeImmersiveCacheLease?.key, keyA)
        XCTAssertFalse(viewModel.hasPreviousMedia)
        XCTAssertTrue(viewModel.hasNextMedia)

        // Verify MediaPreviewView enforces read-only mode when constructed from F4 item
        let previewA = MediaPreviewView(
            fileURL: activeA.url,
            fileName: activeA.name,
            isImmersiveFullscreen: true,
            sourceArchivePath: activeA.sourceArchivePath,
            archiveSubpath: activeA.archiveSubpath,
            resourceCacheKey: activeA.resourceCacheKey,
            isEditable: activeA.isEditable,
            resourceContext: activeA.resolvedResourceContext
        )
        XCTAssertTrue(previewA.effectiveIsFromArchive)
        XCTAssertFalse(previewA.effectiveIsEditable)
        XCTAssertTrue(previewA.effectiveResourceContext.isArchiveEntry)
        XCTAssertFalse(previewA.effectiveResourceContext.isEditableInPlace)
        XCTAssertEqual(previewA.effectiveResourceContext.readOnlyReason, .archiveEntry)

        // Navigate Next -> entryB must preserve F4 archive identity, read-only state, and update cache lease key
        viewModel.navigateNextMedia()
        guard let activeB = viewModel.overlayState.immersiveMediaItem else {
            XCTFail("Expected active immersiveMediaItem for entryB")
            return
        }
        XCTAssertEqual(activeB.name, "bravo.md")
        XCTAssertEqual(activeB.sourceArchivePath, archivePath)
        XCTAssertEqual(activeB.archiveSubpath, "docs/bravo.md")
        XCTAssertEqual(activeB.resourceCacheKey, keyB)
        XCTAssertFalse(activeB.isEditable)
        XCTAssertTrue(activeB.resolvedResourceContext.isArchiveEntry)
        XCTAssertEqual(activeB.resolvedResourceContext.archiveIdentity?.entryPath, "docs/bravo.md")
        XCTAssertEqual(viewModel.activeImmersiveCacheLease?.key, keyB)
        XCTAssertTrue(viewModel.hasPreviousMedia)
        XCTAssertFalse(viewModel.hasNextMedia)

        // Navigate Previous -> back to entryA
        viewModel.navigatePreviousMedia()
        XCTAssertEqual(viewModel.overlayState.immersiveMediaItem?.archiveSubpath, "docs/alpha.txt")
        XCTAssertEqual(viewModel.activeImmersiveCacheLease?.key, keyA)

        // Closing immersive media releases the F4 cache lease
        viewModel.closeImmersiveMedia()
        XCTAssertNil(viewModel.activeImmersiveCacheLease)
        XCTAssertFalse(viewModel.overlayState.showImmersiveMediaBrowser)
    }

    // MARK: - Test 9 (U1-012): Comic Archive Browsing Entry (.cbz / .cbr / .cb7 / .cbt)

    func testComicArchiveItemRoutesToArchiveBrowserFlow() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "U1012_Comic")
        // The archive browsing flow records the routed archive in the process wide
        // recent-archive store. Snapshot the store before the route writes into it and
        // restore exactly that value afterwards, so only this test's own additions are
        // removed and the records that were already there stay untouched. Removing the
        // whole key would also drop records this test does not own.
        let existingRecentArchives = UserDefaults.standard.data(forKey: "TTZipRecentArchivesKey")
        addTeardownBlock {
            if let existingRecentArchives {
                UserDefaults.standard.set(existingRecentArchives, forKey: "TTZipRecentArchivesKey")
            } else {
                UserDefaults.standard.removeObject(forKey: "TTZipRecentArchivesKey")
            }
        }
        for ext in ["cbz", "cbr", "cb7", "cbt"] {
            let comicURL = tempDir.appendingPathComponent("issue_01.\(ext)")
            // The fixture only carries the comic extension and exists on disk, because the
            // routing decision is extension based. The archive content itself is supplied by
            // the controlled inspection at the production driver seam, so this placeholder
            // never pretends to be a successfully openable archive.
            try Data("comic container placeholder".utf8).write(to: comicURL)
            let item = DiskItemInfo(url: comicURL)
            let routedPath = comicURL.standardizedFileURL.resolvingSymlinksInPath().path

            XCTAssertTrue(
                ExplorerItemInspectorView.isComicArchiveItem(item),
                ".\(ext) must be recognized as a comic archive item"
            )

            let receipt = ComicArchiveRouteReceipt()
            let viewModel = AppViewState(
                fileViewer: NoOpFileViewer(),
                passwordDriver: ComicArchiveInspectionDriver(receipt: receipt)
            )
            let originatingSessionID = viewModel.navigationState.activeSessionID

            // The archive route publishes the routed item asynchronously: the production
            // chain inspects the archive and commits it before the window selection becomes
            // visible. Observe that publication instead of assuming it already happened.
            withObservationTracking {
                _ = viewModel.selectedDiskItem
            } onChange: {
                receipt.signalCommitted()
            }
            viewModel.openImmersiveMedia(for: item)

            await fulfillment(of: [receipt.inspectedArrival, receipt.committed], timeout: 3)

            // Must NOT open unsupported media overlay; instead routes into archive browsing flow
            XCTAssertFalse(
                viewModel.overlayState.showImmersiveMediaBrowser,
                ".\(ext) comic archive must route to archive browser instead of unsupported immersive media overlay"
            )
            let inspectedPaths = await receipt.inspectedPaths()
            XCTAssertEqual(
                inspectedPaths,
                [routedPath],
                ".\(ext) comic archive must reach the archive inspection seam for the routed path"
            )
            XCTAssertEqual(
                viewModel.selectedDiskItem?.path,
                routedPath
            )
            XCTAssertEqual(
                viewModel.explorerState.currentArchivePath,
                routedPath,
                ".\(ext) comic archive must be committed as the window archive"
            )
            XCTAssertEqual(
                viewModel.navigationState.tabSessions.first(where: { $0.id == originatingSessionID })?.archivePath,
                routedPath,
                ".\(ext) comic archive must be committed into the originating tab session"
            )
        }
    }

    // MARK: - Test 10 (Feedback ⑦ & ⑧): Host Content Geometry

    func testPreviewHostContentGeometryPropagatesExplicitBounds() {
        let geometry = TTPreviewHostContentGeometry(
            layoutClass: .structuredDocument,
            hostHeaderHeight: 52,
            contentTopSafeInset: 0,
            availableSize: CGSize(width: 1120, height: 740),
            isStandalonePlaybackWindow: false
        )
        XCTAssertEqual(geometry.layoutClass, .structuredDocument)
        XCTAssertEqual(geometry.hostHeaderHeight, 52)
        XCTAssertEqual(geometry.contentTopSafeInset, 0)
        XCTAssertEqual(geometry.availableSize, CGSize(width: 1120, height: 740))
        XCTAssertFalse(geometry.isStandalonePlaybackWindow)
    }

    func testStandalonePlayerWindowUsesStandardResizableMainCapableNSWindowNotFloatingPiP() {
        let window = StandalonePlaybackWindowManager.makeStandardPlayerWindow(title: "demo.mp4")
        XCTAssertEqual(window.level, .normal, "Standalone player window must not use .floating PiP level")
        XCTAssertNotEqual(window.level, .floating)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
    }
}

// MARK: - Comic archive route: controlled archive inspection seam
//
// The comic route drives the real production chain
// (`openImmersiveMedia(for:)` -> `openArchiveAsFolder(url:)` -> `openArchive(at:)`), and that
// chain inspects the archive through the injectable archive driver before it commits the
// archive and publishes the routed item. The helper below provides that seam for the
// routing test: it returns a real acceptable inspection result, so the production commit
// path runs unchanged, and it records that the archive flow really arrived.
//
// The other three driver entry points are unreachable in this scenario. They fail loudly
// instead of pretending to succeed, so a future routing change cannot pass unnoticed.

/// Records the progress of one comic archive route.
///
/// The two expectations are the bounded completion receipt of the route: the test waits for
/// the inspection arrival and for the commit publication inside one budget. Nothing here
/// waits without a bound and nothing here assumes a fixed duration.
private actor ComicArchiveRouteReceipt {
    nonisolated let inspectedArrival = XCTestExpectation(
        description: "comic route reached the archive inspection seam"
    )
    nonisolated let committed = XCTestExpectation(
        description: "comic route published the routed item"
    )

    private var inspectedPathList: [String] = []

    /// Records that the production chain asked the seam to inspect the routed path.
    func recordInspection(path: String) {
        inspectedPathList.append(path)
        inspectedArrival.fulfill()
    }

    /// Signals that the window selection was published by the archive route.
    nonisolated func signalCommitted() {
        committed.fulfill()
    }

    /// The inspected paths of this route, in call order.
    func inspectedPaths() -> [String] {
        inspectedPathList
    }
}

/// Controlled archive inspection seam for the comic routing scenario.
private struct ComicArchiveInspectionDriver: ArchivePasswordOperationsDriver {
    let receipt: ComicArchiveRouteReceipt

    func inspectArchive(
        archivePath: String,
        password: String?,
        autoVaultUnlock: Bool
    ) async throws -> InspectResult {
        await receipt.recordInspection(path: archivePath)
        return InspectResult(
            archivePath: archivePath,
            format: "zip",
            entries: [
                ArchiveEntry(
                    path: "issue_01/page_001.jpg",
                    uncompressedSize: 1024,
                    isDirectory: false,
                    modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                    isEncrypted: false,
                    compressedSize: 1024,
                    crc32: 0x1234_5678
                )
            ],
            totalUncompressedBytes: 1024,
            totalCompressedBytes: 1024,
            unlockedPassword: nil
        )
    }

    func verifyEncryptedEntryPayload(
        archivePath: String,
        entryPath: String,
        password: String
    ) async throws -> Data? {
        throw ComicArchiveRouteUnexpectedCall.verifyEncryptedEntryPayload
    }

    func quickExtract(
        archivePath: String,
        destinationDir: String,
        password: String?,
        autoVaultUnlock: Bool,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)? = nil,
        token: CancellationToken? = nil
    ) async throws -> ExtractResult {
        throw ComicArchiveRouteUnexpectedCall.quickExtract
    }

    func extractEntries(
        archivePath: String,
        entryPaths: [String],
        destinationDir: String,
        password: String?,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws -> ExtractionOutcome {
        throw ComicArchiveRouteUnexpectedCall.extractEntries
    }
}

/// A driver entry point that the comic routing scenario must never reach.
private enum ComicArchiveRouteUnexpectedCall: Error {
    case verifyEncryptedEntryPayload
    case quickExtract
    case extractEntries
}
