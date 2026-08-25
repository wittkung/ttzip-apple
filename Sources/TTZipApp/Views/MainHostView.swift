// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit

/// Top-level native host container integrating Apple Silicon Liquid Glass translucency with the React 19 webview.
public struct MainHostView: View {
    public init() {}
    
    public var body: some View {
        ZStack {
            // macOS Native Liquid Glass Vibrancy Layer
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            // Transparent React 19 WKWebView Presentation Layer
            WebviewHostView()
                .ignoresSafeArea()
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
