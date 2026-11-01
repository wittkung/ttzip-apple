// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTKitDesign

// MARK: - Spreadsheet Table Preview View

/// Professional structured spreadsheet and CSV/TSV preview component with sticky headers, cell inspection, search, and pagination.
public struct SpreadsheetTablePreviewView: View {
    public static let maxPreviewRows: Int = TTSpreadsheetParser.maxInteractivePreviewRows
    public static let maxPreviewUTF8Bytes: Int = TTSpreadsheetParser.maxInteractivePreviewUTF8Bytes

    private static let archiveStagingMarkers: [String] = [
        "TTZipLRUPreviewCache", "TTMediaEphemeralStorage", "TTZipPreviewCache",
        "TTZipArchiveMediaCache", ".ttzip-staging-", "ttzip_vfs_"
    ]

    public static func isArchiveOrEphemeralStagingURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if TTPreviewResourceContext.isManagedPreviewStagingURL(url) { return true }
        if url.scheme?.lowercased() == "ttzip" { return true }
        return archiveStagingMarkers.contains { url.path.contains($0) }
    }

    public let initialContent: String
    public let fileURL: URL?
    public let fileName: String
    public let isReadOnly: Bool
    public let resourceContext: TTPreviewResourceContext?
    public let initialWorkbook: OfficeSpreadsheetWorkbook?
    nonisolated public let sheetLoader: (@Sendable (String) async -> [[String]]?)?
    nonisolated public let sheetDataLoader: (@Sendable (String) async -> TTMediaSheetData?)?

    @Environment(\.previewResourceContext) private var envResourceContext
    @State private var mode: SpreadsheetPreviewMode = .table
    @State private var rawContent = ""
    @State private var parsedRows: [[String]] = []
    @State private var tableState = SpreadsheetTableState(parsedRows: [], useFirstRowAsHeader: false, searchQuery: "")
    @State private var detectedDelimiter: TTSpreadsheetDelimiter = .comma
    @State private var selectedDelimiter: TTSpreadsheetDelimiter = .comma
    @State private var useFirstRowAsHeader = false
    @State private var pageSizeOption: SpreadsheetPageSizeOption = .hundred
    @State private var currentPageIndex = 0
    @State private var searchQuery = ""
    @State private var isSearchExpanded = false
    @State private var selectedCoordinate: SpreadsheetCellCoordinate? = nil
    @State private var isCellDetailPopoverPresented = false
    @State private var jumpRowInput = ""
    @State private var isJumpPopoverPresented = false
    @State private var isEdited = false
    @State private var isSavedToastPresented = false
    @State private var copyToastMessage: String? = nil
    @State private var isToastVisible = false
    @State private var columnWidths: [Int: CGFloat] = [:]
    @State private var availableSheets: [String] = []
    @State private var selectedSheetName: String = ""
    @State private var isLoadingSheet: Bool = false
    @State public private(set) var isPreviewTruncated: Bool = false
    @State private var reparseCount: Int = 0
    @State private var sheetSelectionGeneration: UInt64 = 0
    @State private var sheetLoadingTask: Task<Void, Never>? = nil
    @State private var parseTask: Task<Void, Never>? = nil

    public init(
        initialContent: String,
        fileURL: URL? = nil,
        fileName: String = "",
        workbook: OfficeSpreadsheetWorkbook? = nil,
        sheetLoader: (@Sendable (String) async -> [[String]]?)? = nil,
        sheetDataLoader: (@Sendable (String) async -> TTMediaSheetData?)? = nil,
        isReadOnly: Bool = false,
        resourceContext: TTPreviewResourceContext? = nil
    ) {
        self.initialContent = initialContent
        let resolvedURL = fileURL ?? workbook?.fileURL ?? resourceContext?.readableURL
        self.fileURL = resolvedURL
        self.fileName = fileName.isEmpty ? (workbook?.fileName ?? resourceContext?.displayFileName ?? resolvedURL?.lastPathComponent ?? "Spreadsheet Document") : fileName
        let contextBlocksEdit = resourceContext.map { !$0.isEditableInPlace } ?? false
        self.isReadOnly = isReadOnly || contextBlocksEdit || workbook != nil || sheetLoader != nil || sheetDataLoader != nil || Self.isArchiveOrEphemeralStagingURL(resolvedURL)
        self.resourceContext = resourceContext
        self.initialWorkbook = workbook
        self.sheetLoader = sheetLoader
        self.sheetDataLoader = sheetDataLoader
        let (boundedRaw, _) = TTSpreadsheetParser.truncateUTF8Prefix(initialContent, maxBytes: Self.maxPreviewUTF8Bytes)
        self._rawContent = State(initialValue: boundedRaw)
        self._isPreviewTruncated = State(
            initialValue: TTSpreadsheetParser.exceedsPreviewBudget(
                text: initialContent, workbook: workbook, maxRows: Self.maxPreviewRows, maxUTF8Bytes: Self.maxPreviewUTF8Bytes
            )
        )
    }

    public init(
        workbook: OfficeSpreadsheetWorkbook,
        sheetLoader: (@Sendable (String) async -> [[String]]?)? = nil,
        sheetDataLoader: (@Sendable (String) async -> TTMediaSheetData?)? = nil,
        resourceContext: TTPreviewResourceContext? = nil
    ) {
        self.initialWorkbook = workbook
        self.fileURL = workbook.fileURL
        self.fileName = workbook.fileName
        self.isReadOnly = true
        self.resourceContext = resourceContext ?? .derived(sourceURL: workbook.fileURL, fileName: workbook.fileName, description: "SpreadsheetWorkbook")
        self.sheetLoader = sheetLoader
        self.sheetDataLoader = sheetDataLoader
        self.initialContent = ""
        self._rawContent = State(initialValue: "")
        let initialSheetTruncated = workbook.activeSheet.map {
            $0.isTruncated || $0.rows.count > Self.maxPreviewRows
        } ?? false
        self._isPreviewTruncated = State(initialValue: initialSheetTruncated)
    }

    // MARK: - State Management

    private func updateTableState(rows: [[String]]? = nil, query: String? = nil, firstRowAsHeader: Bool? = nil) {
        tableState = SpreadsheetTableState(
            parsedRows: rows ?? parsedRows,
            useFirstRowAsHeader: firstRowAsHeader ?? useFirstRowAsHeader,
            searchQuery: query ?? searchQuery
        )
    }

    private var selectedCellContent: String? {
        guard let c = selectedCoordinate, c.row >= 0, c.row < parsedRows.count else { return nil }
        let row = parsedRows[c.row]
        return (c.column >= 0 && c.column < row.count) ? row[c.column] : nil
    }

    public var formatBadgeTitle: String {
        if let wb = initialWorkbook {
            return wb.format.badgeTitle
        }
        if sheetLoader != nil || sheetDataLoader != nil || !availableSheets.isEmpty {
            return OfficeSpreadsheetFormat.resolve(fileName: fileName, fileURL: fileURL).badgeTitle
        }
        return selectedDelimiter.shortName
    }

    public var resolvedResourceContext: TTPreviewResourceContext {
        if let explicit = resourceContext { return isReadOnly ? explicit.forcingReadOnly() : explicit }
        if initialWorkbook != nil || sheetLoader != nil || sheetDataLoader != nil { return .derived(sourceURL: fileURL, fileName: fileName, description: "SpreadsheetWorkbook") }
        guard let url = fileURL else { return .inMemory(fileName: fileName) }
        if Self.isArchiveOrEphemeralStagingURL(url) {
            return TTPreviewResourceContext(origin: .diskFile(url: url.standardizedFileURL), displayFileName: fileName, allowsEditingWhenAuthorized: false, isPreviewTruncated: isPreviewTruncated, isDerivedRepresentation: false)
        }
        return .diskFile(url: url, fileName: fileName, allowsEditing: !isReadOnly, isTruncated: isPreviewTruncated)
    }

    private var mountedResourceContext: TTPreviewResourceContext {
        if let explicit = resourceContext { return isReadOnly ? explicit.forcingReadOnly() : explicit }
        if envResourceContext.origin != .unknown(readableURL: nil) {
            return isReadOnly ? envResourceContext.forcingReadOnly() : envResourceContext
        }
        return resolvedResourceContext
    }

    public var canSaveInPlace: Bool {
        guard !isReadOnly, !Self.isArchiveOrEphemeralStagingURL(fileURL) else { return false }
        return SpreadsheetSavePolicy.canSaveInPlace(
            fileURL: fileURL, fileName: fileName, workbook: initialWorkbook,
            hasSheetLoader: sheetLoader != nil || sheetDataLoader != nil, isPreviewTruncated: isPreviewTruncated,
            resourceContext: resolvedResourceContext
        )
    }

    private var mountedCanSaveInPlace: Bool {
        guard !isReadOnly, !Self.isArchiveOrEphemeralStagingURL(fileURL) else { return false }
        return SpreadsheetSavePolicy.canSaveInPlace(
            fileURL: fileURL, fileName: fileName, workbook: initialWorkbook,
            hasSheetLoader: sheetLoader != nil || sheetDataLoader != nil, isPreviewTruncated: isPreviewTruncated,
            resourceContext: mountedResourceContext
        )
    }

    public var isEditorEditable: Bool { canSaveInPlace }

    private var fileSizeString: String {
        if let url = fileURL, url.isFileURL, let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        let byteCount = initialContent.isEmpty ? rawContent.utf8.count : initialContent.utf8.count
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private var taskIdentityKey: String {
        "\(fileName)|\(initialWorkbook?.sheetNames.joined(separator: ",") ?? "")|\(initialContent.utf8.count)|\(initialContent.prefix(64))"
    }

    // MARK: - Body View

    public var body: some View {
        GeometryReader { proxy in
            let metrics = SpreadsheetLayoutMetrics(width: proxy.size.width)
            VStack(spacing: 0) {
                topControlBar(metrics: metrics)
                if !metrics.showsInlineSearchField && (isSearchExpanded || !searchQuery.isEmpty) {
                    Divider()
                    SpreadsheetExpandableSearchRowView(searchQuery: $searchQuery) { newQuery in
                        currentPageIndex = 0
                        updateTableState(query: newQuery)
                    }
                }
                Divider()
                SpreadsheetCellInspectorBarView(
                    selectedCoordinate: selectedCoordinate,
                    selectedCellContent: selectedCellContent,
                    isCellDetailPopoverPresented: $isCellDetailPopoverPresented,
                    onCopyCell: { coord, val in
                        copyToClipboard(val, message: SpreadsheetPreviewLocalization.copiedCellContent(coord.excelReference))
                    }
                )
                Divider()
                contentArea(availableWidth: proxy.size.width)
                Divider()
                SpreadsheetBottomStatusBarView(
                    metrics: metrics,
                    tableState: tableState,
                    fileSizeString: fileSizeString,
                    isPreviewTruncated: isPreviewTruncated,
                    maxPreviewRows: Self.maxPreviewRows,
                    pageSizeOption: $pageSizeOption,
                    currentPageIndex: $currentPageIndex,
                    isJumpPopoverPresented: $isJumpPopoverPresented,
                    jumpRowInput: $jumpRowInput,
                    onJump: performJumpToRow
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .background(Color(NSColor.textBackgroundColor))
            .background(stateProbeBackground(metrics: metrics))
        }
        .task(id: taskIdentityKey) {
            if let wb = initialWorkbook {
                availableSheets = wb.sheetNames
                selectedSheetName = wb.activeSheet?.name ?? wb.sheetNames.first ?? ""
                if let active = wb.activeSheet {
                    loadInitialWorkbookSheet(active)
                    return
                }
            }
            let (boundedRaw, _) = TTSpreadsheetParser.truncateUTF8Prefix(initialContent, maxBytes: Self.maxPreviewUTF8Bytes)
            rawContent = boundedRaw
            isEdited = false
            reparseContent(initialContent)
        }
        .onDisappear {
            parseTask?.cancel()
            parseTask = nil
            sheetLoadingTask?.cancel()
            sheetLoadingTask = nil
        }
    }

    private func stateProbeBackground(metrics: SpreadsheetLayoutMetrics) -> some View {
        SpreadsheetPreviewStateProbeRepresentable(
            metrics: metrics, reparseCount: reparseCount, searchQuery: searchQuery,
            selectedCoordinate: selectedCoordinate, selectedCellContent: selectedCellContent,
            mode: mode, useFirstRowAsHeader: useFirstRowAsHeader,
            canSaveInPlace: mountedCanSaveInPlace, isPreviewTruncated: isPreviewTruncated,
            formatBadgeTitle: formatBadgeTitle,
            selectedSheetName: selectedSheetName, availableSheets: availableSheets,
            isSearchExpanded: isSearchExpanded, currentPageIndex: currentPageIndex, pageSizeOption: pageSizeOption,
            sheetSelectionGeneration: sheetSelectionGeneration, sheetLoadingTask: sheetLoadingTask,
            setSearchQuery: { newQuery in searchQuery = newQuery; currentPageIndex = 0; updateTableState(query: newQuery) },
            setSelectedCoordinate: { selectedCoordinate = $0 },
            setMode: { newMode in mode = newMode; if newMode == .table { reparseContent(rawContent) } },
            toggleHeaderMode: { performHeaderToggle() },
            copySelectedCellAction: {
                if let cellVal = selectedCellContent, let coord = selectedCoordinate {
                    copyToClipboard(cellVal, message: SpreadsheetPreviewLocalization.copiedCellContent(coord.excelReference))
                }
            },
            setPageSizeOption: { pageSizeOption = $0; currentPageIndex = 0 },
            setCurrentPageIndex: { currentPageIndex = max(0, $0) },
            jumpToRow: { row in jumpRowInput = "\(row)"; performJumpToRow() },
            selectSheetAction: { selectSheet($0) }
        )
        .frame(width: 0, height: 0)
    }

    private func contentArea(availableWidth: CGFloat) -> some View {
        ZStack {
            if mode == .table {
                SpreadsheetGridView(
                    paginatedDataRows: tableState.makePaginatedRowItems(
                        parsedRows: parsedRows, currentPageIndex: currentPageIndex,
                        pageSizeOption: pageSizeOption, useFirstRowAsHeader: useFirstRowAsHeader
                    ),
                    headerNames: tableState.headerNames, maxColumnCount: tableState.maxColumnCount,
                    useFirstRowAsHeader: useFirstRowAsHeader, searchQuery: searchQuery,
                    selectedCoordinate: $selectedCoordinate, columnWidths: columnWidths,
                    availableWidth: availableWidth,
                    selectedDelimiter: selectedDelimiter,
                    onCopyText: { copyToClipboard($0, message: $1) },
                    onFilterQuery: { newQuery in searchQuery = newQuery; currentPageIndex = 0; updateTableState(query: newQuery) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeHighlightingEditorNSView(
                    text: $rawContent, fileName: fileName.isEmpty ? "data.csv" : fileName,
                    isEditable: mountedCanSaveInPlace,
                    onTextChange: {
                        guard mountedCanSaveInPlace else { return }
                        if $0 != initialContent { isEdited = true }
                        reparseContent($0)
                    },
                    onSaveShortcut: mountedCanSaveInPlace ? { _ = saveFile() } : nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if isLoadingSheet {
                ZStack {
                    Color(NSColor.textBackgroundColor).opacity(0.4)
                    ProgressView().controlSize(.regular)
                }
                .transition(.opacity)
            }
            if isToastVisible, let msg = copyToastMessage { SpreadsheetToastOverlayView(message: msg) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Toolbar Subviews

    private func topControlBar(metrics: SpreadsheetLayoutMetrics) -> some View {
        HStack(spacing: 4) {
            SpreadsheetFormatBadgeView(badgeTitle: formatBadgeTitle)
            if metrics.showsDocumentTitle {
                Text((fileName.isEmpty || fileName == "Spreadsheet Document") ? SpreadsheetPreviewLocalization.text(.defaultDocumentTitle) : fileName)
                    .font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 40, maxWidth: 160, alignment: .leading)
            }
            SpreadsheetStatusBadgeView(
                metrics: metrics, isPreviewTruncated: isPreviewTruncated,
                canSaveInPlace: mountedCanSaveInPlace, isEdited: isEdited
            )
            if availableSheets.count > 1 { sheetPickerButton }
            Spacer(minLength: 4)
            if metrics.showsInlineSearchField {
                searchBar(width: metrics.searchFieldWidth)
            } else {
                searchToggleBtn
            }
            if metrics.showsInlineHeaderAndDelimiterControls {
                headerToggleBtn
                delimiterButton
            } else {
                tableSettingsButton(includeJumpPopover: !metrics.showsInlineJumpAndPageSize)
            }
            SpreadsheetModePickerView(metrics: metrics, mode: $mode) { selectedMode in
                withAnimation(TTMediaTheme.Motion.micro) {
                    mode = selectedMode
                    if selectedMode == .table { reparseContent(rawContent) }
                }
            }
            copyButton(metrics: metrics)
            saveButton(metrics: metrics)
        }
        .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var sheetPickerButton: some View {
        Button(action: {
            let entries = availableSheets.map { sheetName in
                SpreadsheetPopupMenuEntry.action(title: sheetName, isChecked: selectedSheetName == sheetName) {
                    selectSheet(sheetName)
                }
            }
            SpreadsheetPopupMenuInvoker.shared.present(entries)
        }) {
            HStack(spacing: 4) {
                if isLoadingSheet {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "doc.on.doc.fill").font(.system(size: 10))
                }
                Text(selectedSheetName.isEmpty ? SpreadsheetPreviewLocalization.text(.defaultSheetTitle) : selectedSheetName)
                    .font(.system(size: 10.5, weight: .bold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .padding(.horizontal, 6).frame(height: 24)
            .background(Color.accentColor.opacity(0.15)).foregroundStyle(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(selectedSheetName.isEmpty ? SpreadsheetPreviewLocalization.text(.defaultSheetTitle) : selectedSheetName)
    }

    private var searchToggleBtn: some View {
        let isActive = isSearchExpanded || !searchQuery.isEmpty
        return Button(action: { withAnimation(TTMediaTheme.Motion.micro) { isSearchExpanded.toggle() } }) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 26)
                .background(isActive ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(SpreadsheetPreviewLocalization.text(.searchToggleHelp))
    }

    private func searchBar(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(SpreadsheetPreviewLocalization.text(.filterCellsPlaceholder), text: $searchQuery)
                .textFieldStyle(.plain).font(.system(size: 11)).frame(width: width)
                .onChange(of: searchQuery) { _, newQuery in
                    currentPageIndex = 0
                    updateTableState(query: newQuery)
                }
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = ""; currentPageIndex = 0; updateTableState(query: "") }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .ttButtonHelp(TTButtonHelpLocalization.text(.clearSearch))
            }
        }
        .padding(.horizontal, 7).frame(height: 26)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func performHeaderToggle() {
        withAnimation(TTMediaTheme.Motion.micro) {
            useFirstRowAsHeader.toggle()
            updateTableState(firstRowAsHeader: useFirstRowAsHeader)
            if useFirstRowAsHeader, let coord = selectedCoordinate, coord.row == 0 {
                selectedCoordinate = parsedRows.count > 1 ? SpreadsheetCellCoordinate(row: 1, column: coord.column) : nil
            }
            columnWidths = SpreadsheetTableLayoutEngine.calculateColumnWidths(
                parsedRows: Array(parsedRows.prefix(200)),
                headerNames: tableState.headerNames,
                maxColumnCount: tableState.maxColumnCount
            )
        }
    }

    private var headerToggleBtn: some View {
        Button(action: performHeaderToggle) {
            Label(
                SpreadsheetPreviewLocalization.text(useFirstRowAsHeader ? .headerRowOne : .headerAlphabetical),
                systemImage: useFirstRowAsHeader ? "list.bullet.rectangle.fill" : "list.bullet.rectangle"
            )
            .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            .foregroundStyle(useFirstRowAsHeader ? Color.accentColor : .secondary)
            .padding(.horizontal, 7).frame(height: 26)
            .background(useFirstRowAsHeader ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(SpreadsheetPreviewLocalization.text(.toggleHeaderHelp))
    }

    private var delimiterButton: some View {
        Button(action: {
            let entries = TTSpreadsheetDelimiter.allCases.map { delim in
                SpreadsheetPopupMenuEntry.action(title: delim.localizedDisplayName, isChecked: selectedDelimiter == delim) {
                    selectedDelimiter = delim
                    reparseContent(rawContent, overrideDelimiter: delim.rawValue)
                }
            }
            SpreadsheetPopupMenuInvoker.shared.present(entries)
        }) {
            Label(selectedDelimiter.localizedDisplayName, systemImage: "character.textbox")
                .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 7).frame(height: 26)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(selectedDelimiter.localizedDisplayName)
    }

    private func tableSettingsButton(includeJumpPopover: Bool) -> some View {
        Button(action: presentTableSettingsMenu) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(SpreadsheetPreviewLocalization.text(.tableSettingsMenu))
        .popover(
            isPresented: Binding(get: { includeJumpPopover && isJumpPopoverPresented }, set: { isJumpPopoverPresented = $0 }),
            arrowEdge: .bottom
        ) {
            SpreadsheetJumpRowPopoverView(maxRow: tableState.effectiveRowCount, jumpRowInput: $jumpRowInput, onJump: performJumpToRow)
        }
    }

    private func presentTableSettingsMenu() {
        var entries: [SpreadsheetPopupMenuEntry] = [
            .sectionHeader(SpreadsheetPreviewLocalization.text(.headerSectionTitle)),
            .action(title: SpreadsheetPreviewLocalization.text(.headerAlphabetical), isChecked: !useFirstRowAsHeader) {
                if useFirstRowAsHeader { performHeaderToggle() }
            },
            .action(title: SpreadsheetPreviewLocalization.text(.headerRowOne), isChecked: useFirstRowAsHeader) {
                if !useFirstRowAsHeader { performHeaderToggle() }
            },
            .separator,
            .sectionHeader(SpreadsheetPreviewLocalization.text(.delimiterSectionTitle))
        ]
        for delim in TTSpreadsheetDelimiter.allCases {
            entries.append(.action(title: delim.localizedDisplayName, isChecked: selectedDelimiter == delim) {
                selectedDelimiter = delim
                reparseContent(rawContent, overrideDelimiter: delim.rawValue)
            })
        }
        entries.append(.separator)
        for opt in SpreadsheetPageSizeOption.allCases {
            entries.append(.action(title: SpreadsheetPreviewLocalization.pageSizeMenu(opt.localizedDisplayName), isChecked: pageSizeOption == opt) {
                pageSizeOption = opt
                currentPageIndex = 0
            })
        }
        entries.append(.action(title: SpreadsheetPreviewLocalization.text(.jumpToRowTitle)) {
            isJumpPopoverPresented = true
        })
        SpreadsheetPopupMenuInvoker.shared.present(entries)
    }

    private func copyButton(metrics: SpreadsheetLayoutMetrics) -> some View {
        Button(action: presentCopyMenu) {
            Group {
                if metrics.tier == .narrow || metrics.tier == .regular {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 26)
                } else {
                    Label(SpreadsheetPreviewLocalization.text(.copyButton), systemImage: "doc.on.doc.fill")
                        .font(.system(size: 10.5, weight: .bold)).lineLimit(1).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).frame(height: 26)
                }
            }
            .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(SpreadsheetPreviewLocalization.text(.copyButton))
    }

    private func presentCopyMenu() {
        var entries: [SpreadsheetPopupMenuEntry] = []
        if let cellVal = selectedCellContent, let coord = selectedCoordinate {
            entries.append(.action(title: SpreadsheetPreviewLocalization.copySelectedCell(coord.excelReference)) {
                copyToClipboard(cellVal, message: SpreadsheetPreviewLocalization.copiedCell(coord.excelReference))
            })
        }
        entries.append(.action(title: SpreadsheetPreviewLocalization.text(.copyTableAsCSV)) {
            copyToClipboard(TTSpreadsheetParser.exportToDelimited(rows: parsedRows, delimiter: ","), message: SpreadsheetPreviewLocalization.text(.copiedTableAsCSV))
        })
        entries.append(.action(title: SpreadsheetPreviewLocalization.text(.copyTableAsTSV)) {
            copyToClipboard(TTSpreadsheetParser.exportToDelimited(rows: parsedRows, delimiter: "\t"), message: SpreadsheetPreviewLocalization.text(.copiedTableAsTSV))
        })
        entries.append(.action(title: SpreadsheetPreviewLocalization.text(.copyTableAsMarkdown)) {
            copyToClipboard(TTSpreadsheetParser.exportToMarkdownTable(rows: parsedRows, hasHeader: useFirstRowAsHeader), message: SpreadsheetPreviewLocalization.text(.copiedTableAsMarkdown))
        })
        SpreadsheetPopupMenuInvoker.shared.present(entries)
    }

    @ViewBuilder
    private func saveButton(metrics: SpreadsheetLayoutMetrics) -> some View {
        if mountedCanSaveInPlace {
            if isSavedToastPresented && metrics.tier == .wide {
                Label(SpreadsheetPreviewLocalization.text(.savedBadge), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .bold)).lineLimit(1).foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: true, vertical: false).transition(.opacity)
            }
            Button(action: { _ = saveFile() }) {
                Group {
                    if metrics.tier != .wide {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 10.5, weight: .bold)).frame(width: 28, height: 26)
                    } else {
                        Label(SpreadsheetPreviewLocalization.text(.saveButton), systemImage: "square.and.arrow.down.fill")
                            .font(.system(size: 10.5, weight: .bold)).lineLimit(1).padding(.horizontal, 7).frame(height: 26)
                    }
                }
                .foregroundStyle(isEdited ? Color.white : Color.accentColor)
                .background(isEdited ? Color.accentColor : Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
            .keyboardShortcut("s", modifiers: [.command])
            .ttButtonHelp(SpreadsheetPreviewLocalization.text(.saveHelp))
        }
    }

    // MARK: - Actions & Background Parsing

    private func loadInitialWorkbookSheet(_ sheet: TTMediaSheetData) {
        parseTask?.cancel()
        reparseCount += 1
        let useFirstRow = useFirstRowAsHeader
        let query = searchQuery
        let maxRows = Self.maxPreviewRows
        let expectedGen = sheetSelectionGeneration

        parseTask = Task { @MainActor in
            let firstScreen = await SpreadsheetBackgroundPipeline.computeWorkbookFirstScreenSnapshot(
                sheet: sheet, useFirstRowAsHeader: useFirstRow, searchQuery: query, maxRows: maxRows
            )
            guard !Task.isCancelled, self.sheetSelectionGeneration == expectedGen, let initial = firstScreen else { return }
            self.parsedRows = initial.rows
            self.tableState = initial.tableState
            self.columnWidths = initial.columnWidths
            self.isPreviewTruncated = initial.isTruncated
            self.currentPageIndex = 0

            let fullResult = await SpreadsheetBackgroundPipeline.computeWorkbookFullSnapshot(
                sheet: sheet, useFirstRowAsHeader: useFirstRow, searchQuery: query, maxRows: maxRows
            )
            guard !Task.isCancelled, self.sheetSelectionGeneration == expectedGen, let full = fullResult else { return }
            self.parsedRows = full.snapshot.rows
            self.tableState = full.snapshot.tableState
            self.columnWidths = full.snapshot.columnWidths
            self.rawContent = full.csv
            self.isPreviewTruncated = full.snapshot.isTruncated
        }
    }

    private func selectSheet(_ sheetName: String) {
        guard sheetName != selectedSheetName || parsedRows.isEmpty, let wb = initialWorkbook else { return }
        parseTask?.cancel()
        sheetLoadingTask?.cancel()
        sheetSelectionGeneration &+= 1
        let expectedGen = sheetSelectionGeneration
        selectedSheetName = sheetName
        isLoadingSheet = true
        selectedCoordinate = nil
        let useFirstRow = useFirstRowAsHeader
        let query = searchQuery
        let dataLoader = sheetDataLoader
        let rowLoader = sheetLoader
        let maxRows = Self.maxPreviewRows

        sheetLoadingTask = Task { @MainActor in
            let loaded = await SpreadsheetBackgroundPipeline.loadAndComputeSelectedSheet(
                sheetName: sheetName, workbook: wb, sheetDataLoader: dataLoader, sheetLoader: rowLoader,
                useFirstRowAsHeader: useFirstRow, searchQuery: query, maxRows: maxRows
            )
            guard !Task.isCancelled, self.sheetSelectionGeneration == expectedGen, self.selectedSheetName == sheetName else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isLoadingSheet = false
                if let loaded {
                    self.parsedRows = loaded.result.parsedRows
                    self.rawContent = loaded.result.rawContent
                    self.currentPageIndex = 0
                    self.columnWidths = loaded.result.columnWidths
                    self.tableState = loaded.state
                    self.isPreviewTruncated = loaded.isTruncated
                } else {
                    self.showToast(SpreadsheetPreviewLocalization.sheetLoadFailed(sheetName))
                }
            }
        }
    }

    private func reparseContent(_ content: String, overrideDelimiter: Character? = nil) {
        parseTask?.cancel()
        reparseCount += 1
        let useFirstRow = useFirstRowAsHeader
        let query = searchQuery
        let maxRows = Self.maxPreviewRows
        let maxBytes = Self.maxPreviewUTF8Bytes

        parseTask = Task { @MainActor in
            let firstStage = await SpreadsheetBackgroundPipeline.computeFirstScreenSnapshot(
                content: content, overrideDelimiter: overrideDelimiter,
                useFirstRowAsHeader: useFirstRow, searchQuery: query, maxUTF8Bytes: maxBytes
            )
            guard !Task.isCancelled, let stage1 = firstStage else { return }
            if overrideDelimiter == nil {
                self.detectedDelimiter = stage1.detectedDelimiter
                self.selectedDelimiter = stage1.detectedDelimiter
            }
            self.parsedRows = stage1.rows
            self.tableState = stage1.tableState
            self.columnWidths = stage1.columnWidths
            self.currentPageIndex = 0

            guard stage1.hasMoreRows else {
                self.isPreviewTruncated = stage1.isTruncated
                return
            }
            let secondStage = await SpreadsheetBackgroundPipeline.computeFullBudgetedSnapshot(
                content: content, stage1: stage1,
                useFirstRowAsHeader: useFirstRow, searchQuery: query, maxRows: maxRows, maxUTF8Bytes: maxBytes
            )
            guard !Task.isCancelled, let stage2 = secondStage else { return }
            self.parsedRows = stage2.rows
            self.tableState = stage2.tableState
            self.columnWidths = stage2.columnWidths
            self.isPreviewTruncated = stage2.isTruncated
        }
    }

    nonisolated internal static func parseChunk(text: String, delimiter: Character, limit: Int) -> [[String]] {
        TTSpreadsheetParser.parsePrefix(text: text, delimiter: delimiter, maxRows: limit).rows
    }

    private func performJumpToRow() {
        isJumpPopoverPresented = false
        guard let row = Int(jumpRowInput.trimmingCharacters(in: .whitespacesAndNewlines)), row >= 1 else { return }
        jumpRowInput = ""
        let targetIndex = row - 1
        guard targetIndex < tableState.filteredRowCount else { return }
        let totalPages = tableState.totalPages(for: pageSizeOption)
        let pageSize = tableState.pageSize(for: pageSizeOption)
        if pageSizeOption.rawValue != -1 { currentPageIndex = min(targetIndex / pageSize, max(0, totalPages - 1)) }
        let resolvedRow = tableState.effectiveRowIndex(at: targetIndex, useFirstRowAsHeader: useFirstRowAsHeader)
        let resolvedCol = min(max(0, selectedCoordinate?.column ?? 0), max(0, tableState.maxColumnCount - 1))
        selectedCoordinate = SpreadsheetCellCoordinate(row: resolvedRow, column: resolvedCol)
    }

    private func showToast(_ message: String) {
        copyToastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) { isToastVisible = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            withAnimation(.easeInOut(duration: 0.25)) { isToastVisible = false }
        }
    }

    private func copyToClipboard(_ string: String, message: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        showToast(message)
    }

    @discardableResult
    public func saveFile(contentOverride: String? = nil) -> Bool {
        guard !isReadOnly, !Self.isArchiveOrEphemeralStagingURL(fileURL) else {
            showToast(SpreadsheetPreviewLocalization.text(.saveBlockedReadOnly))
            return false
        }
        let targetContent = contentOverride ?? rawContent
        let context = resolvedResourceContext
        do {
            guard try SpreadsheetSavePolicy.saveInPlace(
                content: targetContent, fileURL: fileURL, fileName: fileName,
                workbook: initialWorkbook, hasSheetLoader: sheetLoader != nil || sheetDataLoader != nil,
                isPreviewTruncated: isPreviewTruncated, resourceContext: context
            ) else {
                let reasonKey: SpreadsheetPreviewLocaleKey =
                    targetContent.utf8.count > TTSpreadsheetParser.maxInteractivePreviewUTF8Bytes
                    ? .saveBlockedExceededBudget
                    : .saveBlockedReadOnly
                showToast(SpreadsheetPreviewLocalization.text(reasonKey))
                return false
            }
            withAnimation { isEdited = false; isSavedToastPresented = true }
            NotificationCenter.default.post(
                name: .ttMediaFileContentDidChange,
                object: fileURL,
                userInfo: context.toUserInfoDictionary()
            )
            NotificationCenter.default.post(name: NSNotification.Name("TTMediaArchiveUnlockedRefreshNotification"), object: nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.0))
                withAnimation { isSavedToastPresented = false }
            }
            return true
        } catch {
            showToast(SpreadsheetPreviewLocalization.saveFailed(error.localizedDescription))
            return false
        }
    }
}
