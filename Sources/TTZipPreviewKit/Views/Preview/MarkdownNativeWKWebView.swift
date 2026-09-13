// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import WebKit

/// Native WKWebView-based rich Markdown renderer with automatic system theme adaptation.
public struct MarkdownNativeWKWebView: NSViewRepresentable {
    public let markdownText: String
    public let baseURL: URL?
    
    public init(markdownText: String, baseURL: URL? = nil) {
        self.markdownText = markdownText
        self.baseURL = baseURL
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        loadRenderedHTML(in: webView)
        return webView
    }
    
    public func updateNSView(_ webView: WKWebView, context: Context) {
        loadRenderedHTML(in: webView)
    }
    
    private func loadRenderedHTML(in webView: WKWebView) {
        let htmlBody = TTZipMarkdownParser.parseToHTML(markdown: markdownText)
        let fullHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                :root {
                    color-scheme: light dark;
                    --text-color: #1d1d1f;
                    --heading-color: #111111;
                    --accent-color: #2ecc71;
                    --code-bg: rgba(128, 128, 128, 0.12);
                    --border-color: rgba(128, 128, 128, 0.22);
                    --blockquote-bg: rgba(46, 204, 113, 0.06);
                    --table-stripe: rgba(128, 128, 128, 0.04);
                    --link-color: #007aff;
                }
                @media (prefers-color-scheme: dark) {
                    :root {
                        --text-color: #e5e5ea;
                        --heading-color: #ffffff;
                        --accent-color: #30d158;
                        --code-bg: rgba(255, 255, 255, 0.10);
                        --border-color: rgba(255, 255, 255, 0.15);
                        --blockquote-bg: rgba(48, 209, 88, 0.08);
                        --table-stripe: rgba(255, 255, 255, 0.04);
                        --link-color: #0a84ff;
                    }
                }
                html, body {
                    background-color: transparent !important;
                }
                body {
                    color: var(--text-color);
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Segoe UI", sans-serif;
                    font-size: 14px;
                    line-height: 1.65;
                    padding: 24px 36px;
                    margin: 0 auto;
                    max-width: 880px;
                    word-wrap: break-word;
                }
                h1, h2, h3, h4, h5, h6 {
                    color: var(--heading-color);
                    font-weight: 700;
                    margin-top: 1.4em;
                    margin-bottom: 0.6em;
                    line-height: 1.25;
                }
                h1 { font-size: 24px; border-bottom: 1px solid var(--border-color); padding-bottom: 0.3em; }
                h2 { font-size: 20px; border-bottom: 1px solid var(--border-color); padding-bottom: 0.25em; }
                h3 { font-size: 16px; }
                h4 { font-size: 14px; }
                p { margin-top: 0; margin-bottom: 1em; }
                a { color: var(--link-color); text-decoration: none; }
                a:hover { text-decoration: underline; }
                strong { font-weight: 700; color: var(--heading-color); }
                em { font-style: italic; }
                hr { border: 0; height: 1px; background-color: var(--border-color); margin: 24px 0; }
                blockquote {
                    margin: 1em 0;
                    padding: 8px 16px;
                    background-color: var(--blockquote-bg);
                    border-left: 4px solid var(--accent-color);
                    border-radius: 0 6px 6px 0;
                }
                blockquote p:last-child { margin-bottom: 0; }
                code {
                    font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
                    font-size: 12.5px;
                    background-color: var(--code-bg);
                    padding: 2px 6px;
                    border-radius: 4px;
                }
                pre {
                    background-color: var(--code-bg);
                    padding: 14px 16px;
                    border-radius: 8px;
                    overflow-x: auto;
                    border: 1px solid var(--border-color);
                }
                pre code { background-color: transparent; padding: 0; font-size: 12.5px; line-height: 1.5; }
                ul, ol { padding-left: 24px; margin-top: 0; margin-bottom: 1em; }
                li { margin-bottom: 0.3em; }
                li.task-item { list-style: none; margin-left: -18px; }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 1.2em 0;
                    border: 1px solid var(--border-color);
                    border-radius: 6px;
                    overflow: hidden;
                }
                th, td { padding: 8px 12px; border: 1px solid var(--border-color); text-align: left; font-size: 13px; }
                th { background-color: var(--code-bg); font-weight: 600; color: var(--heading-color); }
                tr:nth-child(even) { background-color: var(--table-stripe); }
                img { max-width: 100%; height: auto; border-radius: 6px; margin: 1em 0; }
                @media (max-width: 520px) {
                    body { padding: 12px 14px; line-height: 1.5; font-size: 13px; }
                    h1 { font-size: 17px; margin-top: 1.0em; margin-bottom: 0.4em; }
                    h2 { font-size: 15px; margin-top: 0.9em; margin-bottom: 0.35em; }
                    h3 { font-size: 13.5px; margin-top: 0.8em; margin-bottom: 0.3em; }
                    h4 { font-size: 12.5px; }
                    p { margin-bottom: 0.75em; }
                    pre { padding: 8px 10px; border-radius: 6px; margin: 0.8em 0; }
                    blockquote { padding: 6px 10px; margin: 0.8em 0; }
                    ul, ol { padding-left: 18px; margin-bottom: 0.75em; }
                    th, td { padding: 6px 8px; font-size: 12px; }
                }
            </style>
        </head>
        <body>
            \(htmlBody)
        </body>
        </html>
        """
        webView.loadHTMLString(fullHTML, baseURL: baseURL)
    }
    
    @MainActor
    public class Coordinator: NSObject, WKNavigationDelegate {
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
