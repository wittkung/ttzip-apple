// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit

public struct MainHostView: View {
    public init() {}

    public var body: some View {
        ZStack {
            // Native macOS Liquid Glass Material Backdrop
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // React 19 Frontend Webview Host
            WebviewHostView()
                .ignoresSafeArea()
        }
        .frame(minWidth: 800, minHeight: 520)
    }
}
