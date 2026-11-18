// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Strongly-typed descriptor for horizontal scroll targeting.
public struct HorizontalScrollTarget: Equatable, Sendable {
    public let id: String
    public let anchor: UnitPoint
    
    public init(id: String, anchor: UnitPoint = .trailing) {
        self.id = id
        self.anchor = anchor
    }
}

/// Modern lightweight horizontal scroll container with programmatic scroll targeting.
public struct AppKitHorizontalScrollView<Content: View>: View {
    private let scrollToTrailingTrigger: Int
    private let scrollTarget: HorizontalScrollTarget?
    private let content: Content
    
    private static var trailingAnchorID: String { "ttzip_horizontal_scroll_trailing_anchor" }
    
    public init(
        scrollToTrailingTrigger: Int = 0,
        scrollTarget: HorizontalScrollTarget? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollToTrailingTrigger = scrollToTrailingTrigger
        self.scrollTarget = scrollTarget
        self.content = content()
    }
    
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    content
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(Self.trailingAnchorID)
                }
                .background(ConfigureNSScrollView())
            }
            .scrollContentBackground(.hidden)
            .background(ConfigureNSScrollView())
            .onChange(of: scrollTarget) { _, newTarget in
                guard let target = newTarget else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
            }
            .onChange(of: scrollToTrailingTrigger) { oldValue, newValue in
                // Only scroll to trailing if no explicit scroll target is active AND column count strictly increased
                guard scrollTarget == nil else { return }
                guard newValue > oldValue, newValue > 1 else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.trailingAnchorID, anchor: .trailing)
                }
            }
            .onAppear {
                if let target = scrollTarget {
                    proxy.scrollTo(target.id, anchor: target.anchor)
                } else if scrollToTrailingTrigger > 1 {
                    proxy.scrollTo(Self.trailingAnchorID, anchor: .trailing)
                }
            }
        }
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
    private weak var cachedScrollView: NSScrollView?
    private var isConfigured: Bool = false

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            isConfigured = false
            cachedScrollView = nil
            return
        }
        configureOnce()
    }
    
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureOnce()
    }
    
    public override func layout() {
        super.layout()
    }
    
    public func configureTargetScrollView() {
        configureOnce()
    }
    
    public func configureEnclosingScrollView() {
        configureOnce()
    }
    
    private func configureOnce() {
        guard !isConfigured else { return }
        let target = cachedScrollView ?? findTargetScrollView()
        if let target {
            cachedScrollView = target
            applyClearConfiguration(to: target)
            isConfigured = true
        }
    }
    
    private func findTargetScrollView() -> NSScrollView? {
        if let sv = enclosingScrollView { return sv }
        if let siblings = superview?.subviews {
            for sub in siblings {
                if let sv = sub as? NSScrollView { return sv }
            }
        }
        if let parentSiblings = superview?.superview?.subviews {
            for sub in parentSiblings {
                if let sv = sub as? NSScrollView { return sv }
                for inner in sub.subviews {
                    if let sv = inner as? NSScrollView { return sv }
                }
            }
        }
        return nil
    }
    
    private func applyClearConfiguration(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        if let doc = scrollView.documentView {
            doc.wantsLayer = true
            doc.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
