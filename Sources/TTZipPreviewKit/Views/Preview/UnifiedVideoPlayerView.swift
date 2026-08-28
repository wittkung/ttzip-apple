// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// Unified zero-kickout in-app video player view utilizing the high-performance libmpv Metal/EDR viewport.
/// Plays directly inside the right inspector side panel with hardware acceleration and Zen controls across all 16+ video formats.
public struct UnifiedVideoPlayerView: View {
    public let url: URL
    
    @State private var isSecurityScoped: Bool = false
    
    public init(url: URL) {
        self.url = url
    }
    
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            MPVMetalVideoPlayerView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            if url.startAccessingSecurityScopedResource() {
                isSecurityScoped = true
            }
        }
        .onDisappear {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
                isSecurityScoped = false
            }
        }
    }
}
