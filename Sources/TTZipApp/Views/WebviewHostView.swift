// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import WebKit
import os.log

private let logger = Logger(subsystem: "com.ttzip.app", category: "WebviewHost")

public struct WebviewHostView: NSViewRepresentable {
    public init() {}

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let schemeHandler = TTZipURLSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "ttzip-app")

        let bridgeRouter = TTZipBridgeRouter()
        config.userContentController.add(bridgeRouter, name: "ttzipBridge")

        let webView = WKWebView(frame: .zero, configuration: config)
        bridgeRouter.setWebView(webView)
        webView.navigationDelegate = context.coordinator
        context.coordinator.parent = self

        // Allow Safari Web Inspector (Safari -> Develop -> TTZip)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        // Enable transparent background so macOS NSVisualEffectView shows through
        webView.setValue(false, forKey: "drawsBackground")

        let request = URLRequest(url: URL(string: "ttzip-app://localhost/index.html")!)
        webView.load(request)
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}

    public class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebviewHostView?

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("TTZip React 19 Frontend successfully rendered in WebKit Host.")
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.error("Provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
