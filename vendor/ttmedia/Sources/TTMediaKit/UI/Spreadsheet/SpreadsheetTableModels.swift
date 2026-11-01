// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// MARK: - Delimiter & Parsing Model

/// Supported spreadsheet field delimiters.
public enum TTSpreadsheetDelimiter: Character, CaseIterable, Identifiable, Sendable {
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

    @MainActor
    public var localizedDisplayName: String {
        switch self {
        case .comma: return SpreadsheetPreviewLocalization.text(.delimiterComma)
        case .tab: return SpreadsheetPreviewLocalization.text(.delimiterTab)
        case .semicolon: return SpreadsheetPreviewLocalization.text(.delimiterSemicolon)
        case .pipe: return SpreadsheetPreviewLocalization.text(.delimiterPipe)
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

/// Backward compatibility alias.
public typealias TTMediaSpreadsheetDelimiter = TTSpreadsheetDelimiter

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

    @MainActor
    public var localizedDisplayName: String {
        switch self {
        case .all:
            return SpreadsheetPreviewLocalization.text(.pageSizeAllRows)
        default:
            return SpreadsheetPreviewLocalization.pageSizeRows(rawValue)
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

    @MainActor
    public var localizedTitle: String {
        switch self {
        case .table: return SpreadsheetPreviewLocalization.text(.modeTable)
        case .source: return SpreadsheetPreviewLocalization.text(.modeSource)
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
        "\(TTSpreadsheetParser.columnLetter(for: column))\(row + 1)"
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

// MARK: - Asynchronous Spreadsheet Parse Result

/// Thread-safe result container holding parsed spreadsheet data and layout metrics.
public struct SpreadsheetParseResult: Sendable {
    public let sheetName: String
    public let parsedRows: [[String]]
    public let rawContent: String
    public let columnWidths: [Int: CGFloat]

    public init(sheetName: String, parsedRows: [[String]], rawContent: String, columnWidths: [Int: CGFloat]) {
        self.sheetName = sheetName
        self.parsedRows = parsedRows
        self.rawContent = rawContent
        self.columnWidths = columnWidths
    }
}

// MARK: - Memoized Table State

/// Memoized state model managing table metrics, column geometry, and filtered row indices.
/// Replaces unmemoized per-render evaluations and maintains row indices ([Int]) rather than full structs.
public struct SpreadsheetTableState: Sendable {
    public let maxColumnCount: Int
    public let totalRowCount: Int
    public let totalCellCount: Int
    public let effectiveRowCount: Int
    public let headerNames: [String]
    /// Filtered row indices into the underlying raw rows array. Nil when no search filter is active.
    public let filteredRowIndices: [Int]?

    public init(
        parsedRows: [[String]],
        useFirstRowAsHeader: Bool,
        searchQuery: String
    ) {
        let totalRows = parsedRows.count
        self.totalRowCount = totalRows

        var maxCols = 0
        var totalCells = 0
        for row in parsedRows {
            if row.count > maxCols { maxCols = row.count }
            totalCells += row.count
        }
        self.maxColumnCount = maxCols
        self.totalCellCount = totalCells

        let startRow = useFirstRowAsHeader && !parsedRows.isEmpty ? 1 : 0
        let effCount = max(0, totalRows - startRow)
        self.effectiveRowCount = effCount

        if useFirstRowAsHeader && !parsedRows.isEmpty {
            self.headerNames = parsedRows[0]
        } else {
            self.headerNames = (0..<maxCols).map { TTSpreadsheetParser.columnLetter(for: $0) }
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            self.filteredRowIndices = nil
        } else {
            var indices: [Int] = []
            indices.reserveCapacity(min(effCount, 1024))
            for rowIndex in startRow..<totalRows {
                let row = parsedRows[rowIndex]
                if row.contains(where: { $0.localizedCaseInsensitiveContains(trimmedQuery) }) {
                    indices.append(rowIndex)
                }
            }
            self.filteredRowIndices = indices
        }
    }

    public var filteredRowCount: Int {
        filteredRowIndices?.count ?? effectiveRowCount
    }

    public var isFiltered: Bool {
        filteredRowIndices != nil
    }

    public func effectiveRowIndex(at filteredIndex: Int, useFirstRowAsHeader: Bool) -> Int {
        if let indices = filteredRowIndices {
            return indices[filteredIndex]
        }
        return useFirstRowAsHeader ? (filteredIndex + 1) : filteredIndex
    }

    public func pageSize(for option: SpreadsheetPageSizeOption) -> Int {
        option.rawValue == -1 ? max(1, filteredRowCount) : option.rawValue
    }

    public func totalPages(for option: SpreadsheetPageSizeOption) -> Int {
        let count = filteredRowCount
        if count == 0 || option.rawValue == -1 { return 1 }
        let ps = pageSize(for: option)
        return max(1, (count + ps - 1) / ps)
    }

    /// Maps only the currently visible page slice into `SpreadsheetRowItem` structs.
    public func makePaginatedRowItems(
        parsedRows: [[String]],
        currentPageIndex: Int,
        pageSizeOption: SpreadsheetPageSizeOption,
        useFirstRowAsHeader: Bool
    ) -> [SpreadsheetRowItem] {
        let totalCount = filteredRowCount
        guard totalCount > 0 else { return [] }

        let ps = pageSize(for: pageSizeOption)
        let start = min(currentPageIndex * ps, totalCount)
        let end = min(start + ps, totalCount)
        guard start < end else { return [] }

        var items: [SpreadsheetRowItem] = []
        items.reserveCapacity(end - start)

        for i in start..<end {
            let rowIndex = effectiveRowIndex(at: i, useFirstRowAsHeader: useFirstRowAsHeader)
            guard rowIndex < parsedRows.count else { continue }
            let cells = parsedRows[rowIndex]
            items.append(SpreadsheetRowItem(id: i, originalIndex: rowIndex + 1, cells: cells))
        }
        return items
    }
}
