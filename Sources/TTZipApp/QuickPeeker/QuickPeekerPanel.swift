// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Cocoa
import SwiftUI

/// Notification dispatched when spacebar is pressed inside the active QuickPeeker panel.
public extension Notification.Name {
    static let ttzipQuickPeekerTogglePlayback = Notification.Name("TTZipQuickPeekerTogglePlaybackNotification")
    static let ttzipQuickPeekerNextFile = Notification.Name("TTZipQuickPeekerNextFileNotification")
    static let ttzipQuickPeekerPreviousFile = Notification.Name("TTZipQuickPeekerPreviousFileNotification")
    static let ttzipQuickPeekerStepForward = Notification.Name("TTZipQuickPeekerStepForwardNotification")
    static let ttzipQuickPeekerStepBackward = Notification.Name("TTZipQuickPeekerStepBackwardNotification")
}

/// Floating, non-activating HUD panel hosting the QuickPeeker preview pipeline.
@MainActor
public final class QuickPeekerPanel: NSPanel {
    
    nonisolated(unsafe) private var localEventMonitor: Any?
    
    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable, .titled],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.minSize = NSSize(width: 600, height: 400)
        
        setupKeyEventHandler()
    }
    
    public override var canBecomeKey: Bool {
        return true
    }
    
    public override var canBecomeMain: Bool {
        return false
    }
    
    private func setupKeyEventHandler() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            
            // Do not intercept if a text field or search editor currently holds focus
            if let firstResponder = self.firstResponder {
                if (firstResponder.isKind(of: NSTextView.self) && (firstResponder as? NSTextView)?.isFieldEditor == true) || firstResponder is NSTextField {
                    if event.keyCode == 53 { // Allow Escape to exit field editor or close
                        self.hideAnimated()
                        return nil
                    }
                    return event
                }
            }
            
            switch event.keyCode {
            case 53: // Escape -> Close panel immediately
                self.hideAnimated()
                return nil
                
            case 49: // Spacebar -> Dispatch dedicated media play/pause toggle
                NotificationCenter.default.post(name: .ttzipQuickPeekerTogglePlayback, object: nil)
                return nil
                
            case 123: // Left Arrow
                if event.modifierFlags.contains(.command) {
                    NotificationCenter.default.post(name: .ttzipQuickPeekerPreviousFile, object: nil)
                } else {
                    NotificationCenter.default.post(name: .ttzipQuickPeekerStepBackward, object: nil)
                }
                return nil
                
            case 124: // Right Arrow
                if event.modifierFlags.contains(.command) {
                    NotificationCenter.default.post(name: .ttzipQuickPeekerNextFile, object: nil)
                } else {
                    NotificationCenter.default.post(name: .ttzipQuickPeekerStepForward, object: nil)
                }
                return nil
                
            default:
                return event
            }
        }
    }
    
    /// Displays the panel centered on screen with smooth alpha fade-in.
    public func showAnimated() {
        if !self.isVisible {
            self.alphaValue = 0.0
            self.center()
            self.orderFrontRegardless()
            self.makeKey()
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }
        } else {
            self.makeKey()
        }
    }
    
    /// Dismisses the panel with smooth alpha fade-out.
    public func hideAnimated(completion: (@MainActor () -> Void)? = nil) {
        guard self.isVisible else {
            completion?()
            return
        }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.alphaValue = 1.0
                completion?()
            }
        })
    }
    
    deinit {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
