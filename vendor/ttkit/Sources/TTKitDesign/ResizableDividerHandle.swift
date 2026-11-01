// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

/// Draggable vertical and horizontal divider handle controls.
/// Conforms to ttkit-ui-core specification with Kintsugi Gold hover glow and tactile grip pill.
public struct ResizableDividerHandle: View {
    public var topInset: CGFloat = 0
    public var onDragStart: (() -> Void)? = nil
    public let onDragChanged: (CGFloat) -> Void
    public var onDragEnd: (() -> Void)? = nil
    public var onDoubleClick: (() -> Void)? = nil
    
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var isCursorPushed = false
    @State private var startMouseX: CGFloat = 0
    
    public init(
        topInset: CGFloat = 0,
        onDragStart: (() -> Void)? = nil,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnd: (() -> Void)? = nil,
        onDoubleClick: (() -> Void)? = nil
    ) {
        self.topInset = topInset
        self.onDragStart = onDragStart
        self.onDragChanged = onDragChanged
        self.onDragEnd = onDragEnd
        self.onDoubleClick = onDoubleClick
    }
    
    public static let gutterWidth: CGFloat = 8.0
    
    public var body: some View {
        ZStack {
            // 1. Zen Gutter Line: Hairline border in rest state, glowing gold when hovered/dragged
            Rectangle()
                .fill(
                    isHovered || isDragging
                        ? TTKitTheme.kintsugiGold.opacity(0.55)
                        : UniversalTokens.Border.specularHairline
                )
                .frame(width: isHovered || isDragging ? 1.5 : UniversalTokens.Dimensions.hairlineWidth)
            
            // 2. Tactile floating grip pill
            if isHovered || isDragging {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                TTKitTheme.kintsugiGold,
                                TTKitTheme.kintsugiGold.opacity(0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 4, height: 24)
                    .shadow(color: TTKitTheme.kintsugiGold.opacity(0.35), radius: 3, y: 1)
                    .overlay {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(Color.white.opacity(0.95))
                                .frame(width: 1.5, height: 1.5)
                            Circle()
                                .fill(Color.white.opacity(0.95))
                                .frame(width: 1.5, height: 1.5)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, topInset)
        .frame(width: Self.gutterWidth)
        .overlay(alignment: .top) {
            if topInset > 0 {
                TTKintsugiDivider(.horizontal, falloff: false)
                    .offset(y: topInset)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHovered || isDragging)
        .onHover { hovering in
            isHovered = hovering
            updateCursor(hovering: hovering)
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    onDoubleClick?()
                }
        )
        .highPriorityGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in
                    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
                    let currentMouseX = NSEvent.mouseLocation.x
                    if !isDragging {
                        isDragging = true
                        startMouseX = currentMouseX
                        updateCursor(hovering: true)
                        onDragStart?()
                    }
                    let deltaX = currentMouseX - startMouseX
                    onDragChanged(deltaX)
                    #endif
                }
                .onEnded { _ in
                    isDragging = false
                    updateCursor(hovering: isHovered)
                    onDragEnd?()
                }
        )
        .onDisappear {
            resetCursor()
        }
    }

    private func updateCursor(hovering: Bool) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if hovering || isDragging {
            if !isCursorPushed {
                NSCursor.resizeLeftRight.push()
                isCursorPushed = true
            }
        } else {
            if isCursorPushed && !isDragging {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        #endif
    }

    private func resetCursor() {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
        #endif
    }
}
