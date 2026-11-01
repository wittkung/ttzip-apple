// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Control handle location on the interactive crop box perimeter.
public enum CropHandle: CaseIterable, Identifiable, Sendable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight
    
    public var id: Self { self }
}

/// Shape rendering the dimming mask outside the active crop rectangle using even-odd path filling.
private struct CropMaskShape: Shape {
    var cropRect: CGRect
    
    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGSize.AnimatableData> {
        get {
            AnimatablePair(cropRect.origin.animatableData, cropRect.size.animatableData)
        }
        set {
            cropRect.origin.animatableData = newValue.first
            cropRect.size.animatableData = newValue.second
        }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(cropRect)
        return path
    }
}

public protocol TTMediaCropVideoStore {
    var videoSize: CGSize { get }
    var videoWidth: Int32 { get }
    var videoHeight: Int32 { get }
    var activeCropRect: CGRect? { get }
    func calculateVideoContentRect(in viewSize: CGSize, videoSize: CGSize) -> CGRect
    func projectToVideoPixelCoordinates(rect: CGRect, viewSize: CGSize, videoSize: CGSize) -> CGSize?
    func cancelCropSelection()
    func applyCrop(rect: CGRect, viewSize: CGSize, videoSize: CGSize)
    func resetCrop()
}

/// Masterpiece interactive visual crop box overlay view for video cropping.
///
/// Features 8 control handles, high-contrast dark scrim masking, 4px edge snapping,
/// real-time pixel dimension and aspect ratio badge, and floating control actions.
public struct InteractiveCropBoxOverlayView: View {
    public let playerStore: TTMediaCropVideoStore
    
    @State private var cropRect: CGRect = .zero
    @State private var dragStartRect: CGRect = .zero
    @State private var freeSelectionStart: CGPoint? = nil
    @State private var activeHandle: CropHandle? = nil
    @State private var isDraggingWholeBox: Bool = false
    @State private var hasInitializedRect: Bool = false
    
    public init(playerStore: TTMediaCropVideoStore) {
        self.playerStore = playerStore
    }
    
    public var body: some View {
        GeometryReader { proxy in
            let viewSize = proxy.size
            let videoSize = resolveEffectiveVideoSize()
            let videoContentRect = playerStore.calculateVideoContentRect(in: viewSize, videoSize: videoSize)
            
            ZStack {
                // 1. High-contrast semi-transparent outer dimming mask
                CropMaskShape(cropRect: cropRect)
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                
                // 2. Free selection gesture receiver over full video viewport
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .local)
                            .onChanged { value in
                                handleFreeSelectionChanged(value: value, bounds: videoContentRect)
                            }
                            .onEnded { _ in
                                handleFreeSelectionEnded()
                            }
                    )
                
                // 3. Active Crop Box Region & Grid
                if cropRect.width > 4 && cropRect.height > 4 {
                    cropBoxContent(videoContentRect: videoContentRect, viewSize: viewSize, videoSize: videoSize)
                }
                
                // 4. Bottom Floating Action Pill
                VStack {
                    Spacer()
                    floatingControlPill(viewSize: viewSize, videoSize: videoSize)
                        .padding(.bottom, 28)
                }
            }
            .onAppear {
                initializeCropRectIfNeeded(videoContentRect: videoContentRect)
            }
            .onChange(of: videoContentRect) { _, newRect in
                if !hasInitializedRect {
                    initializeCropRectIfNeeded(videoContentRect: newRect)
                }
            }
            .onExitCommand {
                playerStore.cancelCropSelection()
            }
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private func cropBoxContent(videoContentRect: CGRect, viewSize: CGSize, videoSize: CGSize) -> some View {
        ZStack {
            // Interior area supporting whole-box translation drag
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { value in
                            handleBoxDragChanged(value: value, bounds: videoContentRect)
                        }
                        .onEnded { _ in
                            isDraggingWholeBox = false
                        }
                )
            
            // Rule of thirds grid lines
            ruleOfThirdsGrid(rect: cropRect)
                .allowsHitTesting(false)
            
            // High-contrast dual-layer border
            Rectangle()
                .stroke(Color.black.opacity(0.4), lineWidth: 2.5)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)
            
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)
            
            // Real-time dimension and aspect ratio badge
            dimensionBadge(viewSize: viewSize, videoSize: videoSize)
            
            // 8 Interactive resize handles
            ForEach(CropHandle.allCases) { handle in
                handleGrabberView(handle: handle, bounds: videoContentRect)
            }
        }
    }
    
    @ViewBuilder
    private func ruleOfThirdsGrid(rect: CGRect) -> some View {
        Path { path in
            let w = rect.width
            let h = rect.height
            let x1 = rect.minX + w / 3.0
            let x2 = rect.minX + 2.0 * w / 3.0
            let y1 = rect.minY + h / 3.0
            let y2 = rect.minY + 2.0 * h / 3.0
            
            // Vertical lines
            path.move(to: CGPoint(x: x1, y: rect.minY))
            path.addLine(to: CGPoint(x: x1, y: rect.maxY))
            path.move(to: CGPoint(x: x2, y: rect.minY))
            path.addLine(to: CGPoint(x: x2, y: rect.maxY))
            
            // Horizontal lines
            path.move(to: CGPoint(x: rect.minX, y: y1))
            path.addLine(to: CGPoint(x: rect.maxX, y: y1))
            path.move(to: CGPoint(x: rect.minX, y: y2))
            path.addLine(to: CGPoint(x: rect.maxX, y: y2))
        }
        .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
    }
    
    @ViewBuilder
    private func handleGrabberView(handle: CropHandle, bounds: CGRect) -> some View {
        let pos = pointForHandle(handle, in: cropRect)
        
        ZStack {
            // Hit-target expansion circle
            Color.clear
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            
            // Visual handle pill
            Circle()
                .fill(Color.white)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1.0))
                .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
        }
        .position(pos)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { value in
                    handleResizeChanged(handle: handle, value: value, bounds: bounds)
                }
                .onEnded { _ in
                    activeHandle = nil
                }
        )
    }
    
    @ViewBuilder
    private func dimensionBadge(viewSize: CGSize, videoSize: CGSize) -> some View {
        let text = formatDimensionsText(viewSize: viewSize, videoSize: videoSize)
        let badgeY = cropRect.minY > 34 ? (cropRect.minY - 18) : (cropRect.minY + 22)
        
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 2)
            .position(x: cropRect.midX, y: badgeY)
            .allowsHitTesting(false)
    }
    
    @ViewBuilder
    private func floatingControlPill(viewSize: CGSize, videoSize: CGSize) -> some View {
        HStack(spacing: 10) {
            // Apply Crop
            Button {
                playerStore.applyCrop(rect: cropRect, viewSize: viewSize, videoSize: videoSize)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Apply Crop")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            
            // Reset to Fullscreen
            Button {
                playerStore.resetCrop()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                    Text("Reset")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.16))
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            
            // Cancel
            Button {
                playerStore.cancelCropSelection()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.16))
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 5)
        .fixedSize(horizontal: true, vertical: false)
    }
    
    // MARK: - Gesture Handling & Snapping
    
    private func initializeCropRectIfNeeded(videoContentRect: CGRect) {
        guard !hasInitializedRect, videoContentRect.width > 10, videoContentRect.height > 10 else {
            return
        }
        if let existing = playerStore.activeCropRect {
            let clamped = existing.intersection(videoContentRect)
            if !clamped.isNull, !clamped.isEmpty, clamped.width > 20, clamped.height > 20 {
                self.cropRect = clamped
            } else {
                let insetX = videoContentRect.width * 0.1
                let insetY = videoContentRect.height * 0.1
                self.cropRect = videoContentRect.insetBy(dx: insetX, dy: insetY).standardized
            }
        } else {
            // Default initial selection centered at 80% video viewport
            let insetX = videoContentRect.width * 0.1
            let insetY = videoContentRect.height * 0.1
            self.cropRect = videoContentRect.insetBy(dx: insetX, dy: insetY).standardized
        }
        self.hasInitializedRect = true
    }
    
    private func handleFreeSelectionChanged(value: DragGesture.Value, bounds: CGRect) {
        if freeSelectionStart == nil {
            let start = value.startLocation
            guard bounds.contains(start) else { return }
            freeSelectionStart = start
            dragStartRect = cropRect
        }
        
        guard let start = freeSelectionStart else { return }
        let current = value.location
        
        let minX = max(bounds.minX, min(start.x, current.x))
        let maxX = min(bounds.maxX, max(start.x, current.x))
        let minY = max(bounds.minY, min(start.y, current.y))
        let maxY = min(bounds.maxY, max(start.y, current.y))
        
        var rawRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rawRect = applyEdgeSnapping(to: rawRect, bounds: bounds)
        self.cropRect = rawRect.standardized
    }
    
    private func handleFreeSelectionEnded() {
        freeSelectionStart = nil
    }
    
    private func handleBoxDragChanged(value: DragGesture.Value, bounds: CGRect) {
        if !isDraggingWholeBox {
            isDraggingWholeBox = true
            dragStartRect = cropRect
        }
        
        let t = value.translation
        var newX = dragStartRect.minX + t.width
        var newY = dragStartRect.minY + t.height
        
        // 4px edge snapping against bounds
        newX = snap(value: newX, target: bounds.minX)
        newY = snap(value: newY, target: bounds.minY)
        
        let rightEdge = newX + dragStartRect.width
        if abs(rightEdge - bounds.maxX) <= 4.0 {
            newX = bounds.maxX - dragStartRect.width
        }
        
        let bottomEdge = newY + dragStartRect.height
        if abs(bottomEdge - bounds.maxY) <= 4.0 {
            newY = bounds.maxY - dragStartRect.height
        }
        
        newX = max(bounds.minX, min(newX, bounds.maxX - dragStartRect.width))
        newY = max(bounds.minY, min(newY, bounds.maxY - dragStartRect.height))
        
        self.cropRect = CGRect(origin: CGPoint(x: newX, y: newY), size: dragStartRect.size)
    }
    
    private func handleResizeChanged(handle: CropHandle, value: DragGesture.Value, bounds: CGRect) {
        if activeHandle == nil {
            activeHandle = handle
            dragStartRect = cropRect
        }
        
        let t = value.translation
        let minSize: CGFloat = 24.0
        var newRect = dragStartRect
        
        switch handle {
        case .topLeft:
            var minX = snap(value: dragStartRect.minX + t.width, target: bounds.minX)
            var minY = snap(value: dragStartRect.minY + t.height, target: bounds.minY)
            minX = max(bounds.minX, min(minX, dragStartRect.maxX - minSize))
            minY = max(bounds.minY, min(minY, dragStartRect.maxY - minSize))
            newRect = CGRect(x: minX, y: minY, width: dragStartRect.maxX - minX, height: dragStartRect.maxY - minY)
            
        case .top:
            var minY = snap(value: dragStartRect.minY + t.height, target: bounds.minY)
            minY = max(bounds.minY, min(minY, dragStartRect.maxY - minSize))
            newRect = CGRect(x: dragStartRect.minX, y: minY, width: dragStartRect.width, height: dragStartRect.maxY - minY)
            
        case .topRight:
            var maxX = snap(value: dragStartRect.maxX + t.width, target: bounds.maxX)
            var minY = snap(value: dragStartRect.minY + t.height, target: bounds.minY)
            maxX = min(bounds.maxX, max(maxX, dragStartRect.minX + minSize))
            minY = max(bounds.minY, min(minY, dragStartRect.maxY - minSize))
            newRect = CGRect(x: dragStartRect.minX, y: minY, width: maxX - dragStartRect.minX, height: dragStartRect.maxY - minY)
            
        case .left:
            var minX = snap(value: dragStartRect.minX + t.width, target: bounds.minX)
            minX = max(bounds.minX, min(minX, dragStartRect.maxX - minSize))
            newRect = CGRect(x: minX, y: dragStartRect.minY, width: dragStartRect.maxX - minX, height: dragStartRect.height)
            
        case .right:
            var maxX = snap(value: dragStartRect.maxX + t.width, target: bounds.maxX)
            maxX = min(bounds.maxX, max(maxX, dragStartRect.minX + minSize))
            newRect = CGRect(x: dragStartRect.minX, y: dragStartRect.minY, width: maxX - dragStartRect.minX, height: dragStartRect.height)
            
        case .bottomLeft:
            var minX = snap(value: dragStartRect.minX + t.width, target: bounds.minX)
            var maxY = snap(value: dragStartRect.maxY + t.height, target: bounds.maxY)
            minX = max(bounds.minX, min(minX, dragStartRect.maxX - minSize))
            maxY = min(bounds.maxY, max(maxY, dragStartRect.minY + minSize))
            newRect = CGRect(x: minX, y: dragStartRect.minY, width: dragStartRect.maxX - minX, height: maxY - dragStartRect.minY)
            
        case .bottom:
            var maxY = snap(value: dragStartRect.maxY + t.height, target: bounds.maxY)
            maxY = min(bounds.maxY, max(maxY, dragStartRect.minY + minSize))
            newRect = CGRect(x: dragStartRect.minX, y: dragStartRect.minY, width: dragStartRect.width, height: maxY - dragStartRect.minY)
            
        case .bottomRight:
            var maxX = snap(value: dragStartRect.maxX + t.width, target: bounds.maxX)
            var maxY = snap(value: dragStartRect.maxY + t.height, target: bounds.maxY)
            maxX = min(bounds.maxX, max(maxX, dragStartRect.minX + minSize))
            maxY = min(bounds.maxY, max(maxY, dragStartRect.minY + minSize))
            newRect = CGRect(x: dragStartRect.minX, y: dragStartRect.minY, width: maxX - dragStartRect.minX, height: maxY - dragStartRect.minY)
        }
        
        self.cropRect = newRect.standardized
    }
    
    private func snap(value: CGFloat, target: CGFloat, threshold: CGFloat = 4.0) -> CGFloat {
        abs(value - target) <= threshold ? target : value
    }
    
    private func applyEdgeSnapping(to rect: CGRect, bounds: CGRect) -> CGRect {
        var x = rect.minX
        var y = rect.minY
        var w = rect.width
        var h = rect.height
        
        if abs(x - bounds.minX) <= 4.0 { x = bounds.minX; w = rect.maxX - x }
        if abs(y - bounds.minY) <= 4.0 { y = bounds.minY; h = rect.maxY - y }
        if abs(rect.maxX - bounds.maxX) <= 4.0 { w = bounds.maxX - x }
        if abs(rect.maxY - bounds.maxY) <= 4.0 { h = bounds.maxY - y }
        
        return CGRect(x: x, y: y, width: max(4, w), height: max(4, h))
    }
    
    private func pointForHandle(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
    
    // MARK: - Metadata Helpers
    
    private func resolveEffectiveVideoSize() -> CGSize {
        if playerStore.videoSize.width > 0 && playerStore.videoSize.height > 0 {
            return playerStore.videoSize
        }
        let w = CGFloat(max(1, playerStore.videoWidth))
        let h = CGFloat(max(1, playerStore.videoHeight))
        return CGSize(width: w, height: h)
    }
    
    private func formatDimensionsText(viewSize: CGSize, videoSize: CGSize) -> String {
        guard let p = playerStore.projectToVideoPixelCoordinates(rect: cropRect, viewSize: viewSize, videoSize: videoSize) else {
            return "\(Int(cropRect.width)) × \(Int(cropRect.height))"
        }
        
        let ratio = Double(p.width) / Double(max(1, p.height))
        let ratioStr: String
        if abs(ratio - 16.0 / 9.0) < 0.02 {
            ratioStr = "16:9"
        } else if abs(ratio - 4.0 / 3.0) < 0.02 {
            ratioStr = "4:3"
        } else if abs(ratio - 2.39) < 0.04 || abs(ratio - 2.40) < 0.04 {
            ratioStr = "2.40:1"
        } else if abs(ratio - 21.0 / 9.0) < 0.03 {
            ratioStr = "21:9"
        } else if abs(ratio - 1.0) < 0.02 {
            ratioStr = "1:1"
        } else if abs(ratio - 9.0 / 16.0) < 0.02 {
            ratioStr = "9:16"
        } else {
            ratioStr = String(format: "%.2f:1", ratio)
        }
        
        return "\(p.width) × \(p.height) (\(ratioStr))"
    }
}
