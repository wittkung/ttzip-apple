// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Hermetic layout state migration engine ensuring canonical proportions across releases.
@MainActor
public enum LayoutStateMigration {
    public static let layoutStateVersionKey = "TTZip_LayoutStateVersion"
    public static let currentVersion = 1
    
    /// Executes idempotent migration of persisted layout preferences.
    public static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        let storedVersion = defaults.integer(forKey: layoutStateVersionKey)
        guard storedVersion < currentVersion else { return }
        
        // Version 1 Migration:
        // Force reset inspector ratio to canonical 1/3 (2:1 ratio: Center 2/3 vs Right 1/3)
        // Purge deprecated absolute pixel width key to eliminate multi-SSOT hazards.
        defaults.set(1.0 / 3.0, forKey: "TTZip_UserRightInspectorRatio")
        defaults.removeObject(forKey: "TTZip_UserRightSidebarWidth")
        
        defaults.set(currentVersion, forKey: layoutStateVersionKey)
        defaults.synchronize()
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
}
