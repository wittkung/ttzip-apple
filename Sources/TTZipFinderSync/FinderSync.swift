// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine for macOS.

import Cocoa
import FinderSync
import TTZipCore

/// macOS Native FinderSync Extension providing context menu integration and file badges.
@objc(FinderSync)
public final class FinderSync: FIFinderSync {
    
    public override init() {
        super.init()
        
        // Initial sync of language from shared AppGroup suite
        if let saved = TTZipPreferencesStore.getSavedLanguage() {
            TTZipLocalizationManager.shared.currentLanguage = saved
        }
        
        // Register Darwin notification observer for cross-process live language changes
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                if let updated = TTZipPreferencesStore.getSavedLanguage() {
                    TTZipLocalizationManager.shared.currentLanguage = updated
                }
            },
            TTZipPreferencesStore.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
        
        // Monitor user home directory and volumes for archive items
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        FIFinderSyncController.default().directoryURLs = [homeURL]
        
        // Set custom badge images for TTZip recognition
        if let badgeImage = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "TTZip Archive") {
            FIFinderSyncController.default().setBadgeImage(badgeImage, label: "TTZip", forBadgeIdentifier: "TTZipArchiveBadge")
        }
    }
    
    // MARK: - Primary Finder Sync Menu Overrides
    
    public override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        guard let selectedURLs = FIFinderSyncController.default().selectedItemURLs(), !selectedURLs.isEmpty else {
            return nil
        }
        
        // JIT check: Guarantee immediate consistency even if notification was queued
        if let saved = TTZipPreferencesStore.getSavedLanguage(),
           saved != TTZipLocalizationManager.shared.currentLanguage {
            TTZipLocalizationManager.shared.currentLanguage = saved
        }
        
        let targetLanguage = TTZipLocalizationManager.shared.currentLanguage
        let menuItems = FinderSyncHelper.shared.getContextMenuItems(selectedURLs: selectedURLs, language: targetLanguage)
        guard !menuItems.isEmpty else { return nil }
        
        let menu = NSMenu(title: "TTZip")
        
        // Header
        let headerItem = NSMenuItem(title: "TTZip", action: nil, keyEquivalent: "")
        headerItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "TTZip")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())
        
        for item in menuItems {
            let nsItem = NSMenuItem(
                title: item.title,
                action: #selector(handleContextMenuAction(_:)),
                keyEquivalent: ""
            )
            nsItem.target = self
            nsItem.representedObject = [
                "action": item.actionIdentifier,
                "urls": selectedURLs.map { $0.path }
            ]
            if let image = NSImage(systemSymbolName: item.iconSystemName, accessibilityDescription: item.title) {
                nsItem.image = image
            }
            menu.addItem(nsItem)
        }
        
        return menu
    }
    
    @objc private func handleContextMenuAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: Any],
              let action = payload["action"] as? String,
              let paths = payload["urls"] as? [String] else { return }
        
        let joinedPaths = paths.joined(separator: "|")
        guard let encodedPaths = joinedPaths.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        
        let urlString = "ttzip://action?type=\(action)&paths=\(encodedPaths)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Badge Identifiers
    
    public override func requestBadgeIdentifier(for url: URL) {
        let ext = url.pathExtension.lowercased()
        if FinderSyncHelper.supportedArchiveExtensions.contains(ext) {
            FIFinderSyncController.default().setBadgeIdentifier("TTZipArchiveBadge", for: url)
        }
    }
}
