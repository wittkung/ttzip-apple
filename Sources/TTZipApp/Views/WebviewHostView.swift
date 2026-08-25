// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import WebKit
import AppKit
import os.log

/// High-performance NSViewRepresentable wrapping the hardware-accelerated transparent WKWebView.
public struct WebviewHostView: NSViewRepresentable {
    private static let logger = Logger(subsystem: "com.ttzip.app", category: "WebviewHostView")
    
    public init() {}
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // Register custom scheme handler for local static bundle assets
        let distURL = Self.resolveDistURL()
        let schemeHandler = TTZipURLSchemeHandler(distFolderURL: distURL)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "ttzip-app")
        
        // Register asynchronous type-safe IPC Bridge handler
        config.userContentController.addScriptMessageHandler(
            TTZipBridgeRouter.shared,
            contentWorld: .page,
            name: "ttzipBridge"
        )
        
        // Enable Safari Web Inspector
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        #if os(macOS)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        
        // Initial URL loading from custom scheme
        let prodURL = URL(string: "ttzip-app://localhost/index.html")!
        let request = URLRequest(url: prodURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        webView.load(request)
        
        return webView
    }
    
    public func updateNSView(_ nsView: WKWebView, context: Context) {
        // No-op for high-performance zero-re-render stability
    }
    
    private static func resolveDistURL() -> URL {
        let fm = FileManager.default
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("dist"),
            Bundle.main.resourceURL?.appendingPathComponent("TTZipApp_TTZipApp.bundle/dist"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/dist"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TTZipApp_TTZipApp.bundle/dist"),
            URL(fileURLWithPath: "/Users/kevintung/Documents/dev/products/ttzip/apple/Sources/TTZipApp/Resources/dist"),
            URL(fileURLWithPath: "/Users/kevintung/Documents/dev/products/ttzip/frontend/dist")
        ].compactMap { $0 }
        
        for candidate in candidates {
            if fm.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
                logger.info("Resolved web dist assets at: \(candidate.path, privacy: .public)")
                return candidate
            }
        }
        
        return Bundle.main.resourceURL?.appendingPathComponent("dist") ?? URL(fileURLWithPath: "/tmp")
    }
    
    public final class Coordinator: NSObject, WKNavigationDelegate {
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Self.logger.info("WKWebView finished loading ttzip-app://localhost/index.html")
        }
        
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            Self.logger.error("WKWebView failed navigation: \(error.localizedDescription, privacy: .public)")
        }
        
        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            Self.logger.error("WKWebView failed provisional navigation: \(error.localizedDescription, privacy: .public)")
        }
        
        private static let logger = Logger(subsystem: "com.ttzip.app", category: "WebviewNavigation")
    }
}
