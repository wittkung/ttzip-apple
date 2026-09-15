// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI

/// Modern lightweight horizontal scroll container with programmatic trailing scroll support.
public struct AppKitHorizontalScrollView<Content: View>: View {
    private let scrollToTrailingTrigger: Int
    private let content: Content
    
    private static var trailingAnchorID: String { "ttzip_horizontal_scroll_trailing_anchor" }
    
    public init(
        scrollToTrailingTrigger: Int = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollToTrailingTrigger = scrollToTrailingTrigger
        self.content = content()
    }
    
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    content
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(Self.trailingAnchorID)
                }
            }
            .onChange(of: scrollToTrailingTrigger) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.trailingAnchorID, anchor: .trailing)
                }
            }
            .onAppear {
                if scrollToTrailingTrigger > 0 {
                    proxy.scrollTo(Self.trailingAnchorID, anchor: .trailing)
                }
            }
        }
    }
}
