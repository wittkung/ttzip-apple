// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Three visual states for the content-first floating reading tools overlay.
/// Across all three states, the underlying document viewport frame, origin, height, scroll offset,
/// and first-line glyph position remain 100% invariant.
public enum TTTextFloatingToolsPresentationState: String, Sendable, Equatable, CaseIterable {
    /// Quiet reading state: content fills 100% of the window; reading tools cluster is hidden.
    case quietReading = "quietReading"
    /// Floating buttons visible: compact glass `[ Aa ⎘ ]` cluster appears at bottom-right next to `[ ↙↗ ]`.
    case controlsVisible = "controlsVisible"
    /// Tool popover expanded: compact glass card with theme, font size, line numbers, actions, and document badges opens above `[ Aa ⎘ ]`.
    case popoverExpanded = "popoverExpanded"

    public var showsControlsCluster: Bool {
        self != .quietReading
    }

    public var isPopoverOpen: Bool {
        self == .popoverExpanded
    }
}

private struct TTTextFloatingToolsStateOverrideKey: EnvironmentKey {
    static let defaultValue: TTTextFloatingToolsPresentationState? = nil
}

extension EnvironmentValues {
    /// Optional explicit presentation state override for content-first floating reading tools (`quietReading`, `controlsVisible`, `popoverExpanded`).
    public var textFloatingToolsStateOverride: TTTextFloatingToolsPresentationState? {
        get { self[TTTextFloatingToolsStateOverrideKey.self] }
        set { self[TTTextFloatingToolsStateOverrideKey.self] = newValue }
    }
}
