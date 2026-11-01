// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// MARK: - RFC 4180 High-Performance CSV/TSV Parser

/// Strongly typed cell value descriptor for structured spreadsheet data.
public enum TTSpreadsheetCellValue: Sendable {
    case empty
    case text(String)
    case number(Double)
    case boolean(Bool)
    case formula(expression: String, cachedValue: String?)
    case error(String)
}

/// Structural cell descriptor with row, column, and typed value.
public struct TTSpreadsheetCellData: Sendable {
    public let row: Int
    public let col: Int
    public let value: TTSpreadsheetCellValue
    
    public init(row: Int, col: Int, value: TTSpreadsheetCellValue) {
        self.row = row
        self.col = col
        self.value = value
    }
}

/// Structural sheet row container.
public struct TTSpreadsheetRowData: Sendable {
    public let row: Int
    public let cells: [TTSpreadsheetCellData]
    
    public init(row: Int, cells: [TTSpreadsheetCellData]) {
        self.row = row
        self.cells = cells
    }
}

/// Structured worksheet representation with dimensions and cells.
public struct TTSpreadsheetSheetData: Sendable {
    public let sheetName: String
    public let totalRows: Int
    public let totalCols: Int
    public let rows: [TTSpreadsheetRowData]
    
    public init(sheetName: String, totalRows: Int, totalCols: Int, rows: [TTSpreadsheetRowData]) {
        self.sheetName = sheetName
        self.totalRows = totalRows
        self.totalCols = totalCols
        self.rows = rows
    }
}

/// Result of bounded spreadsheet prefix parsing.
public struct TTSpreadsheetPrefixParseResult: Sendable {
    public let rows: [[String]]
    public let isTruncated: Bool

    public init(rows: [[String]], isTruncated: Bool) {
        self.rows = rows
        self.isTruncated = isTruncated
    }
}

/// High-performance RFC 4180 spreadsheet parsing, auto-detection, and export engine.
public enum TTSpreadsheetParser: Sendable {

    /// Maximum number of rows loaded into interactive table preview before truncation guard engages.
    public static let maxInteractivePreviewRows: Int = 50_000

    /// Maximum UTF-8 byte budget loaded into interactive spreadsheet preview before truncation guard engages.
    public static let maxInteractivePreviewUTF8Bytes: Int = 16 * 1024 * 1024

    /// Maximum scalars inspected during delimiter auto-detection.
    public static let maxDelimiterDetectionScalars: Int = 65_536

    /// Maximum non-empty logical records inspected during delimiter auto-detection.
    public static let maxDelimiterDetectionRecords: Int = 40

    private struct DelimiterScoreAccumulator {
        var total: Int = 0
        var nonZeroRecords: Int = 0

        mutating func record(_ count: Int) {
            total += count
            if count > 0 {
                nonZeroRecords += 1
            }
        }
    }

    private struct DelimiterScanState {
        var commaAcc = DelimiterScoreAccumulator()
        var tabAcc = DelimiterScoreAccumulator()
        var semiAcc = DelimiterScoreAccumulator()
        var pipeAcc = DelimiterScoreAccumulator()
        var recordCount = 0
        var scalarsScanned = 0
        var inQuotes = false
        var hasContent = false
        var commaCount = 0
        var tabCount = 0
        var semiCount = 0
        var pipeCount = 0

        mutating func flushRecordIfNonEmpty() {
            guard hasContent || commaCount > 0 || tabCount > 0 || semiCount > 0 || pipeCount > 0 else {
                return
            }
            commaAcc.record(commaCount)
            tabAcc.record(tabCount)
            semiAcc.record(semiCount)
            pipeAcc.record(pipeCount)
            recordCount += 1
            hasContent = false
            commaCount = 0
            tabCount = 0
            semiCount = 0
            pipeCount = 0
        }

        mutating func consumeOutsideQuotes(_ scalar: UnicodeScalar) {
            switch scalar {
            case "\"":
                inQuotes = true
                hasContent = true
            case "\r", "\n":
                flushRecordIfNonEmpty()
            case ",":
                commaCount += 1
                hasContent = true
            case "\t":
                tabCount += 1
            case ";":
                semiCount += 1
                hasContent = true
            case "|":
                pipeCount += 1
                hasContent = true
            case " ":
                break
            default:
                hasContent = true
            }
        }

        mutating func consumeInQuotes(
            _ scalar: UnicodeScalar,
            scalars: String.UnicodeScalarView,
            index: inout String.UnicodeScalarView.Index,
            endIndex: String.UnicodeScalarView.Index
        ) {
            if scalar == "\"" {
                let nextIndex = scalars.index(after: index)
                if nextIndex < endIndex && scalars[nextIndex] == "\"" {
                    index = nextIndex
                    scalarsScanned += 1
                } else {
                    inQuotes = false
                }
            }
            if !isWhitespaceOrNewline(scalar) {
                hasContent = true
            }
        }

        private func isWhitespaceOrNewline(_ scalar: UnicodeScalar) -> Bool {
            switch scalar {
            case " ", "\t", "\r", "\n":
                return true
            default:
                return false
            }
        }
    }

    /// Auto-detects the most likely delimiter from text content using a bounded single-pass scan.
    /// Tracks RFC 4180 quoted fields and escaped quotes so multiline cells do not split logical records.
    public static func detectDelimiter(
        in text: String,
        defaultDelimiter: TTSpreadsheetDelimiter = .comma
    ) -> TTSpreadsheetDelimiter {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        let endIndex = scalars.endIndex
        guard index < endIndex else { return defaultDelimiter }

        var state = DelimiterScanState()
        while index < endIndex && state.recordCount < maxDelimiterDetectionRecords && state.scalarsScanned < maxDelimiterDetectionScalars {
            let scalar = scalars[index]
            state.scalarsScanned += 1

            if state.inQuotes {
                state.consumeInQuotes(scalar, scalars: scalars, index: &index, endIndex: endIndex)
            } else {
                advanceCRLFIfNeeded(scalar: scalar, scalars: scalars, index: &index, endIndex: endIndex, counter: &state.scalarsScanned)
                state.consumeOutsideQuotes(scalar)
            }
            index = scalars.index(after: index)
        }

        if state.recordCount < maxDelimiterDetectionRecords {
            state.flushRecordIfNonEmpty()
        }
        return selectBestDelimiter(from: state, defaultDelimiter: defaultDelimiter)
    }

    private static func advanceCRLFIfNeeded(
        scalar: UnicodeScalar,
        scalars: String.UnicodeScalarView,
        index: inout String.UnicodeScalarView.Index,
        endIndex: String.UnicodeScalarView.Index,
        counter: inout Int
    ) {
        guard scalar == "\r" else { return }
        let nextIndex = scalars.index(after: index)
        if nextIndex < endIndex && scalars[nextIndex] == "\n" {
            index = nextIndex
            counter += 1
        }
    }

    private static func selectBestDelimiter(
        from state: DelimiterScanState,
        defaultDelimiter: TTSpreadsheetDelimiter
    ) -> TTSpreadsheetDelimiter {
        guard state.recordCount > 0 else { return defaultDelimiter }
        let candidates: [(TTSpreadsheetDelimiter, DelimiterScoreAccumulator)] = [
            (.comma, state.commaAcc),
            (.tab, state.tabAcc),
            (.semicolon, state.semiAcc),
            (.pipe, state.pipeAcc)
        ]

        var bestDelimiter = defaultDelimiter
        var bestScore: Double = -1
        for (delim, acc) in candidates where acc.total > 0 {
            let consistency = Double(acc.nonZeroRecords) / Double(state.recordCount)
            let score = Double(acc.total) * consistency * (consistency > 0.5 ? 2.0 : 0.5)
            if score > bestScore {
                bestScore = score
                bestDelimiter = delim
            }
        }
        return bestDelimiter
    }

    /// Parses structured table data according to RFC 4180 with cooperative task cancellation.
    public static func parse(text: String, delimiter: Character? = nil) -> [[String]] {
        parsePrefix(text: text, delimiter: delimiter, maxRows: .max, maxUTF8Bytes: .max).rows
    }

    /// Parses up to `maxRows` and `maxUTF8Bytes` of RFC 4180 structured table data with cooperative cancellation.
    public static func parsePrefix(
        text: String,
        delimiter: Character? = nil,
        maxRows: Int,
        maxUTF8Bytes: Int = .max
    ) -> TTSpreadsheetPrefixParseResult {
        guard maxRows > 0, !text.isEmpty, !Task.isCancelled else {
            return TTSpreadsheetPrefixParseResult(rows: [], isTruncated: false)
        }

        let (boundedText, didTruncateBytes) = truncateUTF8Prefix(text, maxBytes: maxUTF8Bytes)
        let actualDelimiter = delimiter ?? detectDelimiter(in: boundedText).rawValue
        let delimScalar = actualDelimiter.unicodeScalars.first ?? UnicodeScalar(44 as UInt8)

        var rows: [[String]] = []
        rows.reserveCapacity(min(maxRows, 512))
        var currentRow: [String] = []
        var currentCell = ""
        var inQuotes = false
        var scalarsSinceCancelCheck = 0

        let scalars = boundedText.unicodeScalars
        var index = scalars.startIndex
        let endIndex = scalars.endIndex

        while index < endIndex && rows.count < maxRows {
            scalarsSinceCancelCheck += 1
            if scalarsSinceCancelCheck >= 4096 {
                if Task.isCancelled { return TTSpreadsheetPrefixParseResult(rows: [], isTruncated: false) }
                scalarsSinceCancelCheck = 0
            }

            consumeCSVStep(
                scalars: scalars,
                index: &index,
                endIndex: endIndex,
                delimScalar: delimScalar,
                inQuotes: &inQuotes,
                currentCell: &currentCell,
                currentRow: &currentRow,
                rows: &rows
            )
            if (rows.count & 0xFF) == 0 && !rows.isEmpty && Task.isCancelled {
                return TTSpreadsheetPrefixParseResult(rows: [], isTruncated: false)
            }
            index = scalars.index(after: index)
        }

        return finalizeParsedPrefix(
            rows: &rows,
            currentRow: &currentRow,
            currentCell: currentCell,
            maxRows: maxRows,
            didTruncateBytes: didTruncateBytes,
            scalars: scalars,
            stoppedIndex: index
        )
    }

    private static func consumeCSVStep(
        scalars: String.UnicodeScalarView,
        index: inout String.UnicodeScalarView.Index,
        endIndex: String.UnicodeScalarView.Index,
        delimScalar: UnicodeScalar,
        inQuotes: inout Bool,
        currentCell: inout String,
        currentRow: inout [String],
        rows: inout [[String]]
    ) {
        let scalar = scalars[index]
        if inQuotes {
            consumeQuotedCSVStep(scalar: scalar, scalars: scalars, index: &index, endIndex: endIndex, inQuotes: &inQuotes, currentCell: &currentCell)
        } else if scalar == "\"" {
            inQuotes = true
        } else if scalar == delimScalar {
            currentRow.append(currentCell)
            currentCell = ""
        } else if scalar == "\r" || scalar == "\n" {
            var dummyCounter = 0
            advanceCRLFIfNeeded(scalar: scalar, scalars: scalars, index: &index, endIndex: endIndex, counter: &dummyCounter)
            currentRow.append(currentCell)
            currentCell = ""
            rows.append(currentRow)
            currentRow = []
        } else {
            currentCell.unicodeScalars.append(scalar)
        }
    }

    private static func consumeQuotedCSVStep(
        scalar: UnicodeScalar,
        scalars: String.UnicodeScalarView,
        index: inout String.UnicodeScalarView.Index,
        endIndex: String.UnicodeScalarView.Index,
        inQuotes: inout Bool,
        currentCell: inout String
    ) {
        guard scalar == "\"" else {
            currentCell.unicodeScalars.append(scalar)
            return
        }
        let next = scalars.index(after: index)
        if next < endIndex && scalars[next] == "\"" {
            currentCell.unicodeScalars.append("\"")
            index = next
        } else {
            inQuotes = false
        }
    }

    private static func finalizeParsedPrefix(
        rows: inout [[String]],
        currentRow: inout [String],
        currentCell: String,
        maxRows: Int,
        didTruncateBytes: Bool,
        scalars: String.UnicodeScalarView,
        stoppedIndex: String.UnicodeScalarView.Index
    ) -> TTSpreadsheetPrefixParseResult {
        if Task.isCancelled {
            return TTSpreadsheetPrefixParseResult(rows: [], isTruncated: false)
        }
        let stoppedEarlyAtRowLimit: Bool
        if rows.count >= maxRows {
            stoppedEarlyAtRowLimit = hasRemainingNonWhitespace(in: scalars, from: stoppedIndex, endIndex: scalars.endIndex)
        } else {
            stoppedEarlyAtRowLimit = false
            if !currentCell.isEmpty || !currentRow.isEmpty {
                currentRow.append(currentCell)
                rows.append(currentRow)
            }
            while let lastRow = rows.last, lastRow.count == 1,
                  lastRow[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.removeLast()
            }
        }
        return TTSpreadsheetPrefixParseResult(
            rows: rows,
            isTruncated: didTruncateBytes || stoppedEarlyAtRowLimit
        )
    }

    /// Safely truncates a string to at most `maxBytes` UTF-8 bytes on a valid Unicode scalar boundary.
    public static func truncateUTF8Prefix(_ text: String, maxBytes: Int) -> (text: String, isTruncated: Bool) {
        guard maxBytes < .max else { return (text, false) }
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return (text, false) }
        guard maxBytes > 0 else { return ("", !text.isEmpty) }

        var cutIndex = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while cutIndex > utf8.startIndex && (utf8[cutIndex] & 0b1100_0000) == 0b1000_0000 {
            cutIndex = utf8.index(before: cutIndex)
        }
        return (String(text[..<cutIndex]), true)
    }

    /// Fast synchronous check whether spreadsheet text or workbook exceeds interactive preview budget.
    public static func exceedsPreviewBudget(
        text: String,
        workbook: OfficeSpreadsheetWorkbook? = nil,
        maxRows: Int = maxInteractivePreviewRows,
        maxUTF8Bytes: Int = maxInteractivePreviewUTF8Bytes
    ) -> Bool {
        if let activeSheet = workbook?.activeSheet,
           activeSheet.isTruncated || activeSheet.rows.count > maxRows {
            return true
        }
        let utf8 = text.utf8
        if utf8.count > maxUTF8Bytes {
            return true
        }
        let newlineCount = countUTF8Byte(0x0A, in: text, stopAfter: maxRows + 1)
        if newlineCount <= maxRows {
            return false
        }
        let quoteCount = countUTF8Byte(0x22, in: text, stopAfter: 1)
        if quoteCount == 0 {
            return true
        }
        return parsePrefix(text: text, maxRows: maxRows, maxUTF8Bytes: maxUTF8Bytes).isTruncated
    }

    private static func hasRemainingNonWhitespace(
        in scalars: String.UnicodeScalarView,
        from startIndex: String.UnicodeScalarView.Index,
        endIndex: String.UnicodeScalarView.Index
    ) -> Bool {
        var idx = startIndex
        while idx < endIndex {
            let s = scalars[idx]
            if s != " " && s != "\t" && s != "\r" && s != "\n" {
                return true
            }
            idx = scalars.index(after: idx)
        }
        return false
    }

    private static func countUTF8Byte(_ target: UInt8, in text: String, stopAfter limit: Int) -> Int {
        var count = 0
        let handled: Bool? = text.utf8.withContiguousStorageIfAvailable { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return true }
            var offset = 0
            let total = buffer.count
            while offset < total && count < limit {
                guard let found = memchr(base.advanced(by: offset), Int32(target), total - offset) else {
                    break
                }
                count += 1
                let matchedPtr = found.assumingMemoryBound(to: UInt8.self)
                offset = base.distance(to: matchedPtr) + 1
            }
            return true
        }
        if handled == nil {
            for byte in text.utf8 {
                if byte == target {
                    count += 1
                    if count >= limit { break }
                }
            }
        }
        return count
    }
    
    /// Converts 0-based column index to Excel-style letter (0 -> A, 25 -> Z, 26 -> AA, 27 -> AB, etc.).
    public static func columnLetter(for index: Int) -> String {
        var n = index + 1
        var result = ""
        while n > 0 {
            let rem = (n - 1) % 26
            if let scalar = UnicodeScalar(65 + rem) {
                result = String(scalar) + result
            }
            n = (n - 1) / 26
        }
        return result
    }
    
    /// Generates Markdown Table string from rows.
    public static func exportToMarkdownTable(rows: [[String]], hasHeader: Bool) -> String {
        guard !rows.isEmpty else { return "" }
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount > 0 else { return "" }
        
        func sanitizeCell(_ c: String) -> String {
            c.replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "|", with: "\\|")
        }
        
        var output = ""
        let headerRow = rows[0]
        let headers: [String]
        let bodyRows: [[String]]
        
        if hasHeader {
            headers = (0..<colCount).map { i in i < headerRow.count ? sanitizeCell(headerRow[i]) : "Col \(i+1)" }
            bodyRows = Array(rows.dropFirst())
        } else {
            headers = (0..<colCount).map { columnLetter(for: $0) }
            bodyRows = rows
        }
        
        output += "| " + headers.joined(separator: " | ") + " |\n"
        output += "| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |\n"
        
        for r in bodyRows {
            let cells = (0..<colCount).map { i in i < r.count ? sanitizeCell(r[i]) : "" }
            output += "| " + cells.joined(separator: " | ") + " |\n"
        }
        return output
    }
    
    /// Generates CSV/TSV format string from rows according to RFC 4180.
    public static func exportToDelimited(rows: [[String]], delimiter: Character) -> String {
        guard !rows.isEmpty else { return "" }
        var result = ""
        for row in rows {
            let formattedCells = row.map { cell -> String in
                if cell.contains(delimiter) || cell.contains("\"") || cell.contains("\n") || cell.contains("\r") {
                    let escaped = cell.replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(escaped)\""
                }
                return cell
            }
            result += formattedCells.joined(separator: String(delimiter)) + "\n"
        }
        return result
    }
    
    /// Converts TTMediaSheetData into 2D String matrix for table grid view.
    public static func convertSheetDataToRows(_ sheetData: TTMediaSheetData) -> [[String]] {
        return sheetData.rows
    }
    
    /// Converts TTSpreadsheetSheetData into 2D String matrix for table grid view.
    public static func convertSheetDataToRows(_ sheetData: TTSpreadsheetSheetData) -> [[String]] {
        let maxCol = max(sheetData.totalCols, sheetData.rows.flatMap(\.cells).map { $0.col }.max() ?? 0)
        guard maxCol > 0 else { return [] }
        var grid: [[String]] = []
        for sheetRow in sheetData.rows {
            var rowArray = Array(repeating: "", count: maxCol)
            for cell in sheetRow.cells {
                let colIdx = cell.col - 1
                if colIdx >= 0 && colIdx < maxCol {
                    rowArray[colIdx] = formatCellValue(cell.value)
                }
            }
            grid.append(rowArray)
        }
        return grid
    }
    
    /// Formats strongly-typed TTSpreadsheetCellValue into human-readable display string.
    public static func formatCellValue(_ value: TTSpreadsheetCellValue) -> String {
        switch value {
        case .empty:
            return ""
        case .text(let text):
            return text
        case .number(let num):
            if num.truncatingRemainder(dividingBy: 1) == 0 && abs(num) < 1e15 {
                return String(Int64(num))
            } else {
                return String(format: "%g", num)
            }
        case .boolean(let b):
            return b ? "TRUE" : "FALSE"
        case .formula(let expr, let cached):
            return cached ?? "=\(expr)"
        case .error(let err):
            return "#ERR: \(err)"
        }
    }
}

// MARK: - Compatibility Aliases

public typealias TTMediaSpreadsheetParser = TTSpreadsheetParser
