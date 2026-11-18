// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
@preconcurrency import PDFKit
import TTMediaKit
import TTZipUI

struct TTZipPDFPreviewView: View {
    private let url: URL?
    private let data: Data?
    let inputIdentity: PDFPreviewInputIdentity
    @State private var layoutMode: PDFLayoutMode = .singleFullWidth
    @State private var loader: PDFPreviewLoader
    @State private var passwordInput: String = ""

    @State private var containerWidth: CGFloat = 680

    init(url: URL, loader: PDFPreviewLoader? = nil) {
        self.url = url
        self.data = nil
        self.inputIdentity = PDFPreviewInputIdentity(url: url, data: nil)
        _loader = State(initialValue: loader ?? PDFPreviewLoader())
    }

    init(data: Data, url: URL?) {
        self.url = url
        self.data = data
        self.inputIdentity = PDFPreviewInputIdentity(url: url, data: data)
        _loader = State(initialValue: PDFPreviewLoader())
    }

    var body: some View {
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
        TTZipPDFToolbar(
            metrics: PDFToolbarLayoutMetrics(availableWidth: containerWidth),
            pagination: .init(
                currentIndex: loader.currentPageIndex,
                totalPages: loader.totalPages,
                canNavigate: loader.phase == .ready
            ),
            layoutMode: layoutMode,
            onAction: handleToolbarAction
        )
    }

    private func handleToolbarAction(_ action: TTZipPDFToolbar.Action) {
        switch action {
        case .previousPage:
            loader.selectPage(index: loader.currentPageIndex - 1)
        case .nextPage:
            loader.selectPage(index: loader.currentPageIndex + 1)
        case .zoomOut:
            loader.setExplicitZoom(max(0.25, (loader.zoomScale ?? 1) * 0.8))
        case .zoomFit:
            loader.setExplicitZoom(nil)
        case .zoomIn:
            loader.setExplicitZoom(min(10, (loader.zoomScale ?? 1) * 1.25))
        case .selectLayout(let mode):
            withAnimation(TTZipTheme.Motion.micro) {
                layoutMode = mode
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        switch loader.phase {
        case .loading:
            VStack(spacing: TTZipTheme.Spacing.md) {
                ProgressView()
                    .controlSize(.regular)
                Text(TTZipPDFPreviewLocalization.text(.loadingStream))
                    .font(.caption)
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
        VStack(spacing: TTZipTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.orange)
            Text(TTZipPDFPreviewLocalization.text(.loadFailedTitle))
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(action: { loader.retry() }) {
                Text(TTZipPDFPreviewLocalization.text(.retry))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(TTZipTheme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func documentViewport(for doc: PDFDocument) -> some View {
        if loader.phase == .locked || doc.isLocked {
            TTZipPDFPasswordUnlockView(
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
                TTZipPDFPageGrid(
                    document: doc,
                    sourceURL: url ?? doc.documentURL,
                    sourceData: data,
                    inputIdentity: loader.loadedIdentity ?? inputIdentity,
                    unlockPassword: loader.unlockedPassword,
                    currentPageIndex: Binding(
                        get: { loader.currentPageIndex },
                        set: { loader.selectPage(index: $0) }
                    ),
                    onThumbnailRendered: { elapsedMs in
                        loader.recordThumbnailRendered(elapsedMs: elapsedMs)
                    }
                )
            }
        }
    }
}
