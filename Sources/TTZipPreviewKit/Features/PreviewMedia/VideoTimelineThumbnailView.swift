// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import SwiftUI
import TTKitDesign
import TTMediaKit

enum VideoTimelinePreviewLayout {
    static func center(track: CGRect, pointerX: CGFloat, preview: CGSize, viewport: CGSize) -> CGPoint {
        let inset: CGFloat = 8
        let halfWidth = preview.width / 2
        let halfHeight = preview.height / 2
        let left = inset + halfWidth
        let right = max(left, viewport.width - inset - halfWidth)
        let x = min(max(left, track.minX + pointerX), right)
        let above = track.minY - inset - halfHeight
        let below = track.maxY + inset + halfHeight
        let preferred = above - halfHeight >= inset ? above : below
        let top = inset + halfHeight
        let bottom = max(top, viewport.height - inset - halfHeight)
        return CGPoint(x: x, y: min(max(top, preferred), bottom))
    }
}

@MainActor
struct VideoTimelineThumbnailView: View {
    let time: CMTime
    let image: CGImage?
    let rotationDegrees: Int
    let track: CGRect
    let pointerX: CGFloat
    let viewport: CGSize

    var body: some View {
        let size = CGSize(width: 156, height: image == nil ? 28 : 128)
        VStack(spacing: 4) {
            if let image {
                thumbnail(image)
            }
            Text(formatVideoTimelineTimestamp(time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(6)
        .frame(width: size.width, height: size.height)
        .ttOverlayGlassPlate(cornerRadius: 7)
        .position(VideoTimelinePreviewLayout.center(
            track: track,
            pointerX: pointerX,
            preview: size,
            viewport: viewport
        ))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func thumbnail(_ image: CGImage) -> some View {
        let rotation = rotationDegrees
        let quarterTurn = [90, 270].contains(VideoContentGeometry.normalizedRotationDegrees(rotation))
        let oriented = quarterTurn
            ? CGSize(width: image.height, height: image.width)
            : CGSize(width: image.width, height: image.height)
        let size = CGSize(width: 144, height: 96)
        let fit = VideoContentGeometry.contentRect(inside: size, naturalVideoSize: oriented)
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: quarterTurn ? fit.height : fit.width, height: quarterTurn ? fit.width : fit.height)
            .rotationEffect(.degrees(Double(rotation)))
            .frame(width: size.width, height: size.height)
    }
}

func formatVideoTimelineTimestamp(_ time: CMTime) -> String {
    guard time.isNumeric,
          let totalSeconds = Int(exactly: max(0, CMTimeGetSeconds(time)).rounded(.down)) else {
        return "00:00"
    }
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}
