// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
#if canImport(TTI18nCore)
import TTI18nCore
import TTI18nUI
#endif

/// Strongly-typed localization keys for multi-window browsing, menus, and window routing (W1).
public enum MultiWindowLocaleKey: String, TTZipCore.LocaleKeyProtocol, CaseIterable, Sendable {
    case newWindow = "menu.new_window"
    case newWindowDock = "menu.dock.new_window"
    case newSmartFolder = "menu.dock.new_smart_folder"
    case findInWindow = "menu.dock.find"
    case goToFolder = "menu.dock.go_to_folder"
    case connectToServer = "menu.dock.connect_to_server"
    case favoriteLocationsHeader = "menu.dock.favorites_header"
    case recentItemsHeader = "menu.dock.recent_items_header"
    case smartFoldersHeader = "menu.dock.smart_folders_header"
    case clearRecentItems = "menu.dock.clear_recent_items"
    case openInNewWindow = "sidebar.open_in_new_window"
    case newArchiveMenu = "menu.new_archive_menu"

    public var rawKey: String { rawValue }

    @MainActor
    public func localized(for language: TTZipCore.AppLanguage? = nil) -> String {
        let lang = language ?? AppLocalizationState.shared.currentLanguage
        return translation(for: lang)
    }

    public func translation(for language: TTZipCore.AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawValue }
        switch language {
        case .zhHans:
            return values.zh
        case .zhHant:
            return values.hant
        default:
            return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .newWindow: (
            "New Window",
            "新建窗口",
            "新增視窗"
        ),
        .newWindowDock: (
            "New TTZip Window",
            "新建 TTZip 窗口",
            "新增 TTZip 視窗"
        ),
        .newSmartFolder: (
            "New Smart Folder…",
            "新建智能文件夹…",
            "新增智慧型檔案夾…"
        ),
        .findInWindow: (
            "Find…",
            "查找…",
            "尋找…"
        ),
        .goToFolder: (
            "Go to Folder…",
            "前往文件夹…",
            "前往檔案夾…"
        ),
        .connectToServer: (
            "Connect to Server…",
            "连接服务器…",
            "連接伺服器…"
        ),
        .favoriteLocationsHeader: (
            "Favorites",
            "个人收藏",
            "喜好項目"
        ),
        .recentItemsHeader: (
            "Recent Items",
            "最近使用",
            "最近使用項目"
        ),
        .smartFoldersHeader: (
            "Smart Folders",
            "智能文件夹",
            "智慧型檔案夾"
        ),
        .clearRecentItems: (
            "Clear Recents",
            "清除最近使用",
            "清除最近記錄"
        ),
        .openInNewWindow: (
            "Open in New Window",
            "在新窗口中打开",
            "在新視窗中打開"
        ),
        .newArchiveMenu: (
            "New Archive...",
            "新建压缩包...",
            "新增壓縮檔..."
        )
    ]
}

#if canImport(TTI18nCore)
extension MultiWindowLocaleKey: FallbackLocaleKeyProtocol {
    public func fallbackTranslation(for language: TTI18nCore.AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawValue }
        switch language {
        case .zhHans:
            return values.zh
        case .zhHant:
            return values.hant
        default:
            return values.en
        }
    }
}
#endif
