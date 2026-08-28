// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipUI

// MARK: - Spreadsheet Grid View

public struct SpreadsheetGridView: View {
    public let paginatedDataRows: [SpreadsheetRowItem]
    public let headerNames: [String]
    public let maxColumnCount: Int
    public let useFirstRowAsHeader: Bool
    public let searchQuery: String
    @Binding public var selectedCoordinate: SpreadsheetCellCoordinate?
    public let columnWidths: [Int: CGFloat]
    public let selectedDelimiter: TTZipSpreadsheetDelimiter
    public let onCopyText: (String, String) -> Void
    public let onFilterQuery: (String) -> Void
    
    public init(
        paginatedDataRows: [SpreadsheetRowItem],
        headerNames: [String],
        maxColumnCount: Int,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        selectedCoordinate: Binding<SpreadsheetCellCoordinate?>,
        columnWidths: [Int: CGFloat],
        selectedDelimiter: TTZipSpreadsheetDelimiter,
        onCopyText: @escaping (String, String) -> Void,
        onFilterQuery: @escaping (String) -> Void
    ) {
        self.paginatedDataRows = paginatedDataRows
        self.headerNames = headerNames
        self.maxColumnCount = maxColumnCount
        self.useFirstRowAsHeader = useFirstRowAsHeader
        self.searchQuery = searchQuery
        self._selectedCoordinate = selectedCoordinate
        self.columnWidths = columnWidths
        self.selectedDelimiter = selectedDelimiter
        self.onCopyText = onCopyText
        self.onFilterQuery = onFilterQuery
    }
    
    public var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Pinned Header Row
                gridHeaderRow
                
                // Data Rows
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(paginatedDataRows) { rowItem in
                        gridDataRow(for: rowItem)
                    }
                }
            }
        }
    }
    
    // MARK: - Grid Header Row
    
    private var gridHeaderRow: some View {
        HStack(spacing: 0) {
            // Corner Top-Left Cell (#)
            Text("#")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 26)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            
            // Column Headers (A, B, C... or Row 1 titles)
            ForEach(0..<maxColumnCount, id: \.self) { colIndex in
                let width = columnWidths[colIndex] ?? 110
                let colTitle = colIndex < headerNames.count ? headerNames[colIndex] : TTZipSpreadsheetParser.columnLetter(for: colIndex)
                
                HStack(spacing: 4) {
                    Text(colTitle)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(useFirstRowAsHeader ? TTZipTheme.bambooGreen : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(width: width, height: 26)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            }
        }
    }
    
    // MARK: - Grid Data Row
    
    private func gridDataRow(for rowItem: SpreadsheetRowItem) -> some View {
        let isEvenRow = rowItem.id.isMultiple(of: 2)
        let actualRowIndexInParsed = useFirstRowAsHeader ? rowItem.id + 1 : rowItem.id
        
        return HStack(spacing: 0) {
            // Pinned Row Number (1, 2, 3...)
            Text("\(rowItem.originalIndex)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 26, alignment: .center)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            
            // Cells
            ForEach(0..<maxColumnCount, id: \.self) { colIndex in
                gridCell(rowItem: rowItem, colIndex: colIndex, actualRowIndexInParsed: actualRowIndexInParsed, isEvenRow: isEvenRow)
            }
        }
    }
    
    // MARK: - Grid Cell
    
    private func gridCell(rowItem: SpreadsheetRowItem, colIndex: Int, actualRowIndexInParsed: Int, isEvenRow: Bool) -> some View {
        let cellValue = colIndex < rowItem.cells.count ? rowItem.cells[colIndex] : ""
        let width = columnWidths[colIndex] ?? 110
        let isSelected = selectedCoordinate == SpreadsheetCellCoordinate(row: actualRowIndexInParsed, column: colIndex)
        
        return HStack(spacing: 0) {
            Text(highlightedCellText(for: cellValue, query: searchQuery))
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(isSelected ? .primary : Color.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 26)
        .background(
            isSelected
                ? TTZipTheme.bambooGreen.opacity(0.15)
                : (isEvenRow ? Color.primary.opacity(0.02) : Color.clear)
        )
        .overlay(
            Rectangle()
                .stroke(
                    isSelected ? TTZipTheme.bambooGreen : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedCoordinate = SpreadsheetCellCoordinate(row: actualRowIndexInParsed, column: colIndex)
        }
        .contextMenu {
            Button(action: {
                onCopyText(cellValue, "Copied cell content")
            }) {
                Label("Copy Cell Content", systemImage: "doc.on.doc")
            }
            
            Button(action: {
                let rowCSV = TTZipSpreadsheetParser.exportToDelimited(rows: [rowItem.cells], delimiter: selectedDelimiter.rawValue)
                onCopyText(rowCSV.trimmingCharacters(in: .newlines), "Copied row as \(selectedDelimiter.displayName)")
            }) {
                Label("Copy Row (\(selectedDelimiter.displayName))", systemImage: "tablecells")
            }
            
            Button(action: {
                let rowTSV = TTZipSpreadsheetParser.exportToDelimited(rows: [rowItem.cells], delimiter: "\t")
                onCopyText(rowTSV.trimmingCharacters(in: .newlines), "Copy Row as TSV (Tab)")
            }) {
                Label("Copy Row as TSV (Excel)", systemImage: "arrow.right.to.line")
            }
            
            if !cellValue.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                Button(action: {
                    onFilterQuery(cellValue)
                }) {
                    Label("Filter by '\(cellValue.prefix(24))'", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
    
    // MARK: - Highlighting Helper
    
    private func highlightedCellText(for text: String, query: String) -> AttributedString {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return AttributedString(text)
        }
        var attr = AttributedString(text)
        var searchStart = text.startIndex
        while let range = text.range(of: clean, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].backgroundColor = Color.yellow.opacity(0.35)
                attr[attrRange].foregroundColor = Color.primary
                attr[attrRange].font = .system(size: 11.5, weight: .bold, design: .monospaced)
            }
            searchStart = range.upperBound
        }
        return attr
    }
}
