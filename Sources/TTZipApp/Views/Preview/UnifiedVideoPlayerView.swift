// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI

/// Unified zero-kickout in-app video player view delegating to native Metal EDR viewport.
public struct UnifiedVideoPlayerView: View {
    public let url: URL
    
    public init(url: URL) {
        self.url = url
    }
    
    public var body: some View {
        MPVMetalVideoPlayerView(url: url)
    }
}
