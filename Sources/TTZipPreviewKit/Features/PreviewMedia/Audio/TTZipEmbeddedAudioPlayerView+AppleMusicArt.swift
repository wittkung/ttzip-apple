// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit

extension TTZipEmbeddedAudioPlayerView {

    @ViewBuilder
    func artworkCardView(
        image: NSImage,
        size: CGFloat,
        cornerRadius: CGFloat,
        shadowRadius: CGFloat
    ) -> some View {
        let isPlaying = audioEngine.isPlaying
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.38), radius: shadowRadius, x: 0, y: shadowRadius * 0.5)
            .contentShape(Rectangle())
            .onTapGesture { audioEngine.togglePlayPause() }
            .ttButtonHelp(TTZipAudioPreviewLocalization.text(isPlaying ? .clickToPauseHelp : .clickToPlayHelp))
    }
}
