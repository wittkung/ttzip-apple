// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import WebKit
import SwiftUI

// MARK: - Focus Container & Custom WKWebView for Focus, Arrow Keys & IME Routing

@MainActor
public final class EPUBReaderFocusContainerView: NSView {
    public var readerInstanceID: UUID = UUID()

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        TTPreviewKeyboardOwnershipCoordinator.shared.bindReaderViews(
            instanceID: readerInstanceID,
            webView: nil,
            containerView: self
        )
    }
}

public struct EPUBReaderFocusRegionBackground: NSViewRepresentable {
    public let instanceID: UUID

    public init(instanceID: UUID) {
        self.instanceID = instanceID
    }

    public func makeNSView(context: Context) -> EPUBReaderFocusContainerView {
        let view = EPUBReaderFocusContainerView()
        view.readerInstanceID = instanceID
        return view
    }

    public func updateNSView(_ nsView: EPUBReaderFocusContainerView, context: Context) {
        nsView.readerInstanceID = instanceID
    }
}

@MainActor
public final class EPUBReaderWKWebView: WKWebView {
    public var readerInstanceID: UUID = UUID()
    public weak var paginationController: EPUBPaginationController?
    public var onViewportResized: (@MainActor (CGSize) -> Void)?
    private var lastReportedSize: CGSize = .zero

    override public var acceptsFirstResponder: Bool {
        true
    }

    override public func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            TTPreviewKeyboardOwnershipCoordinator.shared.setReaderFocusState(
                instanceID: readerInstanceID,
                isFocused: true,
                source: .readingArea
            )
        }
        return accepted
    }

    override public func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            clearMarkedTextState()
        }
        return resigned
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        TTPreviewKeyboardOwnershipCoordinator.shared.bindReaderViews(
            instanceID: readerInstanceID,
            webView: self
        )
        TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionWindow(
            instanceID: readerInstanceID,
            window: window,
            windowNumber: window?.windowNumber,
            markFocused: false
        )
    }

    override public func mouseDown(with event: NSEvent) {
        TTPreviewKeyboardOwnershipCoordinator.shared.setReaderFocusState(
            instanceID: readerInstanceID,
            isFocused: true,
            source: .readingArea
        )
        if let win = window, win.firstResponder !== self,
           !((win.firstResponder as? NSView)?.isDescendant(of: self) == true) {
            win.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override public func setFrameSize(_ newSize: NSSize) {
        let oldSize = lastReportedSize
        super.setFrameSize(newSize)
        guard newSize.width > 40, newSize.height > 40 else { return }
        if abs(newSize.width - oldSize.width) > 1.0 || abs(newSize.height - oldSize.height) > 1.0 {
            lastReportedSize = newSize
            onViewportResized?(newSize)
        }
    }

    public func clearMarkedTextState() {
        TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionAppKitIMEState(
            instanceID: readerInstanceID,
            isIMEComposing: false
        )
    }

    public func isAppKitMarkedTextActive() -> Bool {
        if let selfClient = (self as AnyObject) as? NSTextInputClient,
           selfClient.hasMarkedText() {
            return true
        }
        if let responder = window?.firstResponder,
           responder !== self,
           let client = responder as? NSTextInputClient,
           client.hasMarkedText() {
            return true
        }
        return Self.subviewTreeHasMarkedText(in: self)
    }

    private static func subviewTreeHasMarkedText(in root: NSView) -> Bool {
        for subview in root.subviews {
            if let client = subview as? NSTextInputClient, client.hasMarkedText() {
                return true
            }
            if subviewTreeHasMarkedText(in: subview) {
                return true
            }
        }
        return false
    }

    override public func scrollWheel(with event: NSEvent) {
        // Paginated reading never exposes partial columns or inertial scrolling.
        guard paginationController?.layoutMode == .scrolling else { return }
        super.scrollWheel(with: event)
    }

    override public func keyDown(with event: NSEvent) {
        if isAppKitMarkedTextActive() {
            if event.keyCode == 53 {
                clearMarkedTextState()
                super.keyDown(with: event)
                return
            }
            TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionAppKitIMEState(
                instanceID: readerInstanceID,
                isIMEComposing: true
            )
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 123 || event.keyCode == 124 {
            let disposition = TTPreviewKeyboardOwnershipCoordinator.shared.handleOrBlockOuterHorizontalArrow(
                event: event,
                preferredInstanceID: readerInstanceID
            )
            if disposition == .consumedByPreviewOwner {
                return
            }
        }
        if event.keyCode == 125 || event.keyCode == 126 {
            let disposition = TTPreviewKeyboardOwnershipCoordinator.shared.handleOrBlockOuterVerticalArrow(
                event: event,
                preferredInstanceID: readerInstanceID
            )
            if disposition == .consumedByPreviewOwner {
                return
            }
        }
        super.keyDown(with: event)
    }
}
