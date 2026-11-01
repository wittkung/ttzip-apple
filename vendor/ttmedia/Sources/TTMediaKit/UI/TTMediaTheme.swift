// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Unified design tokens for TTMediaKit media playback viewports and controls.
/// Follows the MetastudyLine 4-layer optical design token standard.
public enum TTMediaTheme {
    // MARK: - Color Palette
    
    /// Kintsugi Gold (#BF9936 in light, #DEB84B in dark) — Primary accent for scrubbers and active controls.
    public static let kintsugiGold = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 222.0 / 255.0, green: 184.0 / 255.0, blue: 75.0 / 255.0, alpha: 1.0)
        } else {
            return NSColor(srgbRed: 191.0 / 255.0, green: 153.0 / 255.0, blue: 54.0 / 255.0, alpha: 1.0)
        }
    }))
    
    /// Bamboo Green (#789262 in light, #8FA876 in dark) — Active tracks and positive status indicators.
    public static let bambooGreen = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 143.0 / 255.0, green: 168.0 / 255.0, blue: 118.0 / 255.0, alpha: 1.0)
        } else {
            return NSColor(srgbRed: 120.0 / 255.0, green: 146.0 / 255.0, blue: 98.0 / 255.0, alpha: 1.0)
        }
    }))
    
    /// Cinnabar Red (#D15947) — Alerts, errors, and diagnostic warnings.
    public static let cinnabarRed = Color(red: 0.82, green: 0.35, blue: 0.28)
    
    /// Archival Amber (#D97706) — Secondary highlights.
    public static let archiveAmber = Color(red: 0.85, green: 0.47, blue: 0.15)
    
    /// Hairline specular border highlight (0.5pt).
    public static let hairlineBorder = Color.white.opacity(0.14)

    public enum Border {
        public static let subtle = Color.primary.opacity(0.12)
    }
    
    // MARK: - Radius Ramp
    
    public enum Radius {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 18
    }
    
    // MARK: - Spacing Ramp
    
    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 20
        public static let xl: CGFloat = 24
    }
    
    // MARK: - Typography Ramp
    
    public enum Typography {
        public static let title = Font.system(size: 15, weight: .medium, design: .default)
        public static let body = Font.system(size: 13, weight: .regular, design: .default)
        public static let caption = Font.system(size: 11, weight: .regular, design: .default)
        public static let monoCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
    }
    
    // MARK: - Motion Springs
    
    public enum Motion {
        public static let micro = Animation.spring(response: 0.22, dampingFraction: 0.85)
        public static let layout = Animation.spring(response: 0.35, dampingFraction: 0.82)
        public static let snap = Animation.spring(response: 0.28, dampingFraction: 0.78)
    }
}

// MARK: - Immersive Fullscreen Environment Key

private struct TTMediaImmersiveFullscreenKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct TTPreviewBottomTrailingReservedWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct TTTextFloatingToolsStateOverrideKey: EnvironmentKey {
    static let defaultValue: TTTextFloatingToolsPresentationState? = nil
}

extension EnvironmentValues {
    public var isImmersiveFullscreen: Bool {
        get { self[TTMediaImmersiveFullscreenKey.self] }
        set { self[TTMediaImmersiveFullscreenKey.self] = newValue }
    }

    /// Horizontal width (including gap) reserved by the outer host's bottom-trailing corner action button (`[ ↙↗ ]`).
    public var previewBottomTrailingReservedWidth: CGFloat {
        get { self[TTPreviewBottomTrailingReservedWidthKey.self] }
        set { self[TTPreviewBottomTrailingReservedWidthKey.self] = newValue }
    }

    /// Optional explicit presentation state override for content-first floating reading tools (`quietReading`, `controlsVisible`, `popoverExpanded`).
    public var textFloatingToolsStateOverride: TTTextFloatingToolsPresentationState? {
        get { self[TTTextFloatingToolsStateOverrideKey.self] }
        set { self[TTTextFloatingToolsStateOverrideKey.self] = newValue }
    }
}

@_exported import TTKitDesign

// MARK: - Media Notifications

extension Notification.Name {
    /// Notification posted to request or notify a media focus toggle (e.g. fullscreen / theater transition).
    public static let ttMediaToggleMediaFocusNotification = Notification.Name("TTMediaToggleMediaFocusNotification")
}

