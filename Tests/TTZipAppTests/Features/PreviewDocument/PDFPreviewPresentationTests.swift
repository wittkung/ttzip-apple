// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
@preconcurrency import PDFKit
import SwiftUI
import TTI18nCore
import TTI18nUI
import TTMediaKit
@testable import TTZipApp
@testable import TTZipPreviewKit
import TTZipUI
import XCTest

final class PDFPreviewPresentationTests: XCTestCase {
    @MainActor
    func testStoredInputIdentityDoesNotRehashAndPreservesEqualLengthDistinction() async throws {
        var dataA = try makePDFData(pageCount: 2)
        var dataB = dataA
        let paddedSize = 2 * 1024 * 1024
        padPDFData(&dataA, toByteCount: paddedSize, fillByte: UInt8(ascii: "A"))
        padPDFData(&dataB, toByteCount: paddedSize, fillByte: UInt8(ascii: "B"))
        XCTAssertEqual(dataA.count, dataB.count)

        let previewA = TTZipPDFPreviewView(data: dataA, url: nil)
        let previewB = TTZipPDFPreviewView(data: dataB, url: nil)
        XCTAssertNotEqual(previewA.inputIdentity, previewB.inputIdentity)
        XCTAssertEqual(previewA.inputIdentity.dataByteCount, paddedSize)

        let start = ContinuousClock.now
        for _ in 0..<10_000 {
            XCTAssertEqual(previewA.inputIdentity.cacheKey, previewA.inputIdentity.cacheKey)
        }
        XCTAssertLessThan(
            start.duration(to: .now),
            .milliseconds(50),
            "10,000 stored inputIdentity accesses should take < 50 ms without re-hashing 2 MB Data"
        )

        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: nil, data: dataA, identity: previewA.inputIdentity)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.currentIdentity, previewA.inputIdentity)
        let firstGeneration = loader.activeGeneration

        await loader.loadAsync(url: nil, data: dataA, identity: previewA.inputIdentity)
        XCTAssertEqual(loader.activeGeneration, firstGeneration, "Identical stored identity must not reload")

        await loader.loadAsync(url: nil, data: dataB, identity: previewB.inputIdentity)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.currentIdentity, previewB.inputIdentity)
        XCTAssertGreaterThan(loader.activeGeneration, firstGeneration)
    }

    @MainActor
    func testProductPDFPreviewMountsNativeSingleAndTwoPageViews() async throws {
        let pdfData = try makePDFData(pageCount: 9)
        let directory = try makeTemporaryDirectory(prefix: "PDFPresentation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.pdf")
        try pdfData.write(to: url)
        let loader = PDFPreviewLoader()
        let window = makeHiddenWindow()
        defer {
            window.contentView = nil
            window.close()
        }

        let singleHost = mount(TTZipPDFPreviewView(url: url, loader: loader), in: window)
        try await waitForLayout(in: window) {
            loader.phase == .ready && descendants(in: singleHost, ofType: PDFView.self).first?.document != nil
        }
        let document = try XCTUnwrap(loader.document)
        let single = try XCTUnwrap(descendants(in: singleHost, ofType: PDFView.self).first)
        XCTAssertTrue(single.document === document)
        XCTAssertEqual(single.document?.pageCount, 9)
        XCTAssertEqual(single.displayMode, .singlePageContinuous)
        XCTAssertEqual(descendants(in: singleHost, ofType: PDFToolbarStateProbeNSView.self).first?.totalPages, 9)

        let twoPageHost = mount(PDFKitView(document: document, layoutMode: .twoPages), in: window)
        try await waitForLayout(in: window) {
            descendants(in: twoPageHost, ofType: PDFView.self).first?.document === document
        }
        let twoPages = try XCTUnwrap(descendants(in: twoPageHost, ofType: PDFView.self).first)
        XCTAssertEqual(twoPages.displayMode, .twoUpContinuous)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testProductPDFGridVerifiesRenderedImagesIdentityAndScroll() async throws {
        let pdfData = try makePDFData(pageCount: 9)
        let document = try XCTUnwrap(PDFDocument(data: pdfData))
        let identity = PDFPreviewInputIdentity(url: nil, data: pdfData)
        let staleIdentity = PDFPreviewInputIdentity(url: nil, data: Data("stale".utf8))
        let window = makeHiddenWindow()
        defer {
            window.contentView = nil
            window.close()
        }

        let emptyHost = mount(makeObservedGrid(document: PDFDocument(), data: nil, identity: identity), in: window)
        XCTAssertTrue(descendants(in: emptyHost, ofType: TTZipPDFRenderedThumbnailProbeNSView.self).isEmpty)

        let gridHost = mount(makeObservedGrid(document: document, data: pdfData, identity: identity), in: window)
        try await waitForLayout(in: window) {
            let probes = descendants(in: gridHost, ofType: TTZipPDFRenderedThumbnailProbeNSView.self)
            return renderedPages(in: probes, identity: identity).isSuperset(of: [1, 2, 3])
        }
        let probes = descendants(in: gridHost, ofType: TTZipPDFRenderedThumbnailProbeNSView.self)
        XCTAssertFalse(probes.contains { $0.identityKey == staleIdentity.cacheKey })
        XCTAssertTrue(renderedPages(in: probes, identity: identity).isSuperset(of: [1, 2, 3]))

        let scrollView = try XCTUnwrap(descendants(in: gridHost, ofType: NSScrollView.self).first)
        let clip = scrollView.contentView
        let initialY = clip.bounds.minY
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: initialY + 320))
        scrollView.reflectScrolledClipView(clip)
        gridHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(clip.bounds.minY, initialY)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testProductPDFPreviewCopyUsesSharedTTI18nState() {
        let state = LocalizationState.shared
        let original = state.currentLanguage
        defer { state.setLanguage(original) }

        for key in TTZipPDFPreviewLocaleKey.allCases {
            for lang in [AppLanguage.en, .zhHans, .zhHant] {
                let text = key.fallbackTranslation(for: lang)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key.rawKey)
            }
        }

        state.setLanguage(.zhHans)
        XCTAssertEqual(TTZipPDFPreviewLocalization.text(.loadFailedTitle), "无法加载 PDF 文档")
        XCTAssertEqual(TTZipPDFPreviewLocalization.pageTitle(3), "第 3 页")
        XCTAssertEqual(PDFLayoutMode.twoPages.localizedTitle, "双页")

        state.setLanguage(.zhHant)
        XCTAssertEqual(TTZipPDFPreviewLocalization.text(.enterPassword), "輸入密碼")
        XCTAssertEqual(TTZipPDFPreviewLocalization.pageTitle(3), "第 3 頁")

        state.setLanguage(.en)
        XCTAssertEqual(TTZipPDFPreviewLocalization.text(.loadFailedTitle), "Unable to load PDF document")
        XCTAssertEqual(TTZipPDFPreviewLocalization.pageTitle(3), "Page 3")
        XCTAssertEqual(TTZipPDFPreviewLocalization.pageIndicator(currentOneBased: 1, total: 4), "1 / 4")
        XCTAssertEqual(TTZipPDFPreviewLocalization.pageIndicator(currentOneBased: 0, total: 0), "1 / 1")
    }

    func testProductPDFToolbarWidthTiers() {
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
    }

    @MainActor
    func testProductPDFToolbarButtonsAvoidTrailingReservation() throws {
        let unreserved = toolbarHost(width: 300, reservedWidth: 0, currentIndex: 0, totalPages: 4)
        let reserved = toolbarHost(width: 300, reservedWidth: 34, currentIndex: 0, totalPages: 4)
        let unreservedMaxX = try XCTUnwrap(buttonBounds(in: unreserved).map(\.maxX).max())
        let reservedMaxX = try XCTUnwrap(buttonBounds(in: reserved).map(\.maxX).max())
        XCTAssertLessThanOrEqual(reservedMaxX, unreservedMaxX - 34 + 0.5)
        XCTAssertLessThanOrEqual(reservedMaxX, 300 - 34)

        let narrowMetrics = PDFToolbarLayoutMetrics(availableWidth: 260, reservedTrailingWidth: 54)
        XCTAssertEqual(narrowMetrics.effectiveAvailableWidth, 206)
        XCTAssertTrue(narrowMetrics.usesCompactZoomMenu)

        let narrow = toolbarHost(width: 260, reservedWidth: 54, currentIndex: 11, totalPages: 99)
        let narrowBounds = buttonBounds(in: narrow)
        let narrowMinX = try XCTUnwrap(narrowBounds.map(\.minX).min())
        let narrowMaxX = try XCTUnwrap(narrowBounds.map(\.maxX).max())
        XCTAssertGreaterThanOrEqual(narrowMinX, 0)
        XCTAssertLessThanOrEqual(narrowMaxX, 260 - 54 + 0.5)
    }

    @MainActor
    private func toolbarHost(width: CGFloat, reservedWidth: CGFloat, currentIndex: Int, totalPages: Int) -> NSView {
        let toolbar = TTZipPDFToolbar(
            metrics: PDFToolbarLayoutMetrics(availableWidth: width),
            pagination: .init(currentIndex: currentIndex, totalPages: totalPages, canNavigate: true),
            layoutMode: .singleFullWidth,
            onAction: { _ in }
        )
        let host = NSHostingView(rootView: toolbar.environment(\.previewBottomTrailingReservedWidth, reservedWidth))
        host.frame = NSRect(x: 0, y: 0, width: width, height: PDFToolbarLayoutMetrics.barHeight)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func buttonBounds(in host: NSView) -> [NSRect] {
        descendants(in: host, ofType: NSButton.self).map { $0.convert($0.bounds, to: host) }
    }

    @MainActor
    private func makeObservedGrid(
        document: PDFDocument,
        data: Data?,
        identity: PDFPreviewInputIdentity
    ) -> TTZipPDFPageGrid {
        TTZipPDFPageGrid(
            document: document,
            sourceURL: nil,
            sourceData: data,
            inputIdentity: identity,
            unlockPassword: nil,
            currentPageIndex: .constant(0),
            onThumbnailRendered: { _ in },
            observesRenderedThumbnails: true
        )
    }

    @MainActor
    private func renderedPages(
        in probes: [TTZipPDFRenderedThumbnailProbeNSView],
        identity: PDFPreviewInputIdentity
    ) -> Set<Int> {
        Set(probes.compactMap { probe in
            guard probe.identityKey == identity.cacheKey, let image = probe.renderedImage,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  cgImage.width > 0, cgImage.height > 0 else { return nil }
            return probe.pageIndex
        })
    }

    @MainActor
    private func makeHiddenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private func mount<Content: View>(_ content: Content, in window: NSWindow) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func waitForLayout(in window: NSWindow, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func descendants<T: NSView>(in root: NSView, ofType type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants(in: $0, ofType: type) }
    }

    private func makePDFData(pageCount: Int) throws -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(red: CGFloat(page + 1) / CGFloat(pageCount), green: 0.3, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: 32, y: 32, width: 200, height: 400))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func padPDFData(_ data: inout Data, toByteCount targetCount: Int, fillByte: UInt8) {
        let count = targetCount - data.count
        data.append(Data("\n%".utf8))
        data.append(Data(repeating: fillByte, count: count - 3))
        data.append(0x0A)
    }

    @MainActor
    func testProductPDFAccentMatchesProductThemeInInspectorAndStandalone() async throws {
        let directory = try makeTemporaryDirectory(prefix: "PDFAccentSurface")
        defer { try? FileManager.default.removeItem(at: directory) }
        let plainURL = directory.appendingPathComponent("plain-grid.pdf")
        let lockedURL = directory.appendingPathComponent("locked-unlock.pdf")
        try makeNeutralPDFData(pageCount: 3).write(to: plainURL)
        try makeEncryptedNeutralPDFData(pageCount: 2, password: "fixture-password").write(to: lockedURL)

        var mismatches: [String] = []
        var summaryRows = ["surface\ttheme\tcontrol\tr\tg\tb\tchroma\tgreen_dominant"]
        for surface in PreviewSurfaceKind.allCases {
            for theme in WindowThemeCase.allCases {
                try await verifyGridAccent(
                    pdfURL: plainURL, surface: surface, theme: theme,
                    mismatches: &mismatches, summaryRows: &summaryRows
                )
                try await verifyUnlockAccent(
                    pdfURL: lockedURL, surface: surface, theme: theme,
                    mismatches: &mismatches, summaryRows: &summaryRows
                )
            }
        }
        try writeAccentSummaryIfRequested(rows: summaryRows)
        XCTAssertTrue(mismatches.isEmpty, "\n" + mismatches.joined(separator: "\n"))
    }

    private enum PreviewSurfaceKind: String, CaseIterable {
        case inspector
        case standalone

        var windowSize: NSSize {
            self == .inspector ? NSSize(width: 320, height: 680) : NSSize(width: 860, height: 640)
        }
    }

    private enum WindowThemeCase: String, CaseIterable {
        case light
        case dark

        var appearanceName: NSAppearance.Name {
            self == .light ? .aqua : .darkAqua
        }
    }

    private struct SampledSRGB: CustomStringConvertible {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        var chroma: CGFloat {
            max(red, green, blue) - min(red, green, blue)
        }

        var isBambooGreenDominant: Bool {
            chroma > 0.06 && green > red && (green - blue) > 0.04
        }

        var description: String {
            String(format: "sRGB(%.3f, %.3f, %.3f, chroma=%.3f)", red, green, blue, chroma)
        }

        func tsvRow(surface: PreviewSurfaceKind, theme: WindowThemeCase, control: String) -> String {
            String(
                format: "%@\t%@\t%@\t%.4f\t%.4f\t%.4f\t%.4f\t%@",
                surface.rawValue, theme.rawValue, control, red, green, blue, chroma,
                isBambooGreenDominant ? "true" : "false"
            )
        }
    }

    @MainActor
    private func verifyGridAccent(
        pdfURL: URL,
        surface: PreviewSurfaceKind,
        theme: WindowThemeCase,
        mismatches: inout [String],
        summaryRows: inout [String]
    ) async throws {
        let gridSize = surface == .inspector ? NSSize(width: 304, height: 420) : surface.windowSize
        let window = makeThemedWindow(size: gridSize, theme: theme)
        defer { window.contentView = nil; window.close() }
        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        let identity = PDFPreviewInputIdentity(url: pdfURL, data: nil)
        let host = mountGridWorkspace(
            document: document, pdfURL: pdfURL, identity: identity, size: gridSize, surface: surface, in: window
        )
        try await waitForLayout(in: window) {
            let probes = descendants(in: host, ofType: TTZipPDFRenderedThumbnailProbeNSView.self)
            return renderedPages(in: probes, identity: identity).isSuperset(of: [1, 2, 3])
                && descendants(in: host, ofType: PDFToolbarStateProbeNSView.self).first != nil
        }

        let gridDoc = try XCTUnwrap(leafGridDocumentView(in: host))
        let gridBitmap = try captureBitmap(of: gridDoc)
        let hostBitmap = try captureBitmap(of: host)
        try writeDiagnosticPNGIfRequested(bitmap: hostBitmap, name: "\(surface.rawValue)-\(theme.rawValue)-grid.png")

        let docW = gridDoc.bounds.width
        let cardH = ((docW - 20) / 3) / 0.75
        let border = chromaticMeanFromTopRect(
            in: gridBitmap, pointSize: gridDoc.bounds.size,
            topRect: NSRect(x: 0, y: 6 + cardH * 0.25, width: docW / 3, height: cardH * 0.50)
        )
        let title = chromaticMeanFromTopRect(
            in: gridBitmap, pointSize: gridDoc.bounds.size,
            topRect: NSRect(x: 0, y: 6 + cardH + 2, width: docW / 3, height: 22)
        )
        let unselected = chromaticMeanFromTopRect(
            in: gridBitmap, pointSize: gridDoc.bounds.size,
            topRect: NSRect(x: docW / 3, y: 6 + cardH * 0.25, width: docW / 3, height: cardH * 0.75 + 22)
        )
        let toolbar = try sampleToolbarAccent(in: hostBitmap, host: host)

        summaryRows.append(border.tsvRow(surface: surface, theme: theme, control: "grid_selected_border"))
        summaryRows.append(title.tsvRow(surface: surface, theme: theme, control: "grid_selected_title"))
        summaryRows.append(unselected.tsvRow(surface: surface, theme: theme, control: "grid_unselected_card"))
        summaryRows.append(toolbar.tsvRow(surface: surface, theme: theme, control: "toolbar_layout_accent"))

        let tag = "[\(surface.rawValue)/\(theme.rawValue)]"
        if !border.isBambooGreenDominant {
            mismatches.append("\(tag) grid selected border rendered \(border), expected bamboo green (toolbar=\(toolbar))")
        }
        if !title.isBambooGreenDominant {
            mismatches.append("\(tag) grid selected page title rendered \(title), expected bamboo green (toolbar=\(toolbar))")
        }
        if unselected.chroma >= 0.08 {
            mismatches.append("\(tag) unselected grid card unexpectedly tinted \(unselected)")
        }
        if surface == .standalone && !toolbar.isBambooGreenDominant {
            mismatches.append("\(tag) wide toolbar layout accent \(toolbar) was not bamboo green")
        }
        if surface == .inspector && toolbar.chroma >= 0.08 {
            mismatches.append("\(tag) compact toolbar menu unexpectedly tinted \(toolbar)")
        }
    }

    @MainActor
    private func verifyUnlockAccent(
        pdfURL: URL,
        surface: PreviewSurfaceKind,
        theme: WindowThemeCase,
        mismatches: inout [String],
        summaryRows: inout [String]
    ) async throws {
        let window = makeThemedWindow(size: surface.windowSize, theme: theme)
        defer { window.contentView = nil; window.close() }
        let host = mountSurfaceHost(pdfURL: pdfURL, surface: surface, in: window)
        try await waitForLayout(in: window) {
            descendants(in: host, ofType: NSSecureTextField.self).first != nil
                && descendants(in: host, ofType: PDFToolbarStateProbeNSView.self).first != nil
        }

        let secureField = try XCTUnwrap(descendants(in: host, ofType: NSSecureTextField.self).first)
        let hostBitmap = try captureBitmap(of: host)
        try writeDiagnosticPNGIfRequested(bitmap: hostBitmap, name: "\(surface.rawValue)-\(theme.rawValue)-unlock.png")

        let fieldRect = secureField.convert(secureField.bounds, to: host)
        let unlockRect = NSRect(
            x: fieldRect.maxX + 4,
            y: fieldRect.minY - 6,
            width: max(24, min(96, host.bounds.maxX - fieldRect.maxX - 4)),
            height: fieldRect.height + 12
        )
        let unlock = chromaticMeanFromViewRect(in: hostBitmap, view: host, viewRect: unlockRect)
        summaryRows.append(unlock.tsvRow(surface: surface, theme: theme, control: "password_unlock_button"))
        if !unlock.isBambooGreenDominant {
            mismatches.append("[\(surface.rawValue)/\(theme.rawValue)] password unlock button rendered \(unlock), expected bamboo green")
        }
    }

    @MainActor
    private func makeThemedWindow(size: NSSize, theme: WindowThemeCase) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme.appearanceName)
        return window
    }

    @MainActor
    private func mountSurfaceHost(pdfURL: URL, surface: PreviewSurfaceKind, in window: NSWindow) -> NSView {
        let host: NSView
        switch surface {
        case .inspector:
            let view = ExplorerItemInspectorView(
                item: DiskItemInfo(url: pdfURL),
                onSelectArchive: { _ in },
                onCompressPath: { _ in },
                onPreviewFile: { _ in }
            )
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            host = hosting
        case .standalone:
            let item = ImmersiveMediaItem(url: pdfURL, name: pdfURL.lastPathComponent)
            host = StandalonePreviewWindowContent.makeHostingView(item: item, onReturn: {}, onClose: {})
        }
        host.frame = NSRect(origin: .zero, size: surface.windowSize)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return host
    }

    @MainActor
    private func mountGridWorkspace(
        document: PDFDocument,
        pdfURL: URL,
        identity: PDFPreviewInputIdentity,
        size: NSSize,
        surface: PreviewSurfaceKind,
        in window: NSWindow
    ) -> NSView {
        let workspace = VStack(spacing: 0) {
            TTZipPDFPageGrid(
                document: document,
                sourceURL: pdfURL,
                sourceData: nil,
                inputIdentity: identity,
                unlockPassword: nil,
                currentPageIndex: .constant(0),
                onThumbnailRendered: { _ in },
                observesRenderedThumbnails: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TTZipPDFToolbar(
                metrics: PDFToolbarLayoutMetrics(availableWidth: size.width),
                pagination: .init(currentIndex: 0, totalPages: document.pageCount, canNavigate: true),
                layoutMode: .threePages,
                onAction: { _ in }
            )
        }
        .environment(\.isImmersiveFullscreen, surface == .standalone)
        .environment(\.previewBottomTrailingReservedWidth, 34.0)
        .environment(
            \.previewHostContentGeometry,
            TTPreviewHostContentGeometry(
                layoutClass: .structuredDocument,
                hostHeaderHeight: 0,
                contentTopSafeInset: 0,
                availableSize: size,
                isStandalonePlaybackWindow: false
            )
        )
        let host = NSHostingView(rootView: workspace)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return host
    }

    @MainActor
    private func leafGridDocumentView(in host: NSView) -> NSView? {
        let scrolls = allScrollViews(in: host)
        let leaf = scrolls.last { candidate in
            candidate.subviews.flatMap { allScrollViews(in: $0) }.isEmpty
        }
        return leaf?.documentView
    }

    @MainActor
    private func allScrollViews(in root: NSView) -> [NSScrollView] {
        let current = (root as? NSScrollView).map { [$0] } ?? []
        return current + root.subviews.flatMap { allScrollViews(in: $0) }
    }

    @MainActor
    private func sampleToolbarAccent(in hostBitmap: NSBitmapImageRep, host: NSView) throws -> SampledSRGB {
        let probe = try XCTUnwrap(descendants(in: host, ofType: PDFToolbarStateProbeNSView.self).first)
        let probeCenter = probe.convert(NSPoint.zero, to: host)
        let barRect = NSRect(x: host.bounds.midX, y: probeCenter.y - 14, width: host.bounds.width * 0.5, height: 28)
        return chromaticMeanFromViewRect(in: hostBitmap, view: host, viewRect: barRect)
    }

    @MainActor
    private func captureBitmap(of view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func chromaticMeanFromViewRect(
        in bitmap: NSBitmapImageRep,
        view: NSView,
        viewRect: NSRect
    ) -> SampledSRGB {
        let topY = view.isFlipped ? (viewRect.minY - view.bounds.minY) : (view.bounds.maxY - viewRect.maxY)
        let topRect = NSRect(x: viewRect.minX - view.bounds.minX, y: topY, width: viewRect.width, height: viewRect.height)
        return chromaticMeanFromTopRect(in: bitmap, pointSize: view.bounds.size, topRect: topRect)
    }

    private func chromaticMeanFromTopRect(
        in bitmap: NSBitmapImageRep,
        pointSize: NSSize,
        topRect: NSRect
    ) -> SampledSRGB {
        guard pointSize.width > 0, pointSize.height > 0 else {
            return SampledSRGB(red: 0, green: 0, blue: 0)
        }
        let scaleX = CGFloat(bitmap.pixelsWide) / pointSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / pointSize.height
        let minX = max(0, min(bitmap.pixelsWide - 1, Int((topRect.minX * scaleX).rounded(.down))))
        let maxX = max(minX, min(bitmap.pixelsWide - 1, Int((topRect.maxX * scaleX).rounded(.up))))
        let minY = max(0, min(bitmap.pixelsHigh - 1, Int((topRect.minY * scaleY).rounded(.down))))
        let maxY = max(minY, min(bitmap.pixelsHigh - 1, Int((topRect.maxY * scaleY).rounded(.up))))
        var redSum: CGFloat = 0, greenSum: CGFloat = 0, blueSum: CGFloat = 0, count: CGFloat = 0
        for py in minY...maxY {
            for px in minX...maxX {
                guard let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let candidate = SampledSRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
                if candidate.chroma >= 0.08 {
                    redSum += candidate.red; greenSum += candidate.green; blueSum += candidate.blue; count += 1
                }
            }
        }
        guard count > 0 else { return SampledSRGB(red: 0, green: 0, blue: 0) }
        return SampledSRGB(red: redSum / count, green: greenSum / count, blue: blueSum / count)
    }

    private func diagnosticOutputDirectory() throws -> URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["TTZIP_EXPORT_PDF_ACCENT_DIAG"] == "1" else { return nil }
        let root = env["TEST_UNDECLARED_OUTPUTS_DIR"] ?? NSTemporaryDirectory()
        let directoryURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("pdf-accent-diag", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeDiagnosticPNGIfRequested(bitmap: NSBitmapImageRep, name: String) throws {
        guard let directoryURL = try diagnosticOutputDirectory() else { return }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directoryURL.appendingPathComponent(name))
    }

    private func writeAccentSummaryIfRequested(rows: [String]) throws {
        guard let directoryURL = try diagnosticOutputDirectory() else { return }
        let content = rows.joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: directoryURL.appendingPathComponent("summary.tsv"))
    }

    private func makeNeutralPDFData(pageCount: Int) throws -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.96, alpha: 1.0)
            context.fill(bounds)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func makeEncryptedNeutralPDFData(pageCount: Int, password: String) throws -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let options = [
            kCGPDFContextUserPassword as String: password,
            kCGPDFContextOwnerPassword as String: "\(password)-owner",
        ]
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, options as CFDictionary))
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.96, alpha: 1.0)
            context.fill(bounds)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
