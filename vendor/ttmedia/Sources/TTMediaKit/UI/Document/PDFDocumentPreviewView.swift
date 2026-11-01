// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
@preconcurrency import PDFKit

// MARK: - Container View

public struct InteractivePDFPreviewContainerView: View {
    public let url: URL?
    public let data: Data?
    public let inputIdentity: PDFPreviewInputIdentity
    @State private var layoutMode: PDFLayoutMode = .singleFullWidth
    @State private var loader: PDFPreviewLoader
    @State private var passwordInput: String = ""

    @State private var containerWidth: CGFloat = 680

    public init(url: URL, loader: PDFPreviewLoader? = nil) {
        self.url = url
        self.data = nil
        self.inputIdentity = PDFPreviewInputIdentity(url: url, data: nil)
        self._loader = State(initialValue: loader ?? PDFPreviewLoader())
    }

    public init(data: Data, url: URL? = nil, loader: PDFPreviewLoader? = nil) {
        self.url = url
        self.data = data
        self.inputIdentity = PDFPreviewInputIdentity(url: url, data: data)
        self._loader = State(initialValue: loader ?? PDFPreviewLoader())
    }

    public var toolbarMetrics: PDFToolbarLayoutMetrics {
        PDFToolbarLayoutMetrics(availableWidth: containerWidth)
    }

    public var body: some View {
        VStack(spacing: 0) {
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if loader.phase == .ready || loader.phase == .locked {
                adaptiveBottomToolbar
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateContainerWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        updateContainerWidth(newWidth)
                    }
            }
        )
        .task(id: inputIdentity) {
            passwordInput = ""
            await loader.loadAsync(url: url, data: data, identity: inputIdentity)
        }
    }

    private func updateContainerWidth(_ width: CGFloat) {
        guard width > 1 else { return }
        if abs(width - containerWidth) > 0.5 {
            containerWidth = width
        }
    }

    private var adaptiveBottomToolbar: some View {
        let total = max(1, loader.totalPages)
        let currentOneBased = min(max(1, loader.currentPageIndex + 1), total)
        let canNavigate = loader.phase == .ready && loader.totalPages > 0
        return PDFAdaptiveToolbarView(
            metrics: toolbarMetrics,
            currentPageOneBased: currentOneBased,
            totalPages: total,
            canGoPrevious: canNavigate && loader.currentPageIndex > 0,
            canGoNext: canNavigate && (loader.currentPageIndex + 1 < loader.totalPages),
            layoutMode: layoutMode,
            onPreviousPage: {
                loader.selectPage(index: loader.currentPageIndex - 1)
            },
            onNextPage: {
                loader.selectPage(index: loader.currentPageIndex + 1)
            },
            onZoomOut: {
                let current = loader.zoomScale ?? 1.0
                loader.setExplicitZoom(max(0.25, current * 0.8))
            },
            onZoomFit: {
                loader.setExplicitZoom(nil)
            },
            onZoomIn: {
                let current = loader.zoomScale ?? 1.0
                loader.setExplicitZoom(min(10.0, current * 1.25))
            },
            onSelectLayoutMode: { newMode in
                withAnimation(TTMediaTheme.Motion.micro) {
                    layoutMode = newMode
                }
            }
        )
    }

    @ViewBuilder
    private var contentArea: some View {
        switch loader.phase {
        case .loading:
            VStack(spacing: TTMediaTheme.Spacing.md) {
                ProgressView()
                    .controlSize(.regular)
                Text(PDFPreviewLocalization.text(.loadingStream))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready, .locked:
            if let doc = loader.document {
                documentViewport(for: doc)
                    .onReceive(NotificationCenter.default.publisher(for: .PDFDocumentDidUnlock, object: doc)) { _ in
                        loader.syncLockState()
                    }
            }

        case .failed(let message):
            failedView(message: message)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: TTMediaTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.orange)
            Text(PDFPreviewLocalization.text(.loadFailedTitle))
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(action: { loader.retry() }) {
                Text(PDFPreviewLocalization.text(.retry))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func documentViewport(for doc: PDFDocument) -> some View {
        if loader.phase == .locked || doc.isLocked {
            PDFPasswordUnlockOverlayView(
                passwordInput: $passwordInput,
                errorMessage: loader.unlockError,
                onSubmit: {
                    if loader.unlock(withPassword: passwordInput) {
                        passwordInput = ""
                    }
                }
            )
        } else {
            switch layoutMode {
            case .singleFullWidth, .twoPages:
                PDFKitView(
                    document: doc,
                    layoutMode: layoutMode,
                    currentPageIndex: Binding(
                        get: { loader.currentPageIndex },
                        set: { loader.selectPage(index: $0) }
                    ),
                    zoomScale: loader.zoomScale,
                    zoomCommandToken: loader.zoomCommandToken
                )
            case .threePages:
                PDFThreePageTileGridView(
                    document: doc,
                    sourceURL: url,
                    sourceData: data,
                    inputIdentity: loader.loadedIdentity ?? inputIdentity,
                    unlockPassword: loader.unlockedPassword,
                    currentPageIndex: Binding(
                        get: { loader.currentPageIndex },
                        set: { loader.selectPage(index: $0) }
                    ),
                    onUnlocked: { loader.syncLockState() },
                    onThumbnailRendered: { elapsedMs in
                        loader.recordThumbnailRendered(elapsedMs: elapsedMs)
                    }
                )
            }
        }
    }
}

// MARK: - Three Page Grid View

public struct PDFThreePageTileGridView: View {
    public let document: PDFDocument?
    public let sourceURL: URL?
    public let sourceData: Data?
    public let inputIdentity: PDFPreviewInputIdentity?
    public var currentPageIndex: Binding<Int>?
    public var onUnlocked: (() -> Void)? = nil
    public var onThumbnailRendered: ((Double) -> Void)? = nil
    @State private var passwordInput: String = ""
    @State private var unlockedPassword: String? = nil
    @State private var unlockError: String? = nil
    @State private var internalSelectedPageIndex: Int = 0

    public init(url: URL, onUnlocked: (() -> Void)? = nil) {
        self.document = PDFPreviewLoader.loadBudgetedDocument(url: url, data: nil)
        self.sourceURL = url
        self.sourceData = nil
        self.inputIdentity = PDFPreviewInputIdentity(url: url, data: nil)
        self.currentPageIndex = nil
        self.onUnlocked = onUnlocked
        self.onThumbnailRendered = nil
    }

    public init(
        document: PDFDocument?,
        sourceURL: URL? = nil,
        sourceData: Data? = nil,
        inputIdentity: PDFPreviewInputIdentity? = nil,
        unlockPassword: String? = nil,
        currentPageIndex: Binding<Int>? = nil,
        onUnlocked: (() -> Void)? = nil,
        onThumbnailRendered: ((Double) -> Void)? = nil
    ) {
        self.document = document
        self.sourceURL = sourceURL ?? document?.documentURL
        self.sourceData = sourceData
        if let inputIdentity {
            self.inputIdentity = inputIdentity
        } else if let resolvedURL = sourceURL ?? document?.documentURL {
            self.inputIdentity = PDFPreviewInputIdentity(url: resolvedURL, data: sourceData)
        } else if let sourceData {
            self.inputIdentity = PDFPreviewInputIdentity(url: nil, data: sourceData)
        } else {
            self.inputIdentity = nil
        }
        self._unlockedPassword = State(initialValue: unlockPassword)
        self.currentPageIndex = currentPageIndex
        self.onUnlocked = onUnlocked
        self.onThumbnailRendered = onThumbnailRendered
    }

    private var activeZeroBasedPageIndex: Int {
        currentPageIndex?.wrappedValue ?? internalSelectedPageIndex
    }

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    public var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: true) {
                if let doc = document {
                    if doc.isLocked {
                        PDFPasswordUnlockOverlayView(
                            passwordInput: $passwordInput,
                            errorMessage: unlockError,
                            onSubmit: { unlockDocument(doc: doc) }
                        )
                    } else if doc.pageCount > 0 {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(0..<doc.pageCount, id: \.self) { pageIndex in
                                if let page = doc.page(at: pageIndex) {
                                    PDFPageThumbnailCard(
                                        page: page,
                                        pageIndex: pageIndex + 1,
                                        sourceURL: sourceURL,
                                        sourceData: sourceData,
                                        inputIdentity: inputIdentity,
                                        unlockPassword: unlockedPassword,
                                        isSelected: pageIndex == activeZeroBasedPageIndex,
                                        onThumbnailRendered: onThumbnailRendered
                                    )
                                    .id(pageIndex)
                                    .onTapGesture {
                                        internalSelectedPageIndex = pageIndex
                                        currentPageIndex?.wrappedValue = pageIndex
                                    }
                                }
                            }
                        }
                        .padding(6)
                        .onAppear {
                            if activeZeroBasedPageIndex > 0, activeZeroBasedPageIndex < doc.pageCount {
                                scrollProxy.scrollTo(activeZeroBasedPageIndex, anchor: .center)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text(PDFPreviewLocalization.text(.emptyPages))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(40)
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                } else {
                    VStack {
                        Spacer()
                        ProgressView(PDFPreviewLocalization.text(.loadingPDF))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
    }

    private func unlockDocument(doc: PDFDocument) {
        guard !passwordInput.isEmpty else {
            self.unlockError = PDFPreviewLocalization.text(.incorrectPassword)
            return
        }
        let entered = passwordInput
        if doc.unlock(withPassword: entered) {
            self.unlockError = nil
            self.unlockedPassword = entered
            self.passwordInput = ""
            let id = inputIdentity
            let url = sourceURL
            let data = sourceData
            Task {
                await PDFThumbnailRenderCoordinator.shared.registerUnlockPassword(
                    entered,
                    for: id,
                    url: url,
                    data: data
                )
            }
            onUnlocked?()
        } else {
            self.unlockError = PDFPreviewLocalization.text(.incorrectPassword)
        }
    }
}

// MARK: - Page Thumbnail Card

public struct PDFPageThumbnailCard: View {
    public let page: PDFPage
    public let pageIndex: Int
    public let sourceURL: URL?
    public let sourceData: Data?
    public let inputIdentity: PDFPreviewInputIdentity?
    public let unlockPassword: String?
    public let isSelected: Bool
    public var onThumbnailRendered: ((Double) -> Void)? = nil

    @State private var thumbnail: NSImage?
    @State private var measuredPointSize: CGSize = PDFThumbnailRenderCoordinator.defaultCardPointSize

    public init(
        page: PDFPage,
        pageIndex: Int,
        sourceURL: URL? = nil,
        sourceData: Data? = nil,
        inputIdentity: PDFPreviewInputIdentity? = nil,
        unlockPassword: String? = nil,
        isSelected: Bool = false,
        onThumbnailRendered: ((Double) -> Void)? = nil
    ) {
        self.page = page
        self.pageIndex = pageIndex
        self.sourceURL = sourceURL ?? page.document?.documentURL
        self.sourceData = sourceData
        self.inputIdentity = inputIdentity
        self.unlockPassword = unlockPassword
        self.isSelected = isSelected
        self.onThumbnailRendered = onThumbnailRendered
    }

    private var resolvedIdentityKey: String {
        inputIdentity?.cacheKey ?? sourceURL?.standardizedFileURL.absoluteString ?? ""
    }

    private var taskKey: String {
        let idKey = resolvedIdentityKey.isEmpty ? "page" : resolvedIdentityKey
        let bucketW = max(Int((measuredPointSize.width / 32).rounded()) * 32, 160)
        let bucketH = max(Int((measuredPointSize.height / 32).rounded()) * 32, 220)
        let unlockTag = unlockPassword == nil ? "locked" : "unlocked"
        return "\(idKey)#\(pageIndex)#\(bucketW)x\(bucketH)#\(unlockTag)"
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.white

                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .background(
                            PDFThumbnailRenderedProbeRepresentable(
                                identityKey: resolvedIdentityKey,
                                pageIndex: pageIndex,
                                renderedImage: img
                            )
                        )
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { updateMeasuredSize(proxy.size) }
                        .onChange(of: proxy.size) { _, newSize in updateMeasuredSize(newSize) }
                }
            )
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.md, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: TTMediaTheme.Radius.md, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : TTMediaTheme.Border.subtle,
                        lineWidth: isSelected ? 2.0 : 0.5
                    )
            )

            Text(PDFPreviewLocalization.pageTitle(pageIndex))
                .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .lineLimit(1)
        }
        .task(id: taskKey) {
            await loadThumbnailAsync()
        }
    }

    private func updateMeasuredSize(_ size: CGSize) {
        guard size.width > 16, size.height > 16 else { return }
        if abs(size.width - measuredPointSize.width) > 24 || abs(size.height - measuredPointSize.height) > 24 {
            measuredPointSize = size
        }
    }

    @MainActor
    private func loadThumbnailAsync() async {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let zeroBasedIndex = max(0, pageIndex - 1)
        let bounds = page.bounds(for: .cropBox)
        let aspect = bounds.height > 1 ? (bounds.width / bounds.height) : 0.75
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let fallbackDoc = page.document

        let rendered = await PDFThumbnailRenderCoordinator.shared.renderThumbnail(
            zeroBasedPageIndex: zeroBasedIndex,
            displayPointSize: measuredPointSize,
            scaleFactor: scale,
            pageAspectRatio: aspect,
            url: sourceURL,
            data: sourceData,
            identity: inputIdentity,
            unlockPassword: unlockPassword,
            fallbackDocumentDataProvider: { @MainActor in
                fallbackDoc?.dataRepresentation()
            }
        )
        guard !Task.isCancelled else { return }
        if let rendered {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000.0
            self.thumbnail = rendered
            onThumbnailRendered?(elapsedMs)
        }
    }
}

// MARK: - PDFKit NSViewRepresentable

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

// MARK: - Compatibility Aliases

public typealias PDFDocumentPreviewView = InteractivePDFPreviewContainerView
public typealias PDFKitRepresentedView = PDFKitView
