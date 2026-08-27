// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit

/// Dedicated key-focusable borderless full-screen NSWindow supporting native ESC and space bar dismissals.
final class FullScreenMediaWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        // KeyCode 53 is ESC, KeyCode 49 is Space Bar (toggles media play/pause)
        if event.keyCode == 53 {
            FullScreenMediaWindowController.shared.dismiss()
        } else if event.keyCode == 49 {
            MediaPlaybackCoordinator.shared.triggerPlayPause()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Floating wrapper view providing a sleek dismiss overlay for fullscreen media playback.
struct FullScreenMediaWrapperView: View {
    let content: AnyView
    let onClose: () -> Void
    @State private var isHoveringClose: Bool = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Sleek Zen Floating Close Capsule
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("ESC")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(isHoveringClose ? 1.0 : 0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial.opacity(0.85))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(isHoveringClose ? 0.4 : 0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .padding(24)
            .opacity(isHoveringClose ? 1.0 : 0.75)
            .onHover { isHoveringClose = $0 }
            .help("Close Fullscreen Preview (ESC)")
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// Immersive full-screen presentation window controller overriding system Dock and menu bar.
@MainActor
public final class FullScreenMediaWindowController {
    public static let shared = FullScreenMediaWindowController()
    
    private var window: FullScreenMediaWindow?
    private var previousPresentationOptions: NSApplication.PresentationOptions = []
    private var onDismissHandler: (() -> Void)? = nil
    
    private init() {}
    
    public func present(view: AnyView, onDismiss: (() -> Void)? = nil) {
        if window != nil {
            dismiss()
        }
        
        self.onDismissHandler = onDismiss
        
        guard let screen = NSScreen.main else { return }
        
        let win = FullScreenMediaWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .floating
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = false
        
        let wrapper = FullScreenMediaWrapperView(
            content: view,
            onClose: { [weak self] in
                self?.dismiss()
            }
        )
        win.contentView = NSHostingView(rootView: wrapper)
        
        self.previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .autoHideMenuBar]
        
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.becomeKey()
    }
    
    public func dismiss() {
        guard let win = window else { return }
        win.orderOut(nil)
        self.window = nil
        NSApp.presentationOptions = previousPresentationOptions
        onDismissHandler?()
        onDismissHandler = nil
    }
    
    public func update(view: AnyView) {
        guard let win = window else { return }
        let wrapper = FullScreenMediaWrapperView(
            content: view,
            onClose: { [weak self] in
                self?.dismiss()
            }
        )
        if let hostingView = win.contentView as? NSHostingView<FullScreenMediaWrapperView> {
            hostingView.rootView = wrapper
        } else {
            win.contentView = NSHostingView(rootView: wrapper)
        }
    }
    
    public var isPresenting: Bool {
        return window != nil
    }
}
