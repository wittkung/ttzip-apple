// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit

struct TTZipVideoPlaybackNoticesView: View {
    let notices: VideoPlaybackNotices
    let isFullScreen: Bool

    var body: some View {
        if notices.audioWarning != nil || notices.osdMessage != nil {
            VStack(alignment: .trailing, spacing: 8) {
                if let audioWarning = notices.audioWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.yellow)
                        Text(audioWarning)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial.opacity(0.82), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }

                if let osdMessage = notices.osdMessage {
                    Text(osdMessage)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial.opacity(0.75), in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, isFullScreen ? 56 : 16)
            .padding(.trailing, 18)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}
