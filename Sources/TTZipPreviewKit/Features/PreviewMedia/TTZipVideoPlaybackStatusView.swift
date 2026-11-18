// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitDesign
import TTMediaKit

struct TTZipVideoPlaybackStatusView: View {
    let status: VideoPlaybackStatus

    var body: some View {
        switch status {
        case .hidden:
            EmptyView()
        case .loading:
            ProgressView(MediaLocalization.text(.loadingMedia))
                .padding()
                .ttOverlayGlassPlate(cornerRadius: 16)
        case .failed(let detail, let retry):
            VStack(spacing: 12) {
                Label(MediaLocalization.text(.playbackFailed), systemImage: "exclamationmark.triangle")
                if let detail {
                    Text(detail).font(.caption).textSelection(.enabled)
                }
                Button(MediaLocalization.text(.retry)) { retry() }
            }
            .padding()
            .ttOverlayGlassPlate(cornerRadius: 16)
            .padding()
        }
    }
}
