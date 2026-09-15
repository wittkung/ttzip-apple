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
@preconcurrency import Dispatch
import TTZipCore
import TTZipPluginKit
import TTZipUI

/// Media preview view factory for dynamic media previews with zero-kickout video routing.
public enum MediaPreviewFactory {

    /// Consolidated archive extensions referencing ArchiveFormatStandardRegistry and central preview matrix.
    public static let archiveExtensions: Set<String> = ArchiveFormatStandardRegistry.allStandardExtensions.union(PreviewCapabilityMatrix.archiveExtensions)
    
    /// E-book extensions consolidated from central preview matrix.
    public static let ebookExtensions: Set<String> = PreviewCapabilityMatrix.ebookExtensions
    
    /// Image extensions consolidated from central preview matrix.
    public static let imageExtensions: Set<String> = PreviewCapabilityMatrix.imageExtensions
    
    /// All video extensions supported for unified in-app zero-kickout playback via MPV Metal viewport.
    public static let videoExtensions: Set<String> = PreviewCapabilityMatrix.videoExtensions
    
    /// Backward-compatible alias for video extensions.
    public static let nativeVideoExtensions: Set<String> = videoExtensions
    
    /// Backward-compatible alias for extended video formats (now unified into videoExtensions).
    public static let extendedVideoExtensions: Set<String> = videoExtensions
    
    /// Audio extensions consolidated from central preview matrix.
    public static let audioExtensions: Set<String> = PreviewCapabilityMatrix.audioExtensions
    
    /// Backward-compatible alias for audio extensions.
    public static let nativeAudioExtensions: Set<String> = audioExtensions
    
    /// Backward-compatible alias for extended audio formats (now unified into audioExtensions).
    public static let extendedAudioExtensions: Set<String> = audioExtensions
    
    /// Document extensions consolidated from central preview matrix.
    public static let docxExtensions: Set<String> = PreviewCapabilityMatrix.docxExtensions
    
    /// Presentation extensions consolidated from central preview matrix.
    public static let presentationExtensions: Set<String> = PreviewCapabilityMatrix.presentationExtensions
    
    /// Markdown extensions consolidated from central preview matrix (including md, markdown, mdown, mkd, mkdn, mdtxt, mdtext).
    public static let markdownExtensions: Set<String> = PreviewCapabilityMatrix.markdownExtensions
    
    /// HTML, web, and vector document extensions for rich visual rendering and dual-mode inspection.
    public static let htmlWebExtensions: Set<String> = PreviewCapabilityMatrix.htmlWebExtensions
    
    /// Spreadsheet extensions consolidated from central preview matrix.
    public static let spreadsheetExtensions: Set<String> = PreviewCapabilityMatrix.spreadsheetExtensions
    
    /// Binary extensions consolidated from central preview matrix.
    public static let binaryExtensions: Set<String> = PreviewCapabilityMatrix.binaryExtensions
    
    /// Text extensions for native text code viewer consolidated from central preview matrix.
    public static let textExtensions: Set<String> = PreviewCapabilityMatrix.textExtensions
    
    /// Rapidly infers preview type solely from file extension with zero disk I/O.
    nonisolated public static func fastTypeByExtension(url: URL) -> MediaPreviewType {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) {
            return .unsupported("Archive loaded. Double-click to browse contents.")
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
        return .unsupported("Loading...")
    }

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
        if docxExtensions.contains(ext) {
            let sampleData = readInitialSampleData(from: url)
            return sampleData.isEmpty ? .unsupported("Format: \(ext.uppercased())") : .hexViewer(sampleData, url)
        }
        if presentationExtensions.contains(ext) {
            let xmlService = UniFfiXmlMetaService()
            if let outline = try? xmlService.extractOfficeOutline(filePath: url.path) {
                return .officePresentation(OfficePresentationModel(fileName: url.lastPathComponent, outline: outline, fileURL: url))
            }
            let sampleData = readInitialSampleData(from: url)
            return sampleData.isEmpty ? .unsupported("Format: \(ext.uppercased())") : .hexViewer(sampleData, url)
        }
        if spreadsheetExtensions.contains(ext) {
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
                let sampleData = readInitialSampleData(from: url)
                return sampleData.isEmpty ? .unsupported("Format: \(ext.uppercased())") : .hexViewer(sampleData, url)
            }
            if ext == "xls" {
                let sampleData = readInitialSampleData(from: url)
                return sampleData.isEmpty ? .unsupported("Format: \(ext.uppercased())") : .hexViewer(sampleData, url)
            }
            if let content = PreviewContentReader.readTextContent(from: url) {
                return .spreadsheetTable(content, url)
            }
            let sampleData = readInitialSampleData(from: url)
            return sampleData.isEmpty ? .unsupported("Format: \(ext.uppercased())") : .hexViewer(sampleData, url)
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
            if let content = PreviewContentReader.readTextContent(from: url) {
                return .markdown(content, url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        if htmlWebExtensions.contains(ext) {
            if let content = PreviewContentReader.readTextContent(from: url) {
                return .htmlWeb(content: content, fileURL: url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        if binaryExtensions.contains(ext) {
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        if textExtensions.contains(ext) {
            if let content = PreviewContentReader.readTextContent(from: url) {
                return .text(content)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        if let content = PreviewContentReader.readTextContent(from: url) {
            return .text(content)
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
                // Converted DOCX is read-only Markdown; do not expose disk URL to prevent destructive plain-text overwrite.
                return .markdown(md, nil)
            }
            if ext == "doc" {
                if let attrStr = await loadLegacyDocAttributedString(from: url, timeoutSeconds: 1.5) {
                    return .docxDocument(attrStr, url)
                }
                let sampleData = readInitialSampleData(from: url)
                if !sampleData.isEmpty {
                    return .hexViewer(sampleData, url)
                }
                return .unsupported("Legacy Word (.doc) preview timed out or unsupported.")
            } else {
                if let attrStr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                    return .docxDocument(attrStr, url)
                }
                let sampleData = readInitialSampleData(from: url)
                return .hexViewer(sampleData, url)
            }
        }
        
        if markdownExtensions.contains(ext) {
            if let content = PreviewContentReader.readTextContent(from: url) {
                return .markdown(content, url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        if htmlWebExtensions.contains(ext) {
            if let content = PreviewContentReader.readTextContent(from: url) {
                return .htmlWeb(content: content, fileURL: url)
            }
            let sampleData = readInitialSampleData(from: url)
            return .hexViewer(sampleData, url)
        }
        
        if spreadsheetExtensions.contains(ext) {
            if let content = PreviewContentReader.readTextContent(from: url) {
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
            if let content = PreviewContentReader.readTextContent(from: url) {
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
    
    /// Queries the capabilities for a file or extension via unified PreviewCapabilityMatrix.
    nonisolated public static func capabilities(for extensionOrFileName: String) -> PreviewCapabilities {
        PreviewCapabilityMatrix.capabilities(for: extensionOrFileName)
    }
    
    /// Queries the primary preview mode for a file or extension via unified PreviewCapabilityMatrix.
    nonisolated public static func primaryMode(for extensionOrFileName: String) -> PreviewPrimaryMode? {
        PreviewCapabilityMatrix.primaryMode(for: extensionOrFileName)
    }

    /// Resolves SF Symbol icon name for file name.
    nonisolated public static func iconName(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let desc = PreviewCapabilityMatrix.descriptor(for: ext) {
            return desc.iconName
        }
        if imageExtensions.contains(ext) { return "photo.fill" }
        if videoExtensions.contains(ext) { return "film.fill" }
        if audioExtensions.contains(ext) { return "music.note" }
        if ext == "pdf" { return "doc.richtext.fill" }
        if ext == "epub" || ebookExtensions.contains(ext) { return "book.closed.fill" }
        if ["srt", "ass", "vtt", "sub", "lrc"].contains(ext) { return "captions.bubble.fill" }
        if markdownExtensions.contains(ext) { return "doc.text.fill" }
        if htmlWebExtensions.contains(ext) { return (ext == "svg" || ext == "svgz") ? "photo.fill" : "globe" }
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
            if let fileURL = writeDataToTemporaryFile(data: data, fileName: suggestedName) {
                return .video(fileURL)
            } else {
                return .unsupported("Unable to prepare video file for playback: \(suggestedName)")
            }
        }
        
        if audioExtensions.contains(ext) || sniff.kind == TTZIP_KIND_AUDIO {
            if let fileURL = writeDataToTemporaryFile(data: data, fileName: suggestedName) {
                return .audio(fileURL)
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
                // Converted DOCX is read-only Markdown; do not expose disk URL to prevent destructive plain-text overwrite.
                return .markdown(md, nil)
            }
        }
        
        if markdownExtensions.contains(ext) {
            if let str = String(data: data.prefix(1024 * 1024), encoding: .utf8) {
                return .markdown(str, sourceURL)
            }
        }
        
        if htmlWebExtensions.contains(ext) {
            if let str = String(data: data.prefix(10 * 1024 * 1024), encoding: .utf8) ?? PreviewContentReader.decodeText(data: data) {
                return .htmlWeb(content: str, fileURL: sourceURL)
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

    private static let legacyDocConversionQueue = DispatchQueue(
        label: "com.ttzip.preview.legacyDocConversion",
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    private final class AttributedStringBox: @unchecked Sendable {
        let value: NSAttributedString?
        init(_ value: NSAttributedString?) {
            self.value = value
        }
    }
    
    private final class LegacyDocContinuationTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false
        private let continuation: CheckedContinuation<AttributedStringBox, Never>
        
        init(continuation: CheckedContinuation<AttributedStringBox, Never>) {
            self.continuation = continuation
        }
        
        func resume(with box: AttributedStringBox) {
            lock.lock()
            defer { lock.unlock() }
            guard !hasResumed else { return }
            hasResumed = true
            continuation.resume(returning: box)
        }
    }

    /// Loads NSAttributedString for legacy binary documents with hard 1.5s timeout circuit breaker to avoid hanging cooperative thread pool.
    nonisolated private static func loadLegacyDocAttributedString(from url: URL, timeoutSeconds: Double = 1.5) async -> NSAttributedString? {
        let box = await withCheckedContinuation { (continuation: CheckedContinuation<AttributedStringBox, Never>) in
            let tracker = LegacyDocContinuationTracker(continuation: continuation)
            
            legacyDocConversionQueue.async {
                let attrStr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
                tracker.resume(with: AttributedStringBox(attrStr))
            }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                tracker.resume(with: AttributedStringBox(nil))
            }
        }
        return box.value
    }
}
