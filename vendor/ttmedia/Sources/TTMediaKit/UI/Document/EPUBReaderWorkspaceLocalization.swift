// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTI18nCore
import TTI18nUI

public enum EPUBReaderWorkspaceLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case unavailable = "media.epub.unavailable"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "阅读数据存储当前不可用。"
        case .zhHant: return "閱讀資料儲存目前無法使用。"
        default: return "Reader storage is unavailable."
        }
    }
}

@MainActor
public enum EPUBReaderWorkspaceLocalization {
    public static func text(_ key: EPUBReaderWorkspaceLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }
}
