// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine for macOS.

import SwiftUI
import TTZipCore

/// Reactive SwiftUI Commands struct for macOS native menu bar integration.
public struct TTZipMenuCommands: Commands {
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public init() {}
    
    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            #if !MAS_BUILD
            Button(l10n.t(L10n.Menu.checkForUpdates)) {
                UpdateManager.shared.checkForUpdates()
            }
            #endif
        }
        
        CommandGroup(replacing: .newItem) {
            Button(l10n.t(L10n.Menu.newArchiveMenu)) {
                // Trigger new archive workflow
                NotificationCenter.default.post(name: NSNotification.Name("TTZip_TriggerNewArchive"), object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            
            Button(l10n.t(L10n.Menu.openArchive)) {
                NotificationCenter.default.post(name: NSNotification.Name("TTZip_TriggerOpenArchive"), object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
