// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public enum SpreadsheetColumnSizing {
    public static let maxAutoColumnWidth: CGFloat = 380

    public static func columnCount(headers: [String], rows: [[String]]) -> Int {
        let maxRowCols = rows.prefix(64).map(\.count).max() ?? 0
        return max(headers.count, maxRowCols)
    }

    public static func resolve(
        headers: [String],
        rows: [[String]],
        columnWidths: [Int: CGFloat],
        availableWidth: CGFloat,
        minColumnWidth: CGFloat,
        gutterWidth: CGFloat
    ) -> [CGFloat] {
        let count = columnCount(headers: headers, rows: rows)
        guard count > 0 else { return [] }
        let sampleRows = Array(rows.prefix(100))
        var baseWidths: [CGFloat] = []
        baseWidths.reserveCapacity(count)

        for colIndex in 0..<count {
            if let explicit = columnWidths[colIndex], explicit >= minColumnWidth {
                baseWidths.append(min(Self.maxAutoColumnWidth, explicit))
                continue
            }
            let headerTitle = colIndex < headers.count ? headers[colIndex] : "Col \(colIndex + 1)"
            var maxUnits = Self.visualUnitCount(of: headerTitle)
            for row in sampleRows where colIndex < row.count {
                maxUnits = max(maxUnits, Self.visualUnitCount(of: row[colIndex]))
            }
            let estimated = min(Self.maxAutoColumnWidth, max(minColumnWidth, CGFloat(maxUnits * 8 + 24)))
            baseWidths.append(estimated)
        }

        let targetTableWidth = availableWidth - gutterWidth
        let totalBase = baseWidths.reduce(0, +)
        guard targetTableWidth > totalBase, count > 0 else {
            return baseWidths
        }
        let extraPerCol = min(96.0, (targetTableWidth - totalBase) / CGFloat(count))
        guard extraPerCol > 1.0 else { return baseWidths }
        return baseWidths.map { $0 + floor(extraPerCol) }
    }

    private static func visualUnitCount(of text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var maxLineUnits = 1
        for line in lines {
            var units = 0
            for scalar in line.unicodeScalars {
                units += (scalar.value >= 0x2E80) ? 2 : 1
            }
            if units > maxLineUnits { maxLineUnits = units }
        }
        return maxLineUnits
    }
}
