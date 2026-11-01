// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import SwiftUI
import TTI18nCore
import TTI18nUI

// MARK: - EPUB Reading Layout Mode

public enum EPUBReadingLayoutMode: String, Sendable, CaseIterable {
    case paginated = "paginated"
    case scrolling = "scrolling"
}

/// Resolves the persisted reading-layout preference without ever inventing a new default.
///
/// The product contract is: a first launch (no stored value) or an unparsable legacy value
/// falls back to horizontal auto-pagination, while an explicit `scrolling` preference chosen by
/// the user must survive relaunches.
public enum EPUBReadingLayoutPreference {
    public static let defaultMode: EPUBReadingLayoutMode = .paginated

    public static func resolve(stored: String?) -> EPUBReadingLayoutMode {
        guard let stored, !stored.isEmpty,
              let mode = EPUBReadingLayoutMode(rawValue: stored) else {
            return defaultMode
        }
        return mode
    }
}

// MARK: - Standalone TTI18n Locale Key Table for EPUB Pagination & Telemetry (Group C)

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

// MARK: - EPUB Reading Direction, Boundary Landing & Stage Telemetry

public enum EPUBReadingDirection: String, Sendable, Equatable {
    case leftToRight = "ltr"
    case rightToLeft = "rtl"
    case verticalRightToLeft = "vertical-rl"

    public func isForwardStep(forRightArrow isRightArrow: Bool) -> Bool {
        switch self {
        case .leftToRight:
            return isRightArrow
        case .rightToLeft, .verticalRightToLeft:
            return !isRightArrow
        }
    }
}

public enum EPUBBoundaryLanding: Sendable, Equatable {
    case firstPage
    case lastPage
    case preserveAnchor(progressRatio: Double, anchorBlockIndex: Int?, anchorCharOffset: Int = 0)
    case fragment(String)
}

public enum EPUBBookBoundaryNotice: String, Sendable, Equatable {
    case none
    case bookStart
    case bookEnd
}

public enum EPUBPageTurnStepOutcome: Sendable, Equatable {
    case turnedPageInChapter(chapterIndex: Int, pageIndex: Int, totalPages: Int)
    case transitionedChapter(fromChapter: Int, toChapter: Int, landing: EPUBBoundaryLanding)
    case clampedAtBookStart(chapterIndex: Int, pageIndex: Int)
    case clampedAtBookEnd(chapterIndex: Int, pageIndex: Int, totalPages: Int)
    /// The page count of the current chapter is still a placeholder: layout has not been measured yet.
    /// The step has been queued and will be drained in order once the WebKit pagination snapshot arrives.
    case deferredUntilPaginationReady
}

/// Records the chapter-loading stage durations up to the WebKit JavaScript multi-column pagination callback.
public struct EPUBFirstScreenPerfMetrics: Sendable, Equatable {
    public let chapterURL: URL
    public let isVFSSource: Bool
    public let chapterReadMs: Double
    public let resourceAuthAndInlineMs: Double
    public let webKitLoadToFinishMs: Double
    public let firstPaginationLayoutCallbackMs: Double
    public let totalToPaginationCallbackMs: Double
    public let inlinedResourceCount: Int
    public let authenticatedCacheHitCount: Int
    public let initialPageCount: Int

    public var firstPaginationAndPaintMs: Double {
        firstPaginationLayoutCallbackMs
    }

    public var totalFirstScreenMs: Double {
        totalToPaginationCallbackMs
    }

    public init(
        chapterURL: URL,
        isVFSSource: Bool,
        chapterReadMs: Double,
        resourceAuthAndInlineMs: Double,
        webKitLoadToFinishMs: Double,
        firstPaginationLayoutCallbackMs: Double,
        totalToPaginationCallbackMs: Double,
        inlinedResourceCount: Int,
        authenticatedCacheHitCount: Int,
        initialPageCount: Int
    ) {
        self.chapterURL = chapterURL
        self.isVFSSource = isVFSSource
        self.chapterReadMs = chapterReadMs
        self.resourceAuthAndInlineMs = resourceAuthAndInlineMs
        self.webKitLoadToFinishMs = webKitLoadToFinishMs
        self.firstPaginationLayoutCallbackMs = firstPaginationLayoutCallbackMs
        self.totalToPaginationCallbackMs = totalToPaginationCallbackMs
        self.inlinedResourceCount = inlinedResourceCount
        self.authenticatedCacheHitCount = authenticatedCacheHitCount
        self.initialPageCount = initialPageCount
    }

    public init(
        chapterURL: URL,
        isVFSSource: Bool,
        chapterReadMs: Double,
        resourceAuthAndInlineMs: Double,
        webKitLoadToFinishMs: Double,
        firstPaginationAndPaintMs: Double,
        totalFirstScreenMs: Double,
        inlinedResourceCount: Int,
        authenticatedCacheHitCount: Int,
        initialPageCount: Int
    ) {
        self.init(
            chapterURL: chapterURL,
            isVFSSource: isVFSSource,
            chapterReadMs: chapterReadMs,
            resourceAuthAndInlineMs: resourceAuthAndInlineMs,
            webKitLoadToFinishMs: webKitLoadToFinishMs,
            firstPaginationLayoutCallbackMs: firstPaginationAndPaintMs,
            totalToPaginationCallbackMs: totalFirstScreenMs,
            inlinedResourceCount: inlinedResourceCount,
            authenticatedCacheHitCount: authenticatedCacheHitCount,
            initialPageCount: initialPageCount
        )
    }
}

// MARK: - Keyboard Contracts & Query Types

public enum TTPreviewKeyboardContractVersion: String, Sendable {
    case v1 = "1.0.0"
    case v2 = "2.0.0"
}

public enum TTPreviewFocusSource: String, Sendable, Equatable {
    case none
    case readingArea
    case toolbarOrPopover
}

public enum TTPreviewKeyboardDisposition: String, Sendable, Equatable {
    case passThrough
    case consumedByPreviewOwner
    case yieldToTextInput
}

public struct TTPreviewKeyboardOwnershipQuery: Sendable, Equatable {
    public let contractVersion: TTPreviewKeyboardContractVersion
    public let ownsHorizontalArrowKeys: Bool
    public let ownsVerticalArrowKeys: Bool
    public let isTextInputActive: Bool
    public let isEventAlreadyHandled: Bool
    public let focusSource: TTPreviewFocusSource
    public let ownerInstanceID: UUID?
    public let windowNumber: Int?

    public init(
        contractVersion: TTPreviewKeyboardContractVersion = .v2,
        ownsHorizontalArrowKeys: Bool,
        ownsVerticalArrowKeys: Bool = false,
        isTextInputActive: Bool,
        isEventAlreadyHandled: Bool,
        focusSource: TTPreviewFocusSource = .none,
        ownerInstanceID: UUID?,
        windowNumber: Int?
    ) {
        self.contractVersion = contractVersion
        self.ownsHorizontalArrowKeys = ownsHorizontalArrowKeys
        self.ownsVerticalArrowKeys = ownsVerticalArrowKeys
        self.isTextInputActive = isTextInputActive
        self.isEventAlreadyHandled = isEventAlreadyHandled
        self.focusSource = focusSource
        self.ownerInstanceID = ownerInstanceID
        self.windowNumber = windowNumber
    }
}
