// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

/// Localized vocabulary for code syntax headers, 2 MB truncation read-only protection,
/// Markdown preview toolbars, rich document blocks, and preview container states.
public enum TextAndDocumentPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case truncationBannerFormat = "media.text.truncationBannerFormat"
    case encodingReadOnlyBannerFormat = "media.text.encodingReadOnlyBannerFormat"
    case archiveReadOnlyBanner = "media.text.archiveReadOnlyBanner"
    case readOnlyBadge = "media.text.readOnlyBadge"
    case plainTextLabel = "media.text.plainTextLabel"
    case fileSizeAndLinesFormat = "media.text.fileSizeAndLinesFormat"
    case unsavedBadge = "media.text.unsavedBadge"
    case savedBadge = "media.text.savedBadge"
    case hideLineNumbersHelp = "media.text.hideLineNumbersHelp"
    case showLineNumbersHelp = "media.text.showLineNumbersHelp"
    case copiedToClipboardHelp = "media.text.copiedToClipboardHelp"
    case copySourceCodeHelp = "media.text.copySourceCodeHelp"
    case saveButton = "media.text.saveButton"
    case saveWithShortcutFormat = "media.text.saveWithShortcutFormat"
    case saveChangesHelpFormat = "media.text.saveChangesHelpFormat"
    case markdownDefaultTitle = "media.markdown.defaultTitle"
    case markdownModeRich = "media.markdown.modeRich"
    case markdownModeSource = "media.markdown.modeSource"
    case lineCountFormat = "media.markdown.lineCountFormat"
    case wordCountFormat = "media.markdown.wordCountFormat"
    case charCountFormat = "media.markdown.charCountFormat"
    case copyRawMarkdownHelp = "media.markdown.copyRawMarkdownHelp"
    case toggleFullscreenPreviewHelp = "media.markdown.toggleFullscreenPreviewHelp"
    case copyCodeButton = "media.richdoc.copyCodeButton"
    case copiedCodeButton = "media.richdoc.copiedCodeButton"
    case loadingPreview = "media.container.loadingPreview"
    case selectFileToPreview = "media.container.selectFileToPreview"
    case emptyFileFormat = "media.container.emptyFileFormat"
    case archiveContainerLoadedMessage = "media.container.archiveContainerLoadedMessage"
    case permissionDeniedFormat = "media.container.permissionDeniedFormat"
    case toggleFullscreenOrDoubleClickHelp = "media.container.toggleFullscreenOrDoubleClickHelp"

    // MARK: - Hex Preview Keys
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

    // MARK: - Presentation Outline Preview Keys
    case slidesBadge = "media.slides.badge"
    case slidesFilterPlaceholder = "media.slides.filterPlaceholder"
    case slidesCopyOutlineButton = "media.slides.copyOutlineButton"
    case slidesEmptyOutline = "media.slides.emptyOutline"
    case slidesNoMatchFormat = "media.slides.noMatchFormat"
    case slidesCountFormat = "media.slides.countFormat"
    case slidesOutlineFooter = "media.slides.outlineFooter"
    case slideNumberFormat = "media.slides.slideNumberFormat"
    case slideCopiedSingleFormat = "media.slides.copiedSingleFormat"
    case slideCopySingleHelp = "media.slides.copySingleHelp"
    case slidesCopiedAllFormat = "media.slides.copiedAllFormat"

    // MARK: - Shared HTML & EPUB Keys (Delivered for Group C)
    case htmlDefaultTitle = "media.html.defaultTitle"
    case htmlModeRendered = "media.html.modeRendered"
    case htmlModeSource = "media.html.modeSource"
    case htmlRefreshHelp = "media.html.refreshHelp"
    case htmlOpenInBrowserHelp = "media.html.openInBrowserHelp"
    case htmlCopyContentHelp = "media.html.copyContentHelp"
    case epubTypographyTitle = "media.epub.typographyTitle"
    case epubFontFamily = "media.epub.fontFamily"
    case epubFontSerif = "media.epub.fontSerif"
    case epubFontKaiti = "media.epub.fontKaiti"
    case epubFontSansSerif = "media.epub.fontSansSerif"
    case epubFontFangsong = "media.epub.fontFangsong"
    case epubFontSize = "media.epub.fontSize"
    case epubDecreaseFontSizeHelp = "media.epub.decreaseFontSizeHelp"
    case epubIncreaseFontSizeHelp = "media.epub.increaseFontSizeHelp"
    case epubTheme = "media.epub.theme"
    case epubThemeLight = "media.epub.themeLight"
    case epubThemeSepia = "media.epub.themeSepia"
    case epubThemeDark = "media.epub.themeDark"
    case epubThemeGlass = "media.epub.themeGlass"

    // MARK: - 3-State Text Reading Background Keys (Feedback ⑧ & ⑨)
    case readingBackgroundLabel = "media.text.readingBackgroundLabel"
    case readingBackgroundBlack = "media.text.readingBackgroundBlack"
    case readingBackgroundWhite = "media.text.readingBackgroundWhite"
    case readingBackgroundFluidTransparent = "media.text.readingBackgroundFluidTransparent"
    case readingBackgroundBlackHelp = "media.text.readingBackgroundBlackHelp"
    case readingBackgroundWhiteHelp = "media.text.readingBackgroundWhiteHelp"
    case readingBackgroundFluidTransparentHelp = "media.text.readingBackgroundFluidTransparentHelp"
    case readingBackgroundMenuHelpFormat = "media.text.readingBackgroundMenuHelpFormat"

    // MARK: - Soft Wrap (Word Wrap) Toggle Keys
    case softWrapLabel = "media.text.softWrapLabel"
    case enableSoftWrapHelp = "media.text.enableSoftWrapHelp"
    case disableSoftWrapHelp = "media.text.disableSoftWrapHelp"
    case softWrapStateOn = "media.text.softWrapStateOn"
    case softWrapStateOff = "media.text.softWrapStateOff"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .truncationBannerFormat: (
            "Preview truncated to %@ for interactive responsiveness. Editing and in-place saving are disabled to protect the original file.",
            "为保证交互响应，预览已截断至 %@。已禁用编辑与原位保存以保护原始文件。",
            "為確保互動流暢度，預覽已截斷至 %@。已停用編輯與原位儲存以保護原始檔案。"
        ),
        .encodingReadOnlyBannerFormat: (
            "Opened in read-only mode (%@ encoding). In-place saving is disabled to prevent silent UTF-8 conversion.",
            "当前以只读模式打开（%@ 编码）。已禁用原位保存以防静默转换为 UTF-8。",
            "目前以唯讀模式開啟（%@ 編碼）。已停用原位儲存以防靜默轉換為 UTF-8。"
        ),
        .archiveReadOnlyBanner: (
            "Archive entry preview is read-only. Extract the file to disk before editing.",
            "归档内条目预览为只读模式。请先解压到磁盘后再编辑。",
            "歸檔內條目預覽為唯讀模式。請先解壓縮至磁碟後再編輯。"
        ),
        .readOnlyBadge: ("Read-Only", "只读", "唯讀"),
        .plainTextLabel: ("Plain Text", "纯文本", "純文字"),
        .fileSizeAndLinesFormat: ("%@ • %d lines", "%@ • %d 行", "%@ • %d 行"),
        .unsavedBadge: ("Unsaved", "未保存", "未儲存"),
        .savedBadge: ("Saved", "已保存", "已儲存"),
        .hideLineNumbersHelp: ("Hide Line Numbers", "隐藏行号", "隱藏行號"),
        .showLineNumbersHelp: ("Show Line Numbers", "显示行号", "顯示行號"),
        .copiedToClipboardHelp: ("Copied to clipboard", "已复制到剪贴板", "已拷貝到剪貼簿"),
        .copySourceCodeHelp: ("Copy Source Code", "复制源代码", "拷貝原始碼"),
        .saveButton: ("Save", "保存", "儲存"),
        .saveWithShortcutFormat: ("Save (%@)", "保存 (%@)", "儲存 (%@)"),
        .saveChangesHelpFormat: (
            "Save changes to local file (%@)",
            "保存更改到本地文件 (%@)",
            "儲存變更至本機檔案 (%@)"
        ),
        .markdownDefaultTitle: ("Markdown Document", "Markdown 文档", "Markdown 文件"),
        .markdownModeRich: ("Rich Preview", "富文本预览", "富文字預覽"),
        .markdownModeSource: ("Source Code", "源代码", "原始碼"),
        .lineCountFormat: ("%d lines", "%d 行", "%d 行"),
        .wordCountFormat: ("%d words", "%d 词", "%d 詞"),
        .charCountFormat: ("%d chars", "%d 字符", "%d 字元"),
        .copyRawMarkdownHelp: ("Copy Raw Markdown", "复制 Markdown 源码", "拷貝 Markdown 原始碼"),
        .toggleFullscreenPreviewHelp: ("Toggle Fullscreen Preview", "切换全屏预览", "切換全螢幕預覽"),
        .copyCodeButton: ("Copy", "复制", "拷貝"),
        .copiedCodeButton: ("Copied", "已复制", "已拷貝"),
        .loadingPreview: ("Loading...", "正在加载…", "正在載入…"),
        .selectFileToPreview: (
            "Select a file from the explorer to preview",
            "从文件列表中选择文件以预览",
            "從檔案列表中選擇檔案以預覽"
        ),
        .emptyFileFormat: ("Empty file: %@", "空文件：%@", "空檔案：%@"),
        .archiveContainerLoadedMessage: (
            "Archive container loaded. Open or extract to browse contents.",
            "归档容器已加载。打开或解压以浏览内容。",
            "歸檔容器已載入。開啟或解壓縮以瀏覽內容。"
        ),
        .permissionDeniedFormat: ("Permission denied: %@", "权限被拒绝：%@", "權限遭拒：%@"),
        .toggleFullscreenOrDoubleClickHelp: (
            "Toggle fullscreen preview (or double-click canvas)",
            "切换全屏预览（或双击画布）",
            "切換全螢幕預覽（或連按兩下畫布）"
        ),
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
        .slidesBadge: ("SLIDES", "幻灯片", "投影片"),
        .slidesFilterPlaceholder: ("Filter slides...", "筛选幻灯片…", "篩選投影片…"),
        .slidesCopyOutlineButton: ("Copy Outline", "复制大纲", "拷貝大綱"),
        .slidesEmptyOutline: ("No slides found in presentation outline.", "演示文稿大纲中未找到幻灯片。", "簡報大綱中找不到投影片。"),
        .slidesNoMatchFormat: ("No slides match '%@'.", "没有匹配“%@”的幻灯片。", "沒有符合「%@」的投影片。"),
        .slidesCountFormat: ("%d slides", "%d 张幻灯片", "%d 張投影片"),
        .slidesOutlineFooter: ("Presentation Outline", "演示文稿大纲", "簡報大綱"),
        .slideNumberFormat: ("Slide %d", "幻灯片 %d", "投影片 %d"),
        .slideCopiedSingleFormat: ("Copied Slide %d text", "已复制幻灯片 %d 文本", "已拷貝投影片 %d 文字"),
        .slideCopySingleHelp: ("Copy slide text", "复制幻灯片文本", "拷貝投影片文字"),
        .slidesCopiedAllFormat: ("Copied all %d slide outlines", "已复制全部 %d 张幻灯片大纲", "已拷貝全部 %d 張投影片大綱"),
        .htmlDefaultTitle: ("HTML Document", "HTML 文档", "HTML 文件"),
        .htmlModeRendered: ("Rendered Web", "网页渲染", "網頁渲染"),
        .htmlModeSource: ("HTML Source", "HTML 源码", "HTML 原始碼"),
        .htmlRefreshHelp: ("Refresh Web View", "刷新网页视图", "重新整理網頁檢視"),
        .htmlOpenInBrowserHelp: ("Open in Default Browser", "在默认浏览器中打开", "在預設瀏覽器中開啟"),
        .htmlCopyContentHelp: ("Copy Content", "复制内容", "拷貝內容"),
        .epubTypographyTitle: ("Typography & Theme", "排版与主题", "排版與主題"),
        .epubFontFamily: ("Font Family", "字体", "字體"),
        .epubFontSerif: ("Songti / Serif", "宋体 / 衬线", "宋體 / 襯線"),
        .epubFontKaiti: ("Kaiti / Editorial", "楷体 / 书籍", "楷體 / 書籍"),
        .epubFontSansSerif: ("Heiti / Sans-Serif", "黑体 / 无衬线", "黑體 / 無襯線"),
        .epubFontFangsong: ("Fangsong / Classic", "仿宋 / 古籍", "仿宋 / 古籍"),
        .epubFontSize: ("Font Size", "字号", "字級"),
        .epubDecreaseFontSizeHelp: ("Decrease font size", "减小字号", "縮小字級"),
        .epubIncreaseFontSizeHelp: ("Increase font size", "增大字号", "放大字級"),
        .epubTheme: ("Reading Theme", "阅读主题", "閱讀主題"),
        .epubThemeLight: ("Paper", "纸张", "紙張"),
        .epubThemeSepia: ("Sepia", "护眼棕", "護眼棕"),
        .epubThemeDark: ("Night", "夜间", "夜間"),
        .epubThemeGlass: ("Glass", "毛玻璃", "毛玻璃"),
        .readingBackgroundLabel: ("Reading Background", "阅读背景", "閱讀背景"),
        .readingBackgroundBlack: ("Black", "黑色", "黑色"),
        .readingBackgroundWhite: ("White", "白色", "白色"),
        .readingBackgroundFluidTransparent: ("Fluid", "流体透明", "流體透明"),
        .readingBackgroundBlackHelp: (
            "Black reading background (independent of app theme)",
            "黑色阅读背景（独立于应用外观）",
            "黑色閱讀背景（獨立於應用外觀）"
        ),
        .readingBackgroundWhiteHelp: (
            "White reading background (independent of app theme)",
            "白色阅读背景（独立于应用外观）",
            "白色閱讀背景（獨立於應用外觀）"
        ),
        .readingBackgroundFluidTransparentHelp: (
            "Fluid transparent reading background (adapts text to app theme)",
            "流体透明阅读背景（正文随应用外观自适应）",
            "流體透明閱讀背景（內文隨應用外觀自適應）"
        ),
        .readingBackgroundMenuHelpFormat: (
            "Reading Background: %@",
            "阅读背景：%@",
            "閱讀背景：%@"
        ),
        .softWrapLabel: ("Soft Wrap", "自动换行", "自動換行"),
        .enableSoftWrapHelp: ("Enable Soft Wrap", "开启自动换行", "開啟自動換行"),
        .disableSoftWrapHelp: (
            "Disable Soft Wrap (Horizontal Scroll)",
            "关闭自动换行（横向滚动）",
            "關閉自動換行（橫向捲動）"
        ),
        .softWrapStateOn: ("On", "已开启", "已開啟"),
        .softWrapStateOff: ("Off", "已关闭", "已關閉"),
    ]
}

/// Resolves code, Markdown, rich document, Hex, presentation, and preview container vocabulary through the shared observable `TTI18n` localization state.
@MainActor
public enum TextAndDocumentPreviewLocalization {
    public static func text(_ key: TextAndDocumentPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    public static func format(_ key: TextAndDocumentPreviewLocaleKey, _ args: CVarArg...) -> String {
        let template = LocalizationState.shared.t(key)
        return String(format: template, arguments: args)
    }

    public static func truncationBanner(budgetText: String = "2 MB") -> String {
        format(.truncationBannerFormat, budgetText)
    }

    public static func encodingReadOnlyBanner(encodingName: String) -> String {
        format(.encodingReadOnlyBannerFormat, encodingName)
    }

    public static func fileSizeAndLines(sizeText: String, lineCount: Int) -> String {
        format(.fileSizeAndLinesFormat, sizeText, lineCount)
    }

    public static func saveWithShortcut(_ shortcut: String = "⌘S") -> String {
        format(.saveWithShortcutFormat, shortcut)
    }

    public static func saveChangesHelp(_ shortcut: String = "⌘S") -> String {
        format(.saveChangesHelpFormat, shortcut)
    }

    public static func lineCount(_ count: Int) -> String {
        format(.lineCountFormat, count)
    }

    public static func wordCount(_ count: Int) -> String {
        format(.wordCountFormat, count)
    }

    public static func charCount(_ count: Int) -> String {
        format(.charCountFormat, count)
    }

    /// Dynamically localizes known container placeholder and detector messages
    /// (`"Loading..."`, `"Select a file..."`, `"Empty file: <EXT>"`, `"Permission denied: <NAME>"`, etc.)
    /// so active language switches update immediately without requiring state re-initialization.
    public static func localizedUnsupportedMessage(_ rawMessage: String) -> String {
        if rawMessage == "Loading..." {
            return text(.loadingPreview)
        }
        if rawMessage == "Select a file from the explorer to preview" {
            return text(.selectFileToPreview)
        }
        if rawMessage == "Archive container loaded. Open or extract to browse contents." {
            return text(.archiveContainerLoadedMessage)
        }
        if rawMessage.hasPrefix("Empty file: ") {
            let ext = String(rawMessage.dropFirst("Empty file: ".count))
            return format(.emptyFileFormat, ext)
        }
        if rawMessage.hasPrefix("Permission denied: ") {
            let target = String(rawMessage.dropFirst("Permission denied: ".count))
            return format(.permissionDeniedFormat, target)
        }
        return rawMessage
    }
}
