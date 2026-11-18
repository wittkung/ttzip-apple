// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import TTZipUI

@MainActor
struct ImagePreviewView: View {
    struct Identity: Hashable {
        let image: ObjectIdentifier
        let fallbackURL: URL?
    }

    @StateObject private var controller: TTImagePreviewController
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isHovered: Bool = false

    init(image: NSImage, fallbackURL: URL?) {
        _controller = StateObject(wrappedValue: TTImagePreviewController(
            resource: TTMediaDetector.imagePreviewResource(for: image, fallbackURL: fallbackURL)
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                zoomScrollCanvas(geometry: geometry)
                zoomControlsHUD
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .onAppear {
                scale = 1.0
                lastScale = 1.0
                offset = .zero
                lastOffset = .zero
                controller.startPlaybackIfNeeded()
            }
            .onDisappear {
                controller.dismantle()
            }
            .onChange(of: scale) { _, newScale in
                let backing = NSScreen.main?.backingScaleFactor ?? 2.0
                controller.updateViewport(
                    viewportSize: geometry.size,
                    backingScale: backing,
                    scale: newScale,
                    offset: offset
                )
            }
            .onChange(of: offset) { _, newOffset in
                guard scale > TTImageResolutionUpgrader.zoomUpgradeThreshold else { return }
                let backing = NSScreen.main?.backingScaleFactor ?? 2.0
                controller.updateViewport(
                    viewportSize: geometry.size,
                    backingScale: backing,
                    scale: scale,
                    offset: newOffset
                )
            }
            .onChange(of: geometry.size) { _, newSize in
                guard scale > TTImageResolutionUpgrader.zoomUpgradeThreshold else { return }
                let backing = NSScreen.main?.backingScaleFactor ?? 2.0
                controller.updateViewport(
                    viewportSize: newSize,
                    backingScale: backing,
                    scale: scale,
                    offset: offset
                )
            }
        }
    }

    // The controller's high-resolution image is a viewport composite; applying the zoom again would crop it.
    static func zoomCanvasSize(
        viewportSize: CGSize,
        scale: CGFloat,
        isHighResLoaded: Bool
    ) -> CGSize {
        guard !isHighResLoaded else {
            return viewportSize
        }
        return CGSize(
            width: max(viewportSize.width, viewportSize.width * scale),
            height: max(viewportSize.height, viewportSize.height * scale)
        )
    }

    private func zoomScrollCanvas(geometry: GeometryProxy) -> some View {
        let canvasSize = Self.zoomCanvasSize(
            viewportSize: geometry.size,
            scale: scale,
            isHighResLoaded: controller.isHighResLoaded
        )
        return ScrollView([.vertical, .horizontal], showsIndicators: scale > 1.05 && !controller.isHighResLoaded) {
            ZStack {
                Color.clear

                Image(nsImage: controller.displayedImage)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(controller.isHighResLoaded ? 1.0 : scale)
                    .offset(controller.isHighResLoaded ? .zero : offset)
                    .gesture(magnificationGesture)
                    .simultaneousGesture(dragGesture(geometry: geometry))
                    .onTapGesture(count: 2) {
                        handleDoubleTap()
                    }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .background(TTZipUI.ConfigureNSScrollView())
    }

    private var zoomControlsHUD: some View {
        HStack(spacing: 8) {
            Button(action: { stepZoom(by: -0.25) }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .ttButtonHelp("Zoom Out (-)")

            Text("\(Int(round(scale * 100)))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(TTZipTheme.bambooGreen)
                .frame(width: 44)

            Button(action: { stepZoom(by: 0.25) }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .ttButtonHelp("Zoom In (+)")

            if scale != 1.0 || offset != .zero {
                Divider()
                    .frame(height: 12)

                Button(action: { resetZoom() }) {
                    Text("100%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .ttButtonHelp("Reset 100%")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.thinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        )
        .overlay(
            Capsule()
                .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5)
        )
        .opacity((isHovered || scale != 1.0) ? 1.0 : 0.0)
        .animation(.ttMicro, value: isHovered)
        .animation(.ttMicro, value: scale)
        .padding(12)
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                let newScale = scale * delta
                if newScale < 1.0 {
                    scale = TTKitFluid.FluidGesturePhysics.rubberBandClamp(
                        offset: newScale,
                        range: 1.0...10.0,
                        dimension: 1.0,
                        factor: 0.55
                    )
                } else if newScale > 10.0 {
                    scale = TTKitFluid.FluidGesturePhysics.rubberBandClamp(
                        offset: newScale,
                        range: 1.0...10.0,
                        dimension: 2.0,
                        factor: 0.55
                    )
                } else {
                    scale = newScale
                }
            }
            .onEnded { _ in
                lastScale = 1.0
                if scale < 1.0 {
                    resetZoom()
                } else if scale > 10.0 {
                    withAnimation(.ttSnap) {
                        scale = 10.0
                    }
                }
            }
    }

    private func dragGesture(geometry: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                let maxOffsetX = max(0, (geometry.size.width * scale - geometry.size.width) / 2)
                let maxOffsetY = max(0, (geometry.size.height * scale - geometry.size.height) / 2)
                let rawX = lastOffset.width + value.translation.width
                let rawY = lastOffset.height + value.translation.height
                let clampedX = TTKitFluid.FluidGesturePhysics.rubberBandClamp(
                    offset: rawX,
                    range: -maxOffsetX...maxOffsetX,
                    dimension: max(1.0, geometry.size.width),
                    factor: 0.55
                )
                let clampedY = TTKitFluid.FluidGesturePhysics.rubberBandClamp(
                    offset: rawY,
                    range: -maxOffsetY...maxOffsetY,
                    dimension: max(1.0, geometry.size.height),
                    factor: 0.55
                )
                offset = CGSize(width: clampedX, height: clampedY)
            }
            .onEnded { value in
                handleDragEnded(value, geometry: geometry)
            }
    }

    private func handleDragEnded(_ value: DragGesture.Value, geometry: GeometryProxy) {
        guard scale > 1.0 else {
            withAnimation(.ttSnap) {
                offset = .zero
                lastOffset = .zero
            }
            return
        }
        let maxOffsetX = max(0, (geometry.size.width * scale - geometry.size.width) / 2)
        let maxOffsetY = max(0, (geometry.size.height * scale - geometry.size.height) / 2)
        let isBeyondX = offset.width < -maxOffsetX || offset.width > maxOffsetX
        let isBeyondY = offset.height < -maxOffsetY || offset.height > maxOffsetY

        if isBeyondX || isBeyondY {
            let targetX = min(max(offset.width, -maxOffsetX), maxOffsetX)
            let targetY = min(max(offset.height, -maxOffsetY), maxOffsetY)
            withAnimation(.ttSnap) {
                offset = CGSize(width: targetX, height: targetY)
                lastOffset = offset
            }
        } else {
            let velocityX = value.predictedEndTranslation.width - value.translation.width
            let velocityY = value.predictedEndTranslation.height - value.translation.height
            let projectedX = TTKitFluid.FluidGesturePhysics.projectMomentum(
                initialOffset: offset.width,
                velocity: velocityX * 10.0,
                decelerationRate: 0.998
            )
            let projectedY = TTKitFluid.FluidGesturePhysics.projectMomentum(
                initialOffset: offset.height,
                velocity: velocityY * 10.0,
                decelerationRate: 0.998
            )
            let settledX = min(max(projectedX, -maxOffsetX), maxOffsetX)
            let settledY = min(max(projectedY, -maxOffsetY), maxOffsetY)
            withAnimation(.ttLayout) {
                offset = CGSize(width: settledX, height: settledY)
                lastOffset = offset
            }
        }
    }

    private func handleDoubleTap() {
        if scale > 1.2 {
            resetZoom()
        } else {
            withAnimation(.ttSnap) {
                scale = 2.5
            }
        }
    }

    private func stepZoom(by delta: CGFloat) {
        withAnimation(.ttMicro) {
            scale = min(max(scale + delta, 0.5), 10.0)
            if scale <= 1.0 {
                offset = .zero
                lastOffset = .zero
            }
        }
    }

    private func resetZoom() {
        withAnimation(.ttSnap) {
            scale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }
}
