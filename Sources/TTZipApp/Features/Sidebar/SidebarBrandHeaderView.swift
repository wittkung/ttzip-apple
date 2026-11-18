// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

/// Top-level sidebar 52pt header aligning with the global Y=52.0pt Kintsugi baseline.
/// Provides native window dragging across empty space and houses the left sidebar collapse button
/// to the right of the hoisted macOS traffic lights.
public struct SidebarBrandHeaderView: View {
    public let isIconRail: Bool
    public var onToggleSidebar: (() -> Void)?

    @State private var isToggleHovered: Bool = false
    private var l10n = AppLocalizationState.shared

    public init(
        isIconRail: Bool = false,
        onToggleSidebar: (() -> Void)? = nil
    ) {
        self.isIconRail = isIconRail
        self.onToggleSidebar = onToggleSidebar
    }

    public var body: some View {
        ZStack(alignment: .trailing) {
            TopBarWindowDragArea()

            if !isIconRail, let onToggleSidebar {
                HStack(spacing: 0) {
                    Spacer(minLength: 76)

                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(isToggleHovered ? Color.primary : Color.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(isToggleHovered ? 0.08 : 0.0))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isToggleHovered = $0 }
                    .ttButtonHelp(l10n.t(L10n.Menu.toggleSidebar) + " (⌃⌘S)")
                    .accessibilityLabel(l10n.t(L10n.Menu.toggleSidebar))
                    .accessibilityIdentifier("LeftSidebarCollapseButton")
                    .padding(.trailing, 10)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: TTZipTheme.Layout.headerBarHeight)
        .contentShape(Rectangle())
    }
}

/// Transparent AppKit surface initiating standard window drag (`performDrag(with:)`) on background mouse-down
/// while allowing interactive SwiftUI sibling controls placed above it to receive hit-testing normally.
public struct TopBarWindowDragArea: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        WindowDragOverlayNSView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    public final class WindowDragOverlayNSView: NSView {
        public override var mouseDownCanMoveWindow: Bool { true }

        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        public override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
