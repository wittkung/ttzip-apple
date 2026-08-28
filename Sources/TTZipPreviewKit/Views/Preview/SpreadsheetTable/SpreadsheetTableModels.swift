// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipUI

// MARK: - Delimiter & Parsing Model

/// Supported spreadsheet field delimiters.
public enum TTZipSpreadsheetDelimiter: Character, CaseIterable, Identifiable, Sendable {
    case comma = ","
    case tab = "\t"
    case semicolon = ";"
    case pipe = "|"

    public var id: String { String(rawValue) }

    public var displayName: String {
        switch self {
        case .comma: return "Comma (,)"
        case .tab: return "Tab (\\t)"
        case .semicolon: return "Semicolon (;)"
        case .pipe: return "Pipe (|)"
        }
    }

    public var shortName: String {
        switch self {
        case .comma: return "CSV (,)"
        case .tab: return "TSV (⇥)"
        case .semicolon: return "SSV (;)"
        case .pipe: return "PSV (|)"
        }
    }
}

/// Page size options for spreadsheet pagination.
public enum SpreadsheetPageSizeOption: Int, CaseIterable, Identifiable, Sendable {
    case fifty = 50
    case hundred = 100
    case twoHundredFifty = 250
    case fiveHundred = 500
    case oneThousand = 1000
    case all = -1

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .fifty: return "50 rows"
        case .hundred: return "100 rows"
        case .twoHundredFifty: return "250 rows"
        case .fiveHundred: return "500 rows"
        case .oneThousand: return "1,000 rows"
        case .all: return "All rows (No Pagination)"
        }
    }
}

/// Preview mode between Spreadsheet Grid and Raw CSV/TSV source text.
public enum SpreadsheetPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case table = "Grid Table"
    case source = "Raw Source"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .table: return "tablecells"
        case .source: return "curlybraces"
        }
    }
}

/// Cell coordinate for selection and inspection.
public struct SpreadsheetCellCoordinate: Hashable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public var excelReference: String {
        "\(TTZipSpreadsheetParser.columnLetter(for: column))\(row + 1)"
    }
}

/// Row item for identifiable list rendering.
public struct SpreadsheetRowItem: Identifiable, Sendable {
    public let id: Int
    public let originalIndex: Int
    public let cells: [String]

    public init(id: Int, originalIndex: Int, cells: [String]) {
        self.id = id
        self.originalIndex = originalIndex
        self.cells = cells
    }
}

/// Statistical and layout calculation helpers for spreadsheet data.
public enum SpreadsheetTableLayoutEngine {
    public static func calculateColumnWidths(parsedRows: [[String]], headerNames: [String], maxColumnCount: Int) -> [Int: CGFloat] {
        guard !parsedRows.isEmpty else { return [:] }
        let sampleRows = Array(parsedRows.prefix(150))
        var newWidths: [Int: CGFloat] = [:]
        for c in 0..<maxColumnCount {
            let headerCount = (c < headerNames.count) ? headerNames[c].count : 3
            var maxChars = headerCount
            for row in sampleRows where c < row.count { maxChars = max(maxChars, row[c].count) }
            newWidths[c] = min(380, max(85, CGFloat(maxChars * 8 + 24)))
        }
        return newWidths
    }
}
