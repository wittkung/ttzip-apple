// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTI18nCore
import TTI18nUI

/// Supplemental localized vocabulary for subtitle font selection, preview, and fallback states.
/// Untranslated languages explicitly fall back to English, matching `MediaLocaleKey`.
public enum SubtitleFontLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case subtitleFont = "media.subtitleFont"
    case subtitleFontSystemDefault = "media.subtitleFont.systemDefault"
    case subtitleFontSystemDefaultFace = "media.subtitleFont.systemDefaultFace"
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

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .subtitleFont: ("Font", "字体", "字體"),
        .subtitleFontSystemDefault: ("System Default (Rounded)", "系统默认（圆体）", "系統預設（圓體）"),
        .subtitleFontSystemDefaultFace: ("Regular / Rounded", "常规／圆体", "常規／圓體"),
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

/// Resolves media vocabulary through the shared observable language state.
@MainActor
public enum MediaLocalization {
    public static func text(_ key: MediaLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    public static func text(_ key: SubtitleFontLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }
}
