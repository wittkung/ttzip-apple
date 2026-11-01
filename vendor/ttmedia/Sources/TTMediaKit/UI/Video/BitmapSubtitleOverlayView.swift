// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

internal struct BitmapSubtitleOverlayView: View {
    let trackID: String?
    let activeCue: (index: Int, cue: BitmapSubtitleTrack.Cue)?
    let videoRect: CGRect?
    let viewportSize: CGSize
    let rotationDegrees: Int

    var body: some View {
        ZStack {
            if let activeCue, let videoRect, !activeCue.cue.compositions.isEmpty {
                BitmapCueImages(
                    cue: activeCue.cue,
                    videoRect: videoRect,
                    viewportSize: viewportSize,
                    rotationDegrees: VideoContentGeometry.normalizedRotationDegrees(rotationDegrees)
                )
                .id("\(trackID ?? ""):\(activeCue.index)")
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BitmapCueImages: View {
    let cue: BitmapSubtitleTrack.Cue
    let videoRect: CGRect
    let viewportSize: CGSize
    let rotationDegrees: Int

    @State private var images: [NSImage?] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(cue.compositions.indices, id: \.self) { index in
                if images.indices.contains(index), let image = images[index] {
                    let frame = imageFrame(for: cue.compositions[index])
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .rotationEffect(.degrees(Double(rotationDegrees)))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .onAppear {
            images = cue.compositions.map { NSImage(data: $0.pngBase64) }
        }
    }

    private func imageFrame(for image: BitmapSubtitleTrack.Composition) -> CGRect {
        let canvasWidth = CGFloat(cue.canvasWidth)
        let canvasHeight = CGFloat(cue.canvasHeight)
        let turned = rotationDegrees == 90 || rotationDegrees == 270
        let orientedWidth = turned ? canvasHeight : canvasWidth
        let orientedHeight = turned ? canvasWidth : canvasHeight
        let scaleX = videoRect.width / orientedWidth
        let scaleY = videoRect.height / orientedHeight
        let centerX = CGFloat(image.x) + CGFloat(image.width) / 2
        let centerY = CGFloat(image.y) + CGFloat(image.height) / 2
        let rotatedCenter: CGPoint
        switch rotationDegrees {
        case 90:
            rotatedCenter = CGPoint(x: canvasHeight - centerY, y: centerX)
        case 180:
            rotatedCenter = CGPoint(x: canvasWidth - centerX, y: canvasHeight - centerY)
        case 270:
            rotatedCenter = CGPoint(x: centerY, y: canvasWidth - centerX)
        default:
            rotatedCenter = CGPoint(x: centerX, y: centerY)
        }
        let width = CGFloat(image.width) * (turned ? scaleY : scaleX)
        let height = CGFloat(image.height) * (turned ? scaleX : scaleY)
        return CGRect(
            x: videoRect.minX + rotatedCenter.x * scaleX - width / 2,
            y: videoRect.minY + rotatedCenter.y * scaleY - height / 2,
            width: width,
            height: height
        )
    }
}
