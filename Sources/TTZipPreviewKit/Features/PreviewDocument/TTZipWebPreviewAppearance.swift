// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTMediaKit

enum TTZipWebPreviewAppearance {
    static let rendered = HTMLWKWebViewRepresentable.Appearance(
        unstyledHTMLCSS: htmlCSS(adaptsToDarkTheme: true),
        authorStyledHTMLCSS: htmlCSS(adaptsToDarkTheme: false),
        standaloneSVGExtensionCSS: """
        :root { color-scheme: light dark; }
        html, body { padding: 16px; color: #1c1c1e; }
        @media (prefers-color-scheme: dark) {
          html, body { color: #e5e5e7; }
        }
        """
    )

    private static func htmlCSS(adaptsToDarkTheme: Bool) -> String {
        let darkMediaRule: String
        if adaptsToDarkTheme {
            darkMediaRule = """
              @media (prefers-color-scheme: dark) {
                :where(html, body) {
                  background-color: #1e1e1e;
                  color: #e5e5e7;
                }
                :where(a) { color: #58a6ff; }
              }
            """
        } else {
            darkMediaRule = ""
        }
        return """
          :root { color-scheme: \(adaptsToDarkTheme ? "light dark" : "light"); }
          :where(html, body) {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            background-color: #ffffff;
            color: #1c1c1e;
          }
          :where(body) {
            margin: 0;
            padding: 16px;
            word-wrap: break-word;
          }
          :where(a) { color: #0969da; }
          :where(pre, code) {
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          }
          :where(img, svg, video, canvas) {
            max-width: 100%;
            height: auto;
          }
        \(darkMediaRule)
        """
    }
}
