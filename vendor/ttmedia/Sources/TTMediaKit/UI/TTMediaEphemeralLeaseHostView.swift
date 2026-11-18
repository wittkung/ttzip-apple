// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Declarative SwiftUI host wrapper that binds an ephemeral staged media lease to the lifecycle
/// of its rendered preview view. Automatically adopts any unclaimed lease on initialization
/// (covering both mounted and never-mounted views), rebinds on URL changes, and releases on
/// `onDisappear` while preserving staged media across fullscreen handoffs.
@MainActor
public struct TTMediaEphemeralLeaseHostView<Content: View>: View {
    public let url: URL
    public let isFullScreen: Bool
    private let content: () -> Content
    @State private var leaseBox: TTMediaEphemeralLeaseBox

    public init(
        url: URL,
        isFullScreen: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.url = url
        self.isFullScreen = isFullScreen
        self.content = content
        _leaseBox = State(initialValue: TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: url))
    }

    public var body: some View {
        content()
            .onAppear {
                leaseBox.bind(url: url, consumeFullscreenHandoff: isFullScreen)
            }
            .onChange(of: url) { _, newURL in
                leaseBox.bind(url: newURL, consumeFullscreenHandoff: isFullScreen)
            }
            .onDisappear {
                if isFullScreen {
                    TTMediaDetector.endFullscreenEphemeralHandoff(for: url)
                }
                leaseBox.release()
            }
    }
}
