// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTI18nCore
import TTI18nUI

final class MediaLocalizationTests: XCTestCase {
    func testEveryMediaKeyHasChineseAndEnglishFallbacks() {
        for key in MediaLocaleKey.allCases {
            for language in [AppLanguage.en, .zhHans, .zhHant] {
                let value = key.fallbackTranslation(for: language)
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, key.rawKey)
            }
            XCTAssertEqual(key.fallbackTranslation(for: .de), key.fallbackTranslation(for: .en))
        }
        XCTAssertEqual(MediaLocaleKey.loadSubtitles.fallbackTranslation(for: .zhHans), "加载外挂字幕…")
        XCTAssertEqual(MediaLocaleKey.copyPath.fallbackTranslation(for: .zhHant), "拷貝路徑")
    }

    @MainActor
    func testObservableLanguageSwitchUsesSharedMediaCatalog() {
        let state = LocalizationState.shared
        let original = state.currentLanguage
        defer { state.setLanguage(original) }
        state.setLanguage(.zhHans)
        XCTAssertEqual(state.t(MediaLocaleKey.play), "播放")
        state.setLanguage(.en)
        XCTAssertEqual(state.t(MediaLocaleKey.play), "Play")
    }
}
