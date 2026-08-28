// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI

/// Draggable vertical and horizontal divider handle controls.
public struct ResizableDividerHandle: View {
    public var onDragStart: (() -> Void)? = nil
    public let onDragChanged: (CGFloat) -> Void
    public var onDragEnd: (() -> Void)? = nil
    
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var startMouseX: CGFloat = 0
    
    public init(onDragStart: (() -> Void)? = nil, onDragChanged: @escaping (CGFloat) -> Void, onDragEnd: (() -> Void)? = nil) {
        self.onDragStart = onDragStart
        self.onDragChanged = onDragChanged
        self.onDragEnd = onDragEnd
    }
    
    public static let gutterWidth: CGFloat = 8.0
    
    public var body: some View {
        ZStack {
            // 1. Zen Gutter: Transparent in rest state, glowing gold when hovered/dragged
            Rectangle()
                .fill(
                    isHovered || isDragging
                        ? TTZipTheme.kintsugiGold.opacity(0.55)
                        : Color.clear
                )
                .frame(width: 1.5)
            
            // 2. Elegant floating tactile grip pill
            if isHovered || isDragging {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    TTZipTheme.kintsugiGold,
                                    TTZipTheme.kintsugiGold.opacity(0.85)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 4, height: 24)
                        .shadow(color: TTZipTheme.kintsugiGold.opacity(0.35), radius: 3, y: 1)
                    
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
        .frame(width: Self.gutterWidth)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHovered || isDragging)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    let currentMouseX = NSEvent.mouseLocation.x
                    if !isDragging {
                        isDragging = true
                        startMouseX = currentMouseX
                        onDragStart?()
                    }
                    let deltaX = currentMouseX - startMouseX
                    onDragChanged(deltaX)
                }
                .onEnded { _ in
                    isDragging = false
                    onDragEnd?()
                }
        )
    }
}

public struct ResizableHorizontalDividerHandle: View {
    @Binding public var height: CGFloat
    public var minHeight: CGFloat = 100
    public var maxHeight: CGFloat = 500
    @State private var isHovered = false
    
    public init(height: Binding<CGFloat>, minHeight: CGFloat = 100, maxHeight: CGFloat = 500) {
        self._height = height
        self.minHeight = minHeight
        self.maxHeight = maxHeight
    }
    
    public var body: some View {
        ZStack {
            // 1. Subtle baseline hairline (1px)
            Rectangle()
                .fill(isHovered ? TTZipTheme.kintsugiGold.opacity(0.45) : Color.primary.opacity(0.08))
                .frame(height: 1)
            
            // 2. Elegant floating tactile grip pill
            if isHovered {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(TTZipTheme.kintsugiGold)
                        .frame(width: 22, height: 3.5)
                        .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                    
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 1.5, height: 1.5)
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 1.5, height: 1.5)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let newHeight = height + value.translation.height
                    height = min(max(newHeight, minHeight), maxHeight)
                }
        )
    }
}

public struct SidebarToggleButton: View {
    @Binding public var isSidebarVisible: Bool
    @State private var isHovered = false
    
    public init(isSidebarVisible: Binding<Bool>) {
        self._isSidebarVisible = isSidebarVisible
    }
    
    public var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isSidebarVisible.toggle()
            }
            isHovered = false
        }) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
                    .frame(width: 32, height: 32)
                
                Image(systemName: isSidebarVisible ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    .offset(x: isSidebarVisible ? -1 : 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
