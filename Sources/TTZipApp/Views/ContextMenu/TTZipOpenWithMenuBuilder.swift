// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import UniformTypeIdentifiers
import TTZipCore
import TTZipUI

/// Retained action trampoline that routes AppKit NSMenuItem selectors to Swift closures.
@MainActor
public final class MenuItemActionTrampoline: NSObject {
    private let action: () -> Void
    
    public init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }
    
    @objc public func performAction(_ sender: Any?) {
        action()
    }
}

/// Builds 100% native macOS Finder-style "Open With" (打开方式) submenus with system icons and app routing.
@MainActor
public final class TTZipOpenWithMenuBuilder {
    public static let shared = TTZipOpenWithMenuBuilder()
    
    private init() {}
    
    /// Constructs an NSMenu representing the "Open With" submenu for the specified target URLs.
    public func buildMenu(for urls: [URL]) -> NSMenu {
        let l10n = AppLocalizationState.shared
        let menuTitle = l10n.t(L10n.Menu.openWith)
        let menu = NSMenu(title: menuTitle)
        
        guard let primaryURL = urls.first else {
            return menu
        }
        
        let defaultAppURL = NSWorkspace.shared.urlForApplication(toOpen: primaryURL)
        let compatibleAppURLs = NSWorkspace.shared.urlsForApplications(toOpen: primaryURL)
        
        var orderedApps: [URL] = []
        var seenPaths = Set<String>()
        
        if let defaultApp = defaultAppURL {
            let normalized = defaultApp.resolvingSymlinksInPath().path
            orderedApps.append(defaultApp)
            seenPaths.insert(normalized)
        }
        
        let remainingApps = compatibleAppURLs
            .filter { !seenPaths.contains($0.resolvingSymlinksInPath().path) }
            .sorted { lhs, rhs in
                let nameL = FileManager.default.displayName(atPath: lhs.path)
                let nameR = FileManager.default.displayName(atPath: rhs.path)
                return nameL.localizedStandardCompare(nameR) == .orderedAscending
            }
        
        for app in remainingApps {
            let normalized = app.resolvingSymlinksInPath().path
            if !seenPaths.contains(normalized) {
                orderedApps.append(app)
                seenPaths.insert(normalized)
            }
        }
        
        for appURL in orderedApps {
            let baseName = FileManager.default.displayName(atPath: appURL.path)
            let isDefault = (appURL.resolvingSymlinksInPath().path == defaultAppURL?.resolvingSymlinksInPath().path)
            let title = isDefault ? "\(baseName) \(l10n.t(L10n.Menu.defaultSuffix))" : baseName
            
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            
            let trampoline = MenuItemActionTrampoline {
                let config = NSWorkspace.OpenConfiguration()
                config.promptsUserIfNeeded = true
                NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config, completionHandler: nil)
            }
            
            let item = NSMenuItem(
                title: title,
                action: #selector(MenuItemActionTrampoline.performAction(_:)),
                keyEquivalent: ""
            )
            item.target = trampoline
            item.representedObject = trampoline
            item.image = icon
            menu.addItem(item)
        }
        
        if !orderedApps.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }
        
        // App Store...
        let appStoreTitle = "App Store..."
        let appStoreTrampoline = MenuItemActionTrampoline {
            let ext = primaryURL.pathExtension
            if !ext.isEmpty,
               let encoded = ext.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let storeURL = URL(string: "macappstore://search?term=\(encoded)") {
                NSWorkspace.shared.open(storeURL)
            } else if let storeURL = URL(string: "macappstore://") {
                NSWorkspace.shared.open(storeURL)
            }
        }
        let appStoreItem = NSMenuItem(
            title: appStoreTitle,
            action: #selector(MenuItemActionTrampoline.performAction(_:)),
            keyEquivalent: ""
        )
        appStoreItem.target = appStoreTrampoline
        appStoreItem.representedObject = appStoreTrampoline
        appStoreItem.image = NSImage(systemSymbolName: "bag", accessibilityDescription: nil)
        menu.addItem(appStoreItem)
        
        // Other... (其它...)
        let otherTitle = l10n.t(L10n.Menu.otherEllipsis)
        let otherTrampoline = MenuItemActionTrampoline {
            let panel = NSOpenPanel()
            panel.title = l10n.t(L10n.Menu.chooseApplication)
            panel.prompt = l10n.t(L10n.Common.open)
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                if response == .OK, let chosenAppURL = panel.url {
                    let config = NSWorkspace.OpenConfiguration()
                    config.promptsUserIfNeeded = true
                    NSWorkspace.shared.open(urls, withApplicationAt: chosenAppURL, configuration: config, completionHandler: nil)
                }
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
        let otherItem = NSMenuItem(
            title: otherTitle,
            action: #selector(MenuItemActionTrampoline.performAction(_:)),
            keyEquivalent: ""
        )
        otherItem.target = otherTrampoline
        otherItem.representedObject = otherTrampoline
        otherItem.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        menu.addItem(otherItem)
        
        return menu
    }
}
