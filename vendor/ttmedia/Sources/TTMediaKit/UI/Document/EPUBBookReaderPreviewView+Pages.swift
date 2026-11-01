// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import WebKit
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

public struct EBookInspectionBannerModel: Equatable, Sendable {
    public let badgeTitle: String
    public let summaryText: String

    public init(badgeTitle: String, summaryText: String) {
        self.badgeTitle = badgeTitle
        self.summaryText = summaryText
    }

    @MainActor
    public static func resolve(for metadata: EBookMetadata, language: AppLanguage? = nil) -> EBookInspectionBannerModel {
        let badge: String
        let defaultSummary: String
        if let language {
            badge = EBookPreviewLocaleKey.inspectionModeBadge.fallbackTranslation(for: language)
            defaultSummary = EBookPreviewLocaleKey.inspectionModeSummary.fallbackTranslation(for: language)
        } else {
            badge = EBookPreviewLocalization.text(.inspectionModeBadge)
            defaultSummary = EBookPreviewLocalization.text(.inspectionModeSummary)
        }
        let trimmed = metadata.excerptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (trimmed.isEmpty || trimmed == EBookReaderPreviewView.legacyPlaceholderExcerpt)
            ? defaultSummary
            : trimmed
        return EBookInspectionBannerModel(badgeTitle: badge, summaryText: summary)
    }
}

// MARK: - EPUBNativeWKWebView CSS & Pagination Synchronization Extensions

extension EPUBNativeWKWebView {
    public static func resolveFontFamilyCSS(for style: String) -> String {
        let components = style.split(separator: "|", omittingEmptySubsequences: false)
        if components.count == 2 {
            let latin: String
            switch components[0] {
            case "sans": latin = "Arial, Helvetica"
            case "mono": latin = "Menlo, Courier"
            default: latin = "Charter, Georgia, Times"
            }
            let cjk: String
            switch components[1] {
            case "kaiti": cjk = "\"STKaiti\", \"Kaiti SC\", serif"
            case "fangsong": cjk = "\"STFangsong\", \"FangSong\", serif"
            case "sans": cjk = "\"PingFang SC\", \"Hiragino Sans GB\", sans-serif"
            default: cjk = "\"Songti SC\", \"STSong\", serif"
            }
            return latin + ", " + cjk
        }
        switch style {
        case "sans":
            return "-apple-system, BlinkMacSystemFont, \"PingFang SC\", \"Hiragino Sans GB\", \"Microsoft YaHei\", sans-serif"
        case "kaiti":
            return "\"STKaiti\", \"KaiTi\", \"Kaiti SC\", \"Source Han Serif SC\", serif"
        case "fangsong":
            return "\"STFangsong\", \"FangSong\", \"Fangsong SC\", \"Source Han Serif SC\", serif"
        default:
            return "-apple-system, BlinkMacSystemFont, \"Charter\", \"Georgia\", \"Songti SC\", \"PingFang SC\", serif"
        }
    }

    private static func buildBaseTypographyCSS(
        fontSize: Double,
        fontFamilyCSS: String,
        initialBg: String,
        initialText: String
    ) -> String {
        return """
            :root {
                color-scheme: light dark;
                --reader-font-size: \(fontSize)pt;
                --reader-line-height: 1.7;
                --reader-font-family: \(fontFamilyCSS);
                --reader-bg: \(initialBg);
                --reader-text: \(initialText);
            }
            ::-webkit-scrollbar {
                display: none !important;
                width: 0 !important;
                height: 0 !important;
            }
            body {
                background-color: var(--reader-bg) !important;
                color: var(--reader-text) !important;
                font-family: var(--reader-font-family) !important;
                font-size: var(--reader-font-size) !important;
                line-height: var(--reader-line-height) !important;
                margin: 0 auto;
                padding: 36px 28px;
                box-sizing: border-box !important;
                word-wrap: break-word !important;
            }
            p { orphans: 2; widows: 2; }
            h1, h2, h3, h4, h5, h6 { break-after: avoid; }
            pre, code { white-space: pre-wrap; overflow-wrap: anywhere; }
            table { max-width: 100%; border-collapse: collapse; }
            img, svg, video, canvas {
                max-width: 100% !important;
                height: auto !important;
                filter: none !important;
                break-inside: avoid !important;
            }
            img {
                display: block !important;
                margin: 16px auto !important;
            }
        """
    }

    private static func buildThemeRulesCSS() -> String {
        return """
            body.theme-dark {
                background-color: rgba(28, 28, 30, 0.96) !important;
                color: #e5e5e7 !important;
            }
            body.theme-dark p, body.theme-dark h1, body.theme-dark h2, body.theme-dark h3,
            body.theme-dark h4, body.theme-dark h5, body.theme-dark h6,
            body.theme-dark li, body.theme-dark td, body.theme-dark th {
                color: #e5e5e7;
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
                background-color: rgba(248, 241, 227, 0.94) !important;
                color: #3c2f23 !important;
            }
            body.theme-sepia a {
                color: #8a4b08 !important;
            }
            body.theme-light {
                background-color: rgba(255, 255, 255, 0.96) !important;
                color: #1c1c1e !important;
            }
            body.theme-light a {
                color: #0969da !important;
            }
            body.theme-transparent {
                background-color: transparent !important;
                color: #1c1c1e !important;
            }
            @media (prefers-color-scheme: dark) {
                body.theme-transparent {
                    color: #e5e5e7 !important;
                }
                body.theme-transparent a {
                    color: #6cb6ff !important;
                }
            }
        """
    }

    public static func buildCustomCSS(fontSize: Double, fontFamilyCSS: String, readerTheme: String) -> String {
        let (initialBg, initialText) = resolveInitialThemeColors(for: readerTheme)
        let typography = buildBaseTypographyCSS(
            fontSize: fontSize,
            fontFamilyCSS: fontFamilyCSS,
            initialBg: initialBg,
            initialText: initialText
        )
        let themes = buildThemeRulesCSS()
        return "<style>\n\(typography)\n\(themes)\n</style>"
    }

    private static func resolveInitialThemeColors(for readerTheme: String) -> (bg: String, text: String) {
        switch readerTheme {
        case "sepia":
            return ("rgba(248, 241, 227, 0.94)", "#3c2f23")
        case "dark":
            return ("rgba(28, 28, 30, 0.96)", "#e5e5e7")
        case "transparent":
            return ("transparent", "#1c1c1e")
        default:
            return ("rgba(255, 255, 255, 0.96)", "#1c1c1e")
        }
    }
}

extension EPUBNativeWKWebView.Coordinator {
    internal static func makePlaceholderHTML(
        for cleanURL: URL,
        customCSS: String,
        readerTheme: String
    ) -> String {
        let title = cleanURL.lastPathComponent
            .replacingOccurrences(of: ".xhtml", with: "")
            .replacingOccurrences(of: ".html", with: "")
        let loadingMessage = EBookPreviewLocalization.text(.loadingChapterContent)
        return TTWebPreviewContentPolicy.injectOfflineCSP(into: """
        <!DOCTYPE html>
        <html><head>\(customCSS)</head>
        <body class="theme-\(readerTheme)">
        <div style='padding: 60px 20px; text-align: center; font-family: -apple-system, sans-serif;'>
            <h2 style='opacity: 0.8; font-weight: 500;'>\(title)</h2>
            <p style='color: #8e8e93; font-size: 13px; margin-top: 8px;'>\(loadingMessage)</p>
        </div>
        </body></html>
        """)
    }

    private func bindReaderWebViewEvents(
        to webView: WKWebView,
        instanceID: UUID,
        pagination: EPUBPaginationController?
    ) {
        guard let readerWebView = webView as? EPUBReaderWKWebView else { return }
        readerWebView.readerInstanceID = instanceID
        readerWebView.paginationController = pagination
        readerWebView.onViewportResized = { [weak self, weak webView] _ in
            guard let self, let webView, self.lastLoadedChapterContent != nil else { return }
            self.parent?.paginationController?.prepareAnchorPreservationBeforeRelayout()
            self.relayoutPreserveAnchor(in: webView)
        }
    }

    private func registerKeyboardSession(
        instanceID: UUID,
        webView: WKWebView,
        pagination: EPUBPaginationController?
    ) {
        let resolvedLayoutMode = EPUBReadingLayoutPreference.resolve(
            stored: parent?.layoutMode ?? pagination?.layoutMode.rawValue
        )
        TTPreviewKeyboardOwnershipCoordinator.shared.registerOrUpdateSession(
            instanceID: instanceID,
            windowNumber: webView.window?.windowNumber,
            ownsHorizontalArrowKeys: false,
            layoutMode: resolvedLayoutMode,
            onVerticalArrowKey: { [weak pagination] isDown in
                guard let pagination else { return false }
                return pagination.handleVerticalArrow(isDownArrow: isDown)
            }
        ) { [weak pagination] isRightArrow in
            guard let pagination else { return false }
            _ = pagination.handleHorizontalArrow(isRightArrow: isRightArrow)
            return true
        }
        TTPreviewKeyboardOwnershipCoordinator.shared.bindReaderViews(
            instanceID: instanceID,
            webView: webView as? EPUBReaderWKWebView,
            containerView: webView.superview
        )
        inputStateMessageHandler.onInputStateChanged = { message in
            TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionDOMInputLifecycle(
                instanceID: instanceID,
                isInputActive: message.isInputActive,
                isIMEComposing: message.isIMEComposing
            )
        }
    }

    private func bindControllerRequests(
        to webView: WKWebView,
        instanceID: UUID,
        pagination: EPUBPaginationController?
    ) {
        guard let pagination else { return }
        pagination.onRequestWebViewPageJump = { [weak self, weak webView] pageIndex in
            guard let self, let webView else { return }
            self.jumpToPageInWebView(pageIndex, in: webView)
        }
        pagination.onRequestAnchorJump = { [weak self, weak webView] block, character, ratio in
            guard let self, let webView else { return }
            self.restoreAnnotationAnchor(block: block, character: character, ratio: ratio, in: webView)
        }
        pagination.onRequestVerticalScroll = { [weak self, weak webView] isDown in
            guard let self, let webView else { return }
            self.scrollVerticalInWebView(isDown: isDown, in: webView)
        }
        pagination.onRequestRestoreReaderFocus = { [weak webView] in
            guard let webView else { return }
            TTPreviewKeyboardOwnershipCoordinator.shared.notifyToolbarInteraction(instanceID: instanceID)
            if let window = webView.window, window.firstResponder !== webView {
                window.makeFirstResponder(webView)
            }
        }
    }

    public func bindPaginationAndFocusCallbacks(to webView: WKWebView) {
        let pagination = parent?.paginationController
        let instanceID = pagination?.instanceID ?? (webView as? EPUBReaderWKWebView)?.readerInstanceID ?? UUID()
        bindReaderWebViewEvents(to: webView, instanceID: instanceID, pagination: pagination)
        registerKeyboardSession(instanceID: instanceID, webView: webView, pagination: pagination)
        bindControllerRequests(to: webView, instanceID: instanceID, pagination: pagination)
    }

    public func scrollVerticalInWebView(isDown: Bool, in webView: WKWebView) {
        let generation = currentBookGeneration
        let js = "\(EPUBReaderWebKitPagerBridge.bootstrapScript); window.__ttPager.scrollVertical(\(isDown ? "true" : "false"));"
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let dict = try? outcome.get() as? [String: Any] else { return }
            guard let pagination = self.parent?.paginationController else { return }
            let atBoundary = (dict["atBoundary"] as? String) ?? "none"
            if atBoundary == "bottom" || atBoundary == "top" {
                // Vertical keys only scroll the chapter body; crossing chapters stays on the horizontal
                // arrow keys so a held Down key can never skip a chapter.
                pagination.synchronizeScrollingPageIndex((dict["pageIndex"] as? NSNumber)?.intValue)
                return
            }
            if let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: dict) {
                let chapterIdx = self.parent?.chapterIndex ?? pagination.currentChapterIndex
                self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
            }
        }
    }

    private var currentBookGeneration: Int {
        parent?.paginationController?.bookGeneration ?? 0
    }

    private func isCurrentBookGeneration(_ generation: Int) -> Bool {
        guard let controller = parent?.paginationController else { return false }
        return controller.bookGeneration == generation
    }

    private func resolvedLayoutMode() -> EPUBReadingLayoutMode {
        if let stored = parent?.layoutMode {
            return EPUBReadingLayoutPreference.resolve(stored: stored)
        }
        return parent?.paginationController?.layoutMode ?? .paginated
    }

    private func themeBackgroundExpression(theme: String) -> String {
        switch theme {
        case "dark": return "'rgba(28, 28, 30, 0.96)'"
        case "sepia": return "'rgba(248, 241, 227, 0.94)'"
        case "transparent": return "'transparent'"
        default: return "'rgba(255, 255, 255, 0.96)'"
        }
    }

    private func themeTextExpression(theme: String) -> String {
        switch theme {
        case "dark": return "'#e5e5e7'"
        case "sepia": return "'#3c2f23'"
        default: return "'#1c1c1e'"
        }
    }

    private func themeApplicationJS(theme: String, fontSize: Double, escapedFontFamily: String) -> String {
        return """
        document.documentElement.style.setProperty('--reader-font-size', '\(fontSize)pt');
        document.documentElement.style.setProperty('--reader-font-family', '\(escapedFontFamily)');
        var themeBg = \(themeBackgroundExpression(theme: theme));
        var themeColor = \(themeTextExpression(theme: theme));
        document.documentElement.style.setProperty('--reader-bg', themeBg);
        document.documentElement.style.setProperty('--reader-text', themeColor);
        if (document.body) {
            document.body.classList.remove('theme-light', 'theme-sepia', 'theme-dark', 'theme-transparent');
            document.body.classList.add('theme-\(theme)');
            document.documentElement.setAttribute('data-reader-theme', '\(theme)');
            document.body.style.setProperty('background-color', themeBg, 'important');
            document.body.style.setProperty('color', themeColor, 'important');
        }
        """
    }

    public func synchronizePaginationAndRecordTelemetryOnFinish(in webView: WKWebView) {
        let didFinishUptime = ProcessInfo.processInfo.systemUptime
        let webKitMs = pendingWebKitStartUptime > 0
            ? max(0, (didFinishUptime - pendingWebKitStartUptime) * 1000.0)
            : 0.0
        let theme = currentTheme ?? "light"
        let fontSize = Double(currentFontSize ?? 17.0)
        let fontStyle = currentFontStyle ?? "serif"
        let escapedFont = EPUBNativeWKWebView.resolveFontFamilyCSS(for: fontStyle)
            .replacingOccurrences(of: "'", with: "\\'")
        let activeFragment = pendingFragment
        pendingFragment = nil
        let relayoutArgs = buildRelayoutInvocationArgs(fragment: activeFragment)
        let mode = resolvedLayoutMode().rawValue
        let generation = currentBookGeneration

        let js = """
        window.__ttReaderChapterIndex = \(parent?.chapterIndex ?? 0);
        window.__ttReaderBookGeneration = \(generation);
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        \(themeApplicationJS(theme: theme, fontSize: fontSize, escapedFontFamily: escapedFont))
        window.__ttPager.applyDarkThemeContrast('\(theme)' === 'dark');
        window.__ttPager.relayout(\(relayoutArgs), '\(mode)');
        """
        let callbackStart = ProcessInfo.processInfo.systemUptime
        let chapterIdx = (webView as? EPUBReaderWKWebView)?.paginationController?.currentChapterIndex
            ?? parent?.paginationController?.currentChapterIndex
            ?? parent?.chapterIndex
            ?? 0
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self, weak webView] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let layoutCallbackMs = max(0, (now - callbackStart) * 1000.0)
            let totalMs = self.pendingLoadStartUptime > 0
                ? max(0, (now - self.pendingLoadStartUptime) * 1000.0)
                : (webKitMs + layoutCallbackMs)
            let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get())
            self.publishTelemetryAndSync(
                snapshot: snapshot,
                chapterIndex: chapterIdx,
                webKitMs: webKitMs,
                layoutCallbackMs: layoutCallbackMs,
                totalMs: totalMs,
                webView: webView,
                generation: generation
            )
        }
    }

    private func buildRelayoutInvocationArgs(fragment: String?) -> String {
        if let fragment, !fragment.isEmpty {
            return formatFragmentRelayoutArg(fragment)
        }
        switch parent?.paginationController?.pendingLanding {
        case .lastPage:
            return "'last', 1, -1, null, 0"
        case .preserveAnchor(let ratio, let anchorIdx, let charOff):
            return "'anchor', \(ratio), \(anchorIdx ?? -1), null, \(charOff)"
        case .fragment(let frag):
            return formatFragmentRelayoutArg(frag)
        default:
            return "'first', 0, -1, null, 0"
        }
    }

    private func formatFragmentRelayoutArg(_ fragment: String) -> String {
        let escaped = fragment
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'fragment', 0, -1, decodeURIComponent('\(escaped)'), 0"
    }

    private func recordTelemetryIfPresent(
        totalPages: Int,
        webKitMs: Double,
        layoutCallbackMs: Double,
        totalMs: Double
    ) {
        guard let chapterURL = lastLoadedChapterURL else { return }
        let telemetry = pendingLoadTelemetry
        let metrics = EPUBFirstScreenPerfMetrics(
            chapterURL: chapterURL,
            isVFSSource: chapterURL.scheme?.lowercased() == "ttzip-vfs",
            chapterReadMs: telemetry?.chapterReadMs ?? 0.0,
            resourceAuthAndInlineMs: telemetry?.resourceAuthAndInlineMs ?? 0.0,
            webKitLoadToFinishMs: webKitMs,
            firstPaginationLayoutCallbackMs: layoutCallbackMs,
            totalToPaginationCallbackMs: totalMs,
            inlinedResourceCount: telemetry?.inlinedResourceCount ?? 0,
            authenticatedCacheHitCount: telemetry?.authenticatedCacheHitCount ?? 0,
            initialPageCount: totalPages
        )
        latestFirstScreenMetrics = metrics
        parent?.paginationController?.recordFirstScreenMetrics(metrics)
    }

    internal func updatePaginationFromSnapshot(
        _ snapshot: EPUBReaderWebKitPagerBridge.PagerSnapshot,
        chapterIndex: Int,
        generation: Int? = nil
    ) {
        guard let controller = parent?.paginationController else { return }
        if let generation, generation != controller.bookGeneration { return }
        controller.didSynchronizeWebViewPagination(
            chapterIndex: chapterIndex,
            pageIndex: snapshot.pageIndex,
            totalPages: snapshot.totalPages,
            anchorBlockIndex: snapshot.anchorBlockIndex,
            anchorCharOffset: snapshot.anchorCharOffset,
            readingDirectionRaw: snapshot.readingDirection,
            bookGeneration: controller.bookGeneration,
            isLayoutReady: snapshot.isLayoutReady
        )
    }

    private func syncPaginationAndInput(
        snapshot: EPUBReaderWebKitPagerBridge.PagerSnapshot?,
        chapterIndex: Int,
        pageIndex: Int,
        totalPages: Int,
        webView: WKWebView?,
        generation: Int
    ) {
        if let snapshot {
            updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIndex, generation: generation)
        } else {
            parent?.paginationController?.didSynchronizeWebViewPagination(
                chapterIndex: chapterIndex,
                pageIndex: pageIndex,
                totalPages: totalPages,
                anchorBlockIndex: nil,
                anchorCharOffset: 0,
                readingDirectionRaw: nil,
                bookGeneration: generation,
                isLayoutReady: false
            )
        }
        guard let readerWebView = webView as? EPUBReaderWKWebView else { return }
        TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionDOMInputLifecycle(
            instanceID: readerWebView.readerInstanceID,
            isInputActive: snapshot?.isInputActive ?? false,
            isIMEComposing: snapshot?.isIMEComposing ?? false
        )
    }

    private func publishTelemetryAndSync(
        snapshot: EPUBReaderWebKitPagerBridge.PagerSnapshot?,
        chapterIndex: Int,
        webKitMs: Double,
        layoutCallbackMs: Double,
        totalMs: Double,
        webView: WKWebView?,
        generation: Int
    ) {
        let pageIndex = snapshot?.pageIndex ?? 0
        let totalPages = snapshot?.totalPages ?? 1
        recordTelemetryIfPresent(
            totalPages: totalPages,
            webKitMs: webKitMs,
            layoutCallbackMs: layoutCallbackMs,
            totalMs: totalMs
        )
        syncPaginationAndInput(
            snapshot: snapshot,
            chapterIndex: chapterIndex,
            pageIndex: pageIndex,
            totalPages: totalPages,
            webView: webView,
            generation: generation
        )
    }

    public func applyTypographyAndRelayout(
        in webView: WKWebView,
        fontSize: Double,
        escapedFontFamily: String,
        readerTheme: String
    ) {
        let ratio = parent?.paginationController?.normalizedProgressInChapter ?? 0.0
        let anchorIdx = parent?.paginationController?.anchorBlockIndex ?? -1
        let chapterIdx = parent?.chapterIndex ?? parent?.paginationController?.currentChapterIndex ?? 0
        let mode = resolvedLayoutMode().rawValue
        let generation = currentBookGeneration
        let js = """
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        var capturedAnchor = window.__ttPager.captureAnchor();
        var capturedCharOff = window.__ttPager.anchorCharOffset || 0;
        \(themeApplicationJS(theme: readerTheme, fontSize: fontSize, escapedFontFamily: escapedFontFamily))
        window.__ttPager.applyDarkThemeContrast('\(readerTheme)' === 'dark');
        window.__ttPager.relayout('anchor', \(ratio), capturedAnchor >= 0 ? capturedAnchor : \(anchorIdx), null, capturedCharOff, '\(mode)');
        """
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get()) else { return }
            self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
        }
    }

    public func relayoutPreserveAnchor(in webView: WKWebView) {
        let ratio = parent?.paginationController?.normalizedProgressInChapter ?? 0.0
        let anchorIdx = parent?.paginationController?.anchorBlockIndex ?? -1
        let charOff = parent?.paginationController?.anchorCharOffset ?? 0
        let chapterIdx = parent?.chapterIndex ?? parent?.paginationController?.currentChapterIndex ?? 0
        let mode = resolvedLayoutMode().rawValue
        let theme = currentTheme ?? "light"
        let generation = currentBookGeneration
        let js = """
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        window.__ttPager.applyDarkThemeContrast('\(theme)' === 'dark');
        window.__ttPager.relayout('anchor', \(ratio), \(anchorIdx), null, \(charOff), '\(mode)');
        """
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get()) else { return }
            self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
        }
    }

    public func jumpToPageInWebView(_ targetPage: Int, in webView: WKWebView) {
        let chapterIdx = parent?.chapterIndex ?? parent?.paginationController?.currentChapterIndex ?? 0
        let generation = currentBookGeneration
        let js = """
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        window.__ttPager.goToPage(\(targetPage));
        """
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get()) else { return }
            self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
        }
    }

    public func scrollToFragmentAndSyncPager(_ fragment: String, in webView: WKWebView) {
        let escaped = fragment
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let chapterIdx = parent?.chapterIndex ?? parent?.paginationController?.currentChapterIndex ?? 0
        let mode = resolvedLayoutMode().rawValue
        let generation = currentBookGeneration
        let js = """
        (function() {
            var id = decodeURIComponent('\(escaped)');
            var el = document.getElementById(id) || document.getElementsByName(id)[0];
            if (el) {
                window.location.hash = '#' + id;
            }
            if (window.__ttPager) {
                return window.__ttPager.relayout('fragment', 0, -1, id, 0, '\(mode)');
            }
            if (el) { el.scrollIntoView(); }
            return null;
        })();
        """
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get()) else { return }
            self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
        }
    }
}
