// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import SwiftUI

/// NSView subclass that intercepts right-click and Ctrl+Left-click to present a native AppKit context menu,
/// while allowing all primary clicks, hovers, and drag gestures to pass seamlessly to underlying SwiftUI views.
@MainActor
public final class NativeContextMenuBridgeView: NSView {
    public var onMenuWillOpen: (() -> Void)?
    public var targetProvider: (() -> TTZipContextMenuTarget)?
    
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isRightClick = event.type == .rightMouseDown
        let isCtrlLeftClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        guard isRightClick || isCtrlLeftClick else {
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
        } else {
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
    private let target: () -> TTZipContextMenuTarget
    
    public init(
        onMenuWillOpen: (() -> Void)? = nil,
        target: @escaping () -> TTZipContextMenuTarget
    ) {
        self.onMenuWillOpen = onMenuWillOpen
        self.target = target
    }
    
    public func makeNSView(context: Context) -> NativeContextMenuBridgeView {
        let view = NativeContextMenuBridgeView()
        view.onMenuWillOpen = onMenuWillOpen
        view.targetProvider = target
        return view
    }
    
    public func updateNSView(_ nsView: NativeContextMenuBridgeView, context: Context) {
        nsView.onMenuWillOpen = onMenuWillOpen
        nsView.targetProvider = target
    }
}

public extension View {
    /// Attaches a fully native macOS context menu to the view while preserving all tap and drag gestures.
    @MainActor
    func nativeContextMenu(
        onMenuWillOpen: (() -> Void)? = nil,
        target: @escaping () -> TTZipContextMenuTarget
    ) -> some View {
        self.overlay(
            NativeContextMenuBridge(onMenuWillOpen: onMenuWillOpen, target: target)
                .allowsHitTesting(true)
        )
    }
}
