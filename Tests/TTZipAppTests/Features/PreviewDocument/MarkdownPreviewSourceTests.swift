// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import enum TTI18nCore.AppLanguage
import class TTI18nUI.LocalizationState
import TTMediaKit
import TTZipApp
import TTZipUI
import XCTest
@testable import TTZipPreviewKit

@MainActor
final class MarkdownPreviewSourceTests: XCTestCase {
    func testTextReadingPreferencesLoadAndWriteExistingDefaultsKeys() throws {
        let suite = "ttzip.test.text-reading.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let modeKey = "ttmedia.preview.text.readingBackgroundMode"
        let wrapKey = "ttmedia.preview.text.softWrapEnabled"
        let initialAppAppearance = NSApp?.appearance

        let preferences = TTTextReadingPreferenceStore(defaults: defaults)
        XCTAssertEqual(preferences.mode, .fluidTransparent)
        XCTAssertTrue(preferences.isSoftWrapEnabled)
        preferences.mode = .fluidTransparent
        preferences.isSoftWrapEnabled = true
        XCTAssertNil(defaults.object(forKey: modeKey))
        XCTAssertNil(defaults.object(forKey: wrapKey))

        defaults.set("black", forKey: modeKey)
        defaults.set(false, forKey: wrapKey)
        let restored = TTTextReadingPreferenceStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .black)
        XCTAssertFalse(restored.isSoftWrapEnabled)

        restored.mode = .white
        XCTAssertEqual(defaults.string(forKey: modeKey), "white")
        let reloaded = TTTextReadingPreferenceStore(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .white)
        XCTAssertFalse(reloaded.isSoftWrapEnabled)

        reloaded.resetToDefault()
        XCTAssertEqual(reloaded.mode, .fluidTransparent)
        XCTAssertTrue(reloaded.isSoftWrapEnabled)
        XCTAssertEqual(defaults.string(forKey: modeKey), "fluidTransparent")
        XCTAssertEqual(defaults.object(forKey: wrapKey) as? Bool, true)
        XCTAssertEqual(NSApp?.appearance, initialAppAppearance)
    }

    func testTextReadingPreferencesSupportCustomStorageKeys() throws {
        let suite = "ttzip.test.text-reading.custom.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TTTextReadingPreferenceStore(
            defaults: defaults, storageKey: "mode", softWrapStorageKey: "wrap"
        )

        preferences.mode = .black
        preferences.isSoftWrapEnabled = false
        XCTAssertEqual(defaults.string(forKey: "mode"), "black")
        XCTAssertEqual(defaults.object(forKey: "wrap") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: TTTextReadingBackgroundMode.userDefaultsKey))
        XCTAssertNil(defaults.object(forKey: TTTextReadingPreferenceStore.softWrapUserDefaultsKey))
    }

    func testSourceModeFollowsAppColorSchemeAndReadingPreference() throws {
        try withIsolatedReadingPreferences { preferences in
            for appScheme in [ColorScheme.light, .dark] {
                for mode in TTTextReadingBackgroundMode.allCases {
                    preferences.mode = mode
                    try withHostedMarkdownSource(
                        "# Heading\n\nPlain body\n- item", width: 820, appScheme: appScheme,
                        preferences: preferences
                    ) { host in
                        let editor = try XCTUnwrap(findSourceEditor(in: host))
                        try assertSourceAppearance(editor, mode: mode, appScheme: appScheme)
                    }
                }
            }
        }
    }

    func testSourceModeUpdatesSoftWrapWithoutReplacingNativeEditor() throws {
        try withIsolatedReadingPreferences { preferences in
            preferences.isSoftWrapEnabled = false
            let markdown = "# Heading\n\n" + String(repeating: "A long line 中文 ⌘ ", count: 24)
            try withHostedMarkdownSource(
                markdown, width: 300, appScheme: .light, preferences: preferences
            ) { host in
                let editor = try XCTUnwrap(findSourceEditor(in: host))
                XCTAssertEqual(editor.string, markdown)
                XCTAssertFalse(editor.isEditable)
                XCTAssertEqual(editor.textContainer?.widthTracksTextView, false)
                XCTAssertTrue(editor.isHorizontallyResizable)

                preferences.isSoftWrapEnabled = true
                flushLayout(host)
                XCTAssertTrue(findSourceEditor(in: host) === editor)
                XCTAssertEqual(editor.textContainer?.widthTracksTextView, true)
                XCTAssertFalse(editor.isHorizontallyResizable)
                XCTAssertEqual(editor.string, markdown)
            }
        }
    }

    func testModeLabelsAndPreviewCopyFollowProductLanguage() {
        let state = AppLocalizationState.shared
        let original = state.currentLanguage
        defer { state.setLanguage(original) }

        for key in TTZipMarkdownHexPreviewLocaleKey.allCases {
            for language in [AppLanguage.en, .zhHans, .zhHant] {
                let text = key.fallbackTranslation(for: language)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key.rawValue)
            }
        }

        state.setLanguage(.zhHans)
        XCTAssertEqual(MarkdownPreviewMode.rich.localizedTitle, "富文本预览")
        XCTAssertEqual(MarkdownPreviewMode.source.localizedTitle, "源代码")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.lineCount(10), "10 行")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.wordCount(88), "88 词")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.charCount(360), "360 字符")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.text(.copyCodeButton), "复制")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.text(.copiedCodeButton), "已复制")

        state.setLanguage(.zhHant)
        XCTAssertEqual(MarkdownPreviewMode.rich.localizedTitle, "富文字預覽")
        XCTAssertEqual(MarkdownPreviewMode.source.localizedTitle, "原始碼")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.charCount(360), "360 字元")

        state.setLanguage(.en)
        XCTAssertEqual(MarkdownPreviewMode.rich.localizedTitle, "Rich Preview")
        XCTAssertEqual(MarkdownPreviewMode.source.localizedTitle, "Source Code")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.lineCount(10), "10 lines")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.wordCount(88), "88 words")
        XCTAssertEqual(TTZipMarkdownHexPreviewLocalization.charCount(360), "360 chars")
        XCTAssertEqual(MarkdownPreviewMode.rich.id, "Rich Preview")
        XCTAssertEqual(MarkdownPreviewMode.source.id, "Source Code")
        XCTAssertEqual(MarkdownPreviewMode.rich.icon, "doc.richtext.fill")
        XCTAssertEqual(MarkdownPreviewMode.source.icon, "curlybraces")
    }

    func testTextAndDocumentPreviewFallbackCopy() {
        let languages: [AppLanguage] = [.en, .zhHans, .zhHant]
        let examples: [(TextAndDocumentPreviewLocaleKey, [String])] = [
            (.truncationBannerFormat, [
                "Preview truncated to %@ for interactive responsiveness. Editing and in-place saving are disabled to protect the original file.",
                "为保证交互响应，预览已截断至 %@。已禁用编辑与原位保存以保护原始文件。",
                "為確保互動流暢度，預覽已截斷至 %@。已停用編輯與原位儲存以保護原始檔案。",
            ]),
            (.plainTextLabel, ["Plain Text", "纯文本", "純文字"]),
            (.fileSizeAndLinesFormat, ["%@ • %d lines", "%@ • %d 行", "%@ • %d 行"]),
            (.unsavedBadge, ["Unsaved", "未保存", "未儲存"]),
            (.savedBadge, ["Saved", "已保存", "已儲存"]),
            (.hideLineNumbersHelp, ["Hide Line Numbers", "隐藏行号", "隱藏行號"]),
            (.showLineNumbersHelp, ["Show Line Numbers", "显示行号", "顯示行號"]),
            (.copiedToClipboardHelp, ["Copied to clipboard", "已复制到剪贴板", "已拷貝到剪貼簿"]),
            (.copySourceCodeHelp, ["Copy Source Code", "复制源代码", "拷貝原始碼"]),
            (.saveButton, ["Save", "保存", "儲存"]),
            (.saveWithShortcutFormat, ["Save (%@)", "保存 (%@)", "儲存 (%@)"]),
            (.saveChangesHelpFormat, [
                "Save changes to local file (%@)", "保存更改到本地文件 (%@)", "儲存變更至本機檔案 (%@)",
            ]),
            (.loadingPreview, ["Loading...", "正在加载…", "正在載入…"]),
            (.selectFileToPreview, [
                "Select a file from the explorer to preview", "从文件列表中选择文件以预览", "從檔案列表中選擇檔案以預覽",
            ]),
            (.toggleFullscreenOrDoubleClickHelp, [
                "Toggle fullscreen preview (or double-click canvas)", "切换全屏预览（或双击画布）", "切換全螢幕預覽（或連按兩下畫布）",
            ]),
            (.softWrapLabel, ["Soft Wrap", "自动换行", "自動換行"]),
            (.enableSoftWrapHelp, ["Enable Soft Wrap", "开启自动换行", "開啟自動換行"]),
            (.disableSoftWrapHelp, ["Disable Soft Wrap (Horizontal Scroll)", "关闭自动换行（横向滚动）", "關閉自動換行（橫向捲動）"]),
            (.allowEditingButton, ["Allow Editing", "允许编辑", "允許編輯"]),
            (.allowEditingHelp, ["Allow editing this local file", "允许编辑此本地文件", "允許編輯此本機檔案"]),
        ]

        for (index, language) in languages.enumerated() {
            for key in TextAndDocumentPreviewLocaleKey.allCases {
                let text = key.fallbackTranslation(for: language)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key.rawValue)
            }
            for (key, translations) in examples {
                XCTAssertEqual(key.fallbackTranslation(for: language), translations[index], key.rawValue)
            }
        }
    }

    func testTextAndDocumentPreviewCopyUsesActiveLocalization() {
        let state = LocalizationState.shared
        for key in TextAndDocumentPreviewLocaleKey.allCases {
            XCTAssertEqual(TextAndDocumentPreviewLocalization.text(key), state.t(key), key.rawValue)
        }

        let formatExamples: [(TextAndDocumentPreviewLocaleKey, [CVarArg], String)] = [
            (.truncationBannerFormat, ["2 MB"], TextAndDocumentPreviewLocalization.truncationBanner()),
            (
                .encodingReadOnlyBannerFormat, ["GB18030"],
                TextAndDocumentPreviewLocalization.encodingReadOnlyBanner(encodingName: "GB18030")
            ),
            (
                .fileSizeAndLinesFormat, ["12 KB", 42],
                TextAndDocumentPreviewLocalization.fileSizeAndLines(sizeText: "12 KB", lineCount: 42)
            ),
            (.saveWithShortcutFormat, ["⌘S"], TextAndDocumentPreviewLocalization.saveWithShortcut()),
            (.saveChangesHelpFormat, ["⌘S"], TextAndDocumentPreviewLocalization.saveChangesHelp()),
            (
                .emptyFileFormat, ["TXT"],
                TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Empty file: TXT")
            ),
            (
                .permissionDeniedFormat, ["notes.txt"],
                TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Permission denied: notes.txt")
            ),
        ]
        for (key, arguments, result) in formatExamples {
            XCTAssertEqual(result, String(format: state.t(key), arguments: arguments), key.rawValue)
        }
        let detectorMessages: [(String, TextAndDocumentPreviewLocaleKey)] = [
            ("Loading...", .loadingPreview),
            ("Select a file from the explorer to preview", .selectFileToPreview),
            ("Archive container loaded. Open or extract to browse contents.", .archiveContainerLoadedMessage),
        ]
        for (message, key) in detectorMessages {
            XCTAssertEqual(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage(message), state.t(key))
        }
        XCTAssertEqual(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Unknown format"), "Unknown format")
    }

    func testGB18030DiskMarkdownKeepsOriginalEncodingAndBytes() throws {
        let directory = try makeTemporaryDirectory(prefix: "TTZipGB18030Markdown")
        let fileName = "gb18030_中文.md"
        let url = directory.appendingPathComponent(fileName)
        let markdown = "# GB18030 标题\n正文内容测试\n"
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let original = try XCTUnwrap(markdown.data(using: encoding))
        try original.write(to: url)
        let preview = TTZipMarkdownPreviewView(
            initialMarkdown: markdown, fileURL: url, fileName: fileName,
            resourceContext: .diskFile(url: url)
        )

        XCTAssertEqual(preview.sourceEncoding, .gb18030)
        XCTAssertEqual(preview.displayedByteCount, Int64(original.count))
        XCTAssertFalse(preview.canSaveInPlace)
        XCTAssertFalse(preview.saveFile(contentOverride: "# Overwrite"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func assertSourceAppearance(
        _ editor: LargeTextEditorTextView, mode: TTTextReadingBackgroundMode, appScheme: ColorScheme
    ) throws {
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let ruler = try XCTUnwrap(scrollView.verticalRulerView as? LineNumberRulerView)
        let storage = try XCTUnwrap(editor.textStorage)
        let bodyLocation = (editor.string as NSString).range(of: "Plain body").location
        XCTAssertNotEqual(bodyLocation, NSNotFound)
        guard bodyLocation != NSNotFound else { return }
        let foreground = try XCTUnwrap(storage.attribute(.foregroundColor, at: bodyLocation, effectiveRange: nil) as? NSColor)
        let palette = TTZipTextReadingAppearance.resolve(mode: mode, isDarkAppearance: appScheme == .dark)
        let context = "scheme=\(appScheme), mode=\(mode.rawValue)"

        XCTAssertEqual(ruler.readingPalette, palette, context)
        XCTAssertEqual(scrollView.drawsBackground, palette.drawsOpaqueBackground, context)
        XCTAssertEqual(editor.drawsBackground, palette.drawsOpaqueBackground, context)
        XCTAssertEqual(editor.backgroundColor, palette.nsCanvasBackgroundColor, context)
        XCTAssertEqual(editor.insertionPointColor, palette.nsInsertionPointColor, context)

        if palette.drawsOpaqueBackground {
            XCTAssertGreaterThanOrEqual(
                TTTextReadingPalette.contrastRatio(between: foreground, and: editor.backgroundColor), 4.5, context
            )
        } else if appScheme == .light {
            XCTAssertLessThan(TTTextReadingPalette.relativeLuminance(of: foreground), 0.15, context)
        } else {
            XCTAssertGreaterThan(TTTextReadingPalette.relativeLuminance(of: foreground), 0.75, context)
        }
    }

    private func withIsolatedReadingPreferences(_ body: (TTTextReadingPreferenceStore) throws -> Void) throws {
        let suite = "ttzip.test.markdown-source.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(TTTextReadingPreferenceStore(defaults: defaults))
    }

    private func withHostedMarkdownSource(
        _ markdown: String, width: CGFloat, appScheme: ColorScheme,
        preferences: TTTextReadingPreferenceStore, assertions: (NSView) throws -> Void
    ) throws {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: width, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }

        let root = TTZipMarkdownPreviewView(
            initialMarkdown: markdown, fileURL: nil, fileName: "README.md",
            resourceContext: .inMemory(fileName: "README.md"), initialMode: .source,
            readingPreferenceStore: preferences
        )
        .environment(\.colorScheme, appScheme)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 320)
        XCTAssertFalse(window.isVisible)
        flushLayout(host)
        try assertions(host)
    }

    private func findSourceEditor(in view: NSView) -> LargeTextEditorTextView? {
        if let editor = view as? LargeTextEditorTextView { return editor }
        for child in view.subviews {
            if let editor = findSourceEditor(in: child) { return editor }
        }
        return nil
    }

    private func flushLayout(_ host: NSView) {
        for _ in 0..<8 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }
}
