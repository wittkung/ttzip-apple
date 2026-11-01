// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

/// NSView subclass that intercepts right-click, Ctrl+Left-click, and unmodified primary double-clicks,
/// while allowing all single primary clicks, modifier multi-select clicks, hovers, and drag gestures
/// to pass seamlessly to underlying SwiftUI views.
@MainActor
public final class NativeContextMenuBridgeView: NSView {
    /// Optional override for unit tests inspecting `hitTest(_:)` offscreen without `NSApp.sendEvent`.
    public static var testSimulatedCurrentEvent: NSEvent?

    public var onMenuWillOpen: (() -> Void)?
    public var onDoubleClick: (() -> Void)?
    public var targetProvider: (() -> TTZipContextMenuTarget)?

    public func shouldCaptureEvent(_ event: NSEvent) -> Bool {
        let isRightClick = event.type == .rightMouseDown
        let isCtrlLeftClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        let isUnmodifiedPrimaryMultiClick = (event.type == .leftMouseDown || event.type == .leftMouseUp)
            && event.clickCount >= 2
            && event.modifierFlags.intersection([.command, .shift, .control]).isEmpty
            && onDoubleClick != nil
        return isRightClick || isCtrlLeftClick || isUnmodifiedPrimaryMultiClick
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = Self.testSimulatedCurrentEvent ?? NSApp.currentEvent,
              shouldCaptureEvent(event) else {
            return nil
        }
        return super.hitTest(point)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        onMenuWillOpen?()
        guard let target = targetProvider?() else { return nil }
        return TTZipContextMenuBuilder.shared.buildMenu(for: target)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if let menu = self.menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = self.menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else if event.clickCount == 2,
                  event.modifierFlags.intersection([.command, .shift, .control]).isEmpty,
                  let onDoubleClick {
            onDoubleClick()
        } else if event.clickCount < 2 {
            super.mouseDown(with: event)
        }
    }

    public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard returnType == nil else {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
        guard let sendType = sendType else {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        let supportedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .string, .URL]
        if supportedTypes.contains(sendType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

// MARK: - NSServicesMenuRequestor

extension NativeContextMenuBridgeView: NSServicesMenuRequestor {
    nonisolated public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let target = MainActor.assumeIsolated { self.targetProvider?() }
        guard let target = target else { return false }
        switch target {
        case .singleItem(let url, _, _):
            pboard.clearContents()
            _ = pboard.writeObjects([url as NSURL])
            pboard.setString(url.path, forType: .string)
            return true

        case .multipleItems(let urls):
            pboard.clearContents()
            _ = pboard.writeObjects(urls.map { $0 as NSURL })
            pboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            return true

        case .virtualArchiveEntry(_, let subpath, _):
            pboard.clearContents()
            pboard.setString(subpath, forType: .string)
            return true

        case .columnBackground(let directoryURL):
            pboard.clearContents()
            _ = pboard.writeObjects([directoryURL as NSURL])
            pboard.setString(directoryURL.path, forType: .string)
            return true
        }
    }
}

/// SwiftUI wrapper for NativeContextMenuBridgeView.
@MainActor
public struct NativeContextMenuBridge: NSViewRepresentable {
    private let onMenuWillOpen: (() -> Void)?
    private let onDoubleClick: (() -> Void)?
    private let target: () -> TTZipContextMenuTarget

    public init(
        onMenuWillOpen: (() -> Void)? = nil,
        onDoubleClick: (() -> Void)? = nil,
        target: @escaping () -> TTZipContextMenuTarget
    ) {
        self.onMenuWillOpen = onMenuWillOpen
        self.onDoubleClick = onDoubleClick
        self.target = target
    }

    public func makeNSView(context: Context) -> NativeContextMenuBridgeView {
        let view = NativeContextMenuBridgeView()
        view.onMenuWillOpen = onMenuWillOpen
        view.onDoubleClick = onDoubleClick
        view.targetProvider = target
        return view
    }

    public func updateNSView(_ nsView: NativeContextMenuBridgeView, context: Context) {
        nsView.onMenuWillOpen = onMenuWillOpen
        nsView.onDoubleClick = onDoubleClick
        nsView.targetProvider = target
    }
}

public extension View {
    /// Attaches a fully native macOS context menu and optional primary double-click handler to the view
    /// while preserving all single-tap and drag gestures.
    @MainActor
    func nativeContextMenu(
        onMenuWillOpen: (() -> Void)? = nil,
        onDoubleClick: (() -> Void)? = nil,
        target: @escaping () -> TTZipContextMenuTarget
    ) -> some View {
        self.overlay(
            NativeContextMenuBridge(
                onMenuWillOpen: onMenuWillOpen,
                onDoubleClick: onDoubleClick,
                target: target
            )
            .allowsHitTesting(true)
        )
    }
}
