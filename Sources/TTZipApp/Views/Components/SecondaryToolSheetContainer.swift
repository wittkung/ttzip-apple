// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPluginKit
import TTZipBenchmarkKit

/// Unified modal sheet container for presenting secondary workspace tools.
public struct SecondaryToolSheetContainer: View {
    public let tab: WorkspaceTab
    public let onDismiss: () -> Void
    
    @ObservedObject private var l10n = AppLocalizationState.shared
    @ObservedObject private var registry = TTZipPluginRegistry.shared
    
    public init(tab: WorkspaceTab, onDismiss: @escaping () -> Void) {
        self.tab = tab
        self.onDismiss = onDismiss
    }
    
    private var title: String {
        switch tab {
        case .presets:
            return l10n.t(L10n.Sidebar.presets)
        case .benchmark:
            return l10n.t(L10n.Sidebar.benchmark)
        case .vault:
            return l10n.t(L10n.Sidebar.vault)
        case .plugins:
            return l10n.currentLanguage == .zhHans ? "插件中心" : "Extensions"
        case .settings:
            return l10n.t(L10n.Sidebar.settings)
        case .dynamicExtension(let pluginId, let tabId):
            if let plugin = registry.installedPlugins.first(where: { $0.manifest.id == pluginId || $0.sidebarItem?.targetTabIdentifier == tabId }) {
                return plugin.sidebarItem?.title ?? plugin.manifest.name
            }
            return "Extension"
        case .home, .compressWorkspace:
            return ""
        }
    }
    
    private var icon: String {
        switch tab {
        case .presets:
            return "slider.horizontal.3"
        case .benchmark:
            return "speedometer"
        case .vault:
            return "key.fill"
        case .plugins:
            return "puzzlepiece.extension.fill"
        case .settings:
            return "gearshape.fill"
        case .dynamicExtension(let pluginId, let tabId):
            if let plugin = registry.installedPlugins.first(where: { $0.manifest.id == pluginId || $0.sidebarItem?.targetTabIdentifier == tabId }) {
                return plugin.sidebarItem?.icon ?? "puzzlepiece.extension"
            }
            return "puzzlepiece.extension"
        case .home, .compressWorkspace:
            return "app.fill"
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            topBar
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 1)
            
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 760,
            idealWidth: 880,
            maxWidth: 1040,
            minHeight: 540,
            idealHeight: 640,
            maxHeight: 800
        )
        .background(TTZipTheme.paperWhite)
    }
    
    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
            
            Spacer()
            
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(l10n.t(L10n.Common.close))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch tab {
        case .presets:
            PresetWorkspaceView()
        case .benchmark:
            BenchmarkView()
        case .vault:
            PasswordVaultView()
        case .plugins:
            PluginsView()
        case .settings:
            SettingsView()
        case .dynamicExtension(let pluginId, let tabId):
            if let plugin = registry.installedPlugins.first(where: { $0.manifest.id == pluginId || $0.sidebarItem?.targetTabIdentifier == tabId }),
               let pluginView = plugin.makeWorkspaceView(tabIdentifier: tabId) {
                pluginView
            } else {
                TTZipWorkspaceScaffold(
                    title: "Extension",
                    isCardEnclosed: true
                ) {
                    EmptyView()
                } content: {
                    ContentUnavailableView(
                        l10n.currentLanguage == .zhHans ? "未加载该扩展" : "Extension Not Loaded",
                        systemImage: "puzzlepiece.extension",
                        description: Text(l10n.currentLanguage == .zhHans ? "请前往「插件中心」启用或安装对应扩展。" : "Please navigate to Extensions to enable or install the extension.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .home, .compressWorkspace:
            EmptyView()
        }
    }
}
