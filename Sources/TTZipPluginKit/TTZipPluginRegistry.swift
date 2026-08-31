// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import Combine

/// Unified plugin registry and dispatch manager (Swift 6 Strict Concurrency & ObservableObject)
@MainActor
public final class TTZipPluginRegistry: ObservableObject {
    public static let shared = TTZipPluginRegistry()
    
    @Published public private(set) var installedPlugins: [TTZipPlugin] = []
    @Published public private(set) var sidebarItems: [TTZipSidebarContribution] = []
    @Published public private(set) var omnibarCommands: [TTZipCommandAction] = []
    @Published public private(set) var previewProviders: [TTZipPreviewProvider] = []
    @Published public private(set) var archiveSourceProviders: [TTZipArchiveSourceProvider] = []
    @Published public private(set) var contextMenuActions: [TTZipContextMenuAction] = []
    
    private var pluginContexts: [String: TTZipHostContext] = [:]
    
    private init() {}
    
    /// Registers and initializes a plugin with its injected host context
    public func register(plugin: TTZipPlugin, context: TTZipHostContext) async {
        guard !installedPlugins.contains(where: { $0.manifest.id == plugin.manifest.id }) else {
            return
        }
        
        pluginContexts[plugin.manifest.id] = context
        
        do {
            try await plugin.onInitialize(context: context)
            installedPlugins.append(plugin)
            
            // Collect extension point contributions
            if let sidebar = plugin.sidebarItem {
                sidebarItems.removeAll(where: { $0.id == sidebar.id })
                sidebarItems.append(sidebar)
                sidebarItems.sort(by: { $0.priority > $1.priority })
            }
            
            omnibarCommands.append(contentsOf: plugin.omnibarCommands)
            previewProviders.append(contentsOf: plugin.previewProviders)
            archiveSourceProviders.append(contentsOf: plugin.archiveSourceProviders)
            contextMenuActions.append(contentsOf: plugin.contextMenuActions)
        } catch {
            print("[TTZipPluginRegistry] Failed to initialize plugin \(plugin.manifest.id): \(error)")
        }
    }
    
    /// Unregisters and terminates a plugin, releasing its resources and subscription tokens
    public func unregister(pluginId: String) async {
        if let scopedContext = pluginContexts.removeValue(forKey: pluginId) as? PluginScopedHostContext {
            scopedContext.cleanupTokens()
        } else {
            pluginContexts.removeValue(forKey: pluginId)
        }
        
        guard let index = installedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else {
            sidebarItems.removeAll(where: { $0.id.hasPrefix(pluginId) })
            omnibarCommands.removeAll(where: { $0.id.hasPrefix(pluginId) })
            contextMenuActions.removeAll(where: { $0.id.hasPrefix(pluginId) })
            return
        }
        
        let plugin = installedPlugins.remove(at: index)
        await plugin.onTerminate()
        
        let targetSidebarId = plugin.sidebarItem?.id
        sidebarItems.removeAll(where: { item in
            item.id.hasPrefix(pluginId) || item.id == targetSidebarId
        })
        
        let removedOmnibarIds = Set(plugin.omnibarCommands.map(\.id))
        omnibarCommands.removeAll(where: { $0.id.hasPrefix(pluginId) || removedOmnibarIds.contains($0.id) })
        
        let removedPreviewProviders = plugin.previewProviders
        previewProviders.removeAll(where: { provider in
            removedPreviewProviders.contains(where: { $0 === provider })
        })
        
        let removedArchiveProviders = plugin.archiveSourceProviders
        archiveSourceProviders.removeAll(where: { provider in
            removedArchiveProviders.contains(where: { $0 === provider })
        })
        
        let removedContextMenuIds = Set(plugin.contextMenuActions.map(\.id))
        contextMenuActions.removeAll(where: { $0.id.hasPrefix(pluginId) || removedContextMenuIds.contains($0.id) })
    }
}
