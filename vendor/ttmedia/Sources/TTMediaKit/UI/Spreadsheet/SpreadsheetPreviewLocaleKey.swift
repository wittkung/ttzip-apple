// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

/// Localized vocabulary for spreadsheet preview controls, read-only states, in-place save actions,
/// copy actions, row jumping, statistics, pagination, and failure feedback.
public enum SpreadsheetPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case defaultDocumentTitle = "media.spreadsheet.defaultDocumentTitle"
    case defaultSheetTitle = "media.spreadsheet.defaultSheetTitle"
    case readOnlyBadge = "media.spreadsheet.readOnlyBadge"
    case previewCappedReadOnly = "media.spreadsheet.previewCappedReadOnly"
    case unsavedBadge = "media.spreadsheet.unsavedBadge"
    case saveButton = "media.spreadsheet.saveButton"
    case savedBadge = "media.spreadsheet.savedBadge"
    case saveHelp = "media.spreadsheet.saveHelp"
    case saveBlockedReadOnly = "media.spreadsheet.saveBlockedReadOnly"
    case saveBlockedExceededBudget = "media.spreadsheet.saveBlockedExceededBudget"
    case saveFailedFormat = "media.spreadsheet.saveFailedFormat"
    case sheetLoadFailedFormat = "media.spreadsheet.sheetLoadFailedFormat"
    case truncatedStatusFormat = "media.spreadsheet.truncatedStatusFormat"
    case modeTable = "media.spreadsheet.modeTable"
    case modeSource = "media.spreadsheet.modeSource"
    case filterCellsPlaceholder = "media.spreadsheet.filterCellsPlaceholder"
    case headerRowOne = "media.spreadsheet.headerRowOne"
    case headerAlphabetical = "media.spreadsheet.headerAlphabetical"
    case toggleHeaderHelp = "media.spreadsheet.toggleHeaderHelp"
    case delimiterComma = "media.spreadsheet.delimiterComma"
    case delimiterTab = "media.spreadsheet.delimiterTab"
    case delimiterSemicolon = "media.spreadsheet.delimiterSemicolon"
    case delimiterPipe = "media.spreadsheet.delimiterPipe"
    case copyButton = "media.spreadsheet.copyButton"
    case copySelectedCellFormat = "media.spreadsheet.copySelectedCellFormat"
    case copiedCellFormat = "media.spreadsheet.copiedCellFormat"
    case copyTableAsCSV = "media.spreadsheet.copyTableAsCSV"
    case copiedTableAsCSV = "media.spreadsheet.copiedTableAsCSV"
    case copyTableAsTSV = "media.spreadsheet.copyTableAsTSV"
    case copiedTableAsTSV = "media.spreadsheet.copiedTableAsTSV"
    case copyTableAsMarkdown = "media.spreadsheet.copyTableAsMarkdown"
    case copiedTableAsMarkdown = "media.spreadsheet.copiedTableAsMarkdown"
    case noCellSelected = "media.spreadsheet.noCellSelected"
    case copiedCellContentFormat = "media.spreadsheet.copiedCellContentFormat"
    case copyCellTextHelp = "media.spreadsheet.copyCellTextHelp"
    case inspectCellPrompt = "media.spreadsheet.inspectCellPrompt"
    case filteredRowStatusFormat = "media.spreadsheet.filteredRowStatusFormat"
    case rowCountFormat = "media.spreadsheet.rowCountFormat"
    case columnCountFormat = "media.spreadsheet.columnCountFormat"
    case cellCountFormat = "media.spreadsheet.cellCountFormat"
    case jumpButton = "media.spreadsheet.jumpButton"
    case jumpToRowTitle = "media.spreadsheet.jumpToRowTitle"
    case jumpRowRangeFormat = "media.spreadsheet.jumpRowRangeFormat"
    case jumpRowPlaceholder = "media.spreadsheet.jumpRowPlaceholder"
    case jumpGoButton = "media.spreadsheet.jumpGoButton"
    case pageSizeRowsFormat = "media.spreadsheet.pageSizeRowsFormat"
    case pageSizeAllRows = "media.spreadsheet.pageSizeAllRows"
    case pageSizeMenuFormat = "media.spreadsheet.pageSizeMenuFormat"
    case firstPageHelp = "media.spreadsheet.firstPageHelp"
    case previousPageHelp = "media.spreadsheet.previousPageHelp"
    case pageIndicatorAccessibilityFormat = "media.spreadsheet.pageIndicatorAccessibilityFormat"
    case nextPageHelp = "media.spreadsheet.nextPageHelp"
    case lastPageHelp = "media.spreadsheet.lastPageHelp"
    case emptyTableTitle = "media.spreadsheet.emptyTableTitle"
    case emptyTableDescription = "media.spreadsheet.emptyTableDescription"
    case tableSettingsMenu = "media.spreadsheet.tableSettingsMenu"
    case searchToggleHelp = "media.spreadsheet.searchToggleHelp"
    case delimiterSectionTitle = "media.spreadsheet.delimiterSectionTitle"
    case headerSectionTitle = "media.spreadsheet.headerSectionTitle"
    case viewFullCellHelp = "media.spreadsheet.viewFullCellHelp"
    case cellDetailTitleFormat = "media.spreadsheet.cellDetailTitleFormat"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .defaultDocumentTitle: ("Spreadsheet Document", "电子表格文档", "試算表文件"),
        .defaultSheetTitle: ("Sheet", "工作表", "工作表"),
        .readOnlyBadge: ("Read-Only", "只读", "唯讀"),
        .previewCappedReadOnly: ("Preview Capped (Read-Only)", "预览已截断（只读）", "預覽已截斷（唯讀）"),
        .unsavedBadge: ("Unsaved", "未保存", "未儲存"),
        .saveButton: ("Save", "保存", "儲存"),
        .savedBadge: ("Saved", "已保存", "已儲存"),
        .saveHelp: ("Save changes (⌘S)", "保存更改 (⌘S)", "儲存變更 (⌘S)"),
        .saveBlockedReadOnly: (
            "Read-only preview cannot overwrite the original file.",
            "只读预览不允许覆盖原始文件。",
            "唯讀預覽不允許覆寫原始檔案。"
        ),
        .saveBlockedExceededBudget: (
            "Content exceeds interactive preview budget and cannot be saved in place.",
            "内容超出交互预览上限，无法原位保存。",
            "內容超出互動預覽上限，無法原位儲存。"
        ),
        .saveFailedFormat: ("Failed to save: %@", "保存失败：%@", "儲存失敗：%@"),
        .sheetLoadFailedFormat: ("Failed to load sheet: %@", "加载工作表失败：%@", "載入工作表失敗：%@"),
        .truncatedStatusFormat: ("Truncated to %d rows / 16 MB", "已截断至 %d 行 / 16 MB", "已截斷至 %d 列 / 16 MB"),
        .modeTable: ("Grid Table", "表格视图", "表格檢視"),
        .modeSource: ("Raw Source", "原始源码", "原始源碼"),
        .filterCellsPlaceholder: ("Filter cells...", "筛选单元格...", "篩選儲存格..."),
        .headerRowOne: ("Header: Row 1", "表头：第 1 行", "表頭：第 1 列"),
        .headerAlphabetical: ("Header: A, B, C", "表头：A, B, C", "表頭：A, B, C"),
        .toggleHeaderHelp: ("Toggle header rows", "切换首行作为表头", "切換首列作為表頭"),
        .delimiterComma: ("Comma (,)", "逗号 (,)", "逗號 (,)"),
        .delimiterTab: ("Tab (\\t)", "制表符 (\\t)", "定位字元 (\\t)"),
        .delimiterSemicolon: ("Semicolon (;)", "分号 (;)", "分號 (;)"),
        .delimiterPipe: ("Pipe (|)", "竖线 (|)", "直線 (|)"),
        .copyButton: ("Copy", "复制", "複製"),
        .copySelectedCellFormat: ("Copy Selected Cell (%@)", "复制选中单元格 (%@)", "複製選取儲存格 (%@)"),
        .copiedCellFormat: ("Copied cell %@", "已复制单元格 %@", "已複製儲存格 %@"),
        .copyTableAsCSV: ("Copy Full Table as CSV (,)", "复制整表为 CSV (,)", "複製整表為 CSV (,)"),
        .copiedTableAsCSV: ("Copied entire table as CSV (,)", "已复制整表为 CSV (,)", "已複製整表為 CSV (,)"),
        .copyTableAsTSV: ("Copy Full Table as TSV (Tab / Excel)", "复制整表为 TSV (Tab / Excel)", "複製整表為 TSV (Tab / Excel)"),
        .copiedTableAsTSV: ("Copied entire table as TSV (Excel)", "已复制整表为 TSV (Excel)", "已複製整表為 TSV (Excel)"),
        .copyTableAsMarkdown: ("Copy Full Table as Markdown", "复制整表为 Markdown", "複製整表為 Markdown"),
        .copiedTableAsMarkdown: ("Copied entire table as Markdown", "已复制整表为 Markdown", "已複製整表為 Markdown"),
        .noCellSelected: ("None", "无", "無"),
        .copiedCellContentFormat: ("Copied cell %@ content", "已复制单元格 %@ 内容", "已複製儲存格 %@ 內容"),
        .copyCellTextHelp: ("Copy cell text", "复制单元格文本", "複製儲存格文字"),
        .inspectCellPrompt: (
            "Click any cell to inspect or copy full contents",
            "点击任意单元格以查看或复制完整内容",
            "點選任意儲存格以檢視或複製完整內容"
        ),
        .filteredRowStatusFormat: ("Filtered: %d/%d", "已筛选：%d/%d", "已篩選：%d/%d"),
        .rowCountFormat: ("%d rows", "%d 行", "%d 列"),
        .columnCountFormat: ("%d cols", "%d 列", "%d 欄"),
        .cellCountFormat: ("%d cells", "%d 单元格", "%d 儲存格"),
        .jumpButton: ("Jump", "跳转", "跳轉"),
        .jumpToRowTitle: ("Jump to Row", "跳转到行", "跳轉至列"),
        .jumpRowRangeFormat: ("Row index (1–%d):", "行号范围 (1–%d)：", "列號範圍 (1–%d)："),
        .jumpRowPlaceholder: ("Row #", "行号", "列號"),
        .jumpGoButton: ("Go", "前往", "前往"),
        .pageSizeRowsFormat: ("%d rows", "%d 行/页", "%d 列/頁"),
        .pageSizeAllRows: ("All rows (No Pagination)", "全部行（不分页）", "全部列（不分頁）"),
        .pageSizeMenuFormat: ("Page: %@", "每页：%@", "每頁：%@"),
        .firstPageHelp: ("First Page", "第一页", "第一頁"),
        .previousPageHelp: ("Previous Page", "上一页", "上一頁"),
        .pageIndicatorAccessibilityFormat: ("Page %d of %d", "第 %d 页，共 %d 页", "第 %d 頁，共 %d 頁"),
        .nextPageHelp: ("Next Page", "下一页", "下一頁"),
        .lastPageHelp: ("Last Page", "最后一页", "最後一頁"),
        .emptyTableTitle: ("No Table Data", "无表格数据", "無表格資料"),
        .emptyTableDescription: (
            "This spreadsheet contains no rows or columns to display.",
            "此电子表格不包含可显示的行或列。",
            "此試算表不包含可顯示的列或欄。"
        ),
        .tableSettingsMenu: ("Table Options", "表格选项", "表格選項"),
        .searchToggleHelp: ("Toggle cell filter", "展开或收起单元格筛选", "展開或收起儲存格篩選"),
        .delimiterSectionTitle: ("Delimiter", "分隔符", "分隔符"),
        .headerSectionTitle: ("Header Mode", "表头模式", "表頭模式"),
        .viewFullCellHelp: ("Inspect full cell content", "查看完整单元格内容", "檢視完整儲存格內容"),
        .cellDetailTitleFormat: ("Cell %@", "单元格 %@", "儲存格 %@"),
    ]
}

/// Resolves spreadsheet preview vocabulary through the shared observable `TTI18n` localization state.
@MainActor
public enum SpreadsheetPreviewLocalization {
    public static func text(_ key: SpreadsheetPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    public static func saveFailed(_ reason: String) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.saveFailedFormat, reason)
    }

    public static func sheetLoadFailed(_ sheetName: String) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.sheetLoadFailedFormat, sheetName)
    }

    public static func truncatedStatus(maxRows: Int) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.truncatedStatusFormat, maxRows)
    }

    public static func copySelectedCell(_ cellRef: String) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.copySelectedCellFormat, cellRef)
    }

    public static func copiedCell(_ cellRef: String) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.copiedCellFormat, cellRef)
    }

    public static func copiedCellContent(_ cellRef: String) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.copiedCellContentFormat, cellRef)
    }

    public static func filteredRowStatus(filtered: Int, total: Int) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.filteredRowStatusFormat, filtered, total)
    }

    public static func rowCount(_ count: Int) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.rowCountFormat, count)
    }

    public static func columnCount(_ count: Int) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.columnCountFormat, count)
    }

    public static func cellCount(_ count: Int) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.cellCountFormat, count)
    }

    public static func jumpRowRange(maxRow: Int) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.jumpRowRangeFormat, maxRow)
    }

    public static func pageSizeRows(_ count: Int) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.pageSizeRowsFormat, count)
    }

    public static func pageSizeMenu(_ optionLabel: String) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.pageSizeMenuFormat, optionLabel)
    }

    public static func pageIndicatorAccessibility(current: Int, total: Int) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.pageIndicatorAccessibilityFormat, current, total)
    }

    public static func cellDetailTitle(_ cellRef: String) -> String {
        LocalizationState.shared.format(SpreadsheetPreviewLocaleKey.cellDetailTitleFormat, cellRef)
    }
}

// MARK: - F4 Resource Context & Edit Capability Bridge for SpreadsheetSavePolicy

public extension TTPreviewReadOnlyReason {
    nonisolated static var derivedRepresentation: TTPreviewReadOnlyReason { .derivedContent }
    nonisolated static var previewTruncated: TTPreviewReadOnlyReason { .truncatedPreview }
    nonisolated static var missingFileURL: TTPreviewReadOnlyReason { .unknownOrigin }
    nonisolated static var ephemeralStagingPath: TTPreviewReadOnlyReason { .managedStagingCachePath }
    nonisolated static var unsupportedExtension: TTPreviewReadOnlyReason { .unsupportedInPlaceFormat }
    nonisolated static var fileSystemReadOnly: TTPreviewReadOnlyReason { .unwritableDiskFile }
}

public extension TTPreviewEditCapability {
    nonisolated static func readOnly(_ reason: TTPreviewReadOnlyReason) -> TTPreviewEditCapability {
        .readOnly(reason: reason)
    }

    nonisolated static func editableInPlace(targetURL: URL) -> TTPreviewEditCapability {
        .editableInPlace(targetFileURL: targetURL)
    }

    nonisolated var isEditableInPlace: Bool {
        if case .editableInPlace = self {
            return true
        }
        return false
    }

    nonisolated var writableTargetURL: URL? {
        if case .editableInPlace(let targetFileURL) = self {
            return targetFileURL
        }
        return nil
    }
}

public extension TTPreviewResourceContext {
    nonisolated func effectiveEditCapability(
        isTruncated: Bool = false,
        isDerived: Bool = false,
        allowedExtensions: Set<String>? = nil
    ) -> TTPreviewEditCapability {
        if isPreviewTruncated || isTruncated {
            return .readOnly(reason: .truncatedPreview)
        }
        if isDerivedRepresentation || isDerived {
            return .readOnly(reason: .derivedContent)
        }
        if let targetURL = validateInPlaceSaveTarget(
            allowedExtensions: allowedExtensions,
            isTruncated: isTruncated,
            isDerived: isDerived
        ) {
            return .editableInPlace(targetFileURL: targetURL)
        }
        if case .editableInPlace = editCapability, allowedExtensions != nil {
            return .readOnly(reason: .unsupportedInPlaceFormat)
        }
        return editCapability
    }
}

