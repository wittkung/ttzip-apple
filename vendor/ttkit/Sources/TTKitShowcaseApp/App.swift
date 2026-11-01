// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for window in NSApp.windows {
                window.isOpaque = false
                window.backgroundColor = .clear
                if let content = window.contentView {
                    self.maskSidebarVisualEffectViews(in: content)
                }
            }
        }
    }

    @MainActor
    private func maskSidebarVisualEffectViews(in view: NSView) {
        if let effectView = view as? NSVisualEffectView, effectView.material == .sidebar || effectView.frame.width >= 200 {
            // Create a 1x1 fully clear transparent mask image
            let clearImage = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
                NSColor.clear.setFill()
                rect.fill()
                return true
            }
            effectView.maskImage = clearImage
        }
        for sub in view.subviews {
            maskSidebarVisualEffectViews(in: sub)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct TTKitShowcaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("TTKit Optical Architecture Showcase") {
            TTKitShowcaseView()
                .frame(minWidth: 1024, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
