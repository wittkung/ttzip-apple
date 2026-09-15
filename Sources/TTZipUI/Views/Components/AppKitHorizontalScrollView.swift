// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import QuartzCore

/// AppKit native horizontal scroll container providing trackpad gesture axis arbitration,
/// elastic edge bouncing, and smooth programmatic navigation.
public struct AppKitHorizontalScrollView<Content: View>: NSViewRepresentable {
    private let scrollToTrailingTrigger: Int
    private let content: Content
    
    public init(
        scrollToTrailingTrigger: Int = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollToTrailingTrigger = scrollToTrailingTrigger
        self.content = content()
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        
        let container = FlippedContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        scrollView.documentView = container
        
        let minWidthConstraint = container.widthAnchor.constraint(greaterThanOrEqualTo: clipView.widthAnchor)
        minWidthConstraint.priority = .defaultLow
        
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: clipView.topAnchor),
            container.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            minWidthConstraint
        ])
        
        context.coordinator.setup(scrollView: scrollView)
        return scrollView
    }
    
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let container = nsView.documentView as? FlippedContainerView,
           let hostingView = container.subviews.first as? NSHostingView<Content> {
            hostingView.rootView = content
            hostingView.invalidateIntrinsicContentSize()
        }
        context.coordinator.update(scrollView: nsView, trigger: scrollToTrailingTrigger)
    }
    
    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cleanup()
    }
    
    @MainActor
    public final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private var eventMonitor: Any?
        private var isTrackingHorizontalSwipe = false
        private var lastTrigger: Int?
        
        func setup(scrollView: NSScrollView) {
            self.scrollView = scrollView
            setupEventMonitor(for: scrollView)
        }
        
        func update(scrollView: NSScrollView, trigger: Int) {
            self.scrollView = scrollView
            setupEventMonitor(for: scrollView)
            
            if let last = lastTrigger {
                if trigger != last {
                    lastTrigger = trigger
                    DispatchQueue.main.async { [weak self, weak scrollView] in
                        guard let self = self, let scrollView = scrollView else { return }
                        self.scrollToTrailingAnimated(scrollView: scrollView)
                    }
                }
            } else {
                lastTrigger = trigger
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self = self, let scrollView = scrollView else { return }
                    self.scrollToTrailingAnimated(scrollView: scrollView)
                }
            }
        }
        
        private func setupEventMonitor(for scrollView: NSScrollView) {
            guard eventMonitor == nil else { return }
            
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scrollView] event in
                guard let self = self, let scrollView = scrollView, scrollView.window != nil else {
                    return event
                }
                
                let locationInWindow = event.locationInWindow
                let pointInScrollView = scrollView.convert(locationInWindow, from: nil)
                guard scrollView.bounds.contains(pointInScrollView) else {
                    return event
                }
                
                let deltaX = abs(event.scrollingDeltaX)
                let deltaY = abs(event.scrollingDeltaY)
                
                if event.phase == .began || event.phase == .mayBegin {
                    self.isTrackingHorizontalSwipe = deltaX > deltaY
                }
                
                if self.isTrackingHorizontalSwipe {
                    scrollView.scrollWheel(with: event)
                    if event.phase == .ended || event.phase == .cancelled {
                        self.isTrackingHorizontalSwipe = false
                    } else if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                        self.isTrackingHorizontalSwipe = false
                    }
                    return nil
                } else {
                    if event.phase == .ended || event.phase == .cancelled {
                        self.isTrackingHorizontalSwipe = false
                    }
                    return event
                }
            }
        }
        
        public func scrollToTrailingAnimated(scrollView: NSScrollView? = nil) {
            let sv = scrollView ?? self.scrollView
            guard let sv = sv, let documentView = sv.documentView else { return }
            let clipView = sv.contentView
            let docWidth = documentView.bounds.width
            let clipWidth = clipView.bounds.width
            
            let targetX: CGFloat
            if docWidth <= clipWidth + 0.5 {
                targetX = 0
            } else {
                targetX = max(0, docWidth - clipWidth)
            }
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clipView.animator().setBoundsOrigin(NSPoint(x: targetX, y: 0))
            } completionHandler: {
                Task { @MainActor in
                    sv.reflectScrolledClipView(clipView)
                }
            }
        }
        
        func cleanup() {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            isTrackingHorizontalSwipe = false
        }
    }
}
