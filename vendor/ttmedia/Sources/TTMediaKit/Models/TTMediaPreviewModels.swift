// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Foundation
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

/// Comprehensive metadata representation for electronic publications and e-books.
public struct EBookMetadata: @unchecked Sendable {
    public let url: URL
    public let title: String
    public let formatName: String
    public let fileSizeDescription: String
    public let excerptText: String
    public let coverImage: PlatformImage?

    public init(
        url: URL,
        title: String,
        formatName: String,
        fileSizeDescription: String,
        excerptText: String,
        coverImage: PlatformImage?
    ) {
        self.url = url
        self.title = title
        self.formatName = formatName
        self.fileSizeDescription = fileSizeDescription
        self.excerptText = excerptText
        self.coverImage = coverImage
    }
}

/// Structural chapter item inside an unpacked EPUB document container.
public struct EPUBChapterItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let fileURL: URL

    public init(id: String = UUID().uuidString, title: String, fileURL: URL) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
    }
}

/// In-memory representation of an unpacked EPUB publication.
public struct EPUBBookModel: Sendable {
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

/// Tabular sheet data containing row and column matrices.
public struct TTMediaSheetData: Sendable {
    public let name: String
    public let totalRows: Int
    public let totalColumns: Int
    public let rows: [[String]]

    public init(name: String, totalRows: Int, totalColumns: Int, rows: [[String]]) {
        self.name = name
        self.totalRows = totalRows
        self.totalColumns = totalColumns
        self.rows = rows
    }
}

/// Verified Office spreadsheet container format passed from reader/workbook to UI.
public enum OfficeSpreadsheetFormat: String, Sendable, Equatable {
    case xlsx = "XLSX"
    case xlsm = "XLSM"
    case ods = "ODS"

    nonisolated public var badgeTitle: String { rawValue }

    nonisolated public static func resolve(
        explicitExtension: String? = nil,
        fileName: String = "",
        fileURL: URL? = nil
    ) -> OfficeSpreadsheetFormat {
        let candidate = explicitExtension
            ?? (!(fileName as NSString).pathExtension.isEmpty ? (fileName as NSString).pathExtension : fileURL?.pathExtension)
            ?? ""
        switch TTMediaCapabilityMatrix.cleanExtension(from: candidate) {
        case "ods": return .ods
        case "xlsm": return .xlsm
        default: return .xlsx
        }
    }
}

/// Structured workbook representation with multiple sheets.
public struct OfficeSpreadsheetWorkbook: @unchecked Sendable {
    public let fileName: String
    public let sheetNames: [String]
    public let activeSheet: TTMediaSheetData?
    public let fileURL: URL?
    public let rawData: Data?
    public let format: OfficeSpreadsheetFormat

    public init(
        fileName: String,
        sheetNames: [String],
        activeSheet: TTMediaSheetData?,
        fileURL: URL? = nil,
        rawData: Data? = nil,
        format: OfficeSpreadsheetFormat? = nil
    ) {
        self.fileName = fileName
        self.sheetNames = sheetNames
        self.activeSheet = activeSheet
        self.fileURL = fileURL
        self.rawData = rawData
        self.format = format ?? OfficeSpreadsheetFormat.resolve(fileName: fileName, fileURL: fileURL)
    }
}

/// Structural slide outline descriptor for presentations.
public struct TTMediaOfficeOutlineItem: Identifiable, Sendable {
    public let id: String
    public let slideNumber: Int
    public let title: String
    public let bulletPoints: [String]

    public init(
        id: String = UUID().uuidString,
        slideNumber: Int,
        title: String,
        bulletPoints: [String] = []
    ) {
        self.id = id
        self.slideNumber = slideNumber
        self.title = title
        self.bulletPoints = bulletPoints
    }
}

/// Complete presentation outline model.
public struct TTMediaOfficeOutline: Sendable {
    public let title: String
    public let slides: [TTMediaOfficeOutlineItem]
    public let totalSections: Int

    public init(title: String, slides: [TTMediaOfficeOutlineItem], totalSections: Int = 0) {
        self.title = title
        self.slides = slides
        self.totalSections = totalSections
    }
}

/// Structural presentation representation for office slide decks.
public struct OfficePresentationModel: @unchecked Sendable {
    public let fileName: String
    public let outline: TTMediaOfficeOutline
    public let fileURL: URL?

    public init(fileName: String, outline: TTMediaOfficeOutline, fileURL: URL? = nil) {
        self.fileName = fileName
        self.outline = outline
        self.fileURL = fileURL
    }
}

/// Universal discrete preview presentation mode resolved for arbitrary media and document assets.
public enum TTMediaPreviewType: @unchecked Sendable {
    case pluginView(AnyView)
    case image(PlatformImage)
    case video(URL)
    case audio(URL)
    case pdf(URL)
    case pdfData(Data, URL?)
    case text(String)
    case docxDocument(NSAttributedString, URL)
    case epubBook(EPUBBookModel)
    case ebook(EBookMetadata)
    case hexViewer(Data, URL?)
    case markdown(String, URL?)
    case htmlWeb(content: String, fileURL: URL?)
    case spreadsheetTable(String, URL?)
    case officeSpreadsheet(OfficeSpreadsheetWorkbook)
    case officePresentation(OfficePresentationModel)
    case quickLook(URL)
    case unsupported(String)

    /// Convenience helper for binary inspection.
    public static func hexData(_ data: Data, _ url: URL? = nil) -> TTMediaPreviewType {
        .hexViewer(data, url)
    }

    /// Convenience helper for Markdown document presentation.
    public static func markdownDoc(_ text: String, _ url: URL? = nil) -> TTMediaPreviewType {
        .markdown(text, url)
    }

    /// Convenience helper for HTML and web presentation.
    public static func htmlDoc(_ content: String, _ url: URL? = nil) -> TTMediaPreviewType {
        .htmlWeb(content: content, fileURL: url)
    }

    /// Convenience helper for spreadsheet table presentation.
    public static func spreadsheet(_ text: String, _ url: URL? = nil) -> TTMediaPreviewType {
        .spreadsheetTable(text, url)
    }
}

// MARK: - Compatibility Typealiases

public typealias MediaPreviewType = TTMediaPreviewType
public typealias TTMediaEBookMetadata = EBookMetadata
public typealias TTMediaEPUBChapterItem = EPUBChapterItem
public typealias TTMediaEPUBBookModel = EPUBBookModel
public typealias TTMediaOfficeSpreadsheetWorkbook = OfficeSpreadsheetWorkbook
public typealias TTMediaOfficePresentationModel = OfficePresentationModel
