// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

/// Transparent AppKit view overlay that intercepts right-click events to select the row
/// before the system presents the context menu, matching macOS Finder source list behavior.
public struct RightClickSelectRepresentable: NSViewRepresentable {
    public let onRightClick: () -> Void

    public init(onRightClick: @escaping () -> Void) {
        self.onRightClick = onRightClick
    }

    public func makeNSView(context: Context) -> RightClickInterceptingView {
        let view = RightClickInterceptingView()
        view.onRightClick = onRightClick
        return view
    }

    public func updateNSView(_ nsView: RightClickInterceptingView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    public final class RightClickInterceptingView: NSView {
        var onRightClick: (() -> Void)?

        public override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                return self
            }
            return nil
        }

        public override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
            super.rightMouseDown(with: event)
        }
    }
}

public extension View {
    /// Seamlessly activates selection when right-clicking the view before presenting a context menu.
    func onRightClickSelect(perform action: @escaping () -> Void) -> some View {
        overlay(RightClickSelectRepresentable(onRightClick: action))
    }
}
