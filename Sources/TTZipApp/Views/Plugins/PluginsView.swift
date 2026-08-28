// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipPluginKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public struct PluginsView: View {
    @ObservedObject private var l10nState = AppLocalizationState.shared
    
    @State private var selectedTab: Int = 0 // 0: 已安装, 1: 插件商店
    @State private var showConfigSheet: Bool = false
    @State private var configPluginId: String = ""
    @State private var marketplacePlugins: [TTZipMarketplacePlugin] = []
    @State private var errorMessage: String?
    
    @ObservedObject private var registry = TTZipPluginRegistry.shared
    @ObservedObject private var installer = TTZipPluginInstaller.shared
    
    public init() {}
    
    private var pluginLocale: PluginLocale {
        l10nState.currentLanguage == .zhHans ? .zhHans : .en
    }
    
    private func isInstalled(pluginId: String) -> Bool {
        registry.installedPlugins.contains(where: { $0.manifest.id == pluginId })
    }
    
    public var body: some View {
        TTZipWorkspaceScaffold(
            title: PluginL10n.title(locale: pluginLocale),
            isCardEnclosed: true
        ) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(PluginL10n.securityBadge(locale: pluginLocale))
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(TTZipTheme.bambooGreen.opacity(0.12))
            .clipShape(Capsule())
        } content: {
            VStack(spacing: 0) {
                customSegmentedTabBar
                    .padding(.vertical, 14)
                
                Divider()
                
                if let error = errorMessage {
                    errorBanner(error: error)
                }
                
                ScrollView {
                    if selectedTab == 0 {
                        installedPluginsList
                    } else {
                        marketplacePluginsList
                    }
                }
            }
        }
        .task {
            marketplacePlugins = await TTZipMarketplaceService.shared.fetchMarketplaceIndex()
        }
        .sheet(isPresented: $showConfigSheet) {
            PluginConfigSheetView(pluginId: configPluginId, isPresented: $showConfigSheet)
        }
    }
    
    // MARK: - TTZip Kintsugi Gold 胶囊选项卡
    private var customSegmentedTabBar: some View {
        HStack(spacing: 0) {
            tabButton(
                title: PluginL10n.tabInstalled(locale: pluginLocale),
                icon: "checkmark.circle",
                tag: 0
            )
            
            tabButton(
                title: PluginL10n.tabMarketplace(locale: pluginLocale),
                icon: "storefront",
                tag: 1
            )
        }
        .padding(3)
        .background(Color.primary.opacity(0.04))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.35), lineWidth: 0.8)
        )
    }
    
    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        let isSelected = selectedTab == tag
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedTab = tag
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .serif))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? TTZipTheme.kintsugiGold : Color.primary.opacity(0.65))
            .background(
                Group {
                    if isSelected {
                        Capsule()
                            .fill(TTZipTheme.kintsugiGold.opacity(0.16))
                            .overlay(
                                Capsule()
                                    .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.5), lineWidth: 0.8)
                            )
                            .shadow(color: TTZipTheme.kintsugiGold.opacity(0.12), radius: 2, y: 1)
                    } else {
                        Color.clear
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }
    
    private func errorBanner(error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(TTZipTheme.cinnabarRed)
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(TTZipTheme.cinnabarRed)
            Spacer()
            Button(PluginL10n.cancel(locale: pluginLocale)) { errorMessage = nil }
                .buttonStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(TTZipTheme.cinnabarRed.opacity(0.1))
    }
    
    // MARK: - 已安装插件列表
    private var installedPluginsList: some View {
        VStack(spacing: 12) {
            let plugins = registry.installedPlugins
            if plugins.isEmpty {
                emptyInstalledView
            } else {
                ForEach(plugins, id: \.manifest.id) { plugin in
                    InstalledPluginRowView(
                        plugin: plugin,
                        locale: pluginLocale,
                        onConfigure: {
                            configPluginId = plugin.manifest.id
                            showConfigSheet = true
                        },
                        onUninstall: {
                            uninstallPlugin(pluginId: plugin.manifest.id)
                        }
                    )
                }
            }
        }
        .padding(20)
    }
    
    private var emptyInstalledView: some View {
        VStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(PluginL10n.emptyInstalledTitle(locale: pluginLocale))
                .font(.system(size: 15, weight: .medium))
            Text(PluginL10n.emptyInstalledDesc(locale: pluginLocale))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            
            Button(action: {
                selectedTab = 1
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text(PluginL10n.goToMarketplace(locale: pluginLocale))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(TTZipTheme.bambooGreen)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(48)
    }
    
    // MARK: - 插件商店列表
    private var marketplacePluginsList: some View {
        VStack(spacing: 16) {
            ForEach(marketplacePlugins) { plugin in
                MarketplacePluginRowView(
                    plugin: plugin,
                    isInstalled: isInstalled(pluginId: plugin.id),
                    isCurrentTarget: installer.activeInstallingId == plugin.id,
                    phase: installer.currentPhase,
                    locale: pluginLocale,
                    onInstall: {
                        performInstall(plugin: plugin)
                    },
                    onConfigure: {
                        configPluginId = plugin.id
                        showConfigSheet = true
                    }
                )
            }
        }
        .padding(20)
    }
    
    // MARK: - 动态安装与卸载操作
    private func performInstall(plugin: TTZipMarketplacePlugin) {
        errorMessage = nil
        Task {
            do {
                try await installer.install(plugin: plugin, context: TTZipHostContextImpl.shared)
                selectedTab = 0
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func uninstallPlugin(pluginId: String) {
        Task { @MainActor in
            await registry.unregister(pluginId: pluginId)
            let destDir = TTZipPluginLoader.userPluginsDirectory
            let files = (try? FileManager.default.contentsOfDirectory(at: destDir, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                if file.lastPathComponent.localizedCaseInsensitiveContains(pluginId) ||
                   file.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(pluginId) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
