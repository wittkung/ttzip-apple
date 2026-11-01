// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Cocoa
import FinderSync
import os
import TTZipCore

/// macOS Native FinderSync Extension providing context menu integration and file badges.
@objc(FinderSync)
public final class FinderSync: FIFinderSync {
    
    private static let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "FinderSync")
    
    private static var isRunningInTestEnvironment: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        Bundle.main.bundlePath.hasSuffix(".xctest")
    }
    
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
        
        // Register Darwin notification observer for dynamic monitored directory updates
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let instance = Unmanaged<FinderSync>.fromOpaque(observer).takeUnretainedValue()
                instance.updateMonitoredDirectories()
            },
            "com.metastudyline.ttzip.monitoredDirectoriesChanged" as CFString,
            nil,
            .deliverImmediately
        )
        
        // Strictly monitor active archive mount points and workspaces only (cancels global ~ and /Volumes)
        if !Self.isRunningInTestEnvironment {
            updateMonitoredDirectories()
            
            // Set custom badge images for TTZip recognition
            if let badgeImage = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "TTZip Archive") {
                FIFinderSyncController.default().setBadgeImage(badgeImage, label: "TTZip", forBadgeIdentifier: "TTZipArchiveBadge")
            }
        }
    }
    
    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let langName = CFNotificationName(TTZipPreferencesStore.darwinNotificationName as CFString)
        CFNotificationCenterRemoveObserver(center, observer, langName, nil)
        let dirName = CFNotificationName("com.metastudyline.ttzip.monitoredDirectoriesChanged" as CFString)
        CFNotificationCenterRemoveObserver(center, observer, dirName, nil)
    }
    
    // MARK: - Dynamic Scoped Directory Monitoring
    
    /// Dynamically synchronizes monitored directories strictly to active workspace paths and active mount points.
    public func updateMonitoredDirectories() {
        guard !Self.isRunningInTestEnvironment else { return }
        let defaults = UserDefaults(suiteName: "group.com.metastudyline.ttzip")
        var monitoredURLs = Set<URL>()
        
        // 1. Explicitly configured active workspace directories
        if let activePaths = defaults?.stringArray(forKey: "TTZip_ActiveMonitoredDirectoryPaths") {
            for path in activePaths where !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    monitoredURLs.insert(url)
                }
            }
        }
        
        // 2. User directories fallback (Downloads, Desktop) to ensure right-click menu presence
        if monitoredURLs.isEmpty {
            let fm = FileManager.default
            if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                monitoredURLs.insert(downloads)
            }
            if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
                monitoredURLs.insert(desktop)
            }
        }
        
        FIFinderSyncController.default().directoryURLs = monitoredURLs
        Self.logger.info("Updated FinderSync monitored directories count: \(monitoredURLs.count)")
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
              let paths = payload["urls"] as? [String],
              !paths.isEmpty else { return }
        
        // Spool job via App Group shared temporary buffer (or disk-backed token) to prevent URL query parameter overflow on 100+ files
        do {
            let jobId = try AppGroupSpooler.shared.spoolJob(action: action, paths: paths)
            var components = URLComponents()
            components.scheme = "ttzip"
            components.host = "action"
            components.queryItems = [
                URLQueryItem(name: "type", value: action),
                URLQueryItem(name: "jobId", value: jobId.uuidString)
            ]
            
            if let url = components.url {
                NSWorkspace.shared.open(url)
                return
            }
        } catch {
            Self.logger.error("Spooling failed for action '\(action, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        
        // Direct query fallback for small selections when spooling is unavailable
        if paths.count <= 32 {
            var components = URLComponents()
            components.scheme = "ttzip"
            components.host = "action"
            components.queryItems = [
                URLQueryItem(name: "type", value: action),
                URLQueryItem(name: "paths", value: paths.joined(separator: "|"))
            ]
            
            if let url = components.url {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    // MARK: - Badge Identifiers
    
    public override func requestBadgeIdentifier(for url: URL) {
        let ext = url.pathExtension.lowercased()
        if FinderSyncHelper.supportedArchiveExtensions.contains(ext) {
            if !Self.isRunningInTestEnvironment {
                FIFinderSyncController.default().setBadgeIdentifier("TTZipArchiveBadge", for: url)
            }
        }
    }
}
