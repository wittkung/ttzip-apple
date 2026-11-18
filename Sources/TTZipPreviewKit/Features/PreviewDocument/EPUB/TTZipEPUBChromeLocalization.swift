// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

public enum EPUBPaginationLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case pageIndicatorFormat = "ttmedia.ebook.pagination.page_indicator_format"
    case chapterAndPageIndicatorFormat = "ttmedia.ebook.pagination.chapter_and_page_format"
    case chapterPageAndProgressIndicatorFormat = "ttmedia.ebook.pagination.chapter_page_progress_format"
    case previousPageHelp = "ttmedia.ebook.pagination.previous_page_help"
    case nextPageHelp = "ttmedia.ebook.pagination.next_page_help"
    case bookStartReachedNotice = "ttmedia.ebook.pagination.book_start_reached"
    case bookEndReachedNotice = "ttmedia.ebook.pagination.book_end_reached"
    case firstScreenLatencyFormat = "ttmedia.ebook.telemetry.first_screen_latency_format"
    case layoutModePaginated = "ttmedia.ebook.pagination.layout_mode_paginated"
    case layoutModeScrolling = "ttmedia.ebook.pagination.layout_mode_scrolling"
    case layoutModeLabel = "ttmedia.ebook.pagination.layout_mode_label"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let tuple = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return tuple.zhHans
        case .zhHant: return tuple.zhHant
        default: return tuple.en
        }
    }

    private static let translations: [Self: (en: String, zhHans: String, zhHant: String)] = [
        .pageIndicatorFormat: ("Page %d / %d", "第 %d / %d 页", "第 %d / %d 頁"),
        .chapterAndPageIndicatorFormat: ("Ch %d/%d · P %d/%d", "第 %d/%d 章 · 第 %d/%d 页", "第 %d/%d 章 · 第 %d/%d 頁"),
        .chapterPageAndProgressIndicatorFormat: ("Ch %d/%d · P %d/%d · Est. %d%%", "第 %d/%d 章 · 第 %d/%d 页 · 全书估算 %d%%", "第 %d/%d 章 · 第 %d/%d 頁 · 全書估算 %d%%"),
        .previousPageHelp: ("Previous Page / Chapter (Left Arrow)", "上一页／上一章（左方向键）", "上一頁／上一章（左方向鍵）"),
        .nextPageHelp: ("Next Page / Chapter (Right Arrow)", "下一页／下一章（右方向键）", "下一頁／下一章（右方向鍵）"),
        .bookStartReachedNotice: ("Beginning of book", "已到全书首页", "已到全書首頁"),
        .bookEndReachedNotice: ("End of book", "已到全书末页", "已到全書末頁"),
        .firstScreenLatencyFormat: ("Pagination layout %.1f ms", "排版回调 %.1f ms", "排版回調 %.1f ms"),
        .layoutModePaginated: ("Paginated", "分页阅读", "分頁閱讀"),
        .layoutModeScrolling: ("Continuous", "垂直滚动", "垂直捲動"),
        .layoutModeLabel: ("Reading Layout", "阅读排版", "閱讀排版"),
    ]
}

@MainActor
public enum EPUBPaginationLocalization {
    public static func text(_ key: EPUBPaginationLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    public static func pageIndicator(pageIndex: Int, totalPages: Int) -> String {
        let clampedTotal = max(totalPages, 1)
        let clampedPage = min(max(pageIndex + 1, 1), clampedTotal)
        return String(format: text(.pageIndicatorFormat), clampedPage, clampedTotal)
    }

    public static func chapterAndPageIndicator(
        chapterIndex: Int, totalChapters: Int, pageIndex: Int, totalPages: Int
    ) -> String {
        let clampedChapters = max(totalChapters, 1)
        let clampedChapter = min(max(chapterIndex + 1, 1), clampedChapters)
        let clampedPages = max(totalPages, 1)
        let clampedPage = min(max(pageIndex + 1, 1), clampedPages)
        return String(format: text(.chapterAndPageIndicatorFormat), clampedChapter, clampedChapters, clampedPage, clampedPages)
    }

    public static func chapterPageAndProgressIndicator(
        chapterIndex: Int, totalChapters: Int, pageIndex: Int, totalPages: Int, progressRatio: Double
    ) -> String {
        let clampedChapters = max(totalChapters, 1)
        let clampedChapter = min(max(chapterIndex + 1, 1), clampedChapters)
        let clampedPages = max(totalPages, 1)
        let clampedPage = min(max(pageIndex + 1, 1), clampedPages)
        let percent = min(100, max(0, Int(round(progressRatio * 100))))
        return String(format: text(.chapterPageAndProgressIndicatorFormat), clampedChapter, clampedChapters, clampedPage, clampedPages, percent)
    }
}

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
