// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
@preconcurrency import PDFKit
import TTMediaKit
import TTZipUI

struct TTZipPDFPageGrid: View {
    let document: PDFDocument
    let sourceURL: URL?
    let sourceData: Data?
    let inputIdentity: PDFPreviewInputIdentity
    let unlockPassword: String?
    @Binding var currentPageIndex: Int
    let onThumbnailRendered: (Double) -> Void

    var observesRenderedThumbnails = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(0..<document.pageCount, id: \.self) { pageIndex in
                        if let page = document.page(at: pageIndex) {
                            TTZipPDFPageCard(
                                page: page,
                                pageIndex: pageIndex,
                                sourceURL: sourceURL,
                                sourceData: sourceData,
                                inputIdentity: inputIdentity,
                                unlockPassword: unlockPassword,
                                isSelected: pageIndex == currentPageIndex,
                                onThumbnailRendered: onThumbnailRendered,
                                observesRenderedThumbnails: observesRenderedThumbnails
                            )
                            .id(pageIndex)
                            .onTapGesture { currentPageIndex = pageIndex }
                        }
                    }
                }
                .padding(6)
                .onAppear {
                    if currentPageIndex > 0, currentPageIndex < document.pageCount {
                        scrollProxy.scrollTo(currentPageIndex, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct TTZipPDFPageCard: View {
    let page: PDFPage
    let pageIndex: Int
    let sourceURL: URL?
    let sourceData: Data?
    let inputIdentity: PDFPreviewInputIdentity
    let unlockPassword: String?
    let isSelected: Bool
    let onThumbnailRendered: (Double) -> Void

    let observesRenderedThumbnails: Bool

    @State private var thumbnail: RenderedThumbnail?
    @State private var measuredPointSize = PDFThumbnailRenderCoordinator.defaultCardPointSize

    private struct RenderedThumbnail {
        let image: NSImage
        let identityKey: String
        let pageIndex: Int
    }

    private var taskKey: String {
        let bucketWidth = max(Int((measuredPointSize.width / 32).rounded()) * 32, 160)
        let bucketHeight = max(Int((measuredPointSize.height / 32).rounded()) * 32, 220)
        let unlockTag = unlockPassword == nil ? "locked" : "unlocked"
        return "\(inputIdentity.cacheKey)#\(pageIndex)#\(bucketWidth)x\(bucketHeight)#\(unlockTag)"
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.white

                if let thumbnail {
                    Image(nsImage: thumbnail.image)
                        .resizable()
                        .scaledToFit()
                        .background {
                            if observesRenderedThumbnails {
                                TTZipPDFRenderedThumbnailProbe(
                                    identityKey: thumbnail.identityKey,
                                    pageIndex: thumbnail.pageIndex,
                                    renderedImage: thumbnail.image
                                )
                            }
                        }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { updateMeasuredSize(proxy.size) }
                        .onChange(of: proxy.size) { _, size in updateMeasuredSize(size) }
                }
            )
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.md, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: TTZipTheme.Radius.md, style: .continuous)
                    .strokeBorder(
                        isSelected ? TTZipTheme.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 2 : TTZipTheme.Layout.hairlineBorderWidth
                    )
            )

            Text(TTZipPDFPreviewLocalization.pageTitle(pageIndex + 1))
                .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? TTZipTheme.accentColor : .secondary)
                .lineLimit(1)
        }
        .task(id: taskKey) {
            await loadThumbnail()
        }
    }

    private func updateMeasuredSize(_ size: CGSize) {
        guard size.width > 16, size.height > 16 else { return }
        if abs(size.width - measuredPointSize.width) > 24 || abs(size.height - measuredPointSize.height) > 24 {
            measuredPointSize = size
        }
    }

    private func loadThumbnail() async {
        let start = DispatchTime.now().uptimeNanoseconds
        let bounds = page.bounds(for: .cropBox)
        let aspect = bounds.height > 1 ? bounds.width / bounds.height : 0.75
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let fallbackDocument = page.document
        let rendered = await PDFThumbnailRenderCoordinator.shared.renderThumbnail(
            zeroBasedPageIndex: pageIndex,
            displayPointSize: measuredPointSize,
            scaleFactor: scale,
            pageAspectRatio: aspect,
            url: sourceURL,
            data: sourceData,
            identity: inputIdentity,
            unlockPassword: unlockPassword,
            fallbackDocumentDataProvider: { @MainActor in
                fallbackDocument?.dataRepresentation()
            }
        )
        guard !Task.isCancelled, let rendered else { return }
        thumbnail = RenderedThumbnail(
            image: rendered, identityKey: inputIdentity.cacheKey, pageIndex: pageIndex + 1
        )
        onThumbnailRendered(Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }
}

final class TTZipPDFRenderedThumbnailProbeNSView: NSView {
    var identityKey = ""
    var pageIndex = 0
    var renderedImage: NSImage?
}

private struct TTZipPDFRenderedThumbnailProbe: NSViewRepresentable {
    let identityKey: String
    let pageIndex: Int
    let renderedImage: NSImage

    func makeNSView(context: Context) -> TTZipPDFRenderedThumbnailProbeNSView {
        TTZipPDFRenderedThumbnailProbeNSView(frame: .zero)
    }

    func updateNSView(_ view: TTZipPDFRenderedThumbnailProbeNSView, context: Context) {
        view.identityKey = identityKey
        view.pageIndex = pageIndex
        view.renderedImage = renderedImage
    }
}
