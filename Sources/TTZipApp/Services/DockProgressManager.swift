// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Dynamic macOS Dock Tile progress ring and badge orchestrator.
///
/// Draws a smooth circular progress indicator over the TTZip app icon with 2Hz throttling
/// and view reuse to eliminate synchronous XPC IPC blocking to the Dock process during high-speed compression tasks.
@MainActor
public final class DockProgressManager: NSObject {
    public static let shared = DockProgressManager()
    
    private var lastRenderTime: CFAbsoluteTime = 0
    private let minRenderInterval: CFAbsoluteTime = 0.5 // 2Hz throttle (0.5s interval)
    private var currentFraction: Double = 0.0
    private var activeTasksCount: Int = 0
    
    /// Reusable persistent tile view instance to eradicate per-frame view allocation.
    private lazy var tileView: DockProgressTileView = DockProgressTileView()
    
    private override init() {
        super.init()
    }
    
    /// Updates Dock progress and badge label with 2Hz throttling.
    public func updateProgress(fraction: Double, activeCount: Int) {
        self.currentFraction = max(0.0, min(1.0, fraction))
        self.activeTasksCount = activeCount
        
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRenderTime >= minRenderInterval || fraction >= 1.0 || activeCount == 0 else {
            return
        }
        lastRenderTime = now
        renderDockTile()
    }
    
    /// Clears Dock progress and resets icon to default.
    public func clearProgress() {
        self.currentFraction = 0.0
        self.activeTasksCount = 0
        guard let app = NSApplication.shared as NSApplication?, let dockTile = app.dockTile as NSDockTile? else {
            return
        }
        tileView.updateFraction(0.0)
        dockTile.contentView = nil
        dockTile.badgeLabel = nil
        dockTile.display()
    }
    
    private func renderDockTile() {
        guard let app = NSApplication.shared as NSApplication?, let dockTile = app.dockTile as NSDockTile? else {
            return
        }
        
        if activeTasksCount == 0 {
            dockTile.contentView = nil
            dockTile.badgeLabel = nil
            dockTile.display()
            return
        }
        
        dockTile.badgeLabel = "\(activeTasksCount)"
        
        tileView.frame = NSRect(x: 0, y: 0, width: dockTile.size.width, height: dockTile.size.height)
        if dockTile.contentView !== tileView {
            dockTile.contentView = tileView
        }
        tileView.updateFraction(currentFraction)
        dockTile.display()
    }
}

// MARK: - Reusable Custom Dock Tile View

private final class DockProgressTileView: NSView {
    private(set) var fraction: Double = 0.0
    
    init() {
        super.init(frame: .zero)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    func updateFraction(_ newFraction: Double) {
        if abs(fraction - newFraction) > 0.001 {
            self.fraction = newFraction
            self.needsDisplay = true
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Draw app icon base
        if let appIcon = NSApp.applicationIconImage {
            appIcon.draw(in: bounds)
        }
        
        guard fraction > 0.0 else { return }
        
        // Draw circular progress ring
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.38
        let lineWidth: CGFloat = max(4.0, bounds.width * 0.06)
        
        let trackPath = NSBezierPath()
        trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        NSColor.black.withAlphaComponent(0.4).setStroke()
        trackPath.lineWidth = lineWidth
        trackPath.stroke()
        
        let progressPath = NSBezierPath()
        let startAngle: CGFloat = 90.0
        let endAngle: CGFloat = 90.0 - CGFloat(fraction * 360.0)
        progressPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        
        NSColor.systemBlue.setStroke()
        progressPath.lineWidth = lineWidth
        progressPath.lineCapStyle = .round
        progressPath.stroke()
    }
}
