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

/// Media preview view factory for dynamic media previews.
@MainActor
public enum MediaPreviewFactory {

    
    /// Archive extensions.
    public static let archiveExtensions: Set<String> = [
        "7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "xz", "001", "002", "003", "zst", "iso"
    ]
    
    /// E-book extensions.
    public static let ebookExtensions: Set<String> = [
        "mobi", "azw", "azw3", "fb2", "cbz", "cbr", "ibooks"
    ]
    
    /// Image extensions.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico"
    ]
    
    /// Native video extensions directly decodable and playable via AVPlayer with GPU hardware acceleration.
    public static let nativeVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt"
    ]
    
    /// Extended video container extensions that require external player dispatch or specialized container demuxers.
    public static let extendedVideoExtensions: Set<String> = [
        "mkv", "avi", "webm", "ogv", "flv", "3gp", "ts", "wmv", "vob", "rmvb", "divx", "m2ts", "asf"
    ]
    
    /// All recognizable video extensions.
    public static let videoExtensions: Set<String> = nativeVideoExtensions.union(extendedVideoExtensions)
    
    /// All audio extensions supported for unified in-app embedded playback and waveform inspection.
    public static let audioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "aifc", "aiff", "m4b", "alac", "caf",
        "ogg", "opus", "wma", "ape", "dts", "mid", "midi", "mka", "dsf", "dff", "wv"
    ]
    
    /// Backward-compatible alias for audio extensions.
    public static let nativeAudioExtensions: Set<String> = audioExtensions
    
    /// Backward-compatible alias for extended audio formats (now unified into audioExtensions).
    public static let extendedAudioExtensions: Set<String> = []
    
    /// Document extensions.
    public static let docxExtensions: Set<String> = [
        "docx", "doc", "rtf", "odt"
    ]
    
    /// Markdown documentation extensions.
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn"
    ]
    
    /// Structured spreadsheet and tabular data extensions.
    public static let spreadsheetExtensions: Set<String> = [
        "csv", "tsv", "tab", "psv", "ssv"
    ]
    
    /// Binary and compiled code extensions routed to HexDataPreviewView.
    public static let binaryExtensions: Set<String> = [
        "bin", "dat", "so", "dylib", "wasm", "class", "o", "exe", "dll", "obj", "a", "lib", "hex", "rom", "elf", "dex", "pyc"
    ]
    
    /// Text and code extensions.
    public static let textExtensions: Set<String> = [
        "txt", "log", "ini", "conf", "cfg", "properties", "env", "plist",
        "swift", "kt", "kts", "java", "rs", "go", "c", "cpp", "h", "hpp", "cs", "m", "mm",
        "js", "jsx", "ts", "tsx", "vue", "svelte", "py", "rb", "php", "sh", "bash", "zsh", "fish",
        "html", "css", "json", "xml", "yaml", "yml", "sql", "gradle", "srt", "ass", "vtt", "lrc", "sub"
    ]
    
    /// Detects MediaPreviewType synchronously for URL.
    public static func detectType(url: URL) -> MediaPreviewType {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) {
            return .unsupported("Archive loaded. Double-click to browse contents.")
        }
        if imageExtensions.contains(ext), let image = DownsampledImageLoader.loadDownsampledImage(from: url) {
            return .image(image)
        }
        if nativeVideoExtensions.contains(ext) {
            return .video(url)
        }
        if extendedVideoExtensions.contains(ext) {
            return .unsupportedVideo(url, ext.uppercased())
        }
        if audioExtensions.contains(ext) {
            return .audio(url)
        }
        if ext == "pdf" {
            return .pdf(url)
        }
        if ebookExtensions.contains(ext) {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeStr = ByteCountFormatterFlyweight.shared.string(fromByteCount: Int64(fileSize))
            let meta = EBookMetadata(
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                formatName: ext.uppercased(),
                fileSizeDescription: sizeStr,
                excerptText: "E-Book ready for full-screen reading.",
                coverImage: nil
            )
            return .ebook(meta)
        }
        if markdownExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .markdown(content, url)
            }
            return .quickLook(url)
        }
        if spreadsheetExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .spreadsheetTable(content, url)
            }
            return .quickLook(url)
        }
        if binaryExtensions.contains(ext) {
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        return .quickLook(url)
    }

    /// Detects MediaPreviewType asynchronously with deep unpacking.
    public static func detectTypeAsync(url: URL) async -> MediaPreviewType {
        let ext = url.pathExtension.lowercased()
        
        if archiveExtensions.contains(ext) {
            return .unsupported("Archive loaded. Double-click to browse contents.")
        }
        
        if ext == "epub" {
            if let bookModel = EPUBArchiveUnpacker.unpackAndParseEPUB(at: url) {
                return .epubBook(bookModel)
            } else {
                let meta = EBookMetadata(
                    url: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    formatName: "EPUB",
                    fileSizeDescription: "",
                    excerptText: "EPUB open publication format e-book with full structure.",
                    coverImage: nil
                )
                return .ebook(meta)
            }
        }
        
        if ebookExtensions.contains(ext) {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeStr = ByteCountFormatterFlyweight.shared.string(fromByteCount: Int64(fileSize))
            let meta = EBookMetadata(
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                formatName: ext.uppercased(),
                fileSizeDescription: sizeStr,
                excerptText: "E-Book ready for full-screen reading.",
                coverImage: nil
            )
            return .ebook(meta)
        }
        
        if imageExtensions.contains(ext) {
            if let image = await DownsampledImageLoader.loadDownsampledImageAsync(from: url) {
                return .image(image)
            }
        }
        
        if nativeVideoExtensions.contains(ext) {
            return .video(url)
        }
        
        if extendedVideoExtensions.contains(ext) {
            return .unsupportedVideo(url, ext.uppercased())
        }
        
        if audioExtensions.contains(ext) {
            return .audio(url)
        }
        
        if ext == "pdf" {
            return .pdf(url)
        }
        
        if docxExtensions.contains(ext) {
            if let attrStr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                return .docxDocument(attrStr, url)
            }
            return .quickLook(url)
        }
        
        if markdownExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .markdown(content, url)
            }
            return .quickLook(url)
        }
        
        if spreadsheetExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .spreadsheetTable(content, url)
            }
            return .quickLook(url)
        }
        
        if binaryExtensions.contains(ext) {
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        if textExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .text(content)
            }
            // If text sniffing rejected due to null bytes, route to Hex viewer
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        // Sniff unknown files: if binary sniffing finds null bytes, fallback to Hex viewer
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let sample = try? handle.read(upToCount: 4096), !sample.isEmpty {
                let nullCount = sample.filter { $0 == 0 }.count
                if Double(nullCount) / Double(sample.count) > 0.01 {
                    return .hexViewer(sample, url)
                }
            }
        }
        
        return .quickLook(url)
    }
    
    /// Resolves SF Symbol icon name for file name.
    public static func iconName(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return "photo.fill" }
        if videoExtensions.contains(ext) { return "film.fill" }
        if audioExtensions.contains(ext) { return "music.note" }
        if ext == "pdf" { return "doc.richtext.fill" }
        if ext == "epub" || ebookExtensions.contains(ext) { return "book.closed.fill" }
        if ["srt", "ass", "vtt", "sub", "lrc"].contains(ext) { return "captions.bubble.fill" }
        if markdownExtensions.contains(ext) { return "doc.text.fill" }
        if spreadsheetExtensions.contains(ext) { return "tablecells.fill" }
        if binaryExtensions.contains(ext) { return "memorychip.fill" }
        if textExtensions.contains(ext) {
            if ["txt", "log", "ini", "conf", "cfg", "properties", "env", "plist"].contains(ext) {
                return "doc.text.fill"
            }
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc.fill"
    }

    /// Detects MediaPreviewType directly from in-memory Data (Zero Disk I/O) with memory-budgeted downsampling.
    public static func detectTypeFromMemory(data: Data, suggestedName: String) -> MediaPreviewType {
        let sniff = NativeMicrokernelBridge.sniffMagic(data: data)
        if sniff.kind == TTZIP_KIND_IMAGE, let image = DownsampledImageLoader.loadDownsampledImage(from: data) {
            return .image(image)
        }
        
        let ext = (suggestedName as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(ext) {
            if let str = String(data: data.prefix(1024 * 1024), encoding: .utf8) {
                return .markdown(str, nil)
            }
        }
        
        if spreadsheetExtensions.contains(ext) {
            if let str = String(data: data.prefix(1024 * 1024), encoding: .utf8) ?? String(data: data.prefix(1024 * 1024), encoding: .isoLatin1) {
                return .spreadsheetTable(str, nil)
            }
        }
        
        if binaryExtensions.contains(ext) {
            return .hexViewer(data, nil)
        }
        
        if textExtensions.contains(ext) || ext.isEmpty {
            let sample = data.prefix(4096)
            let nullCount = sample.filter { $0 == 0 }.count
            if !sample.isEmpty && Double(nullCount) / Double(sample.count) > 0.01 {
                return .hexViewer(data, nil)
            }
            if let str = String(data: data.prefix(128 * 1024), encoding: .utf8) {
                return .text(str)
            }
        }
        
        if !data.isEmpty {
            return .hexViewer(data, nil)
        }
        
        return .unsupported("Format: \(sniff.format) (\(sniff.mime))")
    }

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
            
        case .video(let url):
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
            
        case .unsupportedVideo(let url, let containerName):
            return AnyView(
                VideoPlaybackFallbackView(
                    url: url,
                    fileName: fileName,
                    containerName: containerName
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            
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
    
    private static func readInitialSampleData(from url: URL, maxBytes: Int = 64 * 1024) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }
}
