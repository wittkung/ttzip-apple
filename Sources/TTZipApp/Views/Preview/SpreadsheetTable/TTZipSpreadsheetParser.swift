// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

// MARK: - RFC 4180 High-Performance CSV/TSV Parser

public enum TTZipSpreadsheetParser {
    
    /// Auto-detects the most likely delimiter from text content.
    public static func detectDelimiter(in text: String, defaultDelimiter: TTZipSpreadsheetDelimiter = .comma) -> TTZipSpreadsheetDelimiter {
        let sampleLines = text.components(separatedBy: .newlines).prefix(40).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !sampleLines.isEmpty else { return defaultDelimiter }
        
        var scores: [TTZipSpreadsheetDelimiter: (total: Int, lineCounts: [Int])] = [
            .comma: (0, []),
            .tab: (0, []),
            .semicolon: (0, []),
            .pipe: (0, [])
        ]
        
        for line in sampleLines {
            var inQuotes = false
            var commaCount = 0
            var tabCount = 0
            var semiCount = 0
            var pipeCount = 0
            
            for ch in line {
                if ch == "\"" {
                    inQuotes.toggle()
                } else if !inQuotes {
                    if ch == "," { commaCount += 1 }
                    else if ch == "\t" { tabCount += 1 }
                    else if ch == ";" { semiCount += 1 }
                    else if ch == "|" { pipeCount += 1 }
                }
            }
            
            scores[.comma]?.total += commaCount
            scores[.comma]?.lineCounts.append(commaCount)
            
            scores[.tab]?.total += tabCount
            scores[.tab]?.lineCounts.append(tabCount)
            
            scores[.semicolon]?.total += semiCount
            scores[.semicolon]?.lineCounts.append(semiCount)
            
            scores[.pipe]?.total += pipeCount
            scores[.pipe]?.lineCounts.append(pipeCount)
        }
        
        var bestDelimiter = defaultDelimiter
        var bestScore: Double = -1
        
        for (delim, data) in scores {
            guard data.total > 0 else { continue }
            let nonZeroLines = data.lineCounts.filter { $0 > 0 }.count
            let consistency = Double(nonZeroLines) / Double(sampleLines.count)
            let score = Double(data.total) * consistency * (consistency > 0.5 ? 2.0 : 0.5)
            if score > bestScore {
                bestScore = score
                bestDelimiter = delim
            }
        }
        
        return bestDelimiter
    }
    
    /// Parses structured table data according to RFC 4180.
    public static func parse(text: String, delimiter: Character? = nil) -> [[String]] {
        let actualDelimiter = delimiter ?? detectDelimiter(in: text).rawValue
        
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentCell = ""
        
        var inQuotes = false
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        let endIndex = scalars.endIndex
        
        while index < endIndex {
            let char = Character(scalars[index])
            
            if inQuotes {
                if char == "\"" {
                    let nextIndex = scalars.index(after: index)
                    if nextIndex < endIndex && Character(scalars[nextIndex]) == "\"" {
                        // Escaped quote: "" -> "
                        currentCell.append("\"")
                        index = nextIndex
                    } else {
                        // Closing quote
                        inQuotes = false
                    }
                } else {
                    currentCell.append(char)
                }
            } else {
                if char == "\"" {
                    inQuotes = true
                } else if char == actualDelimiter {
                    currentRow.append(currentCell)
                    currentCell = ""
                } else if char == "\r" {
                    let nextIndex = scalars.index(after: index)
                    if nextIndex < endIndex && Character(scalars[nextIndex]) == "\n" {
                        index = nextIndex // Skip \r\n
                    }
                    currentRow.append(currentCell)
                    currentCell = ""
                    rows.append(currentRow)
                    currentRow = []
                } else if char == "\n" {
                    currentRow.append(currentCell)
                    currentCell = ""
                    rows.append(currentRow)
                    currentRow = []
                } else {
                    currentCell.append(char)
                }
            }
            
            index = scalars.index(after: index)
        }
        
        // Append trailing cell / row
        if !currentCell.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentCell)
            rows.append(currentRow)
        }
        
        // Trim trailing empty rows
        while let lastRow = rows.last, lastRow.count == 1, lastRow[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.removeLast()
        }
        
        return rows
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
}
