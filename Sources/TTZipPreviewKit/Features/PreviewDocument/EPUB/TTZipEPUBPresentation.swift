// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTMediaKit
import TTI18nCore
import TTI18nUI

// MARK: - E-Book & EPUB Preview TTI18n Vocabulary

public enum EBookPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case inspectionModeBadge = "media.ebook.inspectionModeBadge"
    case inspectionModeSummary = "media.ebook.inspectionModeSummary"
    case openInExternalReader = "media.ebook.openInExternalReader"
    case revealInFinder = "media.ebook.revealInFinder"
    case verifyIntegrity = "media.ebook.verifyIntegrity"
    case fileProperties = "media.ebook.fileProperties"
    case fileName = "media.ebook.fileName"
    case author = "media.ebook.author"
    case format = "media.ebook.format"
    case fileSize = "media.ebook.fileSize"
    case location = "media.ebook.location"
    case identifier = "media.ebook.identifier"
    case integrityVerifiedSHA256 = "media.ebook.integrityVerifiedSHA256"
    case inspectionNotes = "media.ebook.inspectionNotes"
    case copySHA256 = "media.ebook.copySHA256"
    case copied = "media.ebook.copied"
    case computingSHA256 = "media.ebook.computingSHA256"
    case checksumUnavailable = "media.ebook.checksumUnavailable"
    case chapterFallback = "media.ebook.chapterFallback"
    case tableOfContentsHelp = "media.ebook.tableOfContentsHelp"
    case previousChapterHelp = "media.ebook.previousChapterHelp"
    case nextChapterHelp = "media.ebook.nextChapterHelp"
    case typography = "media.ebook.typography"
    case typographyHelp = "media.ebook.typographyHelp"
    case typographyAndThemeTitle = "media.ebook.typographyAndThemeTitle"
    case fontFamilyLabel = "media.ebook.fontFamilyLabel"
    case fontSerif = "media.ebook.fontSerif"
    case fontKaiti = "media.ebook.fontKaiti"
    case fontSansSerif = "media.ebook.fontSansSerif"
    case fontFangsong = "media.ebook.fontFangsong"
    case fontSizeLabel = "media.ebook.fontSizeLabel"
    case decreaseFontSizeHelp = "media.ebook.decreaseFontSizeHelp"
    case increaseFontSizeHelp = "media.ebook.increaseFontSizeHelp"
    case themeLabel = "media.ebook.themeLabel"
    case themeLight = "media.ebook.themeLight"
    case themeSepia = "media.ebook.themeSepia"
    case themeDark = "media.ebook.themeDark"
    case themeGlass = "media.ebook.themeGlass"
    case noChapterContent = "media.ebook.noChapterContent"
    case loadingChapterContent = "media.ebook.loadingChapterContent"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .inspectionModeBadge: ("File & Checksum Inspection Mode", "文件与校验和检视模式", "檔案與校驗和檢視模式"),
        .inspectionModeSummary: (
            "File metadata and SHA-256 integrity inspection only. Full-text reading is not supported in-app for this format; open in an external reader app.",
            "仅提供文件元数据与 SHA-256 完整性检视。应用内暂不支持此格式的正文阅读，请使用外部阅读器打开。",
            "僅提供檔案元資料與 SHA-256 完整性檢視。應用程式內暫不支援此格式的正文閱讀，請使用外部閱讀器打開。"
        ),
        .openInExternalReader: ("Open in External Reader", "在外部阅读器中打开", "在外部閱讀器中打開"),
        .revealInFinder: ("Reveal in Finder", "在访达中显示", "在 Finder 中顯示"),
        .verifyIntegrity: ("Verify Integrity", "校验完整性", "校驗完整性"),
        .fileProperties: ("File Properties", "文件属性", "檔案屬性"),
        .fileName: ("File Name", "文件名", "檔案名稱"),
        .author: ("Author", "作者", "作者"),
        .format: ("Format", "格式", "格式"),
        .fileSize: ("File Size", "文件大小", "檔案大小"),
        .location: ("Location", "位置", "位置"),
        .identifier: ("Identifier", "标识符", "識別碼"),
        .integrityVerifiedSHA256: ("Integrity Verified (SHA-256)", "完整性已校验 (SHA-256)", "完整性已校驗 (SHA-256)"),
        .inspectionNotes: ("Inspection Notes", "检视说明", "檢視說明"),
        .copySHA256: ("Copy SHA-256", "复制 SHA-256", "複製 SHA-256"),
        .copied: ("Copied", "已复制", "已複製"),
        .computingSHA256: ("Computing SHA-256 Checksum...", "正在计算 SHA-256 校验和...", "正在計算 SHA-256 校驗和..."),
        .checksumUnavailable: ("Checksum unavailable", "校验和不可用", "校驗和不可用"),
        .chapterFallback: ("Chapter", "章节", "章節"),
        .tableOfContentsHelp: ("Table of Contents", "目录", "目錄"),
        .previousChapterHelp: ("Previous Chapter", "上一章", "上一章"),
        .nextChapterHelp: ("Next Chapter", "下一章", "下一章"),
        .typography: ("Typography", "排版", "排版"),
        .typographyHelp: ("Customize font, size, and theme", "自定义字体、字号与主题", "自訂字體、字級與主題"),
        .typographyAndThemeTitle: ("Typography & Theme", "排版与主题", "排版與主題"),
        .fontFamilyLabel: ("Font Family", "字体", "字體"),
        .fontSerif: ("Serif", "宋体 / 衬线", "宋體 / 襯線"),
        .fontKaiti: ("Kaiti", "楷体 / 手写", "楷體 / 手寫"),
        .fontSansSerif: ("Sans-Serif", "黑体 / 无衬线", "黑體 / 無襯線"),
        .fontFangsong: ("Fangsong", "仿宋", "仿宋"),
        .fontSizeLabel: ("Font Size", "字号", "字號"),
        .decreaseFontSizeHelp: ("Decrease font size", "减小字号", "減小字號"),
        .increaseFontSizeHelp: ("Increase font size", "增大字号", "增大字號"),
        .themeLabel: ("Theme", "阅读主题", "閱讀主題"),
        .themeLight: ("Light", "浅色", "淺色"),
        .themeSepia: ("Sepia", "护眼", "護眼"),
        .themeDark: ("Dark", "深色", "深色"),
        .themeGlass: ("System", "跟随系统", "跟隨系統"),
        .noChapterContent: ("No chapter content available", "暂无章节内容", "暫無章節內容"),
        .loadingChapterContent: ("Loading chapter content…", "正在加载章节内容…", "正在載入章節內容…"),
    ]
}

@MainActor
public enum EBookPreviewLocalization {
    public static func text(_ key: EBookPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }
}

@MainActor
enum TTZipEPUBAppearance {
    private static let light = EPUBReaderAppearance.Colors(
        background: "rgba(255, 255, 255, 0.96)", text: "#1c1c1e"
    )
    private static let sepia = EPUBReaderAppearance.Colors(
        background: "rgba(248, 241, 227, 0.94)", text: "#3c2f23"
    )
    private static let dark = EPUBReaderAppearance.Colors(
        background: "rgba(28, 28, 30, 0.96)", text: "#e5e5e7"
    )

    static func reader() -> EPUBReaderAppearance {
        EPUBReaderAppearance(
            light: light,
            sepia: sepia,
            dark: dark,
            transparent: .init(background: "transparent", text: light.text),
            themeRulesCSS: themeRulesCSS,
            loadingPlaceholder: .init(
                message: EBookPreviewLocalization.text(.loadingChapterContent),
                containerStyle: "padding: 60px 20px; text-align: center; font-family: -apple-system, sans-serif;",
                titleStyle: "opacity: 0.8; font-weight: 500;",
                messageStyle: "color: #8e8e93; font-size: 13px; margin-top: 8px;"
            )
        )
    }

    private static let themeRulesCSS = """
        body.theme-dark {
            background-color: \(dark.background) !important;
            color: \(dark.text) !important;
        }
        body.theme-dark p, body.theme-dark h1, body.theme-dark h2, body.theme-dark h3,
        body.theme-dark h4, body.theme-dark h5, body.theme-dark h6,
        body.theme-dark li, body.theme-dark td, body.theme-dark th {
            color: \(dark.text);
        }
        body.theme-dark a {
            color: #6cb6ff !important;
        }
        body.theme-dark a:visited {
            color: #b392f0 !important;
        }
        body.theme-dark pre, body.theme-dark code {
            background-color: rgba(255, 255, 255, 0.08) !important;
            color: #f0f6fc !important;
            border: 1px solid rgba(255, 255, 255, 0.12) !important;
            border-radius: 4px !important;
        }
        body.theme-dark blockquote {
            border-left: 3px solid rgba(255, 255, 255, 0.2) !important;
            color: #d1d1d6 !important;
        }
        body.theme-dark hr {
            border-color: rgba(255, 255, 255, 0.15) !important;
        }
        body.theme-sepia {
            background-color: \(sepia.background) !important;
            color: \(sepia.text) !important;
        }
        body.theme-sepia a {
            color: #8a4b08 !important;
        }
        body.theme-light {
            background-color: \(light.background) !important;
            color: \(light.text) !important;
        }
        body.theme-light a {
            color: #0969da !important;
        }
        body.theme-transparent {
            background-color: transparent !important;
            color: \(light.text) !important;
        }
        @media (prefers-color-scheme: dark) {
            body.theme-transparent {
                color: \(dark.text) !important;
            }
            body.theme-transparent a {
                color: #6cb6ff !important;
            }
        }
    """
}
