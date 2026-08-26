// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.

import SwiftUI
import TTZipPluginKit
import TTZipCore

public struct PluginsView: View {
    @ObservedObject private var l10nState = AppLocalizationState.shared
    
    @State private var selectedTab: Int = 0 // 0: 已安装, 1: 插件商店
    @State private var showConfigSheet: Bool = false
    @State private var configPluginId: String = ""
    @State private var appIdInput: String = ""
    @State private var appSecretInput: String = ""
    @State private var marketplacePlugins: [TTZipMarketplacePlugin] = [TTZipMarketplaceService.fallbackPlugin]
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
                // TTZip 专属 Kintsugi Gold 胶囊选项卡 (替换系统默认蓝色 Picker)
                customSegmentedTabBar
                    .padding(.vertical, 14)
                
                Divider()
                
                if let error = errorMessage {
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
            pluginConfigModal
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
    
    // MARK: - 已安装插件列表 (从 Registry 动态渲染)
    private var installedPluginsList: some View {
        VStack(spacing: 12) {
            let plugins = registry.installedPlugins
            if plugins.isEmpty {
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
            } else {
                ForEach(plugins, id: \.manifest.id) { plugin in
                    HStack(spacing: 16) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .frame(width: 48, height: 48)
                            .background(TTZipTheme.kintsugiGold.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(plugin.manifest.name)
                                    .font(.system(size: 15, weight: .semibold))
                                Text("v\(plugin.manifest.version)")
                                    .font(.system(size: 10, weight: .bold, design: .serif))
                                    .foregroundStyle(TTZipTheme.bambooGreen)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(TTZipTheme.bambooGreen.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            
                            Text(plugin.manifest.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 6) {
                                ForEach(plugin.manifest.permissions, id: \.self) { perm in
                                    Text(perm.rawValue)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                }
                            }
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 8) {
                            Button(action: {
                                configPluginId = plugin.manifest.id
                                showConfigSheet = true
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "key.fill")
                                    Text(PluginL10n.configure(locale: pluginLocale))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .foregroundStyle(TTZipTheme.kintsugiGold)
                                .background(TTZipTheme.kintsugiGold.opacity(0.15))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                uninstallPlugin(pluginId: plugin.manifest.id)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                    Text(PluginL10n.uninstall(locale: pluginLocale))
                                }
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .foregroundStyle(TTZipTheme.cinnabarRed)
                                .background(TTZipTheme.cinnabarRed.opacity(0.1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .ttzipLiquidGlass()
                }
            }
        }
        .padding(20)
    }
    
    // MARK: - 插件商店列表 (云端动态拉取并展示安装状态机)
    private var marketplacePluginsList: some View {
        VStack(spacing: 16) {
            ForEach(marketplacePlugins) { plugin in
                let installed = isInstalled(pluginId: plugin.id)
                let isCurrentTarget = installer.activeInstallingId == plugin.id
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .frame(width: 48, height: 48)
                            .background(TTZipTheme.kintsugiGold.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(pluginLocale == .zhHans ? plugin.displayName : plugin.name)
                                    .font(.system(size: 15, weight: .semibold))
                                Text("v\(plugin.version) (Official)")
                                    .font(.system(size: 10, weight: .bold, design: .serif))
                                    .foregroundStyle(TTZipTheme.bambooGreen)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(TTZipTheme.bambooGreen.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            
                            Text(PluginL10n.author(name: plugin.author, locale: pluginLocale))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            
                            Text(plugin.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 6) {
                                ForEach(plugin.permissions, id: \.self) { perm in
                                    Text(perm)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                }
                            }
                        }
                        
                        Spacer()
                        
                        if installed {
                            VStack(alignment: .trailing, spacing: 6) {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(TTZipTheme.bambooGreen)
                                    Text(PluginL10n.installedReady(locale: pluginLocale))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(TTZipTheme.bambooGreen)
                                }
                                
                                Button(action: {
                                    configPluginId = plugin.id
                                    showConfigSheet = true
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "key.fill")
                                        Text(PluginL10n.configure(locale: pluginLocale))
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(TTZipTheme.kintsugiGold)
                                    .background(TTZipTheme.kintsugiGold.opacity(0.15))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        } else if isCurrentTarget {
                            // 正在执行安装流程
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Button(action: {
                                performInstall(plugin: plugin)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text(PluginL10n.getAndInstall(locale: pluginLocale))
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
                    }
                    
                    // 流式下载与安全验签进度条
                    if isCurrentTarget {
                        installProgressBar
                    }
                }
                .padding(16)
                .ttzipLiquidGlass()
            }
        }
        .padding(20)
    }
    
    // MARK: - 实时安装进度状态指示器
    @ViewBuilder
    private var installProgressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.vertical, 4)
            
            switch installer.currentPhase {
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(PluginL10n.downloading(locale: pluginLocale))
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(String(format: "%.1f", Double(progress.bytesWritten) / 1024 / 1024)) MB / \(String(format: "%.1f", Double(progress.totalBytesExpected ?? 0) / 1024 / 1024)) MB")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("(\(String(format: "%.1f", progress.bytesPerSecond / 1024 / 1024)) MB/s)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                    }
                    ProgressView(value: progress.fractionCompleted)
                        .tint(TTZipTheme.bambooGreen)
                }
            case .verifyingHash:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.verifyingHash(locale: pluginLocale))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .verifyingSignature:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.verifyingSignature(locale: pluginLocale))
                        .font(.system(size: 11))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                }
            case .staging:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.staging(locale: pluginLocale))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .committing:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.committing(locale: pluginLocale))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .hotLoading:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.hotLoading(locale: pluginLocale))
                        .font(.system(size: 11))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
            case .installed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Text(PluginL10n.installSuccess(locale: pluginLocale))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
            case .failed(let reason):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                    Text(PluginL10n.installFailed(reason: reason, locale: pluginLocale))
                        .font(.system(size: 11))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                }
            case .idle:
                EmptyView()
            }
        }
    }
    
    // MARK: - 动态安装与卸载操作
    private func performInstall(plugin: TTZipMarketplacePlugin) {
        errorMessage = nil
        Task {
            do {
                try await installer.install(plugin: plugin, context: TTZipHostContextImpl.shared)
                selectedTab = 0 // 安装完成切到已安装列表
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func uninstallPlugin(pluginId: String) {
        Task { @MainActor in
            await registry.unregister(pluginId: pluginId)
            let destDir = TTZipPluginLoader.userPluginsDirectory
            let destURL = destDir.appendingPathComponent("LarkSync.ttplugin")
            try? FileManager.default.removeItem(at: destURL)
            let files = (try? FileManager.default.contentsOfDirectory(at: destDir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.contains("LarkSync") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    
    // MARK: - 配置凭证弹窗
    private var pluginConfigModal: some View {
        VStack(spacing: 16) {
            Text(PluginL10n.configTitle(locale: pluginLocale))
                .font(TTZipTheme.Typography.title1)
            
            Text(PluginL10n.configDesc(locale: pluginLocale))
                .font(TTZipTheme.Typography.caption)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("App ID:")
                    .font(TTZipTheme.Typography.caption)
                TextField("cli_xxxxxxxxxxxx", text: $appIdInput)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("App Secret:")
                    .font(TTZipTheme.Typography.caption)
                SecureField("••••••••••••••••", text: $appSecretInput)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack(spacing: 12) {
                Button(PluginL10n.cancel(locale: pluginLocale)) {
                    showConfigSheet = false
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(PluginL10n.saveToKeychain(locale: pluginLocale)) {
                    Task {
                        try? await TTZipHostContextImpl.shared.keychain.set(key: "lark_app_id", value: appIdInput)
                        try? await TTZipHostContextImpl.shared.keychain.set(key: "lark_app_secret", value: appSecretInput)
                        showConfigSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(TTZipTheme.kintsugiGold)
                .disabled(appIdInput.isEmpty || appSecretInput.isEmpty)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            Task {
                appIdInput = (try? await TTZipHostContextImpl.shared.keychain.get(key: "lark_app_id")) ?? ""
                appSecretInput = (try? await TTZipHostContextImpl.shared.keychain.get(key: "lark_app_secret")) ?? ""
            }
        }
    }
}
