// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import WebKit
import TTZipCore
import TTZipUI

public struct EPUBNativeWKWebView: NSViewRepresentable {
    public let chapterURL: URL
    public let baseDirectory: URL
    public let fontSize: Double
    public let fontStyle: String
    public let readerTheme: String
    
    public init(chapterURL: URL, baseDirectory: URL, fontSize: Double, fontStyle: String, readerTheme: String) {
        self.chapterURL = chapterURL
        self.baseDirectory = baseDirectory
        self.fontSize = fontSize
        self.fontStyle = fontStyle
        self.readerTheme = readerTheme
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let vfsHandler = TTZipVfsSchemeHandler(provider: TTZipArchiveVfsProvider.shared)
        config.setURLSchemeHandler(vfsHandler, forURLScheme: TTZipVfsSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        return webView
    }
    
    public func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        
        // Ensure baseURL has a trailing directory slash so relative paths (e.g. ./images/cover.jpg) resolve properly
        let resolvedBaseURL = chapterURL.hasDirectoryPath ? chapterURL : chapterURL.deletingLastPathComponent().appendingPathComponent("/")
        
        let fontFamilyCSS = resolveFontFamilyCSS(for: fontStyle)
        let escapedFontFamily = fontFamilyCSS.replacingOccurrences(of: "'", with: "\\'")
        
        // If chapter content for this URL is already loaded and baseURL is unchanged, avoid full reload
        let chapterChanged = (coordinator.lastLoadedChapterURL != chapterURL)
        if !chapterChanged && coordinator.lastLoadedChapterContent != nil {
            let fontSizeChanged = (coordinator.currentFontSize != CGFloat(fontSize))
            let themeChanged = (coordinator.currentTheme != readerTheme)
            let fontStyleChanged = (coordinator.currentFontStyle != fontStyle)
            
            if fontSizeChanged || themeChanged || fontStyleChanged {
                coordinator.currentFontSize = CGFloat(fontSize)
                coordinator.currentTheme = readerTheme
                coordinator.currentFontStyle = fontStyle
                
                let js = """
                document.documentElement.style.setProperty('--reader-font-size', '\(fontSize)pt');
                document.documentElement.style.setProperty('--reader-font-family', '\(escapedFontFamily)');
                document.body.className = 'theme-\(readerTheme)';
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            return
        }
        
        // Avoid duplicate concurrent background loads for the same in-flight URL
        if coordinator.isLoadingChapterURL == chapterURL {
            coordinator.currentFontSize = CGFloat(fontSize)
            coordinator.currentTheme = readerTheme
            coordinator.currentFontStyle = fontStyle
            return
        }
        
        coordinator.isLoadingChapterURL = chapterURL
        coordinator.lastLoadedChapterURL = chapterURL
        coordinator.currentFontSize = CGFloat(fontSize)
        coordinator.currentTheme = readerTheme
        coordinator.currentFontStyle = fontStyle
        
        let customCSS = buildCustomCSS(
            fontSize: fontSize,
            fontFamilyCSS: fontFamilyCSS,
            readerTheme: readerTheme
        )
        
        let url = chapterURL
        let baseDir = baseDirectory
        
        Task {
            let loadedHTML = await EPUBChapterContentLoaderActor.shared.loadChapter(at: url, customCSS: customCSS)
            await MainActor.run {
                coordinator.isLoadingChapterURL = nil
                guard coordinator.lastLoadedChapterURL == url else {
                    return
                }
                
                if let injectedHTML = loadedHTML {
                    coordinator.lastLoadedChapterContent = injectedHTML
                    coordinator.lastLoadedBaseURL = resolvedBaseURL
                    webView.loadHTMLString(injectedHTML, baseURL: resolvedBaseURL)
                } else if url.scheme == TTZipVfsSchemeHandler.scheme {
                    coordinator.lastLoadedChapterContent = url.absoluteString
                    coordinator.lastLoadedBaseURL = resolvedBaseURL
                    webView.load(URLRequest(url: url))
                } else if FileManager.default.fileExists(atPath: url.path) {
                    coordinator.lastLoadedChapterContent = url.path
                    coordinator.lastLoadedBaseURL = resolvedBaseURL
                    webView.loadFileURL(url, allowingReadAccessTo: baseDir)
                } else {
                    let title = url.lastPathComponent
                        .replacingOccurrences(of: ".xhtml", with: "")
                        .replacingOccurrences(of: ".html", with: "")
                    let placeholder = "\(customCSS)<div style='padding: 60px 20px; text-align: center;'><h2>\(title)</h2><p style='color: #8e8e93;'>Loading chapter resources...</p></div>"
                    coordinator.lastLoadedChapterContent = placeholder
                    coordinator.lastLoadedBaseURL = nil
                    webView.loadHTMLString(placeholder, baseURL: nil)
                }
            }
        }
    }
    
    private func resolveFontFamilyCSS(for style: String) -> String {
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
    
    private func buildCustomCSS(fontSize: Double, fontFamilyCSS: String, readerTheme: String) -> String {
        let initialBg: String
        let initialText: String
        switch readerTheme {
        case "sepia":
            initialBg = "#f8f1e3"
            initialText = "#433422"
        case "dark":
            initialBg = "#1a1a1a"
            initialText = "#e5e5e5"
        case "transparent":
            initialBg = "transparent"
            initialText = "currentColor"
        default:
            initialBg = "#ffffff"
            initialText = "#1c1c1e"
        }
        
        return """
        <style>
            :root {
                --reader-font-size: \(fontSize)pt;
                --reader-line-height: 1.7;
                --reader-font-family: \(fontFamilyCSS);
                --reader-bg: \(initialBg);
                --reader-text: \(initialText);
            }
            body {
                background-color: var(--reader-bg) !important;
                color: var(--reader-text) !important;
                font-family: var(--reader-font-family) !important;
                font-size: var(--reader-font-size) !important;
                line-height: var(--reader-line-height) !important;
                max-width: 720px !important;
                margin: 0 auto !important;
                padding: 40px 28px !important;
                box-sizing: border-box !important;
                word-wrap: break-word !important;
            }
            p {
                margin-bottom: 1.4em !important;
                text-indent: 2em !important;
            }
            img {
                max-width: 100% !important;
                height: auto !important;
                display: block !important;
                margin: 16px auto !important;
                border-radius: 6px !important;
            }
            body.theme-dark {
                background-color: #1a1a1a !important;
                color: #e5e5e5 !important;
            }
            body.theme-dark *:not(a):not(code):not(pre) {
                color: #e5e5e5 !important;
                background-color: transparent !important;
            }
            body.theme-sepia {
                background-color: #f8f1e3 !important;
                color: #433422 !important;
            }
            body.theme-sepia *:not(a):not(code):not(pre) {
                color: #433422 !important;
                background-color: transparent !important;
            }
            body.theme-light {
                background-color: #ffffff !important;
                color: #1c1c1e !important;
            }
            body.theme-light *:not(a):not(code):not(pre) {
                color: #1c1c1e !important;
                background-color: transparent !important;
            }
            body.theme-transparent {
                background-color: transparent !important;
                color: currentColor !important;
            }
            body.theme-transparent *:not(a):not(code):not(pre) {
                background-color: transparent !important;
            }
        </style>
        <script>
            (function() {
                var cls = 'theme-\(readerTheme)';
                if (document.body) {
                    document.body.className = cls;
                } else {
                    document.addEventListener('DOMContentLoaded', function() {
                        if (document.body) {
                            document.body.className = cls;
                        }
                    });
                }
            })();
        </script>
        """
    }
    
    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate {
        public var lastLoadedChapterURL: URL?
        public var lastLoadedChapterContent: String?
        public var lastLoadedBaseURL: URL?
        public var currentTheme: String?
        public var currentFontSize: CGFloat?
        public var currentFontStyle: String?
        public var isLoadingChapterURL: URL?
        
        public override init() {
            super.init()
        }
        
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let theme = currentTheme {
                let js = "if (document.body) { document.body.className = 'theme-\(theme)'; }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
}

/// Dedicated background actor for asynchronous non-blocking EPUB content loading.
public actor EPUBChapterContentLoaderActor {
    public static let shared = EPUBChapterContentLoaderActor()
    
    private init() {}
    
    public func loadChapter(at chapterURL: URL, customCSS: String) async -> String? {
        var rawHTML: String? = nil
        if chapterURL.scheme == TTZipVfsSchemeHandler.scheme {
            if let (data, _) = try? await TTZipArchiveVfsProvider.shared.loadResource(uri: chapterURL.absoluteString) {
                rawHTML = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            }
        } else {
            rawHTML = try? String(contentsOf: chapterURL, encoding: .utf8)
        }
        
        guard let html = rawHTML else { return nil }
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            var modifiedHTML = html
            modifiedHTML.insert(contentsOf: customCSS, at: range.lowerBound)
            return modifiedHTML
        } else {
            return customCSS + html
        }
    }
}
