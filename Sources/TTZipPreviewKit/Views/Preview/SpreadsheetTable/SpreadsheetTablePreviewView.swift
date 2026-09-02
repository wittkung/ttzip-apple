// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// Professional structured spreadsheet and CSV/TSV preview component with sticky headers, cell inspection, search, and pagination.
public struct SpreadsheetTablePreviewView: View {
    public let initialContent: String
    public let fileURL: URL?
    public let fileName: String
    public let initialWorkbook: OfficeSpreadsheetWorkbook?

    @State private var mode: SpreadsheetPreviewMode = .table
    @State private var rawContent = ""
    @State private var parsedRows: [[String]] = []
    @State private var detectedDelimiter: TTZipSpreadsheetDelimiter = .comma
    @State private var selectedDelimiter: TTZipSpreadsheetDelimiter = .comma
    @State private var useFirstRowAsHeader = false
    @State private var pageSizeOption: SpreadsheetPageSizeOption = .hundred
    @State private var currentPageIndex = 0
    @State private var searchQuery = ""
    @State private var selectedCoordinate: SpreadsheetCellCoordinate? = nil
    @State private var jumpRowInput = ""
    @State private var isJumpPopoverPresented = false
    @State private var isEdited = false
    @State private var isSavedToastPresented = false
    @State private var copyToastMessage: String? = nil
    @State private var isToastVisible = false
    @State private var columnWidths: [Int: CGFloat] = [:]
    @State private var availableSheets: [String] = []
    @State private var selectedSheetName: String = ""

    public init(initialContent: String, fileURL: URL? = nil, fileName: String = "", workbook: OfficeSpreadsheetWorkbook? = nil) {
        self.initialContent = initialContent
        self.fileURL = fileURL ?? workbook?.fileURL
        self.fileName = fileName.isEmpty ? (workbook?.fileName ?? fileURL?.lastPathComponent ?? "Spreadsheet Document") : fileName
        self.initialWorkbook = workbook
        self._rawContent = State(initialValue: initialContent)
    }
    
    public init(workbook: OfficeSpreadsheetWorkbook) {
        self.initialWorkbook = workbook
        self.fileURL = workbook.fileURL
        self.fileName = workbook.fileName
        
        let content: String
        if let sheet = workbook.activeSheet {
            let rows = TTZipSpreadsheetParser.convertSheetDataToRows(sheet)
            content = TTZipSpreadsheetParser.exportToDelimited(rows: rows, delimiter: ",")
        } else {
            content = ""
        }
        self.initialContent = content
        self._rawContent = State(initialValue: content)
    }

    // MARK: - Computed Properties

    private var maxColumnCount: Int { parsedRows.map(\.count).max() ?? 0 }
    private var totalRowCount: Int { parsedRows.count }
    private var totalCellCount: Int { parsedRows.reduce(0) { $0 + $1.count } }
    private var pageSize: Int { pageSizeOption.rawValue == -1 ? max(1, filteredDataRows.count) : pageSizeOption.rawValue }
    private var totalPages: Int { filteredDataRows.isEmpty || pageSizeOption.rawValue == -1 ? 1 : max(1, (filteredDataRows.count + pageSize - 1) / pageSize) }

    private var headerNames: [String] {
        useFirstRowAsHeader && !parsedRows.isEmpty ? parsedRows[0] : (0..<maxColumnCount).map { TTZipSpreadsheetParser.columnLetter(for: $0) }
    }

    private var effectiveDataRows: [SpreadsheetRowItem] {
        guard !parsedRows.isEmpty else { return [] }
        let (rows, offset) = useFirstRowAsHeader ? (Array(parsedRows.dropFirst()), 2) : (parsedRows, 1)
        return rows.enumerated().map { SpreadsheetRowItem(id: $0.offset, originalIndex: $0.offset + offset, cells: $0.element) }
    }

    private var filteredDataRows: [SpreadsheetRowItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return effectiveDataRows }
        return effectiveDataRows.filter { item in item.cells.contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    private var paginatedDataRows: [SpreadsheetRowItem] {
        let rows = filteredDataRows
        guard !rows.isEmpty, pageSizeOption.rawValue != -1 else { return rows }
        let start = min(currentPageIndex * pageSize, rows.count)
        let end = min(start + pageSize, rows.count)
        return Array(rows[start..<end])
    }

    private var selectedCellContent: String? {
        guard let c = selectedCoordinate, c.row >= 0, c.row < parsedRows.count else { return nil }
        let row = parsedRows[c.row]
        return (c.column >= 0 && c.column < row.count) ? row[c.column] : nil
    }

    private var fileSizeString: String {
        if let url = fileURL, url.isFileURL, let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
            return ByteCountFormatterFlyweight.shared.string(fromByteCount: size)
        }
        return ByteCountFormatterFlyweight.shared.string(fromByteCount: Int64(rawContent.utf8.count))
    }

    // MARK: - Body View

    public var body: some View {
        VStack(spacing: 0) {
            topControlBar; Divider(); cellInspectorBar; Divider()
            ZStack {
                if mode == .table {
                    SpreadsheetGridView(
                        paginatedDataRows: paginatedDataRows,
                        headerNames: headerNames,
                        maxColumnCount: maxColumnCount,
                        useFirstRowAsHeader: useFirstRowAsHeader,
                        searchQuery: searchQuery,
                        selectedCoordinate: $selectedCoordinate,
                        columnWidths: columnWidths,
                        selectedDelimiter: selectedDelimiter,
                        onCopyText: { copyToClipboard($0, message: $1) },
                        onFilterQuery: { searchQuery = $0 }
                    ).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CodeHighlightingEditorNSView(text: $rawContent, fileName: fileName.isEmpty ? "data.csv" : fileName) {
                        if $0 != initialContent { isEdited = true }
                        reparseContent($0)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if isToastVisible, let msg = copyToastMessage { toastOverlay(msg) }
            }
            Divider(); bottomStatusBar
        }
        .background(Color(NSColor.textBackgroundColor))
        .task(id: initialContent) {
            if let wb = initialWorkbook {
                availableSheets = wb.sheetNames
                selectedSheetName = wb.activeSheet?.sheetName ?? wb.sheetNames.first ?? ""
                if let active = wb.activeSheet {
                    let rows = TTZipSpreadsheetParser.convertSheetDataToRows(active)
                    self.parsedRows = rows
                    self.rawContent = TTZipSpreadsheetParser.exportToDelimited(rows: rows, delimiter: ",")
                    self.columnWidths = SpreadsheetTableLayoutEngine.calculateColumnWidths(parsedRows: parsedRows, headerNames: headerNames, maxColumnCount: maxColumnCount)
                    return
                }
            }
            rawContent = initialContent; isEdited = false; reparseContent(initialContent)
        }
    }

    // MARK: - Top Toolbar Subviews

    private var topControlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "tablecells.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(TTZipTheme.bambooGreen)
                Text(availableSheets.isEmpty ? selectedDelimiter.shortName : "XLSX").font(.system(size: 10.5, weight: .bold, design: .monospaced))
            }.padding(.horizontal, 8).padding(.vertical, 3.5).background(TTZipTheme.bambooGreen.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
            Text(fileName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            if isEdited {
                Text("Unsaved").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2.5).background(Color.orange.opacity(0.12)).clipShape(Capsule())
            }
            if availableSheets.count > 1 {
                sheetPickerMenu
            }
            Spacer()
            searchBar; headerToggleBtn; delimiterMenu; modePicker; copyMenu; saveButton
        }.padding(.horizontal, 10).padding(.vertical, 6).background(Color(NSColor.windowBackgroundColor))
    }

    private var sheetPickerMenu: some View {
        Menu {
            ForEach(availableSheets, id: \.self) { sheetName in
                Button(action: { selectSheet(sheetName) }) {
                    HStack {
                        Text(sheetName)
                        if selectedSheetName == sheetName { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 10))
                Text(selectedSheetName.isEmpty ? "Sheet" : selectedSheetName).font(.system(size: 10.5, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(TTZipTheme.bambooGreen.opacity(0.15))
            .foregroundStyle(TTZipTheme.bambooGreen)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Filter cells...", text: $searchQuery).textFieldStyle(.plain).font(.system(size: 11)).frame(width: 130)
                .onChange(of: searchQuery) { _, _ in currentPageIndex = 0 }
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 7).padding(.vertical, 3.5).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var headerToggleBtn: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { useFirstRowAsHeader.toggle(); columnWidths = SpreadsheetTableLayoutEngine.calculateColumnWidths(parsedRows: parsedRows, headerNames: headerNames, maxColumnCount: maxColumnCount) } }) {
            Label(useFirstRowAsHeader ? "Header: Row 1" : "Header: A, B, C", systemImage: useFirstRowAsHeader ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(useFirstRowAsHeader ? TTZipTheme.bambooGreen : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 4).background(useFirstRowAsHeader ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help("Toggle header rows")
    }

    private var delimiterMenu: some View {
        Menu {
            ForEach(TTZipSpreadsheetDelimiter.allCases) { delim in
                Button(action: { selectedDelimiter = delim; reparseContent(rawContent, overrideDelimiter: delim.rawValue) }) {
                    HStack { Text(delim.displayName); if selectedDelimiter == delim { Image(systemName: "checkmark") } }
                }
            }
        } label: {
            Label(selectedDelimiter.displayName, systemImage: "character.textbox").font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 4).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 5))
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(SpreadsheetPreviewMode.allCases) { m in
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { mode = m; if m == .table { reparseContent(rawContent) } } }) {
                    Label(m.rawValue, systemImage: m.icon).font(.system(size: 10.5, weight: mode == m ? .bold : .medium))
                        .padding(.horizontal, 7).padding(.vertical, 4).background(mode == m ? TTZipTheme.bambooGreen : Color.clear)
                        .foregroundStyle(mode == m ? Color.white : Color.primary).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }.buttonStyle(.plain)
            }
        }.padding(2).background(Color.primary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var copyMenu: some View {
        Menu {
            if let cellVal = selectedCellContent, let coord = selectedCoordinate {
                Button("Copy Selected Cell (\(coord.excelReference))") { copyToClipboard(cellVal, message: "Copied cell \(coord.excelReference)") }
            }
            Button("Copy Full Table as CSV (,)") { copyToClipboard(TTZipSpreadsheetParser.exportToDelimited(rows: parsedRows, delimiter: ","), message: "Copied entire table as CSV (,)") }
            Button("Copy Full Table as TSV (Tab / Excel)") { copyToClipboard(TTZipSpreadsheetParser.exportToDelimited(rows: parsedRows, delimiter: "\t"), message: "Copied entire table as TSV (Excel)") }
            Button("Copy Full Table as Markdown") { copyToClipboard(TTZipSpreadsheetParser.exportToMarkdownTable(rows: parsedRows, hasHeader: useFirstRowAsHeader), message: "Copied entire table as Markdown") }
        } label: {
            Label("Copy", systemImage: "doc.on.doc.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(TTZipTheme.bambooGreen)
                .padding(.horizontal, 8).padding(.vertical, 4).background(TTZipTheme.bambooGreen.opacity(0.12)).clipShape(Capsule())
        }.menuStyle(.borderlessButton).fixedSize()
    }

    @ViewBuilder
    private var saveButton: some View {
        if isSavedToastPresented {
            Label("Saved", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(TTZipTheme.bambooGreen).transition(.opacity)
        }
        if let url = fileURL, url.isFileURL {
            Button(action: saveFile) {
                Label("Save", systemImage: "square.and.arrow.down.fill").font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(isEdited ? Color.white : TTZipTheme.bambooGreen).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isEdited ? TTZipTheme.bambooGreen : TTZipTheme.bambooGreen.opacity(0.12)).clipShape(Capsule())
            }.buttonStyle(.plain).keyboardShortcut("s", modifiers: [.command]).help("Save changes (⌘S)")
        }
    }

    // MARK: - Inspector & Overlay

    private var cellInspectorBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "target").font(.system(size: 9)).foregroundStyle(TTZipTheme.bambooGreen)
                Text(selectedCoordinate?.excelReference ?? "None").font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(selectedCoordinate != nil ? TTZipTheme.bambooGreen : .secondary)
            }.frame(width: 65, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 2.5).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 4))
            Divider().frame(height: 14)
            if let cellVal = selectedCellContent {
                Text(cellVal).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                Spacer()
                Button(action: {
                    if let c = selectedCoordinate { copyToClipboard(cellVal, message: "Copied cell \(c.excelReference) content") }
                }) { Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("Copy cell text")
            } else {
                Text("Click any cell to inspect or copy full contents").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
        }.padding(.horizontal, 12).padding(.vertical, 4).background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private func toastOverlay(_ msg: String) -> some View {
        VStack {
            Spacer()
            Label(msg, systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(Color.black.opacity(0.85)))
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3).transition(.move(edge: .bottom).combined(with: .opacity)).padding(.bottom, 16)
        }
    }

    // MARK: - Bottom Status & Pagination

    private var bottomStatusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if !searchQuery.isEmpty {
                    Text("Filtered: \(filteredDataRows.count)/\(effectiveDataRows.count)").foregroundStyle(TTZipTheme.bambooGreen)
                } else {
                    Text("\(effectiveDataRows.count) rows")
                }
                Text("•"); Text("\(maxColumnCount) cols"); Text("•"); Text("\(totalCellCount) cells"); Text("•"); Text(fileSizeString)
            }.font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            jumpButton; pageSizeMenu
            if pageSizeOption.rawValue != -1 && totalPages > 1 { paginationControls }
        }.padding(.horizontal, 10).padding(.vertical, 5).background(Color(NSColor.windowBackgroundColor))
    }

    private var jumpButton: some View {
        Button(action: { isJumpPopoverPresented.toggle() }) {
            Label("Jump", systemImage: "arrow.right.to.line.compact").font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2.5).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).popover(isPresented: $isJumpPopoverPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Jump to Row").font(.system(size: 11.5, weight: .bold))
                Text("Row index (1–\(effectiveDataRows.count)):").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("Row #", text: $jumpRowInput).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(width: 90).onSubmit(performJumpToRow)
                    Button("Go", action: performJumpToRow).buttonStyle(.borderedProminent).controlSize(.small)
                }
            }.padding(10).frame(width: 200)
        }
    }

    private var pageSizeMenu: some View {
        Menu {
            ForEach(SpreadsheetPageSizeOption.allCases) { opt in
                Button(action: { pageSizeOption = opt; currentPageIndex = 0 }) {
                    HStack { Text(opt.displayName); if pageSizeOption == opt { Image(systemName: "checkmark") } }
                }
            }
        } label: {
            Label("Page: \(pageSizeOption.displayName)", systemImage: "slider.horizontal.3").font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2.5).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 4))
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private var paginationControls: some View {
        HStack(spacing: 3) {
            Button(action: { currentPageIndex = 0 }) { Image(systemName: "backward.end.fill").font(.system(size: 8.5)) }.disabled(currentPageIndex <= 0)
            Button(action: { if currentPageIndex > 0 { currentPageIndex -= 1 } }) { Image(systemName: "chevron.left").font(.system(size: 9.5, weight: .bold)) }.disabled(currentPageIndex <= 0)
            Text("\(currentPageIndex + 1) / \(totalPages)").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).padding(.horizontal, 4)
            Button(action: { if currentPageIndex < totalPages - 1 { currentPageIndex += 1 } }) { Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold)) }.disabled(currentPageIndex >= totalPages - 1)
            Button(action: { currentPageIndex = max(0, totalPages - 1) }) { Image(systemName: "forward.end.fill").font(.system(size: 8.5)) }.disabled(currentPageIndex >= totalPages - 1)
        }
        .buttonStyle(.plain).padding(3).foregroundStyle(.primary).padding(.horizontal, 4).padding(.vertical, 1.5).background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Actions

    private func selectSheet(_ sheetName: String) {
        selectedSheetName = sheetName
        guard let wb = initialWorkbook else { return }
        
        let officeService = UniFfiOfficeService()
        let sheetData: UniFfiSheetData?
        if let raw = wb.rawData {
            sheetData = try? officeService.extractSheetData(data: raw, sheetNameOrIndex: sheetName, maxRows: 10000, fileName: wb.fileName)
        } else if let url = wb.fileURL, url.isFileURL {
            sheetData = try? officeService.extractSheetDataFromFile(filePath: url.path, sheetNameOrIndex: sheetName, maxRows: 10000)
        } else {
            sheetData = nil
        }
        
        if let sheet = sheetData {
            let rows = TTZipSpreadsheetParser.convertSheetDataToRows(sheet)
            self.parsedRows = rows
            self.rawContent = TTZipSpreadsheetParser.exportToDelimited(rows: rows, delimiter: ",")
            self.currentPageIndex = 0
            self.columnWidths = SpreadsheetTableLayoutEngine.calculateColumnWidths(parsedRows: parsedRows, headerNames: headerNames, maxColumnCount: maxColumnCount)
        }
    }

    private func reparseContent(_ content: String, overrideDelimiter: Character? = nil) {
        let delim = overrideDelimiter ?? {
            let d = TTZipSpreadsheetParser.detectDelimiter(in: content)
            self.detectedDelimiter = d; self.selectedDelimiter = d
            return d.rawValue
        }()
        self.parsedRows = TTZipSpreadsheetParser.parse(text: content, delimiter: delim)
        self.currentPageIndex = 0
        self.columnWidths = SpreadsheetTableLayoutEngine.calculateColumnWidths(parsedRows: parsedRows, headerNames: headerNames, maxColumnCount: maxColumnCount)
    }

    private func performJumpToRow() {
        isJumpPopoverPresented = false
        guard let row = Int(jumpRowInput.trimmingCharacters(in: .whitespacesAndNewlines)), row >= 1 else { return }
        jumpRowInput = ""
        let targetIndex = row - 1
        guard targetIndex < filteredDataRows.count else { return }
        if pageSizeOption.rawValue != -1 { currentPageIndex = min(targetIndex / pageSize, max(0, totalPages - 1)) }
        selectedCoordinate = SpreadsheetCellCoordinate(row: useFirstRowAsHeader ? targetIndex + 1 : targetIndex, column: 0)
    }

    private func showToast(_ message: String) {
        copyToastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) { isToastVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation(.easeInOut(duration: 0.25)) { isToastVisible = false } }
    }

    private func copyToClipboard(_ string: String, message: String) {
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(string, forType: .string)
        showToast(message)
    }

    private func saveFile() {
        guard let url = fileURL, url.isFileURL else { return }
        do {
            try rawContent.write(to: url, atomically: true, encoding: .utf8)
            withAnimation { isEdited = false; isSavedToastPresented = true }
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { isSavedToastPresented = false } }
        } catch { showToast("Failed to save: \(error.localizedDescription)") }
    }
}
