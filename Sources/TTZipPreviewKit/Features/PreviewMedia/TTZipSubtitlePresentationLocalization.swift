// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

/// Product-owned localized vocabulary for TTZip subtitle font picker and quick-settings presentation.
/// Untranslated languages explicitly fall back to English, matching `MediaLocaleKey`.
enum TTZipSubtitleFontLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case subtitleFont = "media.subtitleFont"
    case subtitleFontChoose = "media.subtitleFont.choose"
    case subtitleFontPickerTitle = "media.subtitleFont.pickerTitle"
    case subtitleFontSearchPlaceholder = "media.subtitleFont.searchPlaceholder"
    case subtitleFontFamilyHeader = "media.subtitleFont.familyHeader"
    case subtitleFontTypefaceHeader = "media.subtitleFont.typefaceHeader"
    case subtitleFontPreviewHeader = "media.subtitleFont.previewHeader"
    case subtitleFontPreviewPrimarySample = "media.subtitleFont.previewPrimarySample"
    case subtitleFontPreviewSecondarySample = "media.subtitleFont.previewSecondarySample"
    case subtitleFontCustomNameLabel = "media.subtitleFont.customNameLabel"
    case subtitleFontCustomNamePlaceholder = "media.subtitleFont.customNamePlaceholder"
    case subtitleFontFallbackNotice = "media.subtitleFont.fallbackNotice"
    case subtitleFontNoMatches = "media.subtitleFont.noMatches"
    case subtitleFontDone = "media.subtitleFont.done"

    func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .subtitleFont: ("Font", "字体", "字體"),
        .subtitleFontChoose: ("Choose Font…", "选择字体…", "選擇字體…"),
        .subtitleFontPickerTitle: ("Choose Subtitle Font", "选择字幕字体", "選擇字幕字體"),
        .subtitleFontSearchPlaceholder: ("Type to filter fonts…", "输入以筛选字体…", "輸入以篩選字體…"),
        .subtitleFontFamilyHeader: ("Family", "字体集", "字體集"),
        .subtitleFontTypefaceHeader: ("Typeface", "字型", "樣式"),
        .subtitleFontPreviewHeader: ("Preview (Bilingual)", "预览（中英双语）", "預覽（中英雙語）"),
        .subtitleFontPreviewPrimarySample: (
            "中文字幕预览 · Subtitle Font Preview",
            "中文字幕预览 · Subtitle Font Preview",
            "中文字幕預覽 · Subtitle Font Preview"
        ),
        .subtitleFontPreviewSecondarySample: (
            "The quick brown fox jumps over the lazy dog 0123456789",
            "天地玄黄 宇宙洪荒 · The quick brown fox 0123456789",
            "天地玄黃 宇宙洪荒 · The quick brown fox 0123456789"
        ),
        .subtitleFontCustomNameLabel: ("Font Identifier:", "字体名称：", "字體名稱："),
        .subtitleFontCustomNamePlaceholder: ("System Default", "系统默认", "系統預設"),
        .subtitleFontFallbackNotice: (
            "Font unavailable on this Mac; using System Default",
            "本机未安装该字体，已安全回退至系统默认",
            "本機未安裝該字體，已安全回退至系統預設"
        ),
        .subtitleFontNoMatches: ("No matching fonts", "无匹配字体", "無相符字體"),
        .subtitleFontDone: ("Done", "完成", "完成"),
    ]
}

/// Product-owned localization vocabulary for video-frame-relative subtitle sizing, presets,
/// and text vs. bitmap/pre-styled subtitle capability boundaries.
/// Untranslated languages explicitly fall back to English, matching `MediaLocaleKey`.
enum SubtitleRelativeSizingLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case relativeScaleTitle = "media.subtitle.relativeScale.title"
    case relativeHeightBadgeFormat = "media.subtitle.relativeScale.heightBadgeFormat"
    case presetSmall = "media.subtitle.relativeScale.preset.small"
    case presetStandard = "media.subtitle.relativeScale.preset.standard"
    case presetLarge = "media.subtitle.relativeScale.preset.large"
    case presetExtraLarge = "media.subtitle.relativeScale.preset.extraLarge"
    case capabilityTextActive = "media.subtitle.capability.textActive"
    case capabilityAssExtractedText = "media.subtitle.capability.assExtractedText"
    case capabilityBitmapNotice = "media.subtitle.capability.bitmapNotice"

    func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .relativeScaleTitle: (
            "Relative Size",
            "相对字号",
            "相對字級"
        ),
        .relativeHeightBadgeFormat: (
            "%@ · %@ of video height",
            "%@ · 画面高度 %@",
            "%@ · 畫面高度 %@"
        ),
        .presetSmall: ("0.75x", "0.75x", "0.75x"),
        .presetStandard: ("1.0x", "1.0x", "1.0x"),
        .presetLarge: ("1.25x", "1.25x", "1.25x"),
        .presetExtraLarge: ("1.5x", "1.5x", "1.5x"),
        .capabilityTextActive: (
            "Applies to text subtitles; scales proportionally with video content area.",
            "对文本字幕生效，随实际视频画面区域等比缩放。",
            "對文字字幕生效，隨實際影片畫面區域等比縮放。"
        ),
        .capabilityAssExtractedText: (
            "ASS/SSA tracks render extracted dialogue with relative sizing (vector positioning not applied).",
            "ASS/SSA 字幕按提取文本应用相对字号与字体（不执行矢量特效排版）。",
            "ASS/SSA 字幕按擷取文字套用相對字級與字體（不執行向量特效排版）。"
        ),
        .capabilityBitmapNotice: (
            "Bitmap subtitles (PGS/VobSub/DVB) use pre-rendered images; font and relative size do not alter bitmap glyphs.",
            "位图字幕（PGS/VobSub/DVB）为预渲染图像，字体与相对字号不改变位图字形。",
            "點陣圖字幕（PGS/VobSub/DVB）為預先算繪影像，字體與相對字級不改變點陣字形。"
        ),
    ]
}

/// Resolves TTZip subtitle font picker and relative-sizing vocabulary through shared `TTI18n` state.
@MainActor
enum TTZipSubtitlePresentationLocalization {
    static func text(_ key: TTZipSubtitleFontLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    static func text(_ key: SubtitleRelativeSizingLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    static func formattedRelativeHeightBadge(scaleText: String, percentText: String) -> String {
        String(
            format: text(.relativeHeightBadgeFormat),
            locale: .current,
            scaleText,
            percentText
        )
    }
}
