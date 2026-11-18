// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

/// Localized vocabulary for text editors and preview container states.
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
    case allowEditingButton = "media.text.allowEditingButton"
    case allowEditingHelp = "media.text.allowEditingHelp"
    case saveButton = "media.text.saveButton"
    case saveWithShortcutFormat = "media.text.saveWithShortcutFormat"
    case saveChangesHelpFormat = "media.text.saveChangesHelpFormat"
    case markdownDefaultTitle = "media.markdown.defaultTitle"
    case toggleFullscreenPreviewHelp = "media.markdown.toggleFullscreenPreviewHelp"
    case loadingPreview = "media.container.loadingPreview"
    case selectFileToPreview = "media.container.selectFileToPreview"
    case emptyFileFormat = "media.container.emptyFileFormat"
    case archiveContainerLoadedMessage = "media.container.archiveContainerLoadedMessage"
    case permissionDeniedFormat = "media.container.permissionDeniedFormat"
    case toggleFullscreenOrDoubleClickHelp = "media.container.toggleFullscreenOrDoubleClickHelp"

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
        .allowEditingButton: ("Allow Editing", "允许编辑", "允許編輯"),
        .allowEditingHelp: (
            "Allow editing this local file",
            "允许编辑此本地文件",
            "允許編輯此本機檔案"
        ),
        .saveButton: ("Save", "保存", "儲存"),
        .saveWithShortcutFormat: ("Save (%@)", "保存 (%@)", "儲存 (%@)"),
        .saveChangesHelpFormat: (
            "Save changes to local file (%@)",
            "保存更改到本地文件 (%@)",
            "儲存變更至本機檔案 (%@)"
        ),
        .markdownDefaultTitle: ("Markdown Document", "Markdown 文档", "Markdown 文件"),
        .toggleFullscreenPreviewHelp: ("Toggle Fullscreen Preview", "切换全屏预览", "切換全螢幕預覽"),
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

/// Resolves text editor and preview container vocabulary through the shared observable `TTI18n` localization state.
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
