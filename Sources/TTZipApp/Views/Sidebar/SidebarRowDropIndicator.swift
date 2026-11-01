// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipUI

/// Insertion orientation for drag-and-drop reordering.
public enum SidebarDropPosition: Equatable, Sendable {
    case none
    case above
    case below
}

/// Geometric micro-rendering of the drag-and-drop reordering insertion hairline.
/// Employs a precision bamboo-green indicator with alignment circles and hairline.
public struct SidebarRowDropInsertionLine: View {
    public var color: Color = TTZipTheme.bambooGreen
    public var dotDiameter: CGFloat = 4.5
    public var lineHeight: CGFloat = 2.0
    public var horizontalPadding: CGFloat = 2.0

    public init(
        color: Color = TTZipTheme.bambooGreen,
        dotDiameter: CGFloat = 4.5,
        lineHeight: CGFloat = 2.0,
        horizontalPadding: CGFloat = 2.0
    ) {
        self.color = color
        self.dotDiameter = dotDiameter
        self.lineHeight = lineHeight
        self.horizontalPadding = horizontalPadding
    }

    public var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: dotDiameter, height: dotDiameter)
            Rectangle()
                .fill(color)
                .frame(height: lineHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, horizontalPadding)
        .allowsHitTesting(false)
    }
}

/// Geometric micro-rendering of the drag-hover highlight backdrop and specular border.
/// Highlighted when dropping files directly into a target folder row.
public struct SidebarRowDropBackdrop: View {
    public let isTargeted: Bool
    public var cornerRadius: CGFloat = 6.0
    public var fillColor: Color = TTZipTheme.bambooGreen.opacity(0.24)
    public var strokeColor: Color = TTZipTheme.bambooGreen.opacity(0.65)
    public var lineWidth: CGFloat = TTZipUniversalTokens.Border.width

    public init(
        isTargeted: Bool,
        cornerRadius: CGFloat = 6.0,
        fillColor: Color = TTZipTheme.bambooGreen.opacity(0.24),
        strokeColor: Color = TTZipTheme.bambooGreen.opacity(0.65),
        lineWidth: CGFloat = TTZipUniversalTokens.Border.width
    ) {
        self.isTargeted = isTargeted
        self.cornerRadius = cornerRadius
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.lineWidth = lineWidth
    }

    public var body: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: lineWidth)
                )
                .allowsHitTesting(false)
        }
    }
}

/// ViewModifier that coordinates insertion line overlays and targeted drop highlight backdrops.
public struct SidebarRowDropIndicatorModifier: ViewModifier {
    public let dropPosition: SidebarDropPosition
    public let isDropTargeted: Bool
    public var cornerRadius: CGFloat = 6.0

    public init(
        dropPosition: SidebarDropPosition,
        isDropTargeted: Bool,
        cornerRadius: CGFloat = 6.0
    ) {
        self.dropPosition = dropPosition
        self.isDropTargeted = isDropTargeted
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .overlay(
                SidebarRowDropBackdrop(
                    isTargeted: isDropTargeted && dropPosition == .none,
                    cornerRadius: cornerRadius
                )
            )
            .overlay(alignment: .top) {
                if dropPosition == .above {
                    SidebarRowDropInsertionLine()
                }
            }
            .overlay(alignment: .bottom) {
                if dropPosition == .below {
                    SidebarRowDropInsertionLine()
                }
            }
    }
}

extension View {
    /// Decorates a sidebar row with drop reordering insertion lines and drag-hover highlight backdrops.
    public func sidebarRowDropIndicator(
        dropPosition: SidebarDropPosition,
        isDropTargeted: Bool,
        cornerRadius: CGFloat = 6.0
    ) -> some View {
        modifier(
            SidebarRowDropIndicatorModifier(
                dropPosition: dropPosition,
                isDropTargeted: isDropTargeted,
                cornerRadius: cornerRadius
            )
        )
    }
}
