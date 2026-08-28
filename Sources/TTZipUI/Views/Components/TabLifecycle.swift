// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// Strongly-typed re-entrant activation payload for all workspace tabs.
public enum TabActivationPayload: Sendable, Equatable {
    case none
    case home(directoryURL: URL, selectedPath: String?)
    case compress(inputPaths: [String], targetDirectory: String?, presetID: UUID?)
    case presets(presetID: UUID?, autoEdit: Bool)
    case benchmark(customPath: String?, mode: String?)
    case vault(requestUnlockFocus: Bool)
    case settings(tab: String?)
}

/// Lifecycle contract for tab ViewModels managed under KeepAlive tab containers.
@MainActor
public protocol StatefulTabViewModelProtocol: AnyObject {
    /// Called when the tab transitions from hidden/inactive to active foreground.
    func onTabActivated(payload: TabActivationPayload)
    
    /// Called when the user navigates away from the tab to a different workspace tab.
    func onTabDeactivated()
    
    /// Called when the active tab receives dynamic re-entrant parameters without changing tabs.
    func onReceiveDynamicPayload(_ payload: TabActivationPayload)
}
