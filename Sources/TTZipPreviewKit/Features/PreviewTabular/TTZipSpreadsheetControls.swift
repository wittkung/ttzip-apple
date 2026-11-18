// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit
import TTZipUI

// MARK: - Responsive Layout Metrics & State Probe

enum TTZipSpreadsheetWidthTier: String, Equatable, Sendable {
    case narrow
    case regular
    case medium
    case wide
}

struct TTZipSpreadsheetLayoutMetrics: Equatable, Sendable {
    let tier: TTZipSpreadsheetWidthTier

    init(width: CGFloat) {
        if width < 380 {
            self.tier = .narrow
        } else if width < 500 {
            self.tier = .regular
        } else if width < 680 {
            self.tier = .medium
        } else {
            self.tier = .wide
        }
    }

    var showsDocumentTitle: Bool { tier == .wide }
    var showsInlineSearchField: Bool { tier == .medium || tier == .wide }
    var showsInlineHeaderAndDelimiterControls: Bool { tier == .wide }
    var showsInlineJumpAndPageSize: Bool { tier == .wide }
    var showsExtendedBottomStats: Bool { tier != .narrow }
    var searchFieldWidth: CGFloat { tier == .wide ? 136 : 84 }
}

final class TTZipSpreadsheetPreviewStateProbeNSView: NSView {
    var canSaveInPlace = false
    var selectedSheetName = ""
    var selectedCellContent: String?
    var searchQuery = ""
    var useFirstRowAsHeader = false
    var selectCell: (@MainActor (SpreadsheetCellCoordinate) -> Void)?
    var selectSheet: (@MainActor (String) -> Void)?
    var toggleHeader: (@MainActor () -> Void)?
    var selectMode: (@MainActor (SpreadsheetPreviewMode) -> Void)?
    var selectDelimiter: (@MainActor (TTSpreadsheetDelimiter) -> Void)?
}

struct TTZipSpreadsheetPreviewStateProbeRepresentable: NSViewRepresentable {
    let canSaveInPlace: Bool
    let selectedSheetName: String
    let selectedCellContent: String?
    let searchQuery: String
    let useFirstRowAsHeader: Bool
    let selectCell: @MainActor (SpreadsheetCellCoordinate) -> Void
    let selectSheet: @MainActor (String) -> Void
    let toggleHeader: @MainActor () -> Void
    let selectMode: @MainActor (SpreadsheetPreviewMode) -> Void
    let selectDelimiter: @MainActor (TTSpreadsheetDelimiter) -> Void

    func makeNSView(context: Context) -> TTZipSpreadsheetPreviewStateProbeNSView {
        TTZipSpreadsheetPreviewStateProbeNSView(frame: .zero)
    }

    func updateNSView(_ view: TTZipSpreadsheetPreviewStateProbeNSView, context: Context) {
        view.canSaveInPlace = canSaveInPlace
        view.selectedSheetName = selectedSheetName
        view.selectedCellContent = selectedCellContent
        view.searchQuery = searchQuery
        view.useFirstRowAsHeader = useFirstRowAsHeader
        view.selectCell = selectCell
        view.selectSheet = selectSheet
        view.toggleHeader = toggleHeader
        view.selectMode = selectMode
        view.selectDelimiter = selectDelimiter
    }
}

enum TTZipSpreadsheetPopupMenuEntry {
    case sectionHeader(String)
    case separator
    case action(title: String, isChecked: Bool = false, handler: @MainActor () -> Void)
}

@MainActor
final class TTZipSpreadsheetPopupMenuInvoker: NSObject {
    static let shared = TTZipSpreadsheetPopupMenuInvoker()
    private var handlers: [Int: @MainActor () -> Void] = [:]

    func present(_ entries: [TTZipSpreadsheetPopupMenuEntry]) {
        handlers.removeAll()
        let menu = NSMenu()
        var nextTag = 1
        for entry in entries {
            switch entry {
            case .sectionHeader(let title):
                menu.addItem(.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case .action(let title, let isChecked, let handler):
                let item = NSMenuItem(title: title, action: #selector(handleMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = nextTag
                item.state = isChecked ? .on : .off
                handlers[nextTag] = handler
                nextTag += 1
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        handlers[sender.tag]?()
        handlers.removeAll()
    }
}

// MARK: - Auxiliary Spreadsheet Preview Subviews

struct TTZipSpreadsheetCellDetailPopoverView: View {
    let coordinateReference: String
    let cellValue: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(SpreadsheetPreviewLocalization.cellDetailTitle(coordinateReference))
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                Spacer()
                Button(action: onCopy) {
                    Label(SpreadsheetPreviewLocalization.text(.copyButton), systemImage: "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(cellValue)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 240, maxWidth: 360, minHeight: 72, maxHeight: 220)
        }
        .padding(10)
    }
}

struct TTZipSpreadsheetJumpRowPopoverView: View {
    let maxRow: Int
    @Binding var jumpRowInput: String
    let onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SpreadsheetPreviewLocalization.text(.jumpToRowTitle))
                .font(.system(size: 11.5, weight: .bold))
            Text(SpreadsheetPreviewLocalization.jumpRowRange(maxRow: maxRow))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(SpreadsheetPreviewLocalization.text(.jumpRowPlaceholder), text: $jumpRowInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit(onJump)
                Button(SpreadsheetPreviewLocalization.text(.jumpGoButton), action: onJump)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 200)
    }
}

struct TTZipSpreadsheetPaginationControlsView: View {
    @Binding var currentPageIndex: Int
    let totalPages: Int

    var body: some View {
        HStack(spacing: 2) {
            pageButton(icon: "backward.end.fill", size: 8.5, disabled: currentPageIndex <= 0, label: SpreadsheetPreviewLocalization.text(.firstPageHelp)) {
                currentPageIndex = 0
            }
            pageButton(icon: "chevron.left", size: 9.5, weight: .bold, disabled: currentPageIndex <= 0, label: SpreadsheetPreviewLocalization.text(.previousPageHelp)) {
                if currentPageIndex > 0 { currentPageIndex -= 1 }
            }
            Text("\(currentPageIndex + 1) / \(totalPages)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .accessibilityLabel(SpreadsheetPreviewLocalization.pageIndicatorAccessibility(current: currentPageIndex + 1, total: totalPages))
            pageButton(icon: "chevron.right", size: 9.5, weight: .bold, disabled: currentPageIndex >= totalPages - 1, label: SpreadsheetPreviewLocalization.text(.nextPageHelp)) {
                if currentPageIndex < totalPages - 1 { currentPageIndex += 1 }
            }
            pageButton(icon: "forward.end.fill", size: 8.5, disabled: currentPageIndex >= totalPages - 1, label: SpreadsheetPreviewLocalization.text(.lastPageHelp)) {
                currentPageIndex = max(0, totalPages - 1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 3)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pageButton(icon: String, size: CGFloat, weight: Font.Weight = .regular, disabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: weight))
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct TTZipSpreadsheetCellInspectorBarView: View {
    let selectedCoordinate: SpreadsheetCellCoordinate?
    let selectedCellContent: String?
    @Binding var isCellDetailPopoverPresented: Bool
    let onCopyCell: (SpreadsheetCellCoordinate, String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "target").font(.system(size: 9)).foregroundStyle(TTZipTheme.accentColor)
                Text(selectedCoordinate?.excelReference ?? SpreadsheetPreviewLocalization.text(.noCellSelected))
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(selectedCoordinate != nil ? TTZipTheme.accentColor : .secondary)
            }
            .frame(minWidth: 52, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)

            Divider().frame(height: 14)

            if let cellVal = selectedCellContent {
                let singleLinePreview = cellVal
                    .replacingOccurrences(of: "\r\n", with: " ↵ ")
                    .replacingOccurrences(of: "\n", with: " ↵ ")
                    .replacingOccurrences(of: "\r", with: " ↵ ")
                Text(singleLinePreview)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail).help(cellVal)
                Spacer(minLength: 4)
                Button(action: { isCellDetailPopoverPresented.toggle() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).help(SpreadsheetPreviewLocalization.text(.viewFullCellHelp))
                .popover(isPresented: $isCellDetailPopoverPresented, arrowEdge: .bottom) {
                    TTZipSpreadsheetCellDetailPopoverView(
                        coordinateReference: selectedCoordinate?.excelReference ?? "",
                        cellValue: cellVal,
                        onCopy: {
                            if let c = selectedCoordinate { onCopyCell(c, cellVal) }
                        }
                    )
                }
                Button(action: {
                    if let c = selectedCoordinate { onCopyCell(c, cellVal) }
                }) {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).help(SpreadsheetPreviewLocalization.text(.copyCellTextHelp))
            } else {
                Text(SpreadsheetPreviewLocalization.text(.inspectCellPrompt))
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.tail).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4).frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

struct TTZipSpreadsheetBottomStatusBarView: View {
    let metrics: TTZipSpreadsheetLayoutMetrics
    let tableState: SpreadsheetTableState
    let fileSizeString: String
    let isPreviewTruncated: Bool
    let maxPreviewRows: Int
    @Binding var pageSizeOption: SpreadsheetPageSizeOption
    @Binding var currentPageIndex: Int
    @Binding var isJumpPopoverPresented: Bool
    @Binding var jumpRowInput: String
    let onJump: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if tableState.isFiltered {
                    Text(SpreadsheetPreviewLocalization.filteredRowStatus(filtered: tableState.filteredRowCount, total: tableState.effectiveRowCount))
                        .foregroundStyle(TTZipTheme.accentColor)
                } else {
                    Text(SpreadsheetPreviewLocalization.rowCount(tableState.effectiveRowCount))
                }
                Text("•")
                Text(SpreadsheetPreviewLocalization.columnCount(tableState.maxColumnCount))
                if metrics.showsExtendedBottomStats {
                    Text("•")
                    Text(SpreadsheetPreviewLocalization.cellCount(tableState.totalCellCount))
                    Text("•")
                    Text(fileSizeString)
                }
                if isPreviewTruncated {
                    Text("•")
                    Text(SpreadsheetPreviewLocalization.truncatedStatus(maxRows: maxPreviewRows)).foregroundStyle(Color.orange)
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if metrics.showsInlineJumpAndPageSize {
                jumpButton
                pageSizeButton
            }
            if pageSizeOption.rawValue != -1 && tableState.totalPages(for: pageSizeOption) > 1 {
                TTZipSpreadsheetPaginationControlsView(currentPageIndex: $currentPageIndex, totalPages: tableState.totalPages(for: pageSizeOption))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var jumpButton: some View {
        Button(action: { isJumpPopoverPresented.toggle() }) {
            Label(SpreadsheetPreviewLocalization.text(.jumpButton), systemImage: "arrow.right.to.line.compact")
                .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 6).frame(height: 24)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .popover(isPresented: $isJumpPopoverPresented, arrowEdge: .bottom) {
            TTZipSpreadsheetJumpRowPopoverView(maxRow: tableState.effectiveRowCount, jumpRowInput: $jumpRowInput, onJump: onJump)
        }
    }

    private var pageSizeButton: some View {
        Button(action: {
            let entries = SpreadsheetPageSizeOption.allCases.map { opt in
                TTZipSpreadsheetPopupMenuEntry.action(title: opt.localizedDisplayName, isChecked: pageSizeOption == opt) {
                    pageSizeOption = opt
                    currentPageIndex = 0
                }
            }
            TTZipSpreadsheetPopupMenuInvoker.shared.present(entries)
        }) {
            Label(SpreadsheetPreviewLocalization.pageSizeMenu(pageSizeOption.localizedDisplayName), systemImage: "slider.horizontal.3")
                .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 6).frame(height: 24)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
    }
}

struct TTZipSpreadsheetExpandableSearchRowView: View {
    @Binding var searchQuery: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.secondary)
            TextField(SpreadsheetPreviewLocalization.text(.filterCellsPlaceholder), text: $searchQuery)
                .textFieldStyle(.plain).font(.system(size: 11)).frame(maxWidth: .infinity)
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.65))
    }
}

struct TTZipSpreadsheetToastOverlayView: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity)).padding(.bottom, 16)
        }
    }
}

struct TTZipSpreadsheetFormatBadgeView: View {
    let badgeTitle: String

    init(badgeTitle: String) {
        self.badgeTitle = badgeTitle
    }

    init(isWorkbook: Bool, delimiterShortName: String) {
        self.badgeTitle = isWorkbook ? "XLSX" : delimiterShortName
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tablecells.fill")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(TTZipTheme.accentColor)
            Text(badgeTitle)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(TTZipTheme.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct TTZipSpreadsheetStatusBadgeView: View {
    let metrics: TTZipSpreadsheetLayoutMetrics
    let isPreviewTruncated: Bool
    let canSaveInPlace: Bool
    let isEdited: Bool

    private var isCompactIconTier: Bool {
        metrics.tier == .narrow || metrics.tier == .regular
    }

    var body: some View {
        if isPreviewTruncated {
            let label = metrics.tier == .wide
                ? SpreadsheetPreviewLocalization.text(.previewCappedReadOnly)
                : SpreadsheetPreviewLocalization.text(.readOnlyBadge)
            if isCompactIconTier {
                compactIconPill(icon: "exclamationmark.triangle.fill", helpText: label, foreground: .orange, background: Color.orange.opacity(0.12))
            } else {
                badgePill(text: label, foreground: .orange, background: Color.orange.opacity(0.12))
            }
        } else if !canSaveInPlace {
            let label = SpreadsheetPreviewLocalization.text(.readOnlyBadge)
            if isCompactIconTier {
                compactIconPill(icon: "lock.fill", helpText: label, foreground: .secondary, background: Color.primary.opacity(0.08))
            } else {
                badgePill(text: label, foreground: .secondary, background: Color.primary.opacity(0.08))
            }
        } else if isEdited {
            let label = SpreadsheetPreviewLocalization.text(.unsavedBadge)
            if isCompactIconTier {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .help(label)
            } else {
                badgePill(text: label, foreground: .orange, background: Color.orange.opacity(0.12))
            }
        }
    }

    private func compactIconPill(icon: String, helpText: String, foreground: Color, background: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 22, height: 22)
            .background(background)
            .clipShape(Circle())
            .fixedSize(horizontal: true, vertical: false)
            .help(helpText)
    }

    private func badgePill(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(background)
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct TTZipSpreadsheetModePickerView: View {
    let metrics: TTZipSpreadsheetLayoutMetrics
    @Binding var mode: SpreadsheetPreviewMode
    let onSelectMode: (SpreadsheetPreviewMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SpreadsheetPreviewMode.allCases) { item in
                Button(action: { onSelectMode(item) }) {
                    Group {
                        if metrics.tier == .narrow {
                            Image(systemName: item.icon)
                                .frame(width: 26, height: 22)
                        } else if metrics.tier == .wide {
                            Label(item.localizedTitle, systemImage: item.icon)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                        } else {
                            Text(item.localizedTitle)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                        }
                    }
                    .font(.system(size: 10.5, weight: mode == item ? .bold : .medium))
                    .lineLimit(1)
                    .background(mode == item ? TTZipTheme.accentColor : Color.clear)
                    .foregroundStyle(mode == item ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help(item.localizedTitle)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }
}
