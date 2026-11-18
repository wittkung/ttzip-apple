// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTI18nCore
import TTI18nUI

enum PreviewWindowActionLocaleKey: String, FallbackLocaleKeyProtocol {
    case fullScreen = "preview.full_screen"

    func fallbackTranslation(for language: AppLanguage) -> String {
        switch language {
        case .en: return "Enter Full Screen"
        case .zhHans: return "进入全屏预览"
        case .zhHant: return "進入全螢幕預覽"
        case .ja: return "フルスクリーン表示"
        case .de: return "Vollbildmodus"
        case .fr: return "Plein écran"
        case .es: return "Pantalla completa"
        }
    }
}

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
