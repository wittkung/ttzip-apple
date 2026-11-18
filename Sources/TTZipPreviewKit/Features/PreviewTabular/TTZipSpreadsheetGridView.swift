// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit
import TTZipUI

struct TTZipSpreadsheetGridView: View {
    let paginatedDataRows: [SpreadsheetRowItem]
    let headerNames: [String]
    let maxColumnCount: Int
    @Binding var selectedCoordinate: SpreadsheetCellCoordinate?
    let columnWidths: [Int: CGFloat]
    let availableWidth: CGFloat
    let onCopyText: (String, String) -> Void

    @State private var hoveredRowIndex: Int?

    private static let gutterWidth: CGFloat = 44
    private static let rowHeight: CGFloat = 28
    private let headerBackgroundColor = Color(NSColor.controlBackgroundColor)

    var body: some View {
        if headerNames.isEmpty && paginatedDataRows.isEmpty {
            ContentUnavailableView {
                Label(SpreadsheetPreviewLocalization.text(.emptyTableTitle), systemImage: "tablecells")
            } description: {
                Text(SpreadsheetPreviewLocalization.text(.emptyTableDescription))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let rows = paginatedDataRows.map(\.cells)
            let widths = SpreadsheetColumnSizing.resolve(
                headers: headerNames,
                rows: rows,
                columnWidths: columnWidths,
                availableWidth: availableWidth,
                minColumnWidth: 85,
                gutterWidth: Self.gutterWidth
            )
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if !headerNames.isEmpty {
                        headerView(widths: widths)
                    }
                    ForEach(Array(paginatedDataRows.enumerated()), id: \.offset) { index, row in
                        if index == 0 {
                            rowView(index: index, row: row, widths: widths)
                                .background(
                                    TTZipSpreadsheetGridProbe(
                                        headers: headerNames,
                                        allRows: rows,
                                        renderedRowNumbers: paginatedDataRows.map(\.originalIndex),
                                        resolvedColumnWidths: widths,
                                        activeSelectedCell: visibleSelectedCell,
                                        scrollIdentity: scrollIdentity,
                                        simulateCellTap: selectCell
                                    )
                                )
                        } else {
                            rowView(index: index, row: row, widths: widths)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.clear)
        }
    }

    private var visibleSelectedCell: (row: Int, column: Int)? {
        guard let selectedCoordinate,
              let index = paginatedDataRows.firstIndex(where: { $0.originalIndex - 1 == selectedCoordinate.row }) else {
            return nil
        }
        return (row: index, column: selectedCoordinate.column)
    }

    private var scrollIdentity: String {
        let firstRow = paginatedDataRows.first?.cells.prefix(8).joined(separator: "\u{1F}") ?? ""
        let lastRow = paginatedDataRows.last?.cells.prefix(8).joined(separator: "\u{1F}") ?? ""
        let firstNum = paginatedDataRows.first?.originalIndex ?? 0
        let lastNum = paginatedDataRows.last?.originalIndex ?? 0
        return "\(headerNames.joined(separator: "\u{1F}"))|\(paginatedDataRows.count)|\(firstNum)-\(lastNum)|\(firstRow)|\(lastRow)"
    }

    private func selectCell(rowIndex: Int, columnIndex: Int) {
        guard paginatedDataRows.indices.contains(rowIndex) else { return }
        selectedCoordinate = coordinate(for: paginatedDataRows[rowIndex], columnIndex: columnIndex)
    }

    private func coordinate(for row: SpreadsheetRowItem, columnIndex: Int) -> SpreadsheetCellCoordinate {
        SpreadsheetCellCoordinate(row: max(0, row.originalIndex - 1), column: max(0, columnIndex))
    }

    private func alignment(for columnIndex: Int) -> Alignment {
        for row in paginatedDataRows.prefix(8) where columnIndex < row.cells.count {
            let cell = row.cells[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !cell.isEmpty && Double(cell) != nil {
                return .trailing
            }
        }
        return .leading
    }

    private func headerView(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.gutterWidth, height: Self.rowHeight, alignment: .center)
                .background(headerBackgroundColor)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5)
                }

            ForEach(widths.indices, id: \.self) { columnIndex in
                let title = columnIndex < headerNames.count ? headerNames[columnIndex] : "Col \(columnIndex + 1)"
                let displayTitle = title.replacingOccurrences(of: "\r\n", with: " ↵ ").replacingOccurrences(of: "\n", with: " ↵ ")
                Text(displayTitle)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(width: widths[columnIndex], height: Self.rowHeight, alignment: alignment(for: columnIndex))
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

    private func rowView(index: Int, row: SpreadsheetRowItem, widths: [CGFloat]) -> some View {
        let isSelected = selectedCoordinate?.row == row.originalIndex - 1
        let rowHeight = row.cells.contains(where: hasNewline) ? 42 : Self.rowHeight

        return HStack(spacing: 0) {
            Text("\(row.originalIndex)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.85))
                .frame(width: Self.gutterWidth, height: rowHeight, alignment: .center)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectCell(rowIndex: index, columnIndex: 0)
                }

            ForEach(widths.indices, id: \.self) { columnIndex in
                cellView(
                    rowIndex: index,
                    row: row,
                    columnIndex: columnIndex,
                    width: widths[columnIndex],
                    height: rowHeight,
                    isSelected: isSelected && selectedCoordinate?.column == columnIndex
                )
            }
        }
        .background(rowBackground(index: index, isSelected: isSelected))
        .onHover { inside in
            if inside {
                hoveredRowIndex = index
            } else if hoveredRowIndex == index {
                hoveredRowIndex = nil
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func hasNewline(_ text: String) -> Bool {
        text.contains("\n") || text.contains("\r")
    }

    private func rowBackground(index: Int, isSelected: Bool) -> Color {
        if isSelected { return TTZipTheme.accentColor.opacity(0.14) }
        if hoveredRowIndex == index { return Color.primary.opacity(0.05) }
        return index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear
    }

    private func cellView(
        rowIndex: Int,
        row: SpreadsheetRowItem,
        columnIndex: Int,
        width: CGFloat,
        height: CGFloat,
        isSelected: Bool
    ) -> some View {
        let text = columnIndex < row.cells.count ? row.cells[columnIndex] : ""
        let multiline = hasNewline(text)

        return Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(multiline ? 2 : 1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, multiline ? 3 : 0)
            .frame(width: width, height: height, alignment: alignment(for: columnIndex))
            .background(isSelected ? TTZipTheme.accentColor.opacity(0.18) : Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5)
            }
            .contentShape(Rectangle())
            .help(text)
            .onTapGesture {
                selectCell(rowIndex: rowIndex, columnIndex: columnIndex)
            }
            .contextMenu {
                Button(SpreadsheetPreviewLocalization.text(.copyCellTextHelp)) {
                    let coordinate = coordinate(for: row, columnIndex: columnIndex)
                    selectedCoordinate = coordinate
                    onCopyText(text, SpreadsheetPreviewLocalization.copiedCellContent(coordinate.excelReference))
                }
            }
    }
}

final class TTZipSpreadsheetGridProbeNSView: NSView {
    var headers: [String] = []
    var allRows: [[String]] = []
    var renderedRowNumbers: [Int] = []
    var resolvedColumnWidths: [CGFloat] = []
    var activeSelectedCell: (row: Int, column: Int)?
    var simulateCellTap: (@MainActor (Int, Int) -> Void)?
    fileprivate var lastScrollIdentity = ""
}

private struct TTZipSpreadsheetGridProbe: NSViewRepresentable {
    let headers: [String]
    let allRows: [[String]]
    let renderedRowNumbers: [Int]
    let resolvedColumnWidths: [CGFloat]
    let activeSelectedCell: (row: Int, column: Int)?
    let scrollIdentity: String
    let simulateCellTap: @MainActor (Int, Int) -> Void

    func makeNSView(context: Context) -> TTZipSpreadsheetGridProbeNSView {
        let probe = TTZipSpreadsheetGridProbeNSView(frame: .zero)
        probe.lastScrollIdentity = scrollIdentity
        updateNSView(probe, context: context)
        return probe
    }

    func updateNSView(_ probe: TTZipSpreadsheetGridProbeNSView, context: Context) {
        probe.headers = headers
        probe.allRows = allRows
        probe.renderedRowNumbers = renderedRowNumbers
        probe.resolvedColumnWidths = resolvedColumnWidths
        probe.activeSelectedCell = activeSelectedCell
        probe.simulateCellTap = simulateCellTap
        if probe.lastScrollIdentity != scrollIdentity {
            probe.lastScrollIdentity = scrollIdentity
            if let scrollView = probe.enclosingScrollView {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}
