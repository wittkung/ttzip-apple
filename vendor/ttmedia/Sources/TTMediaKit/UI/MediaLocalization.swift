// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTI18nCore
import TTI18nUI

/// Shared localized vocabulary for synthetic System Default subtitle font catalog and fallback entries.
/// Untranslated languages explicitly fall back to English, matching `MediaLocaleKey`.
public enum SubtitleFontLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case subtitleFontSystemDefault = "media.subtitleFont.systemDefault"
    case subtitleFontSystemDefaultFace = "media.subtitleFont.systemDefaultFace"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .subtitleFontSystemDefault: ("System Default (Rounded)", "系统默认（圆体）", "系統預設（圓體）"),
        .subtitleFontSystemDefaultFace: ("Regular / Rounded", "常规／圆体", "常規／圓體"),
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
