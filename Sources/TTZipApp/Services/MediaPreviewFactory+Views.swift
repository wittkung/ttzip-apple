// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AVKit
import PDFKit
import QuickLookUI
import WebKit
import TTZipCore
import TTZipPluginKit

extension MediaPreviewFactory {

    @MainActor
    public static func makePreviewView(url: URL, fileName: String = "") async -> AnyView {
        let previewType = await detectTypeAsync(url: url)
        let name = fileName.isEmpty ? url.lastPathComponent : fileName
        return makePreviewView(type: previewType, fileName: name, fileURL: url)
    }

    @MainActor
    public static func makePreviewView(
        type: MediaPreviewType,
        fileName: String,
        fileURL: URL?,
        isFullScreenActive: Bool = false
    ) -> AnyView {
        if let fileURL = fileURL,
           let provider = TTZipPluginRegistry.shared.previewProviders.first(where: { $0.canPreview(fileURL: fileURL) }) {
            return provider.makePreviewView(fileURL: fileURL)
        }
        
        switch type {
        case .pluginView(let customView):
            return customView
            
        case .image(let nsImage):
            return AnyView(
                InteractiveZoomImageView(image: nsImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .video(let url), .unsupportedVideo(let url, _):
            if isFullScreenActive {
                return AnyView(
                    ZStack {
                        Color.black
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 24))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                            Text("Full-screen playback active...")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
            } else {
                return AnyView(
                    UnifiedVideoPlayerView(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
            }
            
        case .audio(let url), .unsupportedAudio(let url, _):
            return AnyView(
                UnifiedAudioPlayerView(url: url, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .pdf(let url):
            return AnyView(
                InteractivePDFPreviewContainerView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .text(let textContent):
            return AnyView(
                CodeTextEditorContainerView(initialText: textContent, fileURL: fileURL, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .docxDocument(let attrStr, let url):
            return AnyView(
                DocxDocumentReaderView(attributedString: attrStr, url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .epubBook(let bookModel):
            return AnyView(
                InteractiveEPUBReaderView(bookModel: bookModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .ebook(let metadata):
            return AnyView(
                EBookReaderPreviewView(metadata: metadata)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .hexViewer(let data, let targetURL):
            return AnyView(
                HexDataPreviewView(data: data, fileURL: targetURL ?? fileURL, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .markdown(let markdownText, let targetURL):
            return AnyView(
                MarkdownRichPreviewView(initialMarkdown: markdownText, fileURL: targetURL ?? fileURL, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .spreadsheetTable(let csvContent, let targetURL):
            return AnyView(
                SpreadsheetTablePreviewView(initialContent: csvContent, fileURL: targetURL ?? fileURL, fileName: fileName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .quickLook(let url):
            return AnyView(
                QuickLookNSView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
        case .unsupported(let msg):
            return AnyView(
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(msg)
                        .font(.subheadline)
                }
            )
        }
    }
    
    public static func readInitialSampleData(from url: URL, maxBytes: Int = 64 * 1024) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }
}
