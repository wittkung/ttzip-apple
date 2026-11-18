// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit

@MainActor
struct TTZipVideoSubtitleControls: View {
    @Environment(MediaControlsVisibility.self) private var visibility: MediaControlsVisibility?

    let context: VideoPlaybackControlsContext
    let isCompact: Bool
    @Binding var isStylePresented: Bool

    var body: some View {
        HStack(spacing: 2) {
            TTZipSubtitleTrackMenu(
                options: context.subtitles.options,
                selectedID: context.subtitles.selectedID,
                selectedSecondaryID: context.subtitles.selectedSecondaryID,
                hasExternalSubtitle: context.subtitles.name != nil,
                controlsVisibility: visibility,
                onSelect: { context.send(.subtitle(.select($0))) },
                onSelectSecondary: { context.send(.subtitle(.selectSecondary($0))) },
                onRemove: { context.send(.subtitle(.remove)) },
                onLoad: { context.send(.subtitle(.load)) },
                onShowStyle: { isStylePresented = true },
                onUserInteraction: { context.send(.interaction(.activity)) }
            )
            .frame(width: 24, height: 28)
            .ttButtonHelp(MediaLocalization.text(.subtitleHelp))

            if !isCompact {
                Button {
                    isStylePresented.toggle()
                    context.send(.interaction(.activity))
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain)
                .ttButtonHelp(MediaLocalization.text(.subtitleStyle))
            }
        }
        .popover(isPresented: $isStylePresented, arrowEdge: .top) {
            TTZipSubtitleQuickSettings(
                subtitleOptions: context.subtitles.options,
                selectedSubtitleID: context.subtitles.selectedID,
                selectedSecondarySubtitleID: context.subtitles.selectedSecondaryID,
                style: context.subtitles.style,
                activeSubtitleCodec: context.subtitles.activeCodec,
                onSelectSubtitle: { context.send(.subtitle(.select($0))) },
                onSelectSecondarySubtitle: { context.send(.subtitle(.selectSecondary($0))) },
                onLoadSubtitles: { context.send(.subtitle(.load)) },
                onUpdateStyle: { context.send(.subtitle(.updateStyle($0))) },
                onUserInteraction: { context.send(.interaction(.activity)) }
            )
        }
    }
}
