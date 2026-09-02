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

/// Media preview view factory for dynamic media previews with zero-kickout video routing.
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
    
    /// All video extensions supported for unified in-app zero-kickout playback via MPV Metal viewport.
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "mkv", "avi", "webm", "ogv", "flv", "3gp",
        "3g2", "ts", "mts", "m2ts", "m2t", "wmv", "vob", "rmvb", "rm", "divx",
        "asf", "f4v", "y4m", "mpg", "mpeg", "mpe", "mpv", "m2v", "vro", "dat",
        "nut", "dv"
    ]
    
    /// Backward-compatible alias for video extensions.
    public static let nativeVideoExtensions: Set<String> = videoExtensions
    
    /// Backward-compatible alias for extended video formats (now unified into videoExtensions).
    public static let extendedVideoExtensions: Set<String> = videoExtensions
    
    /// Audio extensions.
    public static let audioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "aifc", "aiff", "aif", "m4b", "m4r",
        "alac", "caf", "ogg", "oga", "opus", "wma", "ape", "dts", "ac3", "eac3",
        "amr", "mid", "midi", "mka", "dsd", "dsf", "dff", "wv", "tta", "mpc",
        "tak", "spx", "au", "snd", "voc", "ra", "gsm"
    ]
    
    /// Backward-compatible alias for audio extensions.
    public static let nativeAudioExtensions: Set<String> = audioExtensions
    
    /// Backward-compatible alias for extended audio formats (now unified into audioExtensions).
    public static let extendedAudioExtensions: Set<String> = audioExtensions
    
    /// Document extensions.
    public static let docxExtensions: Set<String> = [
        "docx", "doc", "rtf", "odt"
    ]
    
    /// Presentation extensions.
    public static let presentationExtensions: Set<String> = [
        "pptx", "ppt", "odp", "key"
    ]
    
    /// Markdown extensions.
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn"
    ]
    
    /// Spreadsheet extensions.
    public static let spreadsheetExtensions: Set<String> = [
        "xlsx", "xls", "ods", "csv", "tsv", "tab", "psv", "ssv"
    ]
    
    /// Binary extensions.
    public static let binaryExtensions: Set<String> = [
        "bin", "dat", "so", "dylib", "wasm", "class", "o", "exe", "dll", "obj", "a", "lib", "hex", "rom", "elf", "dex", "pyc"
    ]
    
    /// Text extensions for native text code viewer.
    public static let textExtensions: Set<String> = [
        "txt", "log", "ini", "conf", "cfg", "properties", "env", "plist",
        "swift", "kt", "kts", "java", "rs", "go", "c", "cpp", "h", "hpp", "cs", "m", "mm",
        "js", "jsx", "ts", "tsx", "vue", "svelte", "py", "rb", "php", "sh", "bash", "zsh", "fish",
        "html", "css", "json", "xml", "yaml", "yml", "sql", "gradle", "srt", "ass", "vtt", "lrc", "sub"
    ]
    
    /// Detects MediaPreviewType synchronously for URL.
    nonisolated public static func detectType(url: URL) -> MediaPreviewType {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) {
            return .unsupported("Archive loaded. Double-click to browse contents.")
        }
        if imageExtensions.contains(ext), let image = DownsampledImageLoader.loadDownsampledImage(from: url) {
            return .image(image)
        }
        if videoExtensions.contains(ext) {
            return .video(url)
        }
        if audioExtensions.contains(ext) {
            return .audio(url)
        }
        if ext == "pdf" {
            return .pdf(url)
        }
        if presentationExtensions.contains(ext) {
            let xmlService = UniFfiXmlMetaService()
            if let outline = try? xmlService.extractOfficeOutline(filePath: url.path) {
                return .officePresentation(OfficePresentationModel(fileName: url.lastPathComponent, outline: outline, fileURL: url))
            }
        }
        if ext == "xlsx" || ext == "ods" {
            let officeService = UniFfiOfficeService()
            if let sheetNames = try? officeService.extractSheetNamesFromFile(filePath: url.path),
               let firstSheetName = sheetNames.first,
               let sheetData = try? officeService.extractSheetDataFromFile(filePath: url.path, sheetNameOrIndex: firstSheetName, maxRows: 10000) {
                return .officeSpreadsheet(OfficeSpreadsheetWorkbook(
                    fileName: url.lastPathComponent,
                    sheetNames: sheetNames,
                    activeSheet: sheetData,
                    fileURL: url
                ))
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
        if markdownExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .markdown(content, url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        if spreadsheetExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .spreadsheetTable(content, url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        if binaryExtensions.contains(ext) {
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        let sampleData = readInitialSampleData(from: url)
        if !sampleData.isEmpty {
            return .hexViewer(sampleData, url)
        }
        return .unsupported("Format: \(ext.uppercased())")
    }

    /// Detects MediaPreviewType asynchronously with deep unpacking.
    nonisolated public static func detectTypeAsync(url: URL) async -> MediaPreviewType {
        let ext = url.pathExtension.lowercased()
        
        if archiveExtensions.contains(ext) {
            return .unsupported("Archive loaded. Double-click to browse contents.")
        }
        
        // Handle in-archive VFS streaming URLs
        if url.scheme == TTZipVfsSchemeHandler.scheme {
            if let (resData, _) = try? await TTZipArchiveVfsProvider.shared.loadResource(uri: url.absoluteString) {
                return detectTypeFromMemory(data: resData, suggestedName: url.lastPathComponent, sourceURL: url)
            }
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
        
        if videoExtensions.contains(ext) {
            return .video(url)
        }
        
        if audioExtensions.contains(ext) {
            return .audio(url)
        }
        
        if ext == "pdf" {
            return .pdf(url)
        }
        
        if presentationExtensions.contains(ext) {
            let xmlService = UniFfiXmlMetaService()
            if let outline = try? xmlService.extractOfficeOutline(filePath: url.path) {
                return .officePresentation(OfficePresentationModel(fileName: url.lastPathComponent, outline: outline, fileURL: url))
            }
        }
        
        if ext == "xlsx" || ext == "ods" {
            let officeService = UniFfiOfficeService()
            if let sheetNames = try? officeService.extractSheetNamesFromFile(filePath: url.path),
               let firstSheetName = sheetNames.first,
               let sheetData = try? officeService.extractSheetDataFromFile(filePath: url.path, sheetNameOrIndex: firstSheetName, maxRows: 10000) {
                return .officeSpreadsheet(OfficeSpreadsheetWorkbook(
                    fileName: url.lastPathComponent,
                    sheetNames: sheetNames,
                    activeSheet: sheetData,
                    fileURL: url
                ))
            }
        }
        
        if docxExtensions.contains(ext) {
            let officeService = UniFfiOfficeService()
            if let md = try? officeService.convertDocxToMarkdownFromFile(filePath: url.path), !md.isEmpty {
                return .markdown(md, url)
            }
            if let attrStr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                return .docxDocument(attrStr, url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        if markdownExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .markdown(content, url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        if spreadsheetExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .spreadsheetTable(content, url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        if binaryExtensions.contains(ext) {
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        if textExtensions.contains(ext) {
            if let content = MediaPreviewView.readTextContent(from: url) {
                return .text(content)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let sample = try? handle.read(upToCount: 4096), !sample.isEmpty {
                let nullCount = sample.filter { $0 == 0 }.count
                if Double(nullCount) / Double(sample.count) > 0.01 {
                    return .hexViewer(sample, url)
                }
            }
        }
        
        let sampleData = readInitialSampleData(from: url)
        if !sampleData.isEmpty {
            return .hexViewer(sampleData, url)
        }
        return .unsupported("Format: \(ext.uppercased())")
    }
    
    /// Resolves SF Symbol icon name for file name.
    nonisolated public static func iconName(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return "photo.fill" }
        if videoExtensions.contains(ext) { return "film.fill" }
        if audioExtensions.contains(ext) { return "music.note" }
        if ext == "pdf" { return "doc.richtext.fill" }
        if ext == "epub" || ebookExtensions.contains(ext) { return "book.closed.fill" }
        if ["srt", "ass", "vtt", "sub", "lrc"].contains(ext) { return "captions.bubble.fill" }
        if markdownExtensions.contains(ext) { return "doc.text.fill" }
        if spreadsheetExtensions.contains(ext) { return "tablecells.fill" }
        if presentationExtensions.contains(ext) { return "rectangle.inset.filled.and.person.filled" }
        if binaryExtensions.contains(ext) { return "memorychip.fill" }
        if textExtensions.contains(ext) {
            if ["txt", "log", "ini", "conf", "cfg", "properties", "env", "plist"].contains(ext) {
                return "doc.text.fill"
            }
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc.fill"
    }

    /// Detects MediaPreviewType directly from in-memory Data (Zero Disk I/O).
    nonisolated public static func detectTypeFromMemory(data: Data, suggestedName: String, sourceURL: URL? = nil) -> MediaPreviewType {
        let sniff = NativeMicrokernelBridge.sniffMagic(data: data)
        if sniff.kind == TTZIP_KIND_IMAGE, let image = DownsampledImageLoader.loadDownsampledImage(from: data) {
            return .image(image)
        }
        
        let ext = (suggestedName as NSString).pathExtension.lowercased()
        
        if videoExtensions.contains(ext) || sniff.kind == TTZIP_KIND_VIDEO {
            if let fileURL = try? ArchiveMediaCachePool.shared.stageData(data, fileName: suggestedName, sourceURL: sourceURL) {
                return .video(fileURL)
            } else if let fallbackURL = writeDataToTemporaryFile(data: data, fileName: suggestedName) {
                return .video(fallbackURL)
            } else {
                return .unsupported("Unable to prepare video file for playback: \(suggestedName)")
            }
        }
        
        if audioExtensions.contains(ext) || sniff.kind == TTZIP_KIND_AUDIO {
            if let fileURL = try? ArchiveMediaCachePool.shared.stageData(data, fileName: suggestedName, sourceURL: sourceURL) {
                return .audio(fileURL)
            } else if let fallbackURL = writeDataToTemporaryFile(data: data, fileName: suggestedName) {
                return .audio(fallbackURL)
            } else {
                return .unsupported("Unable to prepare audio file for playback: \(suggestedName)")
            }
        }
        
        if ext == "pdf" {
            return .pdfData(data, sourceURL)
        }
        
        if presentationExtensions.contains(ext) {
            let xmlService = UniFfiXmlMetaService()
            if let outline = try? xmlService.extractOfficeOutlineFromBytes(bytes: data) {
                return .officePresentation(OfficePresentationModel(fileName: suggestedName, outline: outline, fileURL: sourceURL))
            }
        }
        
        if ext == "xlsx" || ext == "ods" {
            let officeService = UniFfiOfficeService()
            if let sheetNames = try? officeService.extractSheetNames(data: data, fileName: suggestedName),
               let firstSheetName = sheetNames.first,
               let sheetData = try? officeService.extractSheetData(data: data, sheetNameOrIndex: firstSheetName, maxRows: 10000, fileName: suggestedName) {
                return .officeSpreadsheet(OfficeSpreadsheetWorkbook(
                    fileName: suggestedName,
                    sheetNames: sheetNames,
                    activeSheet: sheetData,
                    fileURL: sourceURL,
                    rawData: data
                ))
            }
        }
        
        if docxExtensions.contains(ext) {
            let officeService = UniFfiOfficeService()
            if let md = try? officeService.convertDocxToMarkdown(data: data, fileName: suggestedName), !md.isEmpty {
                return .markdown(md, sourceURL)
            }
        }
        
        if markdownExtensions.contains(ext) {
            if let str = String(data: data.prefix(1024 * 1024), encoding: .utf8) {
                return .markdown(str, sourceURL)
            }
        }
        
        if spreadsheetExtensions.contains(ext) {
            if let str = String(data: data.prefix(1024 * 1024), encoding: .utf8) ?? String(data: data.prefix(1024 * 1024), encoding: .isoLatin1) {
                return .spreadsheetTable(str, sourceURL)
            }
        }
        
        if binaryExtensions.contains(ext) {
            return .hexViewer(data, sourceURL)
        }
        
        if textExtensions.contains(ext) || ext.isEmpty {
            let sample = data.prefix(4096)
            let nullCount = sample.filter { $0 == 0 }.count
            if !sample.isEmpty && Double(nullCount) / Double(sample.count) > 0.01 {
                return .hexViewer(data, sourceURL)
            }
            if let str = String(data: data.prefix(128 * 1024), encoding: .utf8) {
                return .text(str)
            }
        }
        
        if !data.isEmpty {
            return .hexViewer(data, sourceURL)
        }
        
        return .unsupported("Format: \(sniff.format) (\(sniff.mime))")
    }

    /// Reads initial sample data for sniffing up to specified byte budget.
    nonisolated public static func readInitialSampleData(from url: URL, maxBytes: Int = 64 * 1024) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }

    /// Safely writes in-memory media payload to a sandboxed temporary file with POSIX permissions.
    nonisolated private static func writeDataToTemporaryFile(data: Data, fileName: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipFallbackMedia", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let sanitized = ArchiveMediaCachePool.sanitizeFileName(fileName)
            let fileURL = tempDir.appendingPathComponent(sanitized)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return fileURL
        } catch {
            return nil
        }
    }
}
