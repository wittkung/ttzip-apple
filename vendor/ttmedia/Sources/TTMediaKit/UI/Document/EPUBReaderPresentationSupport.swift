// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

public struct EPUBReaderAppearance: Sendable {
    public struct Colors: Sendable {
        public let background: String
        public let text: String

        public init(background: String, text: String) {
            self.background = background
            self.text = text
        }
    }

    public struct LoadingPlaceholder: Sendable {
        let message: String
        let containerStyle: String
        let titleStyle: String
        let messageStyle: String

        public init(message: String, containerStyle: String, titleStyle: String, messageStyle: String) {
            self.message = message
            self.containerStyle = containerStyle
            self.titleStyle = titleStyle
            self.messageStyle = messageStyle
        }
    }

    private let light: Colors
    private let sepia: Colors
    private let dark: Colors
    private let transparent: Colors
    let themeRulesCSS: String
    let loadingPlaceholder: LoadingPlaceholder?

    /// Supply theme CSS and style values from the host's trusted presentation constants.
    public init(
        light: Colors,
        sepia: Colors,
        dark: Colors,
        transparent: Colors,
        themeRulesCSS: String,
        loadingPlaceholder: LoadingPlaceholder? = nil
    ) {
        self.light = light
        self.sepia = sepia
        self.dark = dark
        self.transparent = transparent
        self.themeRulesCSS = themeRulesCSS
        self.loadingPlaceholder = loadingPlaceholder
    }

    public static let neutral: Self = {
        let system = Colors(background: "Canvas", text: "CanvasText")
        return Self(
            light: system, sepia: system, dark: system,
            transparent: .init(background: "transparent", text: system.text),
            themeRulesCSS: ""
        )
    }()

    func colors(for theme: String) -> Colors {
        switch theme {
        case "sepia": return sepia
        case "dark": return dark
        case "transparent": return transparent
        default: return light
        }
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

    public static func buildCustomCSS(
        fontSize: Double,
        fontFamilyCSS: String,
        readerTheme: String,
        appearance: EPUBReaderAppearance = .neutral
    ) -> String {
        let colors = appearance.colors(for: readerTheme)
        let typography = buildBaseTypographyCSS(
            fontSize: fontSize,
            fontFamilyCSS: fontFamilyCSS,
            initialBg: colors.background,
            initialText: colors.text
        )
        return "<style>\n\(typography)\n\(appearance.themeRulesCSS)\n</style>"
    }
}
