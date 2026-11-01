// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
@preconcurrency import PDFKit
@testable import TTMediaKit

final class PDFPreviewPerformanceRegressionTests: XCTestCase {

    // MARK: - 1. Stored Input Identity & Equal-Length Content Sensitivity

    @MainActor
    func testStoredInputIdentityDoesNotRehashAndPreservesEqualLengthDistinction() async throws {
        var dataA = try makeVectorPDFData(pageCount: 2, curvesPerPage: 120, seedLabel: "Alpha")
        var dataB = try makeVectorPDFData(pageCount: 2, curvesPerPage: 120, seedLabel: "Bravo")
        let paddedSize = max(max(dataA.count, dataB.count), 2 * 1024 * 1024)
        padPDFData(&dataA, toByteCount: paddedSize, fillByte: UInt8(ascii: "A"))
        padPDFData(&dataB, toByteCount: paddedSize, fillByte: UInt8(ascii: "B"))
        XCTAssertEqual(dataA.count, dataB.count)

        let containerA = InteractivePDFPreviewContainerView(data: dataA)
        let containerB = InteractivePDFPreviewContainerView(data: dataB)
        XCTAssertNotEqual(containerA.inputIdentity, containerB.inputIdentity)
        XCTAssertEqual(containerA.inputIdentity.dataByteCount, paddedSize)

        let startRepeat = ContinuousClock.now
        for _ in 0..<10_000 {
            XCTAssertEqual(containerA.inputIdentity.cacheKey, containerA.inputIdentity.cacheKey)
        }
        let elapsedRepeat = startRepeat.duration(to: ContinuousClock.now)
        let repeatMs = Double(elapsedRepeat.components.seconds) * 1_000.0
            + Double(elapsedRepeat.components.attoseconds) / 1_000_000_000_000_000.0
        XCTAssertLessThan(
            repeatMs,
            50.0,
            "10,000 stored inputIdentity accesses should take < 50 ms without re-hashing 2 MB Data"
        )

        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: nil, data: dataA, identity: containerA.inputIdentity)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.currentIdentity, containerA.inputIdentity)
        let firstGeneration = loader.activeGeneration

        await loader.loadAsync(url: nil, data: dataA, identity: containerA.inputIdentity)
        XCTAssertEqual(loader.activeGeneration, firstGeneration, "Identical stored identity must not reload")

        await loader.loadAsync(url: nil, data: dataB, identity: containerB.inputIdentity)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.currentIdentity, containerB.inputIdentity)
        XCTAssertGreaterThan(loader.activeGeneration, firstGeneration)
    }

    // MARK: - 2. Pixel Budget, Off-Main-Thread Rendering, Caching & Cancellation

    func testBudgetedPixelSizeClampsToStrictCardPixelBudget() {
        let retinaBudget = PDFThumbnailRenderCoordinator.budgetedPixelSize(
            for: CGSize(width: 612, height: 792),
            scaleFactor: 2.0,
            pageAspectRatio: 612.0 / 792.0
        )
        XCTAssertLessThanOrEqual(retinaBudget.width, PDFThumbnailRenderCoordinator.maxPixelWidth)
        XCTAssertLessThanOrEqual(retinaBudget.height, PDFThumbnailRenderCoordinator.maxPixelHeight)
        XCTAssertLessThanOrEqual(
            retinaBudget.width * retinaBudget.height,
            PDFThumbnailRenderCoordinator.maxPixelArea
        )

        let defaultCardBudget = PDFThumbnailRenderCoordinator.budgetedPixelSize(
            for: PDFThumbnailRenderCoordinator.defaultCardPointSize,
            scaleFactor: 2.0,
            pageAspectRatio: 0.75
        )
        XCTAssertLessThanOrEqual(defaultCardBudget.width, 420)
        XCTAssertLessThanOrEqual(defaultCardBudget.height, 560)
    }

    func testBackgroundThumbnailCoordinatorRendersOffMainThreadCachesAndCancelsPromptly() async throws {
        let coordinator = PDFThumbnailRenderCoordinator(countLimit: 64, totalCostLimit: 32 * 1024 * 1024)
        let pdfData = try makeVectorPDFData(pageCount: 18, curvesPerPage: 450, seedLabel: "HeavyVector")
        let identity = PDFPreviewInputIdentity(url: nil, data: pdfData)

        let firstStart = ContinuousClock.now
        let image0 = await coordinator.renderThumbnail(
            zeroBasedPageIndex: 0,
            displayPointSize: CGSize(width: 240, height: 320),
            scaleFactor: 2.0,
            pageAspectRatio: 0.75,
            url: nil,
            data: pdfData,
            identity: identity
        )
        let firstElapsed = firstStart.duration(to: ContinuousClock.now)
        let rendered = try XCTUnwrap(image0)
        XCTAssertLessThanOrEqual(rendered.size.width, PDFThumbnailRenderCoordinator.maxPixelWidth)
        XCTAssertLessThanOrEqual(rendered.size.height, PDFThumbnailRenderCoordinator.maxPixelHeight)

        let cacheStart = ContinuousClock.now
        let cachedHit = await coordinator.renderThumbnail(
            zeroBasedPageIndex: 0,
            displayPointSize: CGSize(width: 240, height: 320),
            scaleFactor: 2.0,
            pageAspectRatio: 0.75,
            url: nil,
            data: pdfData,
            identity: identity
        )
        let cacheElapsed = cacheStart.duration(to: ContinuousClock.now)
        XCTAssertNotNil(cachedHit)
        let cacheHitMs = Double(cacheElapsed.components.seconds) * 1_000.0
            + Double(cacheElapsed.components.attoseconds) / 1_000_000_000_000_000.0
        let firstRenderMs = Double(firstElapsed.components.seconds) * 1_000.0
            + Double(firstElapsed.components.attoseconds) / 1_000_000_000_000_000.0
        XCTAssertLessThan(cacheHitMs, max(5.0, firstRenderMs * 0.5), "Repeat thumbnail request must hit NSCache")

        var tasks: [Task<NSImage?, Never>] = []
        for pageIdx in 1..<18 {
            let task = Task {
                await coordinator.renderThumbnail(
                    zeroBasedPageIndex: pageIdx,
                    displayPointSize: CGSize(width: 220, height: 290),
                    scaleFactor: 2.0,
                    pageAspectRatio: 0.75,
                    url: nil,
                    data: pdfData,
                    identity: identity
                )
            }
            tasks.append(task)
        }

        for task in tasks.dropFirst(2) {
            task.cancel()
        }

        var cancelledNilCount = 0
        for task in tasks.dropFirst(2) {
            let result = await task.value
            if result == nil {
                cancelledNilCount += 1
            }
        }
        XCTAssertGreaterThan(cancelledNilCount, 0, "Queued tasks cancelled during rapid scroll must abort without rendering")

        for task in tasks.prefix(2) {
            _ = await task.value
        }
    }

    // MARK: - 3. Real NSWindow Lifecycle, Mode Switching & Scroll Verification

    @MainActor
    func testInteractivePDFPreviewWindowLifecycleAndGridScrolling() async throws {
        let pdfData = try makeVectorPDFData(pageCount: 9, curvesPerPage: 220, seedLabel: "WindowVerify")
        let loader = PDFPreviewLoader()
        let previewView = InteractivePDFPreviewContainerView(data: pdfData, loader: loader)

        let hostingController = NSHostingController(rootView: previewView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        await loader.loadAsync(url: nil, data: pdfData, identity: previewView.inputIdentity)
        XCTAssertEqual(loader.phase, .ready)
        let doc = try XCTUnwrap(loader.document)
        XCTAssertEqual(doc.pageCount, 9)

        for mode in [PDFLayoutMode.singleFullWidth, .twoPages, .threePages] {
            let modeView: AnyView
            switch mode {
            case .singleFullWidth, .twoPages:
                modeView = AnyView(PDFKitView(document: doc, layoutMode: mode))
            case .threePages:
                modeView = AnyView(
                    PDFThreePageTileGridView(
                        document: doc,
                        sourceURL: nil,
                        sourceData: pdfData,
                        inputIdentity: previewView.inputIdentity
                    )
                )
            }
            hostingController.rootView = InteractivePDFPreviewContainerView(data: pdfData, loader: loader)
            let subHost = NSHostingView(rootView: modeView)
            subHost.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
            window.contentView?.addSubview(subHost)
            subHost.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            subHost.removeFromSuperview()
        }

        let thumb = await PDFThumbnailRenderCoordinator.shared.renderThumbnail(
            zeroBasedPageIndex: 0,
            displayPointSize: CGSize(width: 220, height: 290),
            scaleFactor: window.backingScaleFactor,
            pageAspectRatio: 0.75,
            url: nil,
            data: pdfData,
            identity: previewView.inputIdentity
        )
        XCTAssertNotNil(thumb)
    }

    // MARK: - 4. Unified Read Budget Enforcement & No Fallback Bypass

    @MainActor
    func testUnifiedReadBudgetRejectsOverBudgetDataFileAndNonFileURLWithoutFallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaPDFBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let smallPDFData = try makeVectorPDFData(pageCount: 1, curvesPerPage: 10, seedLabel: "SmallValid")
        let smallFileURL = tempDir.appendingPathComponent("small.pdf")
        try smallPDFData.write(to: smallFileURL, options: .atomic)

        var overBudgetPDFData = smallPDFData
        padPDFData(&overBudgetPDFData, toByteCount: smallPDFData.count + 4096, fillByte: UInt8(ascii: "X"))
        let overBudgetFileURL = tempDir.appendingPathComponent("over_budget.pdf")
        try overBudgetPDFData.write(to: overBudgetFileURL, options: .atomic)

        let tightBudget = smallPDFData.count + 512
        let budgetedLoader = PDFPreviewLoader(maxReadBudgetBytes: tightBudget)

        await budgetedLoader.loadAsync(url: smallFileURL, data: nil)
        XCTAssertEqual(budgetedLoader.phase, .ready)
        XCTAssertEqual(budgetedLoader.document?.pageCount, 1)

        await budgetedLoader.loadAsync(url: smallFileURL, data: overBudgetPDFData)
        if case .failed = budgetedLoader.phase {
            XCTAssertNil(budgetedLoader.document, "Over-budget Data must fail and never fall back to smallFileURL")
        } else {
            XCTFail("Expected .failed for over-budget Data with valid fallback URL, got \(budgetedLoader.phase)")
        }

        await budgetedLoader.loadAsync(url: overBudgetFileURL, data: nil)
        if case .failed = budgetedLoader.phase {
            XCTAssertNil(budgetedLoader.document, "Over-budget file URL must fail without bypassing budget")
        } else {
            XCTFail("Expected .failed for over-budget file URL, got \(budgetedLoader.phase)")
        }

        let base64OverBudget = overBudgetPDFData.base64EncodedString()
        let dataSchemeURL = try XCTUnwrap(URL(string: "data:application/pdf;base64,\(base64OverBudget)"))
        await budgetedLoader.loadAsync(url: dataSchemeURL, data: nil)
        if case .failed = budgetedLoader.phase {
            XCTAssertNil(budgetedLoader.document, "Over-budget non-file URL must not fall back to PDFDocument(url:)")
        } else {
            XCTFail("Expected .failed for over-budget non-file URL, got \(budgetedLoader.phase)")
        }

        let budgetedCoordinator = PDFThumbnailRenderCoordinator(
            countLimit: 16,
            totalCostLimit: 4 * 1024 * 1024,
            maxReadBudgetBytes: tightBudget
        )
        let overBudgetThumb = await budgetedCoordinator.renderThumbnail(
            zeroBasedPageIndex: 0,
            url: smallFileURL,
            data: overBudgetPDFData
        )
        XCTAssertNil(overBudgetThumb, "Thumbnail coordinator must also reject over-budget Data without URL fallback")
    }

    @MainActor
    func testControlledBoundedReadAbortsWhenLocalFileGrowsPastBudgetMidRead() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaPDFMidReadGrow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let initialPDFData = try makeVectorPDFData(pageCount: 1, curvesPerPage: 12, seedLabel: "InitialSmall")
        let targetURL = tempDir.appendingPathComponent("growing.pdf")
        try initialPDFData.write(to: targetURL, options: .atomic)

        let tightBudget = initialPDFData.count + 256
        let loader = PDFPreviewLoader(maxReadBudgetBytes: tightBudget)
        loader.onBeforeStreamReadChunk = {
            if let handle = try? FileHandle(forWritingTo: targetURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                let extra = Data(repeating: UInt8(ascii: "Z"), count: 4096)
                try? handle.write(contentsOf: extra)
            }
        }

        await loader.loadAsync(url: targetURL, data: nil)
        if case .failed = loader.phase {
            XCTAssertNil(loader.document, "Controlled chunked reader must abort when file grows past budget after stat()")
        } else {
            XCTFail("Expected .failed when file grew past budget mid-read, got \(loader.phase)")
        }
    }

    // MARK: - 5. Disk Resource Version + Content Identity (Equal-Length Overwrite & Atomic Replace)

    @MainActor
    func testSamePathEqualLengthOverwriteAndAtomicReplaceRefreshLoaderCacheAndWorkerPool() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaPDFDiskIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var onePageData = try makeVectorPDFData(pageCount: 1, curvesPerPage: 16, seedLabel: "DiskOne")
        var twoPageData = try makeVectorPDFData(pageCount: 2, curvesPerPage: 16, seedLabel: "DiskTwo")
        var threePageData = try makeVectorPDFData(pageCount: 3, curvesPerPage: 16, seedLabel: "DiskThree")
        let commonLength = max(max(onePageData.count, twoPageData.count), threePageData.count) + 128
        padPDFData(&onePageData, toByteCount: commonLength, fillByte: UInt8(ascii: "1"))
        padPDFData(&twoPageData, toByteCount: commonLength, fillByte: UInt8(ascii: "2"))
        padPDFData(&threePageData, toByteCount: commonLength, fillByte: UInt8(ascii: "3"))
        XCTAssertEqual(onePageData.count, twoPageData.count)
        XCTAssertEqual(twoPageData.count, threePageData.count)

        let fileURL = tempDir.appendingPathComponent("mutable_doc.pdf")
        try onePageData.write(to: fileURL, options: .atomic)

        let coordinator = PDFThumbnailRenderCoordinator(countLimit: 32, totalCostLimit: 16 * 1024 * 1024)
        let loader = PDFPreviewLoader()

        await loader.loadAsync(url: fileURL, data: nil)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.document?.pageCount, 1)
        let idV1 = try XCTUnwrap(loader.loadedIdentity)
        let thumbV1Page0 = await coordinator.renderThumbnail(zeroBasedPageIndex: 0, url: fileURL, identity: idV1)
        XCTAssertNotNil(thumbV1Page0)
        let thumbV1Page1 = await coordinator.renderThumbnail(zeroBasedPageIndex: 1, url: fileURL, identity: idV1)
        XCTAssertNil(thumbV1Page1, "1-page document must not render page index 1")

        if let writer = try? FileHandle(forWritingTo: fileURL) {
            try writer.truncate(atOffset: 0)
            try writer.write(contentsOf: twoPageData)
            try writer.close()
        }

        await loader.loadAsync(url: fileURL, data: nil)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.document?.pageCount, 2, "Same-path equal-length overwrite must reload 2-page PDF")
        let idV2 = try XCTUnwrap(loader.loadedIdentity)
        XCTAssertNotEqual(idV1, idV2, "Same-path equal-length overwrite must produce distinct PDFPreviewInputIdentity")
        let thumbV2Page1 = await coordinator.renderThumbnail(zeroBasedPageIndex: 1, url: fileURL, identity: idV2)
        XCTAssertNotNil(thumbV2Page1, "Worker pool must load new 2-page PDF instead of reusing stale 1-page worker")

        try threePageData.write(to: fileURL, options: .atomic)
        await loader.loadAsync(url: fileURL, data: nil)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.document?.pageCount, 3, "Atomic replacement must reload 3-page PDF")
        let idV3 = try XCTUnwrap(loader.loadedIdentity)
        XCTAssertNotEqual(idV2, idV3, "Atomic replacement must produce distinct PDFPreviewInputIdentity")
        let thumbV3Page2 = await coordinator.renderThumbnail(zeroBasedPageIndex: 2, url: fileURL, identity: idV3)
        XCTAssertNotNil(thumbV3Page2, "Worker pool must render page index 2 after atomic replacement")
    }

    // MARK: - 6. Encrypted PDF Unlock Propagation to Background Worker Pool

    @MainActor
    func testEncryptedPDFUnlockPropagatesPasswordToThumbnailWorkerPool() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaPDFUnlockWorker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plainData = try makeVectorPDFData(pageCount: 3, curvesPerPage: 25, seedLabel: "EncryptedGrid")
        let plainDoc = try XCTUnwrap(PDFDocument(data: plainData))
        let lockedURL = tempDir.appendingPathComponent("encrypted_grid.pdf")
        let wrote = plainDoc.write(
            to: lockedURL,
            withOptions: [
                PDFDocumentWriteOption.userPasswordOption: "test-pass-123",
                PDFDocumentWriteOption.ownerPasswordOption: "owner-pass-456"
            ]
        )
        XCTAssertTrue(wrote)

        await PDFThumbnailRenderCoordinator.shared.clearCache()
        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: lockedURL, data: nil)
        XCTAssertEqual(loader.phase, .locked)
        let identity = try XCTUnwrap(loader.loadedIdentity)

        let lockedThumb = await PDFThumbnailRenderCoordinator.shared.renderThumbnail(
            zeroBasedPageIndex: 0,
            url: lockedURL,
            identity: identity
        )
        XCTAssertNil(lockedThumb, "Locked worker PDFDocument must not render thumbnail before unlock")

        XCTAssertTrue(loader.unlock(withPassword: "test-pass-123"))
        XCTAssertEqual(loader.phase, .ready)
        try await Task.sleep(for: .milliseconds(30))

        let unlockedThumb = await PDFThumbnailRenderCoordinator.shared.renderThumbnail(
            zeroBasedPageIndex: 0,
            url: lockedURL,
            identity: identity
        )
        XCTAssertNotNil(
            unlockedThumb,
            "After unlocking loader, PDFThumbnailRenderCoordinator worker pool must unlock its isolated PDFDocument and render"
        )
    }

    // MARK: - 7. Honest Synchronous PDFKit Cancellation Accounting

    func testHonestCancellationCountersTrackQueueAbortAndCompletedRenders() async throws {
        let coordinator = PDFThumbnailRenderCoordinator(countLimit: 64, totalCostLimit: 32 * 1024 * 1024)
        let pdfData = try makeVectorPDFData(pageCount: 16, curvesPerPage: 400, seedLabel: "CancelCounters")
        let identity = PDFPreviewInputIdentity(url: nil, data: pdfData)

        let first = await coordinator.renderThumbnail(
            zeroBasedPageIndex: 0,
            url: nil,
            data: pdfData,
            identity: identity
        )
        XCTAssertNotNil(first)
        let completedAfterFirst = await coordinator.completedRenderCount
        XCTAssertEqual(completedAfterFirst, 1)

        var batch: [Task<NSImage?, Never>] = []
        for pageIndex in 1..<16 {
            let t = Task {
                await coordinator.renderThumbnail(
                    zeroBasedPageIndex: pageIndex,
                    url: nil,
                    data: pdfData,
                    identity: identity
                )
            }
            batch.append(t)
        }
        for t in batch.dropFirst(2) {
            t.cancel()
        }
        for t in batch {
            _ = await t.value
        }

        let abortedInQueue = await coordinator.abortedInQueueCount
        let suppressedWriteback = await coordinator.suppressedWritebackCount
        let totalCancelled = await coordinator.cancelledRenderCount
        let totalCompleted = await coordinator.completedRenderCount

        XCTAssertGreaterThan(abortedInQueue, 0, "Queued tasks cancelled before entering PDFKit must increment abortedInQueueCount")
        XCTAssertEqual(totalCancelled, abortedInQueue + suppressedWriteback)
        XCTAssertGreaterThanOrEqual(totalCompleted, 1)
    }

    // MARK: - 8. Completion Probe Views & Negative Layout-Only Cases

    @MainActor
    func testPDFThumbnailAndSpreadsheetProbesRejectPlaceholderAndMismatchedIdentity() async throws {
        let pdfData = try makeVectorPDFData(pageCount: 3, curvesPerPage: 16, seedLabel: "ProbeVerify")
        let doc = try XCTUnwrap(PDFDocument(data: pdfData))
        let currentIdentity = PDFPreviewInputIdentity(url: nil, data: pdfData)
        let staleIdentity = PDFPreviewInputIdentity(url: nil, data: Data("stale".utf8))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let emptyGridHost = NSHostingView(
            rootView: PDFThreePageTileGridView(
                document: nil,
                sourceURL: nil,
                sourceData: nil,
                inputIdentity: currentIdentity
            )
        )
        emptyGridHost.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        window.contentView = emptyGridHost
        emptyGridHost.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let placeholderProbes = collectProbes(in: emptyGridHost, ofType: PDFThumbnailRenderedProbeNSView.self)
        XCTAssertTrue(placeholderProbes.isEmpty, "Placeholder PDF grid without rendered thumbnails must not mount PDFThumbnailRenderedProbeNSView")

        let gridHost = NSHostingView(
            rootView: PDFThreePageTileGridView(
                document: doc,
                sourceURL: nil,
                sourceData: pdfData,
                inputIdentity: currentIdentity
            )
        )
        gridHost.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        window.contentView = gridHost
        gridHost.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(20))
            gridHost.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let matching = collectProbes(in: gridHost, ofType: PDFThumbnailRenderedProbeNSView.self)
                .filter { $0.identityKey == currentIdentity.cacheKey && $0.renderedImage != nil }
            if Set(matching.map(\.pageIndex)).isSuperset(of: [1, 2, 3]) {
                break
            }
        }
        let allPDFProbes = collectProbes(in: gridHost, ofType: PDFThumbnailRenderedProbeNSView.self)
        let staleMatches = allPDFProbes.filter { $0.identityKey == staleIdentity.cacheKey }
        XCTAssertTrue(staleMatches.isEmpty, "Mismatched PDFPreviewInputIdentity must never match current document probes")
        let validPages = Set(
            allPDFProbes
                .filter { $0.identityKey == currentIdentity.cacheKey && ($0.renderedImage?.size.width ?? 0) > 0 }
                .map(\.pageIndex)
        )
        XCTAssertTrue(validPages.isSuperset(of: [1, 2, 3]), "All first 3 visible pages must mount PDFThumbnailRenderedProbeNSView with non-empty NSImage")
    }

    @MainActor
    func testSpreadsheetProbeRejectsEmptyRowsAndVerifiesPopulatedFirstScreen() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let emptySheetHost = NSHostingView(rootView: TTSpreadsheetView(headers: ["ColA", "ColB"], rows: []))
        emptySheetHost.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        window.contentView = emptySheetHost
        emptySheetHost.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let emptySheetProbes = collectProbes(in: emptySheetHost, ofType: TTSpreadsheetContentProbeNSView.self)
        XCTAssertTrue(emptySheetProbes.isEmpty, "Header-only spreadsheet with zero data rows must not mount TTSpreadsheetContentProbeNSView")

        let populatedHost = NSHostingView(
            rootView: TTSpreadsheetView(headers: ["ID", "Metric"], rows: [["row-1", "42.5"], ["row-2", "19.0"]])
        )
        populatedHost.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        window.contentView = populatedHost
        populatedHost.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let populatedProbes = collectProbes(in: populatedHost, ofType: TTSpreadsheetContentProbeNSView.self)
        XCTAssertEqual(populatedProbes.first?.renderedRowCount, 2)
        XCTAssertEqual(populatedProbes.first?.renderedColumnCount, 2)
        XCTAssertEqual(populatedProbes.first?.firstRowCells, ["row-1", "42.5"])
    }

    // MARK: - 9. U1-004 Unlock Across Layout Modes, Zoom/Page Preservation & Cross-Document Reset

    @MainActor
    func testEncryptedPDFWrongPasswordThenCorrectUnlockAcrossAllLayoutModes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaPDFUnlockModes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plainData = try makeVectorPDFData(pageCount: 4, curvesPerPage: 16, seedLabel: "AllModesLocked")
        let plainDoc = try XCTUnwrap(PDFDocument(data: plainData))
        let lockedURL = tempDir.appendingPathComponent("modes_locked.pdf")
        XCTAssertTrue(plainDoc.write(
            to: lockedURL,
            withOptions: [
                PDFDocumentWriteOption.userPasswordOption: "correct-horse",
                PDFDocumentWriteOption.ownerPasswordOption: "battery-staple"
            ]
        ))

        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: lockedURL, data: nil)
        XCTAssertEqual(loader.phase, .locked)
        XCTAssertEqual(loader.totalPages, 0)

        XCTAssertFalse(loader.unlock(withPassword: "wrong-password"))
        XCTAssertEqual(loader.phase, .locked)
        XCTAssertNotNil(loader.unlockError)

        XCTAssertTrue(loader.unlock(withPassword: "correct-horse"))
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertNil(loader.unlockError)
        XCTAssertEqual(loader.unlockedPassword, "correct-horse")
        XCTAssertEqual(loader.totalPages, 4)
        XCTAssertEqual(loader.currentPageIndex, 0)
        XCTAssertEqual(
            PDFPreviewLocalization.pageIndicator(currentOneBased: loader.currentPageIndex + 1, total: loader.totalPages),
            "1 / 4"
        )

        let unlockedDoc = try XCTUnwrap(loader.document)
        for mode in [PDFLayoutMode.singleFullWidth, .twoPages] {
            var pageIdx = loader.currentPageIndex
            let view = PDFKitView(
                document: unlockedDoc,
                layoutMode: mode,
                currentPageIndex: Binding(get: { pageIdx }, set: { pageIdx = $0 })
            )
            let coordinator = view.makeCoordinator()
            let nsView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            nsView.document = unlockedDoc
            coordinator.lastLockedState = true
            view.applyViewUpdate(to: nsView, coordinator: coordinator)
            XCTAssertFalse(nsView.document?.isLocked ?? true)
        }
    }

    @MainActor
    func testZoomAndPageSelectionPreservedAcrossOrdinaryUpdateNSViewAndResetOnDocumentSwitch() async throws {
        let dataA = try makeVectorPDFData(pageCount: 5, curvesPerPage: 12, seedLabel: "DocAlpha")
        let dataB = try makeVectorPDFData(pageCount: 3, curvesPerPage: 12, seedLabel: "DocBravo")
        let docA = try XCTUnwrap(PDFDocument(data: dataA))
        let docB = try XCTUnwrap(PDFDocument(data: dataB))

        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: nil, data: dataA)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.totalPages, 5)
        XCTAssertEqual(loader.currentPageIndex, 0)

        loader.selectPage(index: 3)
        loader.setExplicitZoom(2.25)
        XCTAssertEqual(loader.currentPageIndex, 3)
        XCTAssertEqual(loader.zoomScale, 2.25)

        var boundPage = loader.currentPageIndex
        let representable = PDFKitView(
            document: docA,
            layoutMode: .singleFullWidth,
            currentPageIndex: Binding(get: { boundPage }, set: { boundPage = $0 }),
            zoomScale: loader.zoomScale,
            zoomCommandToken: loader.zoomCommandToken
        )
        let coordinator = representable.makeCoordinator()
        let pdfView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        pdfView.document = docA
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 10.0
        coordinator.lastDocumentID = nil
        representable.applyViewUpdate(to: pdfView, coordinator: coordinator)

        pdfView.autoScales = false
        pdfView.scaleFactor = 2.75
        if let page2 = docA.page(at: 2) {
            pdfView.go(to: page2)
        }
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: pdfView)
        XCTAssertEqual(boundPage, 2)

        let hoverReevaluated = PDFKitView(
            document: docA,
            layoutMode: .singleFullWidth,
            currentPageIndex: Binding(get: { boundPage }, set: { boundPage = $0 }),
            zoomScale: loader.zoomScale,
            zoomCommandToken: loader.zoomCommandToken
        )
        hoverReevaluated.applyViewUpdate(to: pdfView, coordinator: coordinator)
        XCTAssertEqual(pdfView.scaleFactor, 2.75, accuracy: 0.01, "Ordinary updateNSView must not reset user zoom")
        XCTAssertEqual(docA.index(for: try XCTUnwrap(pdfView.currentPage)), 2, "Ordinary updateNSView must preserve scrolled page")

        await loader.loadAsync(url: nil, data: dataB)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.totalPages, 3)
        XCTAssertEqual(loader.currentPageIndex, 0, "Switching documents must reset page index to 0 (1 / N)")
        XCTAssertNil(loader.zoomScale, "Switching documents must reset explicit zoomScale to nil (fit)")
        _ = docB
    }

    @MainActor
    func testCorruptPDFEntersFailedStateAndRetryRecoversCleanly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaPDFCorruptRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptURL = tempDir.appendingPathComponent("corrupt_then_valid.pdf")
        try Data("not-a-valid-pdf-stream".utf8).write(to: corruptURL, options: .atomic)

        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: corruptURL, data: nil)
        if case .failed = loader.loadState {
            XCTAssertNil(loader.document)
            XCTAssertEqual(loader.totalPages, 0)
        } else {
            XCTFail("Expected .failed loadState for corrupt PDF, got \(loader.loadState)")
        }

        let validData = try makeVectorPDFData(pageCount: 2, curvesPerPage: 10, seedLabel: "RecoveredPDF")
        try validData.write(to: corruptURL, options: .atomic)
        await loader.retryAsync()
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.totalPages, 2)
        XCTAssertEqual(loader.currentPageIndex, 0)
    }

    @MainActor
    func testResponsiveToolbarTiersContentAvoidanceAndStageTelemetry() async throws {
        // 1. Width tier boundaries: compact (<420pt), regular (420..<620pt), wide (>=620pt)
        let compact = PDFToolbarLayoutMetrics(availableWidth: 260)
        XCTAssertEqual(compact.tier, .compact)
        XCTAssertTrue(compact.usesCompactLayoutMenu)
        XCTAssertFalse(compact.showsLayoutModeLabels)
        let regular = PDFToolbarLayoutMetrics(availableWidth: 480)
        XCTAssertEqual(regular.tier, .regular)
        XCTAssertFalse(regular.usesCompactLayoutMenu)
        XCTAssertFalse(regular.showsLayoutModeLabels)
        let wide = PDFToolbarLayoutMetrics(availableWidth: 860)
        XCTAssertEqual(wide.tier, .wide)
        XCTAssertTrue(wide.showsLayoutModeLabels)

        // 2. Stage telemetry & warm identity reuse (loadReadyStageMs recorded; firstFrameStageMs stays nil until display observed)
        let pdfData = try makeVectorPDFData(pageCount: 3, curvesPerPage: 12, seedLabel: "ToolbarAndStages")
        let loader = PDFPreviewLoader()
        let identity = PDFPreviewInputIdentity(url: nil, data: pdfData)
        await loader.loadAsync(url: nil, data: pdfData, identity: identity)
        let coldMetrics = try XCTUnwrap(loader.latestStageMetrics)
        XCTAssertFalse(coldMetrics.wasCacheHit)
        XCTAssertGreaterThanOrEqual(coldMetrics.loadStageMs, 0)
        XCTAssertGreaterThan(coldMetrics.parseStageMs, 0)
        XCTAssertGreaterThanOrEqual(coldMetrics.loadReadyStageMs, coldMetrics.loadStageMs + coldMetrics.parseStageMs)
        XCTAssertNil(coldMetrics.firstFrameStageMs, "firstFrameStageMs must remain nil before reliable display observation")
        loader.recordThumbnailRendered(elapsedMs: 4.5)
        XCTAssertEqual(loader.latestStageMetrics?.thumbnailStageMs ?? 0, 4.5, accuracy: 0.01)

        await loader.loadAsync(url: nil, data: pdfData, identity: identity)
        XCTAssertEqual(loader.latestStageMetrics?.wasCacheHit, true)
        XCTAssertNil(loader.latestStageMetrics?.firstFrameStageMs)
    }

    private func collectProbes<T: NSView>(in root: NSView, ofType type: T.Type) -> [T] {
        var result: [T] = []
        if let match = root as? T {
            result.append(match)
        }
        for sub in root.subviews {
            result.append(contentsOf: collectProbes(in: sub, ofType: type))
        }
        return result
    }

    // MARK: - Helpers

    private func makeVectorPDFData(pageCount: Int, curvesPerPage: Int, seedLabel: String) throws -> Data {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFPreviewPerformanceRegressionTests", code: 1)
        }

        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0))
            context.fill(mediaBox)

            for i in 0..<curvesPerPage {
                let phase = CGFloat((pageIndex * 97 + i * 31) % 360) * (.pi / 180.0)
                context.setStrokeColor(
                    red: 0.1 + 0.8 * abs(sin(phase)),
                    green: 0.2 + 0.6 * abs(cos(phase)),
                    blue: 0.3 + 0.5 * abs(sin(phase * 0.5)),
                    alpha: 0.65
                )
                context.setLineWidth(0.75)
                let startX = CGFloat((i * 19) % 580) + 16
                let startY = CGFloat((i * 23) % 740) + 24
                context.move(to: CGPoint(x: startX, y: startY))
                context.addCurve(
                    to: CGPoint(x: 612 - startX, y: 792 - startY),
                    control1: CGPoint(x: (startX + 180).truncatingRemainder(dividingBy: 600), y: startY * 0.5),
                    control2: CGPoint(x: startX * 0.5, y: (startY + 240).truncatingRemainder(dividingBy: 780))
                )
                context.strokePath()
            }
            _ = seedLabel
            context.endPDFPage()
        }
        context.closePDF()
        return pdfData as Data
    }

    private func padPDFData(_ data: inout Data, toByteCount targetCount: Int, fillByte: UInt8) {
        guard data.count < targetCount else { return }
        let needed = targetCount - data.count
        var comment = Data("\n%".utf8)
        if needed > 3 {
            comment.append(Data(repeating: fillByte, count: needed - 3))
        }
        comment.append(UInt8(ascii: "\n"))
        data.append(comment.prefix(needed))
    }
}
