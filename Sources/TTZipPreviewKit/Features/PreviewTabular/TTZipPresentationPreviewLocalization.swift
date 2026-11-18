// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

enum TTZipPresentationPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case slidesBadge = "media.slides.badge"
    case slidesFilterPlaceholder = "media.slides.filterPlaceholder"
    case slidesCopyOutlineButton = "media.slides.copyOutlineButton"
    case slidesEmptyOutline = "media.slides.emptyOutline"
    case slidesNoMatchFormat = "media.slides.noMatchFormat"
    case slidesCountFormat = "media.slides.countFormat"
    case slidesOutlineFooter = "media.slides.outlineFooter"
    case slideNumberFormat = "media.slides.slideNumberFormat"
    case slideCopiedSingleFormat = "media.slides.copiedSingleFormat"
    case slideCopySingleHelp = "media.slides.copySingleHelp"
    case slidesCopiedAllFormat = "media.slides.copiedAllFormat"

    func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .slidesBadge: ("SLIDES", "幻灯片", "投影片"),
        .slidesFilterPlaceholder: ("Filter slides...", "筛选幻灯片…", "篩選投影片…"),
        .slidesCopyOutlineButton: ("Copy Outline", "复制大纲", "拷貝大綱"),
        .slidesEmptyOutline: ("No slides found in presentation outline.", "演示文稿大纲中未找到幻灯片。", "簡報大綱中找不到投影片。"),
        .slidesNoMatchFormat: ("No slides match '%@'.", "没有匹配“%@”的幻灯片。", "沒有符合「%@」的投影片。"),
        .slidesCountFormat: ("%d slides", "%d 张幻灯片", "%d 張投影片"),
        .slidesOutlineFooter: ("Presentation Outline", "演示文稿大纲", "簡報大綱"),
        .slideNumberFormat: ("Slide %d", "幻灯片 %d", "投影片 %d"),
        .slideCopiedSingleFormat: ("Copied Slide %d text", "已复制幻灯片 %d 文本", "已拷貝投影片 %d 文字"),
        .slideCopySingleHelp: ("Copy slide text", "复制幻灯片文本", "拷貝投影片文字"),
        .slidesCopiedAllFormat: ("Copied all %d slide outlines", "已复制全部 %d 张幻灯片大纲", "已拷貝全部 %d 張投影片大綱"),
    ]
}

@MainActor
enum TTZipPresentationPreviewLocalization {
    static func text(_ key: TTZipPresentationPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    static func format(_ key: TTZipPresentationPreviewLocaleKey, _ args: CVarArg...) -> String {
        let template = LocalizationState.shared.t(key)
        return String(format: template, arguments: args)
    }
}
