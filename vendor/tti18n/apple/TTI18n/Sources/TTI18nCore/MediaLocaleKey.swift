// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Keys with a built-in catalog can resolve without a host lookup handler.
public protocol FallbackLocaleKeyProtocol: LocaleKeyProtocol {
    func fallbackTranslation(for language: AppLanguage) -> String
}

/// Shared media vocabulary; untranslated languages explicitly fall back to English.
public enum MediaLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable {
    case off = "media.off"
    case loadSubtitles = "media.loadSubtitles"
    case turnOffSubtitles = "media.turnOffSubtitles"
    case subtitleHelp = "media.subtitleHelp"
    case subtitles = "media.subtitles"
    case fullscreen = "media.fullscreen"
    case exitFullscreen = "media.exitFullscreen"
    case seekBack = "media.seekBack"
    case seekForward = "media.seekForward"
    case pause = "media.pause"
    case play = "media.play"
    case remainingTime = "media.remainingTime"
    case volumeMute = "media.volumeMute"
    case playbackSpeed = "media.playbackSpeed"
    case pip = "media.pip"
    case volume = "media.volume"
    case loadingMedia = "media.loadingMedia"
    case playbackFailed = "media.playbackFailed"
    case retry = "media.retry"
    case loadingSubtitles = "media.loadingSubtitles"
    case subtitleFailed = "media.subtitleFailed"
    case ok = "media.ok"
    case previousHelp = "media.previousHelp"
    case previous = "media.previous"
    case previousHint = "media.previousHint"
    case nextHelp = "media.nextHelp"
    case next = "media.next"
    case nextHint = "media.nextHint"
    case copied = "media.copied"
    case copyPath = "media.copyPath"
    case copyPathHelp = "media.copyPathHelp"
    case copyPathLabel = "media.copyPathLabel"
    case dismissHelp = "media.dismissHelp"
    case close = "media.close"
    case escapeHint = "media.escapeHint"
    case finderHelp = "media.finderHelp"
    case finder = "media.finder"
    case subtitleTrack = "media.subtitleTrack"
    case secondarySubtitle = "media.secondarySubtitle"
    case subtitleStyle = "media.subtitleStyle"
    case subtitleFontSize = "media.subtitleFontSize"
    case subtitleScale = "media.subtitleScale"
    case subtitlePosition = "media.subtitlePosition"
    case subtitleDelay = "media.subtitleDelay"
    case subtitleColor = "media.subtitleColor"
    case subtitleBorder = "media.subtitleBorder"
    case subtitleBackground = "media.subtitleBackground"
    case subtitleBold = "media.subtitleBold"
    case subtitleItalic = "media.subtitleItalic"
    case subtitleReset = "media.subtitleReset"
    case colorWhite = "media.colorWhite"
    case colorYellow = "media.colorYellow"
    case colorCyan = "media.colorCyan"
    case colorGreen = "media.colorGreen"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .off: ("Off", "关闭", "關閉"),
        .loadSubtitles: ("Load External Subtitles…", "加载外挂字幕…", "載入外掛字幕…"),
        .turnOffSubtitles: ("Turn Off Subtitles", "关闭字幕", "關閉字幕"),
        .subtitleHelp: ("Subtitles & Style Settings", "字幕与样式设置", "字幕與樣式設定"),
        .subtitles: ("Subtitles", "字幕", "字幕"),
        .fullscreen: ("Fullscreen", "全窗口播放", "全視窗播放"),
        .exitFullscreen: ("Exit Fullscreen", "退出全窗口", "退出全視窗"),
        .seekBack: ("Seek backward 10s", "后退 10 秒", "後退 10 秒"),
        .seekForward: ("Seek forward 10s", "前进 10 秒", "前進 10 秒"),
        .pause: ("Pause", "暂停", "暫停"),
        .play: ("Play", "播放", "播放"),
        .remainingTime: ("Click to toggle remaining time", "点击切换剩余时间", "點按切換剩餘時間"),
        .volumeMute: ("Volume & Mute", "音量与静音", "音量與靜音"),
        .playbackSpeed: ("Playback Speed", "播放速度", "播放速度"),
        .pip: ("Picture in Picture", "画中画", "子母畫面"),
        .volume: ("Volume", "音量", "音量"),
        .loadingMedia: ("Loading media…", "正在加载媒体…", "正在載入媒體…"),
        .playbackFailed: ("Unable to play media", "无法播放媒体", "無法播放媒體"),
        .retry: ("Retry", "重试", "重試"),
        .loadingSubtitles: ("Loading subtitles…", "正在加载字幕…", "正在載入字幕…"),
        .subtitleFailed: ("Unable to load subtitles", "无法加载字幕", "無法載入字幕"),
        .ok: ("OK", "好", "好"),
        .previousHelp: ("Previous media (Left arrow)", "上一个媒体（左方向键）", "上一個媒體（向左鍵）"),
        .previous: ("Previous media", "上一个媒体", "上一個媒體"),
        .previousHint: ("Keyboard shortcut: Left Arrow", "快捷键：左方向键", "快速鍵：向左鍵"),
        .nextHelp: ("Next media (Right arrow)", "下一个媒体（右方向键）", "下一個媒體（向右鍵）"),
        .next: ("Next media", "下一个媒体", "下一個媒體"),
        .nextHint: ("Keyboard shortcut: Right Arrow", "快捷键：右方向键", "快速鍵：向右鍵"),
        .copied: ("Copied", "已复制", "已拷貝"),
        .copyPath: ("Copy Path", "复制路径", "拷貝路徑"),
        .copyPathHelp: ("Copy full path to clipboard", "复制完整路径到剪贴板", "拷貝完整路徑到剪貼簿"),
        .copyPathLabel: ("Copy File Path", "复制文件路径", "拷貝檔案路徑"),
        .dismissHelp: ("Dismiss (Esc)", "关闭（Esc）", "關閉（Esc）"),
        .close: ("Close", "关闭", "關閉"),
        .escapeHint: ("Keyboard shortcut: Escape", "快捷键：Escape", "快速鍵：Escape"),
        .finderHelp: ("Reveal in Finder (⌘R)", "在访达中显示（⌘R）", "在 Finder 中顯示（⌘R）"),
        .finder: ("Reveal in Finder", "在访达中显示", "在 Finder 中顯示"),
        .subtitleTrack: ("Primary Subtitle", "主字幕", "主字幕"),
        .secondarySubtitle: ("Secondary Subtitle", "副字幕（双语）", "副字幕（雙語）"),
        .subtitleStyle: ("Subtitle Style & Timing…", "字幕样式与同步…", "字幕樣式與同步…"),
        .subtitleFontSize: ("Font Size", "字号", "字級"),
        .subtitleScale: ("Scale", "缩放倍率", "縮放倍率"),
        .subtitlePosition: ("Position", "垂直位置", "垂直位置"),
        .subtitleDelay: ("Delay", "时间延迟", "時間延遲"),
        .subtitleColor: ("Text Color", "文字颜色", "文字顏色"),
        .subtitleBorder: ("Outline", "描边宽度", "描邊寬度"),
        .subtitleBackground: ("Background", "背景底框", "背景底框"),
        .subtitleBold: ("Bold", "粗体", "粗體"),
        .subtitleItalic: ("Italic", "斜体", "斜體"),
        .subtitleReset: ("Reset Default", "恢复默认", "恢復預設"),
        .colorWhite: ("White", "纯白", "純白"),
        .colorYellow: ("Yellow", "明黄", "明黃"),
        .colorCyan: ("Cyan", "青色", "青色"),
        .colorGreen: ("Green", "柔绿", "柔綠"),
    ]
}
