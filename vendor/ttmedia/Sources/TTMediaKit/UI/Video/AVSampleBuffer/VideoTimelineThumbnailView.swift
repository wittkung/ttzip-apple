// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0
// Doc twin: products/ttzip/docs/twin/preview/video-timeline-thumbnails.md

import SwiftUI
import TTKitDesign

struct VideoTimelineTrackAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

enum VideoTimelinePreviewLayout {
    static func center(track: CGRect, pointerX: CGFloat, preview: CGSize, viewport: CGSize) -> CGPoint {
        let inset: CGFloat = 8
        let halfWidth = preview.width / 2
        let x = min(max(inset + halfWidth, track.minX + pointerX), max(inset + halfWidth, viewport.width - inset - halfWidth))
        let above = track.minY - inset - preview.height / 2
        let below = track.maxY + inset + preview.height / 2
        let preferred = above - preview.height / 2 >= inset ? above : below
        let y = min(max(inset + preview.height / 2, preferred), max(inset + preview.height / 2, viewport.height - inset - preview.height / 2))
        return CGPoint(x: x, y: y)
    }
}

@MainActor
struct VideoTimelineThumbnailView: View {
    let image: CGImage?
    let timestamp: String
    let rotationDegrees: Int

    var body: some View {
        VStack(spacing: 4) {
            if let image {
                let quarterTurn = [90, 270].contains(VideoContentGeometry.normalizedRotationDegrees(rotationDegrees))
                let oriented = quarterTurn ? CGSize(width: image.height, height: image.width) : CGSize(width: image.width, height: image.height)
                let fit = VideoContentGeometry.contentRect(inside: CGSize(width: 144, height: 96), naturalVideoSize: oriented)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: quarterTurn ? fit.height : fit.width, height: quarterTurn ? fit.width : fit.height)
                    .rotationEffect(.degrees(Double(rotationDegrees)))
                    .frame(width: 144, height: 96)
            }
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(6)
        .frame(width: 156, height: image == nil ? 28 : 128)
        .ttOverlayGlassPlate(cornerRadius: 7)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
