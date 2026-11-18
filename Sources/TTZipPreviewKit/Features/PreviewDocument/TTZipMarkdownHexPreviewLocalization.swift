// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

enum TTZipMarkdownHexPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case markdownModeRich = "media.markdown.modeRich"
    case markdownModeSource = "media.markdown.modeSource"
    case lineCountFormat = "media.markdown.lineCountFormat"
    case wordCountFormat = "media.markdown.wordCountFormat"
    case charCountFormat = "media.markdown.charCountFormat"
    case copyRawMarkdownHelp = "media.markdown.copyRawMarkdownHelp"
    case copyCodeButton = "media.richdoc.copyCodeButton"
    case copiedCodeButton = "media.richdoc.copiedCodeButton"

    case hexDefaultTitle = "media.hex.defaultTitle"
    case hexViewerBadge = "media.hex.viewerBadge"
    case hexViewerCompactBadge = "media.hex.viewerCompactBadge"
    case hexColumnOffset = "media.hex.columnOffset"
    case hexColumnDecodedText = "media.hex.columnDecodedText"
    case hexPageSizeLinesFormat = "media.hex.pageSizeLinesFormat"
    case hexPageSizeMenuFormat = "media.hex.pageSizeMenuFormat"
    case hexPageSizeCompactFormat = "media.hex.pageSizeCompactFormat"
    case hexCopyHexBytesMenu = "media.hex.copyHexBytesMenu"
    case hexCopyContinuousHexMenu = "media.hex.copyContinuousHexMenu"
    case hexCopyASCIIMenu = "media.hex.copyASCIIMenu"
    case hexCopyCArrayMenu = "media.hex.copyCArrayMenu"
    case hexCopyFullDumpMenu = "media.hex.copyFullDumpMenu"
    case hexCopiedBytesFormat = "media.hex.copiedBytesFormat"
    case hexCopiedContinuous = "media.hex.copiedContinuous"
    case hexCopiedASCII = "media.hex.copiedASCII"
    case hexCopiedCArray = "media.hex.copiedCArray"
    case hexCopiedFullDump = "media.hex.copiedFullDump"
    case hexJumpToOffsetTitle = "media.hex.jumpToOffsetTitle"
    case hexJumpToOffsetPrompt = "media.hex.jumpToOffsetPrompt"
    case hexJumpConfirmButton = "media.hex.jumpConfirmButton"
    case hexJumpTriggerButton = "media.hex.jumpTriggerButton"
    case hexPageOfTotalFormat = "media.hex.pageOfTotalFormat"
    case hexRangeLabel = "media.hex.rangeLabel"

    func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .markdownModeRich: ("Rich Preview", "富文本预览", "富文字預覽"),
        .markdownModeSource: ("Source Code", "源代码", "原始碼"),
        .lineCountFormat: ("%d lines", "%d 行", "%d 行"),
        .wordCountFormat: ("%d words", "%d 词", "%d 詞"),
        .charCountFormat: ("%d chars", "%d 字符", "%d 字元"),
        .copyRawMarkdownHelp: ("Copy Raw Markdown", "复制 Markdown 源码", "拷貝 Markdown 原始碼"),
        .copyCodeButton: ("Copy", "复制", "拷貝"),
        .copiedCodeButton: ("Copied", "已复制", "已拷貝"),
        .hexDefaultTitle: ("Binary Data", "二进制数据", "二進位資料"),
        .hexViewerBadge: ("HEX VIEWER", "十六进制视图", "十六進位檢視"),
        .hexViewerCompactBadge: ("HEX", "十六进制", "十六進位"),
        .hexColumnOffset: ("Offset (h)", "偏移量 (h)", "位移量 (h)"),
        .hexColumnDecodedText: ("Decoded Text", "解码文本", "解碼文字"),
        .hexPageSizeLinesFormat: ("%d KB (%d lines)", "%d KB（%d 行）", "%d KB（%d 行）"),
        .hexPageSizeMenuFormat: ("Page: %d KB", "每页：%d KB", "每頁：%d KB"),
        .hexPageSizeCompactFormat: ("%dK", "%dK", "%dK"),
        .hexCopyHexBytesMenu: ("Copy Hex Bytes (Space Separated)", "复制十六进制字节（空格分隔）", "拷貝十六進位位元組（空格分隔）"),
        .hexCopyContinuousHexMenu: ("Copy Continuous Hex String", "复制连续十六进制字符串", "拷貝連續十六進位字串"),
        .hexCopyASCIIMenu: ("Copy Decoded ASCII Text", "复制解码 ASCII 文本", "拷貝解碼 ASCII 文字"),
        .hexCopyCArrayMenu: ("Copy as C Array (0x...)", "复制为 C 数组 (0x...)", "拷貝為 C 陣列 (0x...)"),
        .hexCopyFullDumpMenu: ("Copy Full Formatted Dump Table", "复制完整格式化转储表", "拷貝完整格式化傾印表"),
        .hexCopiedBytesFormat: ("Copied %d Hex bytes to clipboard", "已复制 %d 个十六进制字节到剪贴板", "已拷貝 %d 個十六進位位元組至剪貼簿"),
        .hexCopiedContinuous: ("Copied continuous Hex string", "已复制连续十六进制字符串", "已拷貝連續十六進位字串"),
        .hexCopiedASCII: ("Copied ASCII decoded text", "已复制 ASCII 解码文本", "已拷貝 ASCII 解碼文字"),
        .hexCopiedCArray: ("Copied as C array structure", "已复制为 C 数组结构", "已拷貝為 C 陣列結構"),
        .hexCopiedFullDump: ("Copied formatted hex dump table", "已复制格式化十六进制转储表", "已拷貝格式化十六進位傾印表"),
        .hexJumpToOffsetTitle: ("Jump to Offset", "跳转到偏移量", "跳轉至位移量"),
        .hexJumpToOffsetPrompt: (
            "Enter hex (e.g. 0x1000 or 1A0) or decimal byte offset:",
            "输入十六进制（如 0x1000 或 1A0）或十进制字节偏移量：",
            "輸入十六進位（如 0x1000 或 1A0）或十進位位元組位移量："
        ),
        .hexJumpConfirmButton: ("Jump", "跳转", "跳轉"),
        .hexJumpTriggerButton: ("Jump (0x...)", "跳转 (0x...)", "跳轉 (0x...)"),
        .hexPageOfTotalFormat: ("Page %d of %d", "第 %d / %d 页", "第 %d / %d 頁"),
        .hexRangeLabel: ("Range:", "范围：", "範圍："),
    ]
}

@MainActor
enum TTZipMarkdownHexPreviewLocalization {
    static func text(_ key: TTZipMarkdownHexPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    static func format(_ key: TTZipMarkdownHexPreviewLocaleKey, _ args: CVarArg...) -> String {
        let template = LocalizationState.shared.t(key)
        return String(format: template, arguments: args)
    }

    static func lineCount(_ count: Int) -> String {
        format(.lineCountFormat, count)
    }

    static func wordCount(_ count: Int) -> String {
        format(.wordCountFormat, count)
    }

    static func charCount(_ count: Int) -> String {
        format(.charCountFormat, count)
    }
}
