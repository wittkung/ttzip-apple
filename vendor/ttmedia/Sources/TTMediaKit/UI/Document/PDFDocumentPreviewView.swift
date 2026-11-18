// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
@preconcurrency import PDFKit

public struct PDFKitView: NSViewRepresentable {
    public let document: PDFDocument?
    public let layoutMode: PDFLayoutMode
    public var currentPageIndex: Binding<Int>?
    public var zoomScale: CGFloat?
    public var zoomCommandToken: UInt64

    public init(url: URL, layoutMode: PDFLayoutMode) {
        self.document = PDFPreviewLoader.loadBudgetedDocument(url: url, data: nil)
        self.layoutMode = layoutMode
        self.currentPageIndex = nil
        self.zoomScale = nil
        self.zoomCommandToken = 0
    }

    public init(
        document: PDFDocument?,
        layoutMode: PDFLayoutMode,
        currentPageIndex: Binding<Int>? = nil,
        zoomScale: CGFloat? = nil,
        zoomCommandToken: UInt64 = 0
    ) {
        self.document = document
        self.layoutMode = layoutMode
        self.currentPageIndex = currentPageIndex
        self.zoomScale = zoomScale
        self.zoomCommandToken = zoomCommandToken
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> PDFView {
        let pdfView = InteractivePDFView()
        pdfView.document = document
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 10.0
        pdfView.interpolationQuality = .high
        pdfView.displaysPageBreaks = true
        pdfView.displayBox = .cropBox
        pdfView.wantsLayer = true
        pdfView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        configurePDFScrollView(pdfView)
        applyLayoutModeAndInitialFit(layoutMode, to: pdfView)
        syncRequestedPageAndZoom(to: pdfView, coordinator: context.coordinator, forceInitial: true)
        context.coordinator.bindNotifications(to: pdfView)
        return pdfView
    }

    public func updateNSView(_ nsView: PDFView, context: Context) {
        applyViewUpdate(to: nsView, coordinator: context.coordinator)
    }

    @MainActor
    public func applyViewUpdate(to nsView: PDFView, coordinator: Coordinator) {
        coordinator.parent = self
        coordinator.bindNotifications(to: nsView)
        let docID = document.map(ObjectIdentifier.init)
        let isLockedNow = document?.isLocked ?? false
        let docChanged = nsView.document !== document || coordinator.lastDocumentID != docID
        let unlockedTransition = coordinator.lastLockedState && !isLockedNow
        let layoutChanged = coordinator.lastLayoutMode != layoutMode
        let zoomTokenChanged = coordinator.lastZoomCommandToken != zoomCommandToken

        if nsView.document !== document {
            nsView.document = document
        }
        configurePDFScrollView(nsView)
        nsView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        if docChanged || unlockedTransition || layoutChanged {
            applyLayoutModeAndInitialFit(layoutMode, to: nsView)
            coordinator.lastDocumentID = docID
            coordinator.lastLockedState = isLockedNow
            coordinator.lastLayoutMode = layoutMode
        }

        if docChanged || unlockedTransition || zoomTokenChanged {
            applyExplicitZoom(zoomScale, to: nsView)
            coordinator.lastZoomCommandToken = zoomCommandToken
        }

        syncRequestedPageAndZoom(
            to: nsView,
            coordinator: coordinator,
            forceInitial: docChanged || unlockedTransition || layoutChanged
        )
    }

    @MainActor
    public final class Coordinator: NSObject {
        var parent: PDFKitView
        var lastDocumentID: ObjectIdentifier?
        var lastLockedState: Bool = false
        var lastLayoutMode: PDFLayoutMode?
        var lastZoomCommandToken: UInt64 = 0
        var lastKnownPageIndex: Int = 0
        var isUpdatingFromNotification: Bool = false
        private weak var observedView: PDFView?

        init(parent: PDFKitView) {
            self.parent = parent
            self.lastDocumentID = parent.document.map(ObjectIdentifier.init)
            self.lastLockedState = parent.document?.isLocked ?? false
            self.lastLayoutMode = parent.layoutMode
            self.lastZoomCommandToken = parent.zoomCommandToken
            self.lastKnownPageIndex = parent.currentPageIndex?.wrappedValue ?? 0
        }

        func bindNotifications(to pdfView: PDFView) {
            guard observedView !== pdfView else { return }
            NotificationCenter.default.removeObserver(self)
            observedView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePageChanged(_:)),
                name: .PDFViewPageChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScaleChanged(_:)),
                name: .PDFViewScaleChanged,
                object: pdfView
            )
        }

        @objc private func handlePageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let doc = pdfView.document,
                  let currentPage = pdfView.currentPage else {
                return
            }
            let idx = doc.index(for: currentPage)
            guard idx != NSNotFound, idx >= 0 else { return }
            lastKnownPageIndex = idx
            guard parent.currentPageIndex?.wrappedValue != idx else { return }
            isUpdatingFromNotification = true
            parent.currentPageIndex?.wrappedValue = idx
            isUpdatingFromNotification = false
        }

        @objc private func handleScaleChanged(_ notification: Notification) {
            // User-initiated pinch/magnify inside PDFView; Coordinator preserves this scale
            // by not re-running applyLayoutModeAndInitialFit on ordinary SwiftUI updates.
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    private func syncRequestedPageAndZoom(
        to pdfView: PDFView,
        coordinator: Coordinator,
        forceInitial: Bool
    ) {
        guard let doc = pdfView.document, !doc.isLocked, doc.pageCount > 0 else { return }
        let targetIndex = min(max(0, currentPageIndex?.wrappedValue ?? 0), doc.pageCount - 1)
        let shouldNavigate = forceInitial || (!coordinator.isUpdatingFromNotification && targetIndex != coordinator.lastKnownPageIndex)
        guard shouldNavigate, let targetPage = doc.page(at: targetIndex) else { return }
        coordinator.lastKnownPageIndex = targetIndex
        if pdfView.currentPage !== targetPage {
            pdfView.go(to: targetPage)
        }
    }

    private func applyExplicitZoom(_ explicitScale: CGFloat?, to pdfView: PDFView) {
        if let explicitScale {
            pdfView.autoScales = false
            pdfView.scaleFactor = min(max(explicitScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        } else {
            pdfView.autoScales = true
            pdfView.layoutDocumentView()
            let fitScale = pdfView.scaleFactorForSizeToFit
            if fitScale > 0 {
                pdfView.scaleFactor = fitScale
            }
        }
    }

    private func configurePDFScrollView(_ pdfView: PDFView) {
        if let scrollView = pdfView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
            scrollView.allowsMagnification = true
            scrollView.minMagnification = 0.25
            scrollView.maxMagnification = 10.0
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.verticalScroller?.scrollerStyle = .overlay
            scrollView.horizontalScroller?.scrollerStyle = .overlay
            scrollView.verticalScroller?.alphaValue = 0
            scrollView.horizontalScroller?.alphaValue = 0
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
        }
    }

    private func applyLayoutModeAndInitialFit(_ mode: PDFLayoutMode, to pdfView: PDFView) {
        switch mode {
        case .singleFullWidth:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.autoScales = true

        case .twoPages:
            pdfView.displayMode = .twoUpContinuous
            pdfView.displayDirection = .vertical
            pdfView.displaysAsBook = false
            pdfView.autoScales = true

        case .threePages:
            pdfView.displayMode = .twoUpContinuous
            pdfView.displayDirection = .vertical
            pdfView.displaysAsBook = true
            pdfView.autoScales = true
        }

        pdfView.layoutDocumentView()
        let fitScale = pdfView.scaleFactorForSizeToFit
        if fitScale > 0 {
            pdfView.scaleFactor = fitScale
        }
    }
}
