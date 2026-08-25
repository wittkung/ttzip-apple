// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import WebKit
import AppKit

/// High-performance NSViewRepresentable wrapping the hardware-accelerated transparent WKWebView.
public struct WebviewHostView: NSViewRepresentable {
    public init() {}
    
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // Register custom scheme handler for local static bundle assets
        let distURL = Bundle.main.resourceURL?.appendingPathComponent("dist") ??
                      Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/dist")
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
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        
        // Initial URL loading from custom scheme
        let prodURL = URL(string: "ttzip-app://localhost/index.html")!
        
        // Load production bundle
        let request = URLRequest(url: prodURL)
        webView.load(request)
        
        return webView
    }
    
    public func updateNSView(_ nsView: WKWebView, context: Context) {
        // No-op for high-performance zero-re-render stability
    }
}
