// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import Combine

/// 统一插件注册与分发管理器 (Swift 6 Strict Concurrency & ObservableObject)
@MainActor
public final class TTZipPluginRegistry: ObservableObject {
    public static let shared = TTZipPluginRegistry()
    
    @Published public private(set) var installedPlugins: [TTZipPlugin] = []
    @Published public private(set) var sidebarItems: [TTZipSidebarContribution] = []
    @Published public private(set) var omnibarCommands: [TTZipCommandAction] = []
    @Published public private(set) var previewProviders: [TTZipPreviewProvider] = []
    @Published public private(set) var archiveSourceProviders: [TTZipArchiveSourceProvider] = []
    @Published public private(set) var contextMenuActions: [TTZipContextMenuAction] = []
    
    private init() {}
    
    /// 注册并初始化插件
    public func register(plugin: TTZipPlugin, context: TTZipHostContext) async {
        guard !installedPlugins.contains(where: { $0.manifest.id == plugin.manifest.id }) else {
            return
        }
        
        do {
            try await plugin.onInitialize(context: context)
            installedPlugins.append(plugin)
            
            // 收集 8 大扩展点
            if let sidebar = plugin.sidebarItem {
                sidebarItems.removeAll(where: { $0.id == sidebar.id })
                sidebarItems.append(sidebar)
                sidebarItems.sort(by: { $0.priority > $1.priority })
            }
            
            omnibarCommands.append(contentsOf: plugin.omnibarCommands)
            previewProviders.append(contentsOf: plugin.previewProviders)
            archiveSourceProviders.append(contentsOf: plugin.archiveSourceProviders)
            contextMenuActions.append(contentsOf: plugin.contextMenuActions)
            
            self.objectWillChange.send()
        } catch {
            print("[TTZipPluginRegistry] Failed to initialize plugin \(plugin.manifest.id): \(error)")
        }
    }
    
    /// 卸载并终止插件
    public func unregister(pluginId: String) async {
        guard let index = installedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else {
            // 即使未在 installedPlugins，也强制清理孤立的 sidebarItems
            sidebarItems.removeAll(where: { $0.id.hasPrefix(pluginId) || $0.id.contains("larksync") })
            self.objectWillChange.send()
            return
        }
        
        let plugin = installedPlugins.remove(at: index)
        await plugin.onTerminate()
        
        let targetSidebarId = plugin.sidebarItem?.id
        sidebarItems.removeAll(where: { item in
            item.id.hasPrefix(pluginId) ||
            item.id == targetSidebarId ||
            (pluginId.contains("larksync") && item.id.contains("larksync"))
        })
        
        omnibarCommands.removeAll(where: { $0.id.hasPrefix(pluginId) || (pluginId.contains("larksync") && $0.id.contains("larksync")) })
        previewProviders.removeAll(where: { _ in true })
        archiveSourceProviders.removeAll(where: { _ in true })
        contextMenuActions.removeAll(where: { _ in true })
        
        self.objectWillChange.send()
    }
}
