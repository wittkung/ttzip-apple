// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit

protocol TTZipSpreadsheetParsePipeline: Sendable {
    func computeFirstScreenSnapshot(
        content: String,
        overrideDelimiter: Character?,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxUTF8Bytes: Int
    ) async -> SpreadsheetComputedTableSnapshot?

    func computeFullBudgetedSnapshot(
        content: String,
        stage1: SpreadsheetComputedTableSnapshot,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int,
        maxUTF8Bytes: Int
    ) async -> SpreadsheetComputedTableSnapshot?

    func computeWorkbookFirstScreenSnapshot(
        sheet: TTMediaSheetData,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> SpreadsheetComputedTableSnapshot?

    func computeWorkbookFullSnapshot(
        sheet: TTMediaSheetData,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> (snapshot: SpreadsheetComputedTableSnapshot, csv: String)?

    func loadAndComputeSelectedSheet(
        sheetName: String,
        workbook: OfficeSpreadsheetWorkbook,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> (result: SpreadsheetParseResult, state: SpreadsheetTableState, isTruncated: Bool)?
}

struct DefaultTTZipSpreadsheetParsePipeline: TTZipSpreadsheetParsePipeline {
    func computeFirstScreenSnapshot(
        content: String,
        overrideDelimiter: Character?,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxUTF8Bytes: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        await SpreadsheetBackgroundPipeline.computeFirstScreenSnapshot(
            content: content,
            overrideDelimiter: overrideDelimiter,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxUTF8Bytes: maxUTF8Bytes
        )
    }

    func computeFullBudgetedSnapshot(
        content: String,
        stage1: SpreadsheetComputedTableSnapshot,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int,
        maxUTF8Bytes: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        await SpreadsheetBackgroundPipeline.computeFullBudgetedSnapshot(
            content: content,
            stage1: stage1,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxRows: maxRows,
            maxUTF8Bytes: maxUTF8Bytes
        )
    }

    func computeWorkbookFirstScreenSnapshot(
        sheet: TTMediaSheetData,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        await SpreadsheetBackgroundPipeline.computeWorkbookFirstScreenSnapshot(
            sheet: sheet,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxRows: maxRows
        )
    }

    func computeWorkbookFullSnapshot(
        sheet: TTMediaSheetData,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> (snapshot: SpreadsheetComputedTableSnapshot, csv: String)? {
        await SpreadsheetBackgroundPipeline.computeWorkbookFullSnapshot(
            sheet: sheet,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxRows: maxRows
        )
    }

    func loadAndComputeSelectedSheet(
        sheetName: String,
        workbook: OfficeSpreadsheetWorkbook,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> (result: SpreadsheetParseResult, state: SpreadsheetTableState, isTruncated: Bool)? {
        await SpreadsheetBackgroundPipeline.loadAndComputeSelectedSheet(
            sheetName: sheetName,
            workbook: workbook,
            sheetDataLoader: nil,
            sheetLoader: nil,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxRows: maxRows
        )
    }
}

private struct TTZipSpreadsheetParsePipelineKey: EnvironmentKey {
    static let defaultValue: any TTZipSpreadsheetParsePipeline = DefaultTTZipSpreadsheetParsePipeline()
}

extension EnvironmentValues {
    var ttZipSpreadsheetParsePipeline: any TTZipSpreadsheetParsePipeline {
        get { self[TTZipSpreadsheetParsePipelineKey.self] }
        set { self[TTZipSpreadsheetParsePipelineKey.self] = newValue }
    }
}

struct TTZipSpreadsheetUserControls: Equatable, Sendable {
    var searchQuery = ""
    var useFirstRowAsHeader = false
    var pageSizeOption: SpreadsheetPageSizeOption = .hundred
    var currentPageIndex = 0
    var selectedCoordinate: SpreadsheetCellCoordinate?
}

struct TTZipSpreadsheetParseToken: Equatable, Sendable {
    let parseGeneration: UInt64
    let sheetGeneration: UInt64
    let targetSheetName: String?
}

enum TTZipSpreadsheetTruncationUpdate: Equatable, Sendable {
    case accumulatePartial(Bool)
    case replaceFinal(Bool)
}

enum TTZipSpreadsheetDocumentSource: Equatable, Sendable {
    case delimitedText
    case workbook(loadedSheetName: String?)
}

struct TTZipSpreadsheetTransientParseOutput {
    let rows: [[String]]
    let precomputedTableState: SpreadsheetTableState
    let precomputedColumnWidths: [Int: CGFloat]
    let capturedUseFirstRowAsHeader: Bool
    let capturedSearchQuery: String
    let truncationUpdate: TTZipSpreadsheetTruncationUpdate
    var autoDetectedDelimiter: TTSpreadsheetDelimiter?
    var updatedRawContent: String?

    static func fromSnapshot(
        _ snapshot: SpreadsheetComputedTableSnapshot,
        capturedHeader: Bool,
        capturedQuery: String,
        truncationUpdate: TTZipSpreadsheetTruncationUpdate,
        autoDetectedDelimiter: TTSpreadsheetDelimiter? = nil,
        updatedRawContent: String? = nil
    ) -> Self {
        Self(
            rows: snapshot.rows,
            precomputedTableState: snapshot.tableState,
            precomputedColumnWidths: snapshot.columnWidths,
            capturedUseFirstRowAsHeader: capturedHeader,
            capturedSearchQuery: capturedQuery,
            truncationUpdate: truncationUpdate,
            autoDetectedDelimiter: autoDetectedDelimiter,
            updatedRawContent: updatedRawContent
        )
    }

    static func fromSelectedSheet(
        _ loaded: (result: SpreadsheetParseResult, state: SpreadsheetTableState, isTruncated: Bool),
        capturedHeader: Bool,
        capturedQuery: String
    ) -> Self {
        Self(
            rows: loaded.result.parsedRows,
            precomputedTableState: loaded.state,
            precomputedColumnWidths: loaded.result.columnWidths,
            capturedUseFirstRowAsHeader: capturedHeader,
            capturedSearchQuery: capturedQuery,
            truncationUpdate: .replaceFinal(loaded.isTruncated),
            updatedRawContent: loaded.result.rawContent
        )
    }
}

struct TTZipSpreadsheetTableSession {
    private(set) var source: TTZipSpreadsheetDocumentSource
    private(set) var controls = TTZipSpreadsheetUserControls()
    private(set) var rawContent: String
    private(set) var parsedRows: [[String]] = []
    private(set) var tableState = SpreadsheetTableState(parsedRows: [], useFirstRowAsHeader: false, searchQuery: "")
    private(set) var columnWidths: [Int: CGFloat] = [:]
    private(set) var detectedDelimiter: TTSpreadsheetDelimiter = .comma
    private(set) var selectedDelimiter: TTSpreadsheetDelimiter = .comma
    private(set) var availableSheets: [String] = []
    private(set) var selectedSheetName = ""
    private(set) var isLoadingSheet = false
    private(set) var isPreviewTruncated: Bool
    private(set) var parseGeneration: UInt64 = 0
    private(set) var sheetGeneration: UInt64 = 0

    init(initialRawContent: String, isPreviewTruncated: Bool, isWorkbook: Bool = false) {
        self.source = isWorkbook ? .workbook(loadedSheetName: nil) : .delimitedText
        self.rawContent = initialRawContent
        self.isPreviewTruncated = isPreviewTruncated
    }

    mutating func resetForDocument(
        workbook: OfficeSpreadsheetWorkbook?,
        boundedRawContent: String,
        initialIsTruncated: Bool
    ) {
        parseGeneration &+= 1
        sheetGeneration &+= 1
        isLoadingSheet = false
        let preservedPageSize = controls.pageSizeOption
        controls = TTZipSpreadsheetUserControls(pageSizeOption: preservedPageSize)
        parsedRows = []
        tableState = SpreadsheetTableState(parsedRows: [], useFirstRowAsHeader: false, searchQuery: "")
        columnWidths = [:]
        rawContent = boundedRawContent
        isPreviewTruncated = initialIsTruncated
        if let workbook {
            source = .workbook(loadedSheetName: nil)
            availableSheets = workbook.sheetNames
            selectedSheetName = workbook.activeSheet?.name ?? workbook.sheetNames.first ?? ""
        } else {
            source = .delimitedText
            availableSheets = []
            selectedSheetName = ""
        }
    }

    mutating func beginWorkbookInitialParse() -> TTZipSpreadsheetParseToken {
        parseGeneration &+= 1
        controls.currentPageIndex = 0
        return TTZipSpreadsheetParseToken(
            parseGeneration: parseGeneration,
            sheetGeneration: sheetGeneration,
            targetSheetName: selectedSheetName
        )
    }

    mutating func beginSheetSelection(_ sheetName: String) -> TTZipSpreadsheetParseToken? {
        if sheetName == selectedSheetName {
            if isLoadingSheet { return nil }
            if case .workbook(let loadedSheet) = source, loadedSheet == sheetName, !parsedRows.isEmpty {
                return nil
            }
        }
        parseGeneration &+= 1
        sheetGeneration &+= 1
        selectedSheetName = sheetName
        isLoadingSheet = true
        controls.selectedCoordinate = nil
        controls.currentPageIndex = 0
        return TTZipSpreadsheetParseToken(
            parseGeneration: parseGeneration,
            sheetGeneration: sheetGeneration,
            targetSheetName: sheetName
        )
    }

    mutating func beginContentParse() -> TTZipSpreadsheetParseToken? {
        guard source == .delimitedText, !isLoadingSheet else { return nil }
        parseGeneration &+= 1
        return TTZipSpreadsheetParseToken(
            parseGeneration: parseGeneration,
            sheetGeneration: sheetGeneration,
            targetSheetName: nil
        )
    }

    mutating func selectDelimiter(_ delimiter: TTSpreadsheetDelimiter) {
        guard source == .delimitedText else { return }
        selectedDelimiter = delimiter
        controls.currentPageIndex = 0
    }

    mutating func setSearchQuery(_ newQuery: String) {
        guard controls.searchQuery != newQuery else { return }
        controls.searchQuery = newQuery
        controls.currentPageIndex = 0
        rebuildTableStateFromCurrentControls()
    }

    mutating func toggleFirstRowAsHeader() {
        controls.useFirstRowAsHeader.toggle()
        rebuildTableStateFromCurrentControls()
        reconcileSelectedCoordinate()
        columnWidths = SpreadsheetTableLayoutEngine.calculateColumnWidths(
            parsedRows: Array(parsedRows.prefix(200)),
            headerNames: tableState.headerNames,
            maxColumnCount: tableState.maxColumnCount
        )
    }

    mutating func setPageSizeOption(_ option: SpreadsheetPageSizeOption) {
        guard controls.pageSizeOption != option else { return }
        controls.pageSizeOption = option
        controls.currentPageIndex = 0
    }

    mutating func setCurrentPageIndex(_ index: Int) {
        let maxPage = max(0, tableState.totalPages(for: controls.pageSizeOption) - 1)
        controls.currentPageIndex = min(max(0, index), maxPage)
    }

    mutating func setSelectedCoordinate(_ coordinate: SpreadsheetCellCoordinate?) {
        controls.selectedCoordinate = coordinate
    }

    mutating func setRawContent(_ content: String) {
        rawContent = content
    }

    func isCurrent(_ token: TTZipSpreadsheetParseToken) -> Bool {
        guard token.parseGeneration == parseGeneration, token.sheetGeneration == sheetGeneration else {
            return false
        }
        if let targetSheet = token.targetSheetName, targetSheet != selectedSheetName {
            return false
        }
        return true
    }

    mutating func finishSheetLoadingFailure(token: TTZipSpreadsheetParseToken) -> Bool {
        guard isCurrent(token) else { return false }
        isLoadingSheet = false
        return true
    }

    @discardableResult
    mutating func applyParseOutput(
        _ output: TTZipSpreadsheetTransientParseOutput,
        token: TTZipSpreadsheetParseToken
    ) -> Bool {
        guard isCurrent(token) else { return false }
        isLoadingSheet = false
        if case .workbook = source, let targetSheet = token.targetSheetName {
            source = .workbook(loadedSheetName: targetSheet)
        }
        if let detected = output.autoDetectedDelimiter {
            detectedDelimiter = detected
            selectedDelimiter = detected
        }
        if let updatedRaw = output.updatedRawContent {
            rawContent = updatedRaw
        }
        parsedRows = output.rows
        switch output.truncationUpdate {
        case .accumulatePartial(let stageTruncated):
            isPreviewTruncated = isPreviewTruncated || stageTruncated
        case .replaceFinal(let finalTruncated):
            isPreviewTruncated = finalTruncated
        }

        let headerMatches = output.capturedUseFirstRowAsHeader == controls.useFirstRowAsHeader
        let queryMatches = output.capturedSearchQuery == controls.searchQuery
        if headerMatches && queryMatches {
            tableState = output.precomputedTableState
            columnWidths = output.precomputedColumnWidths
        } else {
            let reconciledState = SpreadsheetTableState(
                parsedRows: output.rows,
                useFirstRowAsHeader: controls.useFirstRowAsHeader,
                searchQuery: controls.searchQuery
            )
            tableState = reconciledState
            columnWidths = headerMatches
                ? output.precomputedColumnWidths
                : SpreadsheetTableLayoutEngine.calculateColumnWidths(
                    parsedRows: Array(output.rows.prefix(200)),
                    headerNames: reconciledState.headerNames,
                    maxColumnCount: reconciledState.maxColumnCount
                )
        }
        reconcileSelectedCoordinate()
        let maxPage = max(0, tableState.totalPages(for: controls.pageSizeOption) - 1)
        controls.currentPageIndex = min(max(0, controls.currentPageIndex), maxPage)
        return true
    }

    private mutating func rebuildTableStateFromCurrentControls() {
        tableState = SpreadsheetTableState(
            parsedRows: parsedRows,
            useFirstRowAsHeader: controls.useFirstRowAsHeader,
            searchQuery: controls.searchQuery
        )
    }

    private mutating func reconcileSelectedCoordinate() {
        guard let coord = controls.selectedCoordinate, !parsedRows.isEmpty else { return }
        if controls.useFirstRowAsHeader && coord.row == 0 {
            controls.selectedCoordinate = parsedRows.count > 1
                ? SpreadsheetCellCoordinate(row: 1, column: coord.column)
                : nil
        } else if coord.row >= parsedRows.count {
            controls.selectedCoordinate = nil
        }
    }
}
