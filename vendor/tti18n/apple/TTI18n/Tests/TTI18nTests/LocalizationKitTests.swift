// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTI18nCore
import TTI18nIPC
import TTI18nUI
#if canImport(AppKit)
import TTI18nAppKit
#endif

enum MockLocaleKey: String, LocaleKeyProtocol {
    case cancel = "common.cancel"
    case ok = "common.ok"
}

final class LocalizationKitTests: XCTestCase {
    func testLanguageEnumParsing() {
        XCTAssertEqual(AppLanguage.from(identifier: "zh-Hans-CN"), .zhHans)
        XCTAssertEqual(AppLanguage.from(identifier: "zh-Hant-TW"), .zhHant)
        XCTAssertEqual(AppLanguage.from(identifier: "de-DE"), .de)
        XCTAssertEqual(AppLanguage.from(identifier: "en-US"), .en)
        XCTAssertEqual(AppLanguage.from(identifier: "ja-JP"), .ja)
        XCTAssertEqual(AppLanguage.from(identifier: "fr-FR"), .fr)
        XCTAssertEqual(AppLanguage.from(identifier: "es-ES"), .es)
    }
    
    func testLocalizationManagerFallback() {
        let manager = TTLocalizationManager.shared
        manager.currentLanguage = .en
        
        manager.registerLookupHandler { key, lang in
            if key == "common.ok" && lang == .zhHans {
                return "好"
            } else if key == "common.ok" && lang == .en {
                return "OK"
            }
            return ""
        }
        
        XCTAssertEqual(manager.string(for: MockLocaleKey.ok, language: .zhHans), "好")
        XCTAssertEqual(manager.string(for: MockLocaleKey.ok, language: .en), "OK")
    }

    @MainActor
    func testLocalizationStateAndAliases() {
        let state = LocalizationState.shared
        let appState: AppLocalizationState = state
        XCTAssertNotNil(appState)
        let resolved = state.t(MockLocaleKey.ok)
        XCTAssertFalse(resolved.isEmpty)
    }

    func testGeneratedLocaleKeyEnum() {
        XCTAssertEqual(L10n.Inspector.title.rawKey, "inspector.title")
        XCTAssertEqual(L10n.Common.calculating.rawKey, "common.calculating")
        XCTAssertEqual(L10n.Units.filesAndDirectories.rawKey, "units.files_and_directories")
        XCTAssertEqual(L10n.Inspector.allCases.count, 41)
    }

    #if canImport(AppKit)
    @MainActor
    func testAppKitMenuSynchronizerRegistration() {
        let synchronizer = AppKitMenuSynchronizer.shared
        synchronizer.registerTag(1001, key: MockLocaleKey.ok)
        synchronizer.registerSelector(#selector(NSApplication.terminate(_:)), key: MockLocaleKey.cancel)
    }
    #endif
}
