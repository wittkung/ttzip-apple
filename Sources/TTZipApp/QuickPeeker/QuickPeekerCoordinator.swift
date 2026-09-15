// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Cocoa
import SwiftUI
import Carbon
import TTZipPreviewKit

/// Central coordinator managing QuickPeeker lifecycle, hotkey events, and panel warm pool.
@MainActor
public final class QuickPeekerCoordinator {
    
    public static let shared = QuickPeekerCoordinator()
    
    private var panel: QuickPeekerPanel?
    private var isStarted = false
    
    private init() {}
    
    /// Starts the coordinator and registers the global Shift + Space hotkey.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        
        // Pre-warm the HUD panel in advance to guarantee sub-10ms appearance
        warmUpPanel()
        
        // Register default hotkey Shift + Space (keyCode 49, shiftKey)
        GlobalHotKeyManager.shared.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(shiftKey)
        ) { [weak self] in
            self?.handleHotKeyTriggered()
        }
        
        // Listen for spacebar play/pause toggles dispatched by QuickPeekerPanel
        NotificationCenter.default.addObserver(
            forName: .ttzipQuickPeekerTogglePlayback,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                MPVMetalPlayerStore.shared.togglePlayPause()
            }
        }
        
        // Listen for step forward/backward events from arrow keys
        NotificationCenter.default.addObserver(
            forName: .ttzipQuickPeekerStepForward,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                MPVMetalPlayerStore.shared.seekBy(5.0)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .ttzipQuickPeekerStepBackward,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                MPVMetalPlayerStore.shared.seekBy(-5.0)
            }
        }
    }
    
    /// Pre-allocates and caches the floating HUD panel.
    private func warmUpPanel() {
        if panel == nil {
            panel = QuickPeekerPanel()
        }
    }
    
    /// Handles the Shift + Space global event.
    public func handleHotKeyTriggered() {
        guard let p = panel else {
            warmUpPanel()
            return
        }
        
        // If already visible, toggle it off
        if p.isVisible {
            hide()
            return
        }
        
        // Extract selected URLs from frontmost Finder
        let selectedURLs = FinderSelectionExtractor.getSelectedFileURLs()
        guard !selectedURLs.isEmpty else {
            return
        }
        
        present(urls: selectedURLs)
    }
    
    /// Presents the QuickPeeker panel for the given list of file URLs.
    public func present(urls: [URL]) {
        guard !urls.isEmpty else { return }
        warmUpPanel()
        guard let p = panel else { return }
        
        let hostView = QuickPeekerHostView(urls: urls) { [weak self] in
            self?.hide()
        }
        
        p.contentView = NSHostingView(rootView: hostView)
        p.showAnimated()
    }
    
    /// Hides and resets the QuickPeeker panel.
    public func hide() {
        panel?.hideAnimated { [weak self] in
            self?.panel?.contentView = nil
        }
    }
}
