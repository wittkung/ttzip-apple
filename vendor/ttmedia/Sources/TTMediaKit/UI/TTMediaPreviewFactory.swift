// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
#if os(macOS)
import QuickLookUI
#endif

/// Factory for constructing declarative preview views from TTMediaPreviewType descriptors.
public enum TTMediaPreviewFactory {

    @MainActor
    public static func makePreviewView(
        type: TTMediaPreviewType,
        fileName: String,
        fileURL: URL?,
        resourceContext: TTPreviewResourceContext? = nil,
        isFullScreenActive: Bool = false,
        useMediaKit: Bool = false,
        onSave: ((String) -> Void)? = nil
    ) -> some View {
        let resolvedContext = resolveResourceContext(
            explicitContext: resourceContext,
            type: type,
            fileName: fileName,
            fileURL: fileURL
        )
        let effectiveOnSave: ((String) -> Void)? = resolvedContext.isEditableInPlace ? onSave : nil
        return makePreviewContent(
            type: type,
            fileName: fileName,
            fileURL: fileURL,
            resolvedContext: resolvedContext,
            isFullScreenActive: isFullScreenActive,
            effectiveOnSave: effectiveOnSave
        )
        .environment(\.previewResourceContext, resolvedContext)
    }

    @MainActor
    @ViewBuilder
    private static func makePreviewContent(
        type: TTMediaPreviewType,
        fileName: String,
        fileURL: URL?,
        resolvedContext: TTPreviewResourceContext,
        isFullScreenActive: Bool,
        effectiveOnSave: ((String) -> Void)?
    ) -> some View {
        switch type {
        case .pluginView(let customView):
            customView
        case .image(let nsImage):
            let resource = TTMediaDetector.imagePreviewResource(for: nsImage, fallbackURL: fileURL)
            InteractiveZoomImageView(resource: resource)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .video(let url):
            TTMediaEphemeralLeaseHostView(url: url, isFullScreen: isFullScreenActive) {
                UnifiedVideoPlayerView(url: url, isFullScreen: isFullScreenActive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .audio(let url):
            TTMediaEphemeralLeaseHostView(url: url, isFullScreen: isFullScreenActive) {
                UnifiedAudioPlayerView(url: url, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .pdf(let url):
            InteractivePDFPreviewContainerView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .pdfData(let data, let url):
            InteractivePDFPreviewContainerView(data: data, url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            makeDocumentOrStructuredPreview(
                type: type,
                fileName: fileName,
                fileURL: fileURL,
                resolvedContext: resolvedContext,
                isFullScreenActive: isFullScreenActive,
                effectiveOnSave: effectiveOnSave
            )
        }
    }

    @MainActor
    @ViewBuilder
    private static func makeDocumentOrStructuredPreview(
        type: TTMediaPreviewType,
        fileName: String,
        fileURL: URL?,
        resolvedContext: TTPreviewResourceContext,
        isFullScreenActive: Bool,
        effectiveOnSave: ((String) -> Void)?
    ) -> some View {
        switch type {
        case .text(let textContent):
            CodeTextEditorContainerView(
                initialText: textContent,
                fileURL: resolvedContext.readableURL ?? fileURL,
                fileName: fileName,
                isReadOnly: !resolvedContext.isEditableInPlace,
                resourceContext: resolvedContext
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .docxDocument(let attrStr, let url):
            DocxDocumentReaderView(attributedString: attrStr, url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .epubBook(let bookModel):
            InteractiveEPUBReaderView(bookModel: bookModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ebook(let metadata):
            EBookReaderPreviewView(metadata: metadata)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .hexViewer(let data, let targetURL):
            HexDataPreviewView(
                data: data,
                fileURL: targetURL ?? resolvedContext.readableURL ?? fileURL,
                fileName: fileName
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .markdown(let markdownText, let targetURL):
            MarkdownRichPreviewView(
                initialMarkdown: markdownText,
                fileURL: resolvedContext.readableURL ?? targetURL ?? fileURL,
                fileName: fileName,
                isReadOnly: !resolvedContext.isEditableInPlace,
                resourceContext: resolvedContext
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .htmlWeb(let content, let targetURL):
            HTMLWebRichPreviewView(
                content: content,
                fileURL: targetURL ?? resolvedContext.readableURL ?? fileURL,
                fileName: fileName,
                onSave: effectiveOnSave
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            makeStructuredOrFallbackPreview(
                type: type,
                fileName: fileName,
                fileURL: fileURL,
                resolvedContext: resolvedContext,
                isFullScreenActive: isFullScreenActive
            )
        }
    }

    @MainActor
    @ViewBuilder
    private static func makeStructuredOrFallbackPreview(
        type: TTMediaPreviewType,
        fileName: String,
        fileURL: URL?,
        resolvedContext: TTPreviewResourceContext,
        isFullScreenActive: Bool
    ) -> some View {
        switch type {
        case .spreadsheetTable(let csvContent, let targetURL):
            SpreadsheetTablePreviewView(
                initialContent: csvContent,
                fileURL: resolvedContext.readableURL ?? targetURL ?? fileURL,
                fileName: fileName,
                isReadOnly: !resolvedContext.isEditableInPlace,
                resourceContext: resolvedContext
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .officeSpreadsheet(let workbook):
            SpreadsheetTablePreviewView(
                workbook: workbook,
                sheetLoader: { sheetName in
                    TTMediaOfficeSpreadsheetReader.loadSheetRows(
                        workbook: workbook,
                        sheetName: sheetName
                    )
                },
                sheetDataLoader: { sheetName in
                    TTMediaOfficeSpreadsheetReader.loadSheet(
                        workbook: workbook,
                        sheetName: sheetName
                    )
                },
                resourceContext: resolvedContext
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .officePresentation(let model):
            PresentationPreviewView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        case .quickLook(let url):
            TTMediaEphemeralLeaseHostView(url: url, isFullScreen: isFullScreenActive) {
                QuickLookNativePreviewView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        #else
        case .quickLook(let url):
            TTMediaEphemeralLeaseHostView(url: url, isFullScreen: isFullScreenActive) {
                unsupportedPlaceholderView(text: url.lastPathComponent)
            }
        #endif
        case .unsupported(let msg):
            unsupportedPlaceholderView(
                text: TextAndDocumentPreviewLocalization.localizedUnsupportedMessage(msg)
            )
        default:
            EmptyView()
        }
    }

    @MainActor
    private static func unsupportedPlaceholderView(text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Resolves the canonical `TTPreviewResourceContext` for a preview invocation.
    /// When no explicit context is supplied (`nil`), defaults to `.unknown` (read-only)
    /// or `.derivedContent` for Office workbooks/presentations.
    nonisolated public static func resolveResourceContext(
        explicitContext: TTPreviewResourceContext?,
        type: TTMediaPreviewType,
        fileName: String,
        fileURL: URL?
    ) -> TTPreviewResourceContext {
        switch type {
        case .officeSpreadsheet(let workbook):
            let sourceURL = explicitContext?.originalResourceURL ?? workbook.fileURL ?? fileURL
            let base = explicitContext?.withDerivedRepresentation(true, description: "OfficeSpreadsheet")
                ?? .derivedContent(sourceURL: sourceURL, fileName: fileName, description: "OfficeSpreadsheet")
            return workbook.isTruncated ? base.withTruncatedPreview(true) : base
        case .officePresentation:
            let sourceURL = explicitContext?.originalResourceURL ?? fileURL
            return explicitContext?.withDerivedRepresentation(true, description: "OfficePresentation")
                ?? .derivedContent(sourceURL: sourceURL, fileName: fileName, description: "OfficePresentation")
        default:
            if let explicitContext {
                return explicitContext
            }
            return .unknown(readableURL: fileURL, fileName: fileName)
        }
    }

    /// Creates a direct declarative universal media preview using TTMediaPreview.
    @MainActor
    public static func makeMediaKitPreview(
        url: URL,
        title: String? = nil,
        resourceContext: TTPreviewResourceContext? = nil
    ) -> TTMediaPreview {
        TTMediaPreview(url: url, title: title, resourceContext: resourceContext)
    }

    /// Creates a direct declarative spreadsheet visualizer.
    @MainActor
    public static func makeSpreadsheetView(headers: [String], rows: [[String]]) -> TTSpreadsheetView {
        TTSpreadsheetView(headers: headers, rows: rows)
    }

    /// Creates a direct declarative rich structured document preview.
    @MainActor
    public static func makeRichDocumentView(markdown: String, title: String? = nil) -> TTRichDocumentView {
        TTRichDocumentView(markdown: markdown, metadata: title != nil ? DocumentMetadata(title: title) : nil)
    }
}

/// Declarative SwiftUI host wrapper that binds an ephemeral staged media lease to the lifecycle
/// of its rendered preview view. Automatically adopts any unclaimed lease on initialization
/// (covering both mounted and never-mounted views), rebinds on URL changes, and releases on
/// `onDisappear` while preserving staged media across fullscreen handoffs.
@MainActor
public struct TTMediaEphemeralLeaseHostView<Content: View>: View {
    public let url: URL
    public let isFullScreen: Bool
    private let content: () -> Content
    @State private var leaseBox: TTMediaEphemeralLeaseBox

    public init(
        url: URL,
        isFullScreen: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.url = url
        self.isFullScreen = isFullScreen
        self.content = content
        _leaseBox = State(initialValue: TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: url))
    }

    public var body: some View {
        content()
            .onAppear {
                leaseBox.bind(url: url, consumeFullscreenHandoff: isFullScreen)
            }
            .onChange(of: url) { _, newURL in
                leaseBox.bind(url: newURL, consumeFullscreenHandoff: isFullScreen)
            }
            .onDisappear {
                if isFullScreen {
                    TTMediaDetector.endFullscreenEphemeralHandoff(for: url)
                }
                leaseBox.release()
            }
    }
}

#if os(macOS)
/// Native AppKit QLPreviewView bridging macOS system QuickLook engine for office documents and spreadsheets.
public struct QuickLookNativePreviewView: NSViewRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.previewItem = url as QLPreviewItem
        preview.autoresizingMask = [.width, .height]
        return preview
    }

    public func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as QLPreviewItem
        }
    }
}
#endif
