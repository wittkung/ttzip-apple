// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
    
    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        if axis == .horizontal {
            return true
        }
        return super.wantsForwardedScrollEvents(for: axis)
    }
}

final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
    
    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        if axis == .horizontal {
            return true
        }
        return super.wantsForwardedScrollEvents(for: axis)
    }
}

/// AppKit native autohiding overlay scroll view.
public struct AppKitMillerColumnScrollView<Content: View>: NSViewRepresentable {
    let content: Content
    
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    public func makeNSView(context: Context) -> AutoHidingOverlayScrollView {
        let scrollView = AutoHidingOverlayScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        
        let container = FlippedContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        scrollView.documentView = container
        
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: clipView.topAnchor),
            container.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clipView.trailingAnchor)
        ])
        
        return scrollView
    }
    
    public func updateNSView(_ nsView: AutoHidingOverlayScrollView, context: Context) {
        if let container = nsView.documentView as? FlippedContainerView,
           let hostingView = container.subviews.first as? NSHostingView<Content> {
            hostingView.rootView = content
        }
        if nsView.scrollerStyle != .overlay {
            nsView.scrollerStyle = .overlay
        }
        if !nsView.autohidesScrollers {
            nsView.autohidesScrollers = true
        }
    }
}

@MainActor
public final class AutoHidingOverlayScrollView: NSScrollView {
    public override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        if axis == .horizontal {
            return true
        }
        return super.wantsForwardedScrollEvents(for: axis)
    }
}

/// Clean AppKit NSScrollView configurator establishing standard overlay autohiding scrollers.
public struct ConfigureNSScrollView: NSViewRepresentable {
    public init() {}
    
    public func makeNSView(context: Context) -> SmartScrollerConfiguratorView {
        SmartScrollerConfiguratorView()
    }
    
    public func updateNSView(_ nsView: SmartScrollerConfiguratorView, context: Context) {
        nsView.configureEnclosingScrollView()
    }
}

@MainActor
public final class SmartScrollerConfiguratorView: NSView {
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEnclosingScrollView()
    }
    
    public func configureEnclosingScrollView() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
    }
}
