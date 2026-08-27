// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipPluginKit
import TTZipCore

public struct InstalledPluginRowView: View {
    public let plugin: TTZipPlugin
    public let locale: PluginLocale
    public let onConfigure: () -> Void
    public let onUninstall: () -> Void
    
    public init(
        plugin: TTZipPlugin,
        locale: PluginLocale,
        onConfigure: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) {
        self.plugin = plugin
        self.locale = locale
        self.onConfigure = onConfigure
        self.onUninstall = onUninstall
    }
    
    public var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension.fill")
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
                Button(action: onConfigure) {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                        Text(PluginL10n.configure(locale: locale))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .background(TTZipTheme.kintsugiGold.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
                Button(action: onUninstall) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text(PluginL10n.uninstall(locale: locale))
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

public struct MarketplacePluginRowView: View {
    public let plugin: TTZipMarketplacePlugin
    public let isInstalled: Bool
    public let isCurrentTarget: Bool
    public let phase: PluginInstallPhase
    public let locale: PluginLocale
    public let onInstall: () -> Void
    public let onConfigure: () -> Void
    
    public init(
        plugin: TTZipMarketplacePlugin,
        isInstalled: Bool,
        isCurrentTarget: Bool,
        phase: PluginInstallPhase,
        locale: PluginLocale,
        onInstall: @escaping () -> Void,
        onConfigure: @escaping () -> Void
    ) {
        self.plugin = plugin
        self.isInstalled = isInstalled
        self.isCurrentTarget = isCurrentTarget
        self.phase = phase
        self.locale = locale
        self.onInstall = onInstall
        self.onConfigure = onConfigure
    }
    
    public var body: some View {
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
                        Text(locale == .zhHans ? plugin.displayName : plugin.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text("v\(plugin.version)")
                            .font(.system(size: 10, weight: .bold, design: .serif))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(TTZipTheme.bambooGreen.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    
                    Text(PluginL10n.author(name: plugin.author, locale: locale))
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
                
                if isInstalled {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(TTZipTheme.bambooGreen)
                            Text(PluginL10n.installedReady(locale: locale))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                        }
                        
                        Button(action: onConfigure) {
                            HStack(spacing: 4) {
                                Image(systemName: "key.fill")
                                Text(PluginL10n.configure(locale: locale))
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
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button(action: onInstall) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(PluginL10n.getAndInstall(locale: locale))
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
            
            if isCurrentTarget {
                PluginInstallProgressBar(phase: phase, locale: locale)
            }
        }
        .padding(16)
        .ttzipLiquidGlass()
    }
}

public struct PluginInstallProgressBar: View {
    public let phase: PluginInstallPhase
    public let locale: PluginLocale
    
    public init(phase: PluginInstallPhase, locale: PluginLocale) {
        self.phase = phase
        self.locale = locale
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            
            switch phase {
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(PluginL10n.downloading(locale: locale))
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
                    Text(PluginL10n.verifyingHash(locale: locale))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .verifyingSignature:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.verifyingSignature(locale: locale))
                        .font(.system(size: 11))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                }
            case .staging:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.staging(locale: locale))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .committing:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.committing(locale: locale))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .hotLoading:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(PluginL10n.hotLoading(locale: locale))
                        .font(.system(size: 11))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
            case .installed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Text(PluginL10n.installSuccess(locale: locale))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
            case .failed(let reason):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                    Text(PluginL10n.installFailed(reason: reason, locale: locale))
                        .font(.system(size: 11))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                }
            case .idle:
                EmptyView()
            }
        }
    }
}
