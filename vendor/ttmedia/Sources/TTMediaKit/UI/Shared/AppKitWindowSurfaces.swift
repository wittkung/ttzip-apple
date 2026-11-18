// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

/// Non-interactive AppKit view subclass triggering window-drag movement on mouseDown events.
public struct WindowDragBackingView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> WindowDragResponderView {
        WindowDragResponderView()
    }

    public func updateNSView(_ nsView: WindowDragResponderView, context: Context) {}
}

public final class WindowDragResponderView: NSView {
    public override var mouseDownCanMoveWindow: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

public struct VisualEffectBlurRepresentable: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
