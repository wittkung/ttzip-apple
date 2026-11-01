// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitDesign
#if os(macOS)
import AppKit

public final class TTSpreadsheetContentProbeNSView: NSView {
    public var renderedRowCount: Int = 0
    public var renderedColumnCount: Int = 0
    public var firstRowCells: [String] = []
    public var headers: [String] = []
    public var resolvedColumnWidths: [CGFloat] = []
    public var allRows: [[String]] = []
    public var renderedRowNumbers: [Int] = []
    public var simulateCellTap: (@MainActor (Int, Int) -> Void)?
}

struct TTSpreadsheetContentProbeRepresentable: NSViewRepresentable {
    let renderedRowCount: Int
    let renderedColumnCount: Int
    let firstRowCells: [String]
    let headers: [String]
    let resolvedColumnWidths: [CGFloat]
    let allRows: [[String]]
    let renderedRowNumbers: [Int]
    let simulateCellTap: @MainActor (Int, Int) -> Void

    func makeNSView(context: Context) -> TTSpreadsheetContentProbeNSView {
        let probe = TTSpreadsheetContentProbeNSView(frame: .zero)
        updateProbe(probe)
        return probe
    }

    func updateNSView(_ nsView: TTSpreadsheetContentProbeNSView, context: Context) {
        updateProbe(nsView)
    }

    private func updateProbe(_ probe: TTSpreadsheetContentProbeNSView) {
        probe.renderedRowCount = renderedRowCount
        probe.renderedColumnCount = renderedColumnCount
        probe.firstRowCells = firstRowCells
        probe.headers = headers
        probe.resolvedColumnWidths = resolvedColumnWidths
        probe.allRows = allRows
        probe.renderedRowNumbers = renderedRowNumbers
        probe.simulateCellTap = simulateCellTap
    }
}
#endif

/// Declarative, high-efficiency tabular data visualizer with bidirectional scrolling,
/// sticky headers, deterministic column alignment, multiline cell support, and zebra-striped contrast.
public struct TTSpreadsheetView: View {
    public static let gutterWidth: CGFloat = 44.0
    public static let maxAutoColumnWidth: CGFloat = 380.0

    public let headers: [String]
    public let rows: [[String]]
    public var rowNumbers: [Int]?
    public var columnAlignments: [Alignment]?
    public var columnWidths: [Int: CGFloat]
    public var availableWidth: CGFloat
    public var minColumnWidth: CGFloat
    public var rowHeight: CGFloat
    public var alternateRowColor: Color
    public var headerBackgroundColor: Color
    public var selectedCell: (row: Int, column: Int)?
    public var onRowSelect: (@MainActor @Sendable (Int) -> Void)?
    public var onCellSelect: (@MainActor @Sendable (Int, Int) -> Void)?
    public var onCopyCell: (@MainActor @Sendable (Int, Int, String) -> Void)?

    @State private var selectedRowIndex: Int?
    @State private var selectedColumnIndex: Int?
    @State private var hoveredRowIndex: Int?

    public init(
        headers: [String],
        rows: [[String]],
        rowNumbers: [Int]? = nil,
        columnAlignments: [Alignment]? = nil,
        columnWidths: [Int: CGFloat] = [:],
        availableWidth: CGFloat = 0.0,
        minColumnWidth: CGFloat = 90.0,
        rowHeight: CGFloat = 30.0,
        alternateRowColor: Color = Color.primary.opacity(0.035),
        headerBackgroundColor: Color = Color.secondary.opacity(0.12),
        selectedCell: (row: Int, column: Int)? = nil,
        onRowSelect: (@MainActor @Sendable (Int) -> Void)? = nil,
        onCellSelect: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
        onCopyCell: (@MainActor @Sendable (Int, Int, String) -> Void)? = nil
    ) {
        self.headers = headers
        self.rows = rows
        self.rowNumbers = rowNumbers
        self.columnAlignments = columnAlignments
        self.columnWidths = columnWidths
        self.availableWidth = availableWidth
        self.minColumnWidth = max(50.0, minColumnWidth)
        self.rowHeight = max(28.0, rowHeight)
        self.alternateRowColor = alternateRowColor
        self.headerBackgroundColor = headerBackgroundColor
        self.selectedCell = selectedCell
        self.onRowSelect = onRowSelect
        self.onCellSelect = onCellSelect
        self.onCopyCell = onCopyCell
    }

    public var columnCount: Int {
        let maxRowCols = rows.prefix(64).map(\.count).max() ?? 0
        return max(headers.count, maxRowCols)
    }

    public func resolvedColumnWidths(availableWidth: CGFloat = 0) -> [CGFloat] {
        let count = columnCount
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

        let targetTableWidth = availableWidth - Self.gutterWidth
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

    private func alignment(for columnIndex: Int) -> Alignment {
        if let alignments = columnAlignments, columnIndex < alignments.count {
            return alignments[columnIndex]
        }
        for row in rows.prefix(8) where columnIndex < row.count {
            let cell = row[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !cell.isEmpty && Double(cell) != nil {
                return .trailing
            }
        }
        return .leading
    }

    private func effectiveRowHeight(for row: [String]) -> CGFloat {
        let hasMultiline = row.contains { $0.contains("\n") || $0.contains("\r") }
        return hasMultiline ? max(rowHeight, 42.0) : rowHeight
    }

    public var body: some View {
        if headers.isEmpty && rows.isEmpty {
            ContentUnavailableView {
                Label(SpreadsheetPreviewLocalization.text(.emptyTableTitle), systemImage: "tablecells")
            } description: {
                Text(SpreadsheetPreviewLocalization.text(.emptyTableDescription))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let colWidths = resolvedColumnWidths(availableWidth: availableWidth)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if !headers.isEmpty {
                        headerView(colWidths: colWidths)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowData in
                        #if os(macOS)
                        if rowIndex == 0 {
                            rowView(index: rowIndex, row: rowData, colWidths: colWidths)
                                .background(
                                    TTSpreadsheetContentProbeRepresentable(
                                        renderedRowCount: rows.count,
                                        renderedColumnCount: columnCount,
                                        firstRowCells: rows.first ?? [],
                                        headers: headers,
                                        resolvedColumnWidths: colWidths,
                                        allRows: rows,
                                        renderedRowNumbers: rowNumbers ?? Array(1...rows.count),
                                        simulateCellTap: { tappedRow, tappedCol in
                                            selectedRowIndex = tappedRow
                                            selectedColumnIndex = tappedCol
                                            onCellSelect?(tappedRow, tappedCol)
                                            onRowSelect?(tappedRow)
                                        }
                                    )
                                )
                        } else {
                            rowView(index: rowIndex, row: rowData, colWidths: colWidths)
                        }
                        #else
                        rowView(index: rowIndex, row: rowData, colWidths: colWidths)
                        #endif
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.clear)
        }
    }

    private func headerView(colWidths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.gutterWidth, height: rowHeight, alignment: .center)
                .background(headerBackgroundColor)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5)
                }

            ForEach(0..<colWidths.count, id: \.self) { colIndex in
                let title = colIndex < headers.count ? headers[colIndex] : "Col \(colIndex + 1)"
                let displayTitle = title.replacingOccurrences(of: "\r\n", with: " ↵ ").replacingOccurrences(of: "\n", with: " ↵ ")
                Text(displayTitle)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(width: colWidths[colIndex], height: rowHeight, alignment: alignment(for: colIndex))
                    .help(title)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5)
                    }
            }
        }
        .background(headerBackgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.16)).frame(height: 0.5)
        }
    }

    private func rowView(index: Int, row: [String], colWidths: [CGFloat]) -> some View {
        let activeRow = selectedCell?.row ?? selectedRowIndex
        let activeCol = selectedCell?.column ?? selectedColumnIndex
        let isRowSelected = activeRow == index
        let isHovered = hoveredRowIndex == index
        let isEven = index.isMultiple(of: 2)
        let currentRowHeight = effectiveRowHeight(for: row)
        let displayRowNum = displayedRowNumber(at: index)

        return HStack(spacing: 0) {
            Text("\(displayRowNum)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.85))
                .frame(width: Self.gutterWidth, height: currentRowHeight, alignment: .center)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedRowIndex = index
                    selectedColumnIndex = 0
                    onCellSelect?(index, 0)
                    onRowSelect?(index)
                }

            ForEach(0..<colWidths.count, id: \.self) { colIndex in
                cellView(
                    rowIndex: index,
                    colIndex: colIndex,
                    cellText: colIndex < row.count ? row[colIndex] : "",
                    width: colWidths[colIndex],
                    height: currentRowHeight,
                    isCellSelected: isRowSelected && activeCol == colIndex
                )
            }
        }
        .background(rowBackground(isSelected: isRowSelected, isHovered: isHovered, isEven: isEven))
        #if os(macOS)
        .onHover { inside in
            if inside {
                hoveredRowIndex = index
            } else if hoveredRowIndex == index {
                hoveredRowIndex = nil
            }
        }
        #endif
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func displayedRowNumber(at index: Int) -> Int {
        if let rowNumbers, index < rowNumbers.count {
            return rowNumbers[index]
        }
        return index + 1
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool, isEven: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.05) }
        return isEven ? alternateRowColor : .clear
    }

    private func cellView(
        rowIndex: Int,
        colIndex: Int,
        cellText: String,
        width: CGFloat,
        height: CGFloat,
        isCellSelected: Bool
    ) -> some View {
        let hasNewline = cellText.contains("\n") || cellText.contains("\r")
        let align = alignment(for: colIndex)

        return Text(cellText)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(hasNewline ? 2 : 1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, hasNewline ? 3 : 0)
            .frame(width: width, height: height, alignment: align)
            .background(isCellSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5)
            }
            .contentShape(Rectangle())
            .help(cellText)
            .onTapGesture {
                selectedRowIndex = rowIndex
                selectedColumnIndex = colIndex
                onCellSelect?(rowIndex, colIndex)
                onRowSelect?(rowIndex)
            }
            .contextMenu {
                Button(SpreadsheetPreviewLocalization.text(.copyCellTextHelp)) {
                    onCopyCell?(rowIndex, colIndex, cellText)
                }
            }
    }
}
