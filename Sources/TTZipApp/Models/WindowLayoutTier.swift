// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CoreGraphics

/// Three-tier responsive window layout tier for macOS desktop ergonomics.
public enum WindowLayoutTier: String, CaseIterable, Equatable, Sendable {
    /// Compact mode: Total Width < 820pt (64pt icon track sidebar, inspector hidden, focus on main workspace)
    case compact
    /// Medium mode: 820pt <= Total Width < 1100pt (Standard desktop: 200pt navigation sidebar, on-demand docked right panel)
    case medium
    /// Expanded mode: Total Width >= 1100pt (Widescreen pro: 3 columns expanded, multi-level Miller columns side-by-side)
    case expanded
    
    /// Evaluates the layout tier given the total window width.
    public static func evaluate(width: CGFloat) -> WindowLayoutTier {
        if width < 820 { return .compact }
        if width < 1100 { return .medium }
        return .expanded
    }
}
