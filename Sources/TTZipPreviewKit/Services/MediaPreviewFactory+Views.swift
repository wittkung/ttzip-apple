// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AVKit
import PDFKit
import WebKit
import TTZipCore
import TTZipPluginKit
import TTZipUI

extension MediaPreviewFactory {

    @MainActor
    @ViewBuilder
    public static func makePreviewView(
        type: MediaPreviewType,
        fileName: String,
        fileURL: URL?,
        isFullScreenActive: Bool = false
    ) -> some View {
        if let fileURL = fileURL,
           let provider = TTZipPluginRegistry.shared.previewProviders.first(where: { $0.canPreview(fileURL: fileURL) }) {
            provider.makePreviewView(fileURL: fileURL)
        } else {
            switch type {
            case .pluginView(let customView):
                customView
                
            case .image(let nsImage):
                InteractiveZoomImageView(image: nsImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .video(let url):
                UnifiedVideoPlayerView(url: url, isFullScreen: isFullScreenActive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .audio(let url):
                UnifiedAudioPlayerView(url: url, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .pdf(let url):
                InteractivePDFPreviewContainerView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .pdfData(let data, let url):
                InteractivePDFPreviewContainerView(data: data, url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .text(let textContent):
                CodeTextEditorContainerView(initialText: textContent, fileURL: fileURL, fileName: fileName)
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
                HexDataPreviewView(data: data, fileURL: targetURL ?? fileURL, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .markdown(let markdownText, let targetURL):
                MarkdownRichPreviewView(initialMarkdown: markdownText, fileURL: targetURL ?? fileURL, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .spreadsheetTable(let csvContent, let targetURL):
                SpreadsheetTablePreviewView(initialContent: csvContent, fileURL: targetURL ?? fileURL, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .officeSpreadsheet(let workbook):
                SpreadsheetTablePreviewView(workbook: workbook)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .officePresentation(let model):
                PresentationPreviewView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .unsupported(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(msg)
                        .font(.subheadline)
                }
            }
        }
    }
}
