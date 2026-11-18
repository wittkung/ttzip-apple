// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
#if canImport(TTI18nCore)
import TTI18nCore
#endif

/// Strongly-typed localization keys for the standalone video playback window and browser-player handoff (W1 — Feedback ②).
public enum PlaybackWindowLocaleKey: String, TTZipCore.LocaleKeyProtocol, CaseIterable, Sendable {
    case returnToOriginPreview = "playback.window.return_to_origin_preview"
    case returnToOriginPreviewHelp = "playback.window.return_to_origin_preview.help"
    case openInStandalonePlayer = "playback.window.open_in_standalone_player"
    case playingInStandaloneWindowTitle = "playback.window.playing_in_standalone.title"
    case playingInStandaloneWindowSubtitle = "playback.window.playing_in_standalone.subtitle"
    case focusStandaloneWindowButton = "playback.window.focus_standalone_window"

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
        .returnToOriginPreview: (
            "Return to Preview",
            "返回原预览",
            "返回原預覽"
        ),
        .returnToOriginPreviewHelp: (
            "Close standalone player window and continue playback in the browser inspector",
            "关闭独立播放器窗口并在原浏览窗口侧栏继续预览",
            "關閉獨立播放器視窗並在原瀏覽視窗側欄繼續預覽"
        ),
        .openInStandalonePlayer: (
            "Open in Standalone Player",
            "在独立播放器中打开",
            "在獨立播放器中打開"
        ),
        .playingInStandaloneWindowTitle: (
            "Playing in Standalone Player Window",
            "正在独立播放器窗口中播放",
            "正在獨立播放器視窗中播放"
        ),
        .playingInStandaloneWindowSubtitle: (
            "This video is active in an independent window so you can continue browsing files freely.",
            "当前视频已在独立播放器窗口中打开，您可以继续在此浏览文件。",
            "目前影片已在獨立播放器視窗中打開，您可以繼續在此瀏覽檔案。"
        ),
        .focusStandaloneWindowButton: (
            "Focus Player Window",
            "聚焦播放器窗口",
            "聚焦播放器視窗"
        )
    ]
}

#if canImport(TTI18nCore)
extension PlaybackWindowLocaleKey: FallbackLocaleKeyProtocol {
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
