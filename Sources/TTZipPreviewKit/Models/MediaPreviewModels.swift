// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI

public struct EBookMetadata {
    public let url: URL
    public let title: String
    public let formatName: String
    public let fileSizeDescription: String
    public let excerptText: String
    public let coverImage: NSImage?
    
    public init(url: URL, title: String, formatName: String, fileSizeDescription: String, excerptText: String, coverImage: NSImage?) {
        self.url = url
        self.title = title
        self.formatName = formatName
        self.fileSizeDescription = fileSizeDescription
        self.excerptText = excerptText
        self.coverImage = coverImage
    }
}

public struct EPUBChapterItem: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let fileURL: URL
    
    public init(id: String = UUID().uuidString, title: String, fileURL: URL) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
    }
}

public struct EPUBBookModel {
    public let url: URL
    public let title: String
    public let chapters: [EPUBChapterItem]
    public let extractDir: URL
    
    public init(url: URL, title: String, chapters: [EPUBChapterItem], extractDir: URL) {
        self.url = url
        self.title = title
        self.chapters = chapters
        self.extractDir = extractDir
    }
}

/// Structured workbook representation with multiple sheets parsed via UniFfiOfficeService.
public struct OfficeSpreadsheetWorkbook {
    public let fileName: String
    public let sheetNames: [String]
    public let activeSheet: UniFfiSheetData?
    public let fileURL: URL?
    public let rawData: Data?
    
    public init(fileName: String, sheetNames: [String], activeSheet: UniFfiSheetData?, fileURL: URL? = nil, rawData: Data? = nil) {
        self.fileName = fileName
        self.sheetNames = sheetNames
        self.activeSheet = activeSheet
        self.fileURL = fileURL
        self.rawData = rawData
    }
}

/// Structural presentation representation parsed via UniFfiXmlMetaService.
public struct OfficePresentationModel {
    public let fileName: String
    public let outline: UniFfiOfficeOutline
    public let fileURL: URL?
    
    public init(fileName: String, outline: UniFfiOfficeOutline, fileURL: URL? = nil) {
        self.fileName = fileName
        self.outline = outline
        self.fileURL = fileURL
    }
}

public enum MediaPreviewType {
    case pluginView(AnyView)
    case image(NSImage)
    case video(URL)
    case audio(URL)
    case unsupportedAudio(URL, String)
    case pdf(URL)
    case pdfData(Data, URL?)
    case text(String)
    case docxDocument(NSAttributedString, URL)
    case epubBook(EPUBBookModel)
    case ebook(EBookMetadata)
    case hexViewer(Data, URL?)
    case markdown(String, URL?)
    case spreadsheetTable(String, URL?)
    case officeSpreadsheet(OfficeSpreadsheetWorkbook)
    case officePresentation(OfficePresentationModel)
    case unsupported(String)
    
    /// Convenience helper for .hexViewer
    public static func hexData(_ data: Data, _ url: URL? = nil) -> MediaPreviewType {
        .hexViewer(data, url)
    }
    
    /// Convenience helper for .markdown
    public static func markdownDoc(_ text: String, _ url: URL? = nil) -> MediaPreviewType {
        .markdown(text, url)
    }
    
    /// Convenience helper for .spreadsheetTable
    public static func spreadsheet(_ text: String, _ url: URL? = nil) -> MediaPreviewType {
        .spreadsheetTable(text, url)
    }
}
