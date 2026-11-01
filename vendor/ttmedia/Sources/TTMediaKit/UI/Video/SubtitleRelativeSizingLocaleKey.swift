// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTI18nCore
import TTI18nUI

/// Independent S1 localization vocabulary for video-frame-relative subtitle sizing, presets,
/// and text vs. bitmap/pre-styled subtitle capability boundaries.
/// Untranslated languages explicitly fall back to English, matching `MediaLocaleKey`.
public enum SubtitleRelativeSizingLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case relativeScaleTitle = "media.subtitle.relativeScale.title"
    case relativeHeightBadgeFormat = "media.subtitle.relativeScale.heightBadgeFormat"
    case presetSmall = "media.subtitle.relativeScale.preset.small"
    case presetStandard = "media.subtitle.relativeScale.preset.standard"
    case presetLarge = "media.subtitle.relativeScale.preset.large"
    case presetExtraLarge = "media.subtitle.relativeScale.preset.extraLarge"
    case capabilityTextActive = "media.subtitle.capability.textActive"
    case capabilityAssExtractedText = "media.subtitle.capability.assExtractedText"
    case capabilityBitmapNotice = "media.subtitle.capability.bitmapNotice"

    public func fallbackTranslation(for language: AppLanguage) -> String {
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

extension MediaLocalization {
    @MainActor
    public static func text(_ key: SubtitleRelativeSizingLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    @MainActor
    public static func formattedRelativeHeightBadge(scaleText: String, percentText: String) -> String {
        String(
            format: text(.relativeHeightBadgeFormat),
            locale: .current,
            scaleText,
            percentText
        )
    }
}
