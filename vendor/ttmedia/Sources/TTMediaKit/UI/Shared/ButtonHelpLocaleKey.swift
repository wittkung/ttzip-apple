// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTI18nCore
import TTI18nUI

public enum TTButtonHelpLocaleKey: String, FallbackLocaleKeyProtocol, Sendable {
    case clearSearch = "media.buttonHelp.clearSearch"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "清空搜索"
        case .zhHant: return "清除搜尋"
        default: return "Clear Search"
        }
    }
}

@MainActor
public enum TTButtonHelpLocalization {
    public static func text(_ key: TTButtonHelpLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }
}
