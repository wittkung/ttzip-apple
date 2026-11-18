// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Unified helper service for native system open/save dialogs.
@MainActor
public enum SystemDialogHelper {
    /// Presents directory selection panel.
    public static func pickDirectory(prompt: String? = nil, defaultPath: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt ?? TTZipLocalizationManager.shared.string(for: L10n.Common.selectDestination)
        if let path = defaultPath, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        if panel.runModal() == .OK, let url = panel.url {
            return url.path
        }
        return nil
    }

    /// Presents file selection panel.
    public static func pickFiles(
        prompt: String? = nil,
        canChooseDirectories: Bool = true,
        allowsMultipleSelection: Bool = true
    ) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = canChooseDirectories
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.prompt = prompt ?? TTZipLocalizationManager.shared.string(for: L10n.Common.openFiles)
        if panel.runModal() == .OK {
            return panel.urls.map { $0.path }
        }
        return []
    }
    
    /// Displays a localized confirmation alert for deleting an item.
    public static func confirmDeletion(itemName: String) -> Bool {
        let alert = NSAlert()
        let manager = TTZipLocalizationManager.shared
        alert.messageText = manager.string(for: L10n.Dialogs.confirmDeleteTitle)
        let msgTemplate = manager.string(for: L10n.Dialogs.confirmDeleteMessage)
        alert.informativeText = String(format: msgTemplate, itemName)
        alert.addButton(withTitle: manager.string(for: L10n.Common.delete))
        alert.addButton(withTitle: manager.string(for: L10n.Common.cancel))
        alert.alertStyle = .critical
        return alert.runModal() == .alertFirstButtonReturn
    }
    
    /// Displays a localized confirmation alert for overwriting an existing destination file.
    /// Strictly adheres to Apple HIG: Cancel is the default button bound to Return/Esc,
    /// while Overwrite is configured as a secondary destructive action requiring explicit user confirmation.
    public static func confirmOverwrite(itemName: String) -> Bool {
        let alert = NSAlert()
        let manager = TTZipLocalizationManager.shared
        alert.messageText = manager.string(for: L10n.Dialogs.overwriteTitle)
        let msgTemplate = manager.string(for: L10n.Dialogs.overwriteMessage)
        alert.informativeText = String(format: msgTemplate, itemName)
        alert.alertStyle = .warning
        
        // Button 0 (Default): Safe Cancel bound to Return / Esc
        let cancelButton = alert.addButton(withTitle: manager.string(for: L10n.Common.cancel))
        cancelButton.keyEquivalent = "\r"
        
        // Button 1 (Secondary Destructive): Overwrite requires explicit interaction
        let overwriteButton = alert.addButton(withTitle: manager.string(for: L10n.Dialogs.alertOverwrite))
        overwriteButton.hasDestructiveAction = true
        overwriteButton.keyEquivalent = ""
        
        // Intercept Escape key to safely trigger cancel action
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
                cancelButton.performClick(nil)
                return nil
            }
            return event
        }
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        
        return alert.runModal() == .alertSecondButtonReturn
    }
}
