// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI
import TTMediaKit

enum TTZipPDFPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case layoutSinglePage = "media.pdf.layoutSinglePage"
    case layoutTwoPages = "media.pdf.layoutTwoPages"
    case layoutThreePages = "media.pdf.layoutThreePages"
    case loadingStream = "media.pdf.loadingStream"
    case loadingPDF = "media.pdf.loadingPDF"
    case loadFailedTitle = "media.pdf.loadFailedTitle"
    case retry = "media.pdf.retry"
    case encryptedTitle = "media.pdf.encryptedTitle"
    case encryptedPrompt = "media.pdf.encryptedPrompt"
    case enterPassword = "media.pdf.enterPassword"
    case unlock = "media.pdf.unlock"
    case emptyPages = "media.pdf.emptyPages"
    case pageNumberFormat = "media.pdf.pageNumberFormat"
    case pageIndicatorFormat = "media.pdf.pageIndicatorFormat"
    case zoomIn = "media.pdf.zoomIn"
    case zoomOut = "media.pdf.zoomOut"
    case zoomFit = "media.pdf.zoomFit"
    case previousPage = "media.pdf.previousPage"
    case nextPage = "media.pdf.nextPage"

    func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .layoutSinglePage: ("Single Page", "单页", "單頁"),
        .layoutTwoPages: ("Two Pages", "双页", "雙頁"),
        .layoutThreePages: ("Three Pages", "三页", "三頁"),
        .loadingStream: ("Loading PDF Stream…", "正在加载 PDF 文档…", "正在載入 PDF 文件…"),
        .loadingPDF: ("Loading PDF…", "正在加载 PDF…", "正在載入 PDF…"),
        .loadFailedTitle: ("Unable to load PDF document", "无法加载 PDF 文档", "無法載入 PDF 文件"),
        .retry: ("Retry", "重试", "重試"),
        .encryptedTitle: ("Encrypted PDF Document", "加密的 PDF 文档", "加密的 PDF 文件"),
        .encryptedPrompt: (
            "This document is password protected. Enter password to view contents.",
            "此文档受密码保护，请输入密码以查看内容。",
            "此文件受密碼保護，請輸入密碼以檢視內容。"
        ),
        .enterPassword: ("Enter Password", "输入密码", "輸入密碼"),
        .unlock: ("Unlock", "解锁", "解鎖"),
        .emptyPages: ("PDF Document has no pages or is empty.", "PDF 文档没有页面或内容为空。", "PDF 文件沒有頁面或內容為空。"),
        .pageNumberFormat: ("Page %d", "第 %d 页", "第 %d 頁"),
        .pageIndicatorFormat: ("%d / %d", "%d / %d", "%d / %d"),
        .zoomIn: ("Zoom In", "放大", "放大"),
        .zoomOut: ("Zoom Out", "縮小", "縮小"),
        .zoomFit: ("Fit", "适应", "適應"),
        .previousPage: ("Previous Page", "上一页", "上一頁"),
        .nextPage: ("Next Page", "下一页", "下一頁"),
    ]
}

@MainActor
enum TTZipPDFPreviewLocalization {
    static func text(_ key: TTZipPDFPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    static func pageTitle(_ pageNumber: Int) -> String {
        LocalizationState.shared.format(TTZipPDFPreviewLocaleKey.pageNumberFormat, pageNumber)
    }

    static func pageIndicator(currentOneBased: Int, total: Int) -> String {
        LocalizationState.shared.format(
            TTZipPDFPreviewLocaleKey.pageIndicatorFormat,
            max(1, currentOneBased),
            max(1, total)
        )
    }
}

extension PDFLayoutMode {
    var icon: String {
        switch self {
        case .singleFullWidth: return "doc.text.fill"
        case .twoPages: return "book.fill"
        case .threePages: return "square.grid.3x1.fill"
        }
    }

    @MainActor
    var localizedTitle: String {
        switch self {
        case .singleFullWidth: return TTZipPDFPreviewLocalization.text(.layoutSinglePage)
        case .twoPages: return TTZipPDFPreviewLocalization.text(.layoutTwoPages)
        case .threePages: return TTZipPDFPreviewLocalization.text(.layoutThreePages)
        }
    }
}
