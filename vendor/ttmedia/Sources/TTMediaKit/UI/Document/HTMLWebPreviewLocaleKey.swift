// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

// MARK: - HTML & SVG Preview TTI18n Vocabulary

public enum HTMLWebPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case modeRendered = "media.html.modeRendered"
    case modeSourceCode = "media.html.modeSourceCode"
    case formatVectorSVG = "media.html.formatVectorSVG"
    case formatWebRich = "media.html.formatWebRich"
    case webDocumentFallback = "media.html.webDocumentFallback"
    case linesUnit = "media.html.linesUnit"
    case charsUnit = "media.html.charsUnit"
    case refreshHelp = "media.html.refreshHelp"
    case openInBrowserHelp = "media.html.openInBrowserHelp"
    case copySourceHelp = "media.html.copySourceHelp"
    case copiedToClipboard = "media.html.copiedToClipboard"
    case zoomOutHelp = "media.html.zoomOutHelp"
    case zoomInHelp = "media.html.zoomInHelp"
    case zoomResetHelp = "media.html.zoomResetHelp"
    case moreActionsHelp = "media.html.moreActionsHelp"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .modeRendered: ("Rendered", "渲染视图", "渲染視圖"),
        .modeSourceCode: ("Source Code", "源代码", "原始碼"),
        .formatVectorSVG: ("SVG Vector", "SVG 矢量图", "SVG 向量圖"),
        .formatWebRich: ("Web Preview", "网页预览", "網頁預覽"),
        .webDocumentFallback: ("Web Document", "网页文档", "網頁文件"),
        .linesUnit: ("lines", "行", "行"),
        .charsUnit: ("chars", "字符", "字元"),
        .refreshHelp: ("Refresh Preview", "刷新预览", "重新整理預覽"),
        .openInBrowserHelp: ("Open in Default Application", "在默认应用中打开", "在預設應用程式中打開"),
        .copySourceHelp: ("Copy HTML/SVG Source", "复制 HTML/SVG 源码", "複製 HTML/SVG 原始碼"),
        .copiedToClipboard: ("Copied", "已复制", "已複製"),
        .zoomOutHelp: ("Zoom Out", "缩小", "縮小"),
        .zoomInHelp: ("Zoom In", "放大", "放大"),
        .zoomResetHelp: ("Reset Zoom (100%)", "重置缩放 (100%)", "重置縮放 (100%)"),
        .moreActionsHelp: ("More Preview Actions", "更多预览操作", "更多預覽操作"),
    ]
}

@MainActor
public enum HTMLWebPreviewLocalization {
    public static func text(_ key: HTMLWebPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }
}
