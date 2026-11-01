// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTI18nCore
import TTI18nUI

public enum EPUBReaderWorkspaceLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case notes = "media.epub.notes"
    case selectedText = "media.epub.selectedText"
    case highlight = "media.epub.highlight"
    case saveNote = "media.epub.saveNote"
    case note = "media.epub.note"
    case locate = "media.epub.locate"
    case delete = "media.epub.delete"
    case dictionary = "media.epub.dictionary"
    case webSearch = "media.epub.webSearch"
    case exportJSON = "media.epub.exportJSON"
    case exportMarkdown = "media.epub.exportMarkdown"
    case noSelection = "media.epub.noSelection"
    case unavailable = "media.epub.unavailable"
    case cjkFont = "media.epub.cjkFont"
    case latinFont = "media.epub.latinFont"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        let values = Self.translations[self] ?? (rawKey, rawKey, rawKey)
        switch language { case .zhHans: return values.1; case .zhHant: return values.2; default: return values.0 }
    }
    private static let translations: [Self: (String, String, String)] = [
        .notes: ("Highlights & Notes", "划线与笔记", "畫線與筆記"),
        .selectedText: ("Selected Text", "选中文本", "所選文字"),
        .highlight: ("Highlight Selection", "划线选中文本", "畫線所選文字"),
        .saveNote: ("Save Note", "保存笔记", "儲存筆記"),
        .note: ("Note", "笔记", "筆記"),
        .locate: ("Go to Passage", "定位原文", "定位原文"),
        .delete: ("Delete", "删除", "刪除"),
        .dictionary: ("Look Up in Dictionary", "查询系统字典", "查詢系統辭典"),
        .webSearch: ("Search the Web", "在网页中查询", "在網頁中查詢"),
        .exportJSON: ("Export JSON", "导出 JSON", "匯出 JSON"),
        .exportMarkdown: ("Export Markdown", "导出 Markdown", "匯出 Markdown"),
        .noSelection: ("Select text in the book first.", "请先在正文中选中文字。", "請先在正文中選取文字。"),
        .unavailable: ("Reader storage is unavailable.", "阅读数据存储当前不可用。", "閱讀資料儲存目前無法使用。"),
        .cjkFont: ("Chinese Font", "中文字体", "中文字體"),
        .latinFont: ("English Font", "英文字体", "英文字體"),
    ]

}

@MainActor
public enum EPUBReaderWorkspaceLocalization {
    public static func text(_ key: EPUBReaderWorkspaceLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }
}
