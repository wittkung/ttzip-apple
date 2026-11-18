// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit

struct AudioPreviewHostView: View {
    let url: URL
    let fileName: String
    let resourceContext: TTPreviewResourceContext
    let isFullScreen: Bool

    var body: some View {
        TTMediaEphemeralLeaseHostView(url: url, isFullScreen: isFullScreen) {
            TTZipEmbeddedAudioPlayerView(url: url, fileName: fileName) { engine, title, artist, artwork in
                AudioMiniPlayerPresenter.shared.present(
                    store: engine,
                    title: title,
                    artist: artist,
                    artwork: artwork,
                    parentWindow: NSApp.keyWindow
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.previewResourceContext, resourceContext)
    }
}
