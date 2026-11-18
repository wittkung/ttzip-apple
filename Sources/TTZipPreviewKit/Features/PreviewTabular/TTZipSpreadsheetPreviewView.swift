// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit
import TTZipUI
import TTKitDesign

struct TTZipSpreadsheetPreviewView: View {
    private static let maxPreviewRows: Int = TTSpreadsheetParser.maxInteractivePreviewRows
    private static let maxPreviewUTF8Bytes: Int = TTSpreadsheetParser.maxInteractivePreviewUTF8Bytes

    private let initialContent: String
    private let fileURL: URL?
    private let fileName: String
    private let resourceContext: TTPreviewResourceContext
    private let initialWorkbook: OfficeSpreadsheetWorkbook?

    @Environment(\.previewBottomTrailingReservedWidth) private var bottomTrailingReservedWidth
    @Environment(\.ttZipSpreadsheetParsePipeline) private var parsePipeline
    @State private var mode: SpreadsheetPreviewMode = .table
    @State private var tableSession: TTZipSpreadsheetTableSession
    @State private var isSearchExpanded = false
    @State private var isCellDetailPopoverPresented = false
    @State private var jumpRowInput = ""
    @State private var isJumpPopoverPresented = false
    @State private var isEdited = false
    @State private var isSavedToastPresented = false
    @State private var copyToastMessage: String? = nil
    @State private var isToastVisible = false
    @State private var sheetLoadingTask: Task<Void, Never>? = nil
    @State private var parseTask: Task<Void, Never>? = nil
    @State private var savedBaselineContent: String?
    private let baselineTracker: TTSavedBaselineTracker

    init(content: String, fileURL: URL?, fileName: String, resourceContext: TTPreviewResourceContext) {
        self.initialContent = content
        self.fileURL = fileURL
        self.fileName = fileName
        self.resourceContext = resourceContext
        self.initialWorkbook = nil
        let (boundedRaw, _) = TTSpreadsheetParser.truncateUTF8Prefix(content, maxBytes: Self.maxPreviewUTF8Bytes)
        let initialTruncated = TTSpreadsheetParser.exceedsPreviewBudget(
            text: content, workbook: nil, maxRows: Self.maxPreviewRows, maxUTF8Bytes: Self.maxPreviewUTF8Bytes
        )
        self.baselineTracker = TTSavedBaselineTracker(initialContent: boundedRaw, fileURL: fileURL)
        self._tableSession = State(initialValue: TTZipSpreadsheetTableSession(
            initialRawContent: boundedRaw,
            isPreviewTruncated: initialTruncated
        ))
    }

    init(workbook: OfficeSpreadsheetWorkbook, resourceContext: TTPreviewResourceContext) {
        self.initialContent = ""
        self.fileURL = workbook.fileURL
        self.fileName = workbook.fileName
        self.resourceContext = resourceContext
        self.initialWorkbook = workbook
        let initialTruncated = workbook.activeSheet.map {
            $0.isTruncated || $0.rows.count > Self.maxPreviewRows
        } ?? false
        self.baselineTracker = TTSavedBaselineTracker(initialContent: "")
        self._tableSession = State(initialValue: TTZipSpreadsheetTableSession(
            initialRawContent: "",
            isPreviewTruncated: initialTruncated,
            isWorkbook: true
        ))
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { tableSession.controls.searchQuery },
            set: { tableSession.setSearchQuery($0) }
        )
    }

    private var pageSizeOptionBinding: Binding<SpreadsheetPageSizeOption> {
        Binding(
            get: { tableSession.controls.pageSizeOption },
            set: { tableSession.setPageSizeOption($0) }
        )
    }

    private var currentPageIndexBinding: Binding<Int> {
        Binding(
            get: { tableSession.controls.currentPageIndex },
            set: { tableSession.setCurrentPageIndex($0) }
        )
    }

    private var selectedCoordinateBinding: Binding<SpreadsheetCellCoordinate?> {
        Binding(
            get: { tableSession.controls.selectedCoordinate },
            set: { tableSession.setSelectedCoordinate($0) }
        )
    }

    private var rawContentBinding: Binding<String> {
        Binding(
            get: { tableSession.rawContent },
            set: { tableSession.setRawContent($0) }
        )
    }

    private var selectedCellContent: String? {
        guard let c = tableSession.controls.selectedCoordinate,
              c.row >= 0,
              c.row < tableSession.parsedRows.count else { return nil }
        let row = tableSession.parsedRows[c.row]
        return (c.column >= 0 && c.column < row.count) ? row[c.column] : nil
    }

    private var formatBadgeTitle: String {
        initialWorkbook?.format.badgeTitle ?? tableSession.selectedDelimiter.shortName
    }

    private var hasStagingURL: Bool {
        PreviewStagingPolicy.hasStagingURL(fileURL, context: resourceContext)
    }

    private var canSaveInPlace: Bool {
        !hasStagingURL && SpreadsheetSavePolicy.canSaveInPlace(
            fileURL: fileURL,
            fileName: fileName,
            workbook: initialWorkbook,
            isPreviewTruncated: tableSession.isPreviewTruncated,
            resourceContext: resourceContext
        )
    }

    private var fileSizeString: String {
        if let url = fileURL, url.isFileURL, let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        let byteCount = initialContent.isEmpty ? tableSession.rawContent.utf8.count : initialContent.utf8.count
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private var taskIdentityKey: String {
        let resolvedPath = fileURL?.path ?? initialWorkbook?.fileURL?.path ?? ""
        let sheetSample = initialWorkbook?.activeSheet?.rows.prefix(4).map { $0.prefix(8).joined(separator: "\u{1F}") }.joined(separator: "\u{1E}") ?? ""
        let wbSig = "\(initialWorkbook?.sheetNames.joined(separator: ",") ?? "")|\(initialWorkbook?.activeSheet?.totalRows ?? 0)x\(initialWorkbook?.activeSheet?.totalColumns ?? 0)|\(initialWorkbook?.rawData?.count ?? 0)|\(sheetSample)"
        return "\(fileName)|\(resolvedPath)|\(wbSig)|\(initialContent.utf8.count)|\(initialContent.prefix(64))"
    }

    // MARK: - Body View

    var body: some View {
        GeometryReader { proxy in
            let metrics = TTZipSpreadsheetLayoutMetrics(width: proxy.size.width)
            VStack(spacing: 0) {
                topControlBar(metrics: metrics)
                    .accessibilityIdentifier("TTZipSpreadsheetToolbar")
                if !metrics.showsInlineSearchField && (isSearchExpanded || !tableSession.controls.searchQuery.isEmpty) {
                    Divider()
                    TTZipSpreadsheetExpandableSearchRowView(searchQuery: searchQueryBinding)
                }
                Divider()
                TTZipSpreadsheetCellInspectorBarView(
                    selectedCoordinate: tableSession.controls.selectedCoordinate,
                    selectedCellContent: selectedCellContent,
                    isCellDetailPopoverPresented: $isCellDetailPopoverPresented,
                    onCopyCell: { coord, val in
                        copyToClipboard(val, message: SpreadsheetPreviewLocalization.copiedCellContent(coord.excelReference))
                    }
                )
                Divider()
                contentArea(availableWidth: proxy.size.width)
                Divider()
                TTZipSpreadsheetBottomStatusBarView(
                    metrics: metrics,
                    tableState: tableSession.tableState,
                    fileSizeString: fileSizeString,
                    isPreviewTruncated: tableSession.isPreviewTruncated,
                    maxPreviewRows: Self.maxPreviewRows,
                    pageSizeOption: pageSizeOptionBinding,
                    currentPageIndex: currentPageIndexBinding,
                    isJumpPopoverPresented: $isJumpPopoverPresented,
                    jumpRowInput: $jumpRowInput,
                    onJump: performJumpToRow
                )
                .padding(.trailing, bottomTrailingReservedWidth > 0 ? (2 + bottomTrailingReservedWidth) : 0)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .background(Color(NSColor.textBackgroundColor))
            .background {
                TTZipSpreadsheetPreviewStateProbeRepresentable(
                    canSaveInPlace: canSaveInPlace,
                    selectedSheetName: tableSession.selectedSheetName,
                    selectedCellContent: selectedCellContent,
                    searchQuery: tableSession.controls.searchQuery,
                    useFirstRowAsHeader: tableSession.controls.useFirstRowAsHeader,
                    selectCell: { tableSession.setSelectedCoordinate($0) },
                    selectSheet: selectSheet,
                    toggleHeader: performHeaderToggle,
                    selectMode: performModeSelection,
                    selectDelimiter: performDelimiterSelection
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .task(id: taskIdentityKey) {
            parseTask?.cancel(); parseTask = nil
            sheetLoadingTask?.cancel(); sheetLoadingTask = nil
            isCellDetailPopoverPresented = false
            isSearchExpanded = false
            isJumpPopoverPresented = false; jumpRowInput = ""
            if let wb = initialWorkbook {
                let initialTruncated = wb.activeSheet.map {
                    $0.isTruncated || $0.rows.count > Self.maxPreviewRows
                } ?? false
                tableSession.resetForDocument(workbook: wb, boundedRawContent: "", initialIsTruncated: initialTruncated)
                if let active = wb.activeSheet {
                    loadInitialWorkbookSheet(active)
                }
                return
            }
            let (boundedRaw, _) = TTSpreadsheetParser.truncateUTF8Prefix(initialContent, maxBytes: Self.maxPreviewUTF8Bytes)
            let initialTruncated = TTSpreadsheetParser.exceedsPreviewBudget(
                text: initialContent, workbook: nil, maxRows: Self.maxPreviewRows, maxUTF8Bytes: Self.maxPreviewUTF8Bytes
            )
            tableSession.resetForDocument(workbook: nil, boundedRawContent: boundedRaw, initialIsTruncated: initialTruncated)
            savedBaselineContent = nil
            baselineTracker.reset(initialContent: boundedRaw, fileURL: fileURL)
            isEdited = false
            reparseContent(initialContent)
        }
        .onDisappear {
            parseTask?.cancel(); parseTask = nil
            sheetLoadingTask?.cancel(); sheetLoadingTask = nil
        }
    }

    private func contentArea(availableWidth: CGFloat) -> some View {
        ZStack {
            if mode == .table {
                TTZipSpreadsheetGridView(
                    paginatedDataRows: tableSession.tableState.makePaginatedRowItems(
                        parsedRows: tableSession.parsedRows,
                        currentPageIndex: tableSession.controls.currentPageIndex,
                        pageSizeOption: tableSession.controls.pageSizeOption,
                        useFirstRowAsHeader: tableSession.controls.useFirstRowAsHeader
                    ),
                    headerNames: tableSession.tableState.headerNames,
                    maxColumnCount: tableSession.tableState.maxColumnCount,
                    selectedCoordinate: selectedCoordinateBinding,
                    columnWidths: tableSession.columnWidths,
                    availableWidth: availableWidth,
                    onCopyText: { copyToClipboard($0, message: $1) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeHighlightingEditorNSView(
                    text: rawContentBinding,
                    fileName: fileName.isEmpty ? "data.csv" : fileName,
                    isEditable: canSaveInPlace,
                    readingPalette: TTZipTextReadingAppearance.resolve(
                        mode: .fluidTransparent, isDarkAppearance: true
                    ),
                    onTextChange: {
                        guard canSaveInPlace else { return }
                        if $0 != initialContent { isEdited = true }
                        reparseContent($0)
                    },
                    onSaveShortcut: canSaveInPlace ? { saveFile() } : nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if tableSession.isLoadingSheet {
                ZStack {
                    Color(NSColor.textBackgroundColor).opacity(0.4)
                    ProgressView().controlSize(.regular)
                }
                .transition(.opacity)
            }
            if isToastVisible, let msg = copyToastMessage { TTZipSpreadsheetToastOverlayView(message: msg) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Toolbar Subviews

    private func topControlBar(metrics: TTZipSpreadsheetLayoutMetrics) -> some View {
        HStack(spacing: 4) {
            TTZipSpreadsheetFormatBadgeView(badgeTitle: formatBadgeTitle)
            if metrics.showsDocumentTitle {
                Text((fileName.isEmpty || fileName == "Spreadsheet Document") ? SpreadsheetPreviewLocalization.text(.defaultDocumentTitle) : fileName)
                    .font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 40, maxWidth: 160, alignment: .leading)
            }
            TTZipSpreadsheetStatusBadgeView(
                metrics: metrics, isPreviewTruncated: tableSession.isPreviewTruncated,
                canSaveInPlace: canSaveInPlace, isEdited: isEdited
            )
            if tableSession.availableSheets.count > 1 { sheetPickerButton }
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
            TTZipSpreadsheetModePickerView(metrics: metrics, mode: $mode, onSelectMode: performModeSelection)
            copyButton(metrics: metrics)
            saveButton(metrics: metrics)
        }
        .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var sheetPickerButton: some View {
        Button(action: {
            let entries = tableSession.availableSheets.map { sheetName in
                TTZipSpreadsheetPopupMenuEntry.action(title: sheetName, isChecked: tableSession.selectedSheetName == sheetName) {
                    selectSheet(sheetName)
                }
            }
            TTZipSpreadsheetPopupMenuInvoker.shared.present(entries)
        }) {
            HStack(spacing: 4) {
                if tableSession.isLoadingSheet {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "doc.on.doc.fill").font(.system(size: 10))
                }
                Text(tableSession.selectedSheetName.isEmpty ? SpreadsheetPreviewLocalization.text(.defaultSheetTitle) : tableSession.selectedSheetName)
                    .font(.system(size: 10.5, weight: .bold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .padding(.horizontal, 6).frame(height: 24)
            .background(TTZipTheme.accentColor.opacity(0.15)).foregroundStyle(TTZipTheme.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(tableSession.selectedSheetName.isEmpty ? SpreadsheetPreviewLocalization.text(.defaultSheetTitle) : tableSession.selectedSheetName)
    }

    private var searchToggleBtn: some View {
        let isActive = isSearchExpanded || !tableSession.controls.searchQuery.isEmpty
        return Button(action: { withAnimation(TTZipTheme.Motion.micro) { isSearchExpanded.toggle() } }) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? TTZipTheme.accentColor : Color.secondary)
                .frame(width: 28, height: 26)
                .background(isActive ? TTZipTheme.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(SpreadsheetPreviewLocalization.text(.searchToggleHelp))
    }

    private func searchBar(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(SpreadsheetPreviewLocalization.text(.filterCellsPlaceholder), text: searchQueryBinding)
                .textFieldStyle(.plain).font(.system(size: 11)).frame(width: width)
            if !tableSession.controls.searchQuery.isEmpty {
                Button(action: { tableSession.setSearchQuery("") }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .ttButtonHelp(TTButtonHelpLocalization.text(.clearSearch))
            }
        }
        .padding(.horizontal, 7).frame(height: 26)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func performHeaderToggle() {
        withAnimation(TTZipTheme.Motion.micro) {
            tableSession.toggleFirstRowAsHeader()
        }
    }

    private func performModeSelection(_ selectedMode: SpreadsheetPreviewMode) {
        withAnimation(TTZipTheme.Motion.micro) {
            mode = selectedMode
            if selectedMode == .table { reparseContent(tableSession.rawContent) }
        }
    }

    private func performDelimiterSelection(_ delimiter: TTSpreadsheetDelimiter) {
        tableSession.selectDelimiter(delimiter)
        reparseContent(tableSession.rawContent, overrideDelimiter: delimiter.rawValue)
    }

    private var headerToggleBtn: some View {
        let headerEnabled = tableSession.controls.useFirstRowAsHeader
        return Button(action: performHeaderToggle) {
            Label(
                SpreadsheetPreviewLocalization.text(headerEnabled ? .headerRowOne : .headerAlphabetical),
                systemImage: headerEnabled ? "list.bullet.rectangle.fill" : "list.bullet.rectangle"
            )
            .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            .foregroundStyle(headerEnabled ? TTZipTheme.accentColor : .secondary)
            .padding(.horizontal, 7).frame(height: 26)
            .background(headerEnabled ? TTZipTheme.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(SpreadsheetPreviewLocalization.text(.toggleHeaderHelp))
    }

    private var delimiterButton: some View {
        Button(action: {
            let entries = TTSpreadsheetDelimiter.allCases.map { delim in
                TTZipSpreadsheetPopupMenuEntry.action(
                    title: delim.localizedDisplayName,
                    isChecked: tableSession.selectedDelimiter == delim
                ) {
                    performDelimiterSelection(delim)
                }
            }
            TTZipSpreadsheetPopupMenuInvoker.shared.present(entries)
        }) {
            Label(tableSession.selectedDelimiter.localizedDisplayName, systemImage: "character.textbox")
                .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 7).frame(height: 26)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(tableSession.selectedDelimiter.localizedDisplayName)
    }

    private func tableSettingsButton(includeJumpPopover: Bool) -> some View {
        Button(action: presentTableSettingsMenu) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(SpreadsheetPreviewLocalization.text(.tableSettingsMenu))
        .popover(
            isPresented: Binding(get: { includeJumpPopover && isJumpPopoverPresented }, set: { isJumpPopoverPresented = $0 }),
            arrowEdge: .bottom
        ) {
            TTZipSpreadsheetJumpRowPopoverView(
                maxRow: tableSession.tableState.effectiveRowCount,
                jumpRowInput: $jumpRowInput,
                onJump: performJumpToRow
            )
        }
    }

    private func presentTableSettingsMenu() {
        let headerEnabled = tableSession.controls.useFirstRowAsHeader
        var entries: [TTZipSpreadsheetPopupMenuEntry] = [
            .sectionHeader(SpreadsheetPreviewLocalization.text(.headerSectionTitle)),
            .action(title: SpreadsheetPreviewLocalization.text(.headerAlphabetical), isChecked: !headerEnabled) {
                if tableSession.controls.useFirstRowAsHeader { performHeaderToggle() }
            },
            .action(title: SpreadsheetPreviewLocalization.text(.headerRowOne), isChecked: headerEnabled) {
                if !tableSession.controls.useFirstRowAsHeader { performHeaderToggle() }
            },
            .separator,
            .sectionHeader(SpreadsheetPreviewLocalization.text(.delimiterSectionTitle))
        ]
        for delim in TTSpreadsheetDelimiter.allCases {
            entries.append(.action(title: delim.localizedDisplayName, isChecked: tableSession.selectedDelimiter == delim) {
                performDelimiterSelection(delim)
            })
        }
        entries.append(.separator)
        for opt in SpreadsheetPageSizeOption.allCases {
            entries.append(.action(
                title: SpreadsheetPreviewLocalization.pageSizeMenu(opt.localizedDisplayName),
                isChecked: tableSession.controls.pageSizeOption == opt
            ) {
                tableSession.setPageSizeOption(opt)
            })
        }
        entries.append(.action(title: SpreadsheetPreviewLocalization.text(.jumpToRowTitle)) {
            isJumpPopoverPresented = true
        })
        TTZipSpreadsheetPopupMenuInvoker.shared.present(entries)
    }

    private func copyButton(metrics: TTZipSpreadsheetLayoutMetrics) -> some View {
        Button(action: presentCopyMenu) {
            Group {
                if metrics.tier == .narrow || metrics.tier == .regular {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(TTZipTheme.accentColor)
                        .frame(width: 28, height: 26)
                } else {
                    Label(SpreadsheetPreviewLocalization.text(.copyButton), systemImage: "doc.on.doc.fill")
                        .font(.system(size: 10.5, weight: .bold)).lineLimit(1).foregroundStyle(TTZipTheme.accentColor)
                        .padding(.horizontal, 7).frame(height: 26)
                }
            }
            .background(TTZipTheme.accentColor.opacity(0.12)).clipShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(SpreadsheetPreviewLocalization.text(.copyButton))
    }

    private func presentCopyMenu() {
        var entries: [TTZipSpreadsheetPopupMenuEntry] = []
        if let cellVal = selectedCellContent, let coord = tableSession.controls.selectedCoordinate {
            entries.append(.action(title: SpreadsheetPreviewLocalization.copySelectedCell(coord.excelReference)) {
                copyToClipboard(cellVal, message: SpreadsheetPreviewLocalization.copiedCell(coord.excelReference))
            })
        }
        entries.append(.action(title: SpreadsheetPreviewLocalization.text(.copyTableAsCSV)) {
            copyToClipboard(
                TTSpreadsheetParser.exportToDelimited(rows: tableSession.parsedRows, delimiter: ","),
                message: SpreadsheetPreviewLocalization.text(.copiedTableAsCSV)
            )
        })
        entries.append(.action(title: SpreadsheetPreviewLocalization.text(.copyTableAsTSV)) {
            copyToClipboard(
                TTSpreadsheetParser.exportToDelimited(rows: tableSession.parsedRows, delimiter: "\t"),
                message: SpreadsheetPreviewLocalization.text(.copiedTableAsTSV)
            )
        })
        entries.append(.action(title: SpreadsheetPreviewLocalization.text(.copyTableAsMarkdown)) {
            copyToClipboard(
                TTSpreadsheetParser.exportToMarkdownTable(
                    rows: tableSession.parsedRows,
                    hasHeader: tableSession.controls.useFirstRowAsHeader
                ),
                message: SpreadsheetPreviewLocalization.text(.copiedTableAsMarkdown)
            )
        })
        TTZipSpreadsheetPopupMenuInvoker.shared.present(entries)
    }

    @ViewBuilder
    private func saveButton(metrics: TTZipSpreadsheetLayoutMetrics) -> some View {
        if canSaveInPlace {
            if isSavedToastPresented && metrics.tier == .wide {
                Label(SpreadsheetPreviewLocalization.text(.savedBadge), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .bold)).lineLimit(1).foregroundStyle(TTZipTheme.accentColor)
                    .fixedSize(horizontal: true, vertical: false).transition(.opacity)
            }
            Button(action: saveFile) {
                Group {
                    if metrics.tier != .wide {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 10.5, weight: .bold)).frame(width: 28, height: 26)
                    } else {
                        Label(SpreadsheetPreviewLocalization.text(.saveButton), systemImage: "square.and.arrow.down.fill")
                            .font(.system(size: 10.5, weight: .bold)).lineLimit(1).padding(.horizontal, 7).frame(height: 26)
                    }
                }
                .foregroundStyle(isEdited ? Color.white : TTZipTheme.accentColor)
                .background(isEdited ? TTZipTheme.accentColor : TTZipTheme.accentColor.opacity(0.12))
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
        let pipeline = parsePipeline
        let token = tableSession.beginWorkbookInitialParse()
        let stage1Header = tableSession.controls.useFirstRowAsHeader
        let stage1Query = tableSession.controls.searchQuery
        let maxRows = Self.maxPreviewRows

        parseTask = Task { @MainActor in
            let firstScreen = await pipeline.computeWorkbookFirstScreenSnapshot(
                sheet: sheet, useFirstRowAsHeader: stage1Header, searchQuery: stage1Query, maxRows: maxRows
            )
            guard !Task.isCancelled, let initial = firstScreen else { return }
            let appliedStage1 = self.tableSession.applyParseOutput(
                .fromSnapshot(
                    initial,
                    capturedHeader: stage1Header,
                    capturedQuery: stage1Query,
                    truncationUpdate: .replaceFinal(initial.isTruncated)
                ),
                token: token
            )
            guard appliedStage1 else { return }

            let stage2Header = self.tableSession.controls.useFirstRowAsHeader
            let stage2Query = self.tableSession.controls.searchQuery
            let fullResult = await pipeline.computeWorkbookFullSnapshot(
                sheet: sheet, useFirstRowAsHeader: stage2Header, searchQuery: stage2Query, maxRows: maxRows
            )
            guard !Task.isCancelled, let full = fullResult else { return }
            self.tableSession.applyParseOutput(
                .fromSnapshot(
                    full.snapshot,
                    capturedHeader: stage2Header,
                    capturedQuery: stage2Query,
                    truncationUpdate: .replaceFinal(full.snapshot.isTruncated),
                    updatedRawContent: full.csv
                ),
                token: token
            )
        }
    }

    private func selectSheet(_ sheetName: String) {
        guard let wb = initialWorkbook,
              let token = tableSession.beginSheetSelection(sheetName) else { return }
        parseTask?.cancel()
        sheetLoadingTask?.cancel()
        let pipeline = parsePipeline
        let capturedHeader = tableSession.controls.useFirstRowAsHeader
        let capturedQuery = tableSession.controls.searchQuery
        let maxRows = Self.maxPreviewRows

        sheetLoadingTask = Task { @MainActor in
            let loaded = await pipeline.loadAndComputeSelectedSheet(
                sheetName: sheetName, workbook: wb,
                useFirstRowAsHeader: capturedHeader, searchQuery: capturedQuery, maxRows: maxRows
            )
            guard !Task.isCancelled, self.tableSession.isCurrent(token) else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if let loaded {
                    self.tableSession.applyParseOutput(
                        .fromSelectedSheet(loaded, capturedHeader: capturedHeader, capturedQuery: capturedQuery),
                        token: token
                    )
                } else if self.tableSession.finishSheetLoadingFailure(token: token) {
                    self.showToast(SpreadsheetPreviewLocalization.sheetLoadFailed(sheetName))
                }
            }
        }
    }

    private func reparseContent(_ content: String, overrideDelimiter: Character? = nil) {
        guard let token = tableSession.beginContentParse() else { return }
        parseTask?.cancel()
        let pipeline = parsePipeline
        let stage1Header = tableSession.controls.useFirstRowAsHeader
        let stage1Query = tableSession.controls.searchQuery
        let maxRows = Self.maxPreviewRows
        let maxBytes = Self.maxPreviewUTF8Bytes

        parseTask = Task { @MainActor in
            let firstStage = await pipeline.computeFirstScreenSnapshot(
                content: content, overrideDelimiter: overrideDelimiter,
                useFirstRowAsHeader: stage1Header, searchQuery: stage1Query, maxUTF8Bytes: maxBytes
            )
            guard !Task.isCancelled, let stage1 = firstStage else { return }
            let stage1Truncation: TTZipSpreadsheetTruncationUpdate = stage1.hasMoreRows
                ? .accumulatePartial(stage1.isTruncated)
                : .replaceFinal(stage1.isTruncated)
            let appliedStage1 = self.tableSession.applyParseOutput(
                .fromSnapshot(
                    stage1,
                    capturedHeader: stage1Header,
                    capturedQuery: stage1Query,
                    truncationUpdate: stage1Truncation,
                    autoDetectedDelimiter: overrideDelimiter == nil ? stage1.detectedDelimiter : nil
                ),
                token: token
            )
            guard appliedStage1, stage1.hasMoreRows else { return }

            let stage2Header = self.tableSession.controls.useFirstRowAsHeader
            let stage2Query = self.tableSession.controls.searchQuery
            let secondStage = await pipeline.computeFullBudgetedSnapshot(
                content: content, stage1: stage1,
                useFirstRowAsHeader: stage2Header, searchQuery: stage2Query, maxRows: maxRows, maxUTF8Bytes: maxBytes
            )
            guard !Task.isCancelled, let stage2 = secondStage else { return }
            self.tableSession.applyParseOutput(
                .fromSnapshot(
                    stage2,
                    capturedHeader: stage2Header,
                    capturedQuery: stage2Query,
                    truncationUpdate: .replaceFinal(stage2.isTruncated)
                ),
                token: token
            )
        }
    }

    private func performJumpToRow() {
        isJumpPopoverPresented = false
        guard let row = Int(jumpRowInput.trimmingCharacters(in: .whitespacesAndNewlines)), row >= 1 else { return }
        jumpRowInput = ""
        let targetIndex = row - 1
        let state = tableSession.tableState
        let pageSizeOption = tableSession.controls.pageSizeOption
        guard targetIndex < state.filteredRowCount else { return }
        let totalPages = state.totalPages(for: pageSizeOption)
        let pageSize = state.pageSize(for: pageSizeOption)
        if pageSizeOption.rawValue != -1 {
            tableSession.setCurrentPageIndex(min(targetIndex / pageSize, max(0, totalPages - 1)))
        }
        let resolvedRow = state.effectiveRowIndex(at: targetIndex, useFirstRowAsHeader: tableSession.controls.useFirstRowAsHeader)
        let resolvedCol = min(max(0, tableSession.controls.selectedCoordinate?.column ?? 0), max(0, state.maxColumnCount - 1))
        tableSession.setSelectedCoordinate(SpreadsheetCellCoordinate(row: resolvedRow, column: resolvedCol))
    }

    private func showToast(_ message: String) {
        copyToastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) { isToastVisible = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            withAnimation(.easeInOut(duration: 0.25)) { isToastVisible = false }
        }
    }

    private func copyToClipboard(_ string: String, message: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        showToast(message)
    }

    private func saveFile() {
        guard !hasStagingURL else {
            showToast(SpreadsheetPreviewLocalization.text(.saveBlockedReadOnly))
            return
        }
        let targetContent = tableSession.rawContent
        let expectedBaseline = baselineTracker.activeBaseline(hasContentOverride: false, stateBaseline: savedBaselineContent)
        do {
            guard try SpreadsheetSavePolicy.saveInPlace(
                content: targetContent, expectedBaseline: expectedBaseline, fileURL: fileURL, fileName: fileName,
                workbook: initialWorkbook, isPreviewTruncated: tableSession.isPreviewTruncated, resourceContext: resourceContext
            ) else {
                let reasonKey: SpreadsheetPreviewLocaleKey =
                    targetContent.utf8.count > TTSpreadsheetParser.maxInteractivePreviewUTF8Bytes ? .saveBlockedExceededBudget : .saveBlockedReadOnly
                showToast(SpreadsheetPreviewLocalization.text(reasonKey))
                return
            }
            baselineTracker.recordSave(targetContent)
            savedBaselineContent = targetContent
            withAnimation { isEdited = false; isSavedToastPresented = true }
            NotificationCenter.default.post(name: .ttMediaFileContentDidChange, object: fileURL, userInfo: resourceContext.toUserInfoDictionary())
            NotificationCenter.default.post(name: NSNotification.Name("TTMediaArchiveUnlockedRefreshNotification"), object: nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.0))
                withAnimation { isSavedToastPresented = false }
            }
        } catch {
            showToast(SpreadsheetPreviewLocalization.saveFailed(error.localizedDescription))
        }
    }
}
