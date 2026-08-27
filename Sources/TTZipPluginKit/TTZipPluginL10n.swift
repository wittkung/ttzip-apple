// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

public enum PluginLocale: Sendable {
    case zhHans
    case en
    
    public static func current() -> PluginLocale {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if lang.contains("zh") {
            return .zhHans
        }
        return .en
    }
}

public struct PluginL10n {
    public static func text(zh: String, en: String, locale: PluginLocale = .current()) -> String {
        switch locale {
        case .zhHans: return zh
        case .en: return en
        }
    }
    
    // Header & Tabs
    public static func title(locale: PluginLocale = .current()) -> String {
        text(zh: "插件中心与生态商店", en: "Extensions & Marketplace", locale: locale)
    }
    
    public static func securityBadge(locale: PluginLocale = .current()) -> String {
        text(zh: "Ed25519 签名与 OCap 沙盒双重防护", en: "Ed25519 Signed & OCap Sandbox Ready", locale: locale)
    }
    
    public static func tabInstalled(locale: PluginLocale = .current()) -> String {
        text(zh: "已安装插件 (Installed)", en: "Installed Extensions", locale: locale)
    }
    
    public static func tabMarketplace(locale: PluginLocale = .current()) -> String {
        text(zh: "插件商店 (Marketplace)", en: "Plugin Marketplace", locale: locale)
    }
    
    // Empty State
    public static func emptyInstalledTitle(locale: PluginLocale = .current()) -> String {
        text(zh: "暂未安装任何插件", en: "No Plugins Installed", locale: locale)
    }
    
    public static func emptyInstalledDesc(locale: PluginLocale = .current()) -> String {
        text(
            zh: "可在「插件商店」中一键获取并安装官方生态扩展插件。安装后左侧边栏与主工作区将自动动态挂载对应功能。",
            en: "Browse the Marketplace to install official ecosystem extensions. Workspace tabs and tools will dynamically mount upon installation.",
            locale: locale
        )
    }

    
    public static func goToMarketplace(locale: PluginLocale = .current()) -> String {
        text(zh: "前往插件商店", en: "Explore Marketplace", locale: locale)
    }
    
    // Actions & Badges
    public static func getAndInstall(locale: PluginLocale = .current()) -> String {
        text(zh: "获取安装", en: "Get & Install", locale: locale)
    }
    
    public static func configure(locale: PluginLocale = .current()) -> String {
        text(zh: "配置凭证", en: "Configure", locale: locale)
    }
    
    public static func uninstall(locale: PluginLocale = .current()) -> String {
        text(zh: "卸载", en: "Uninstall", locale: locale)
    }
    
    public static func installedReady(locale: PluginLocale = .current()) -> String {
        text(zh: "已安装并就绪", en: "Installed & Ready", locale: locale)
    }
    
    public static func author(name: String, locale: PluginLocale = .current()) -> String {
        text(zh: "作者: \(name)", en: "Author: \(name)", locale: locale)
    }
    
    // Install Phases
    public static func downloading(locale: PluginLocale = .current()) -> String {
        text(zh: "正在从云端下载分发包...", en: "Downloading distribution package from cloud...", locale: locale)
    }
    
    public static func verifyingHash(locale: PluginLocale = .current()) -> String {
        text(zh: "正在进行 O(1) 流式 SHA-256 完整性哈希校验...", en: "Verifying O(1) streaming SHA-256 integrity digest...", locale: locale)
    }
    
    public static func verifyingSignature(locale: PluginLocale = .current()) -> String {
        text(zh: "正在进行 Apple CryptoKit Ed25519 官方数字签名认证...", en: "Validating Apple CryptoKit Ed25519 publisher signature...", locale: locale)
    }
    
    public static func staging(locale: PluginLocale = .current()) -> String {
        text(zh: "正在解压并执行 Zip Slip 安全沙盒检测...", en: "Extracting & auditing Zip Slip path sandbox...", locale: locale)
    }
    
    public static func committing(locale: PluginLocale = .current()) -> String {
        text(zh: "正在执行 2PC APFS 原子切换与落盘提交...", en: "Performing 2PC APFS atomic swap & commit...", locale: locale)
    }
    
    public static func hotLoading(locale: PluginLocale = .current()) -> String {
        text(zh: "正在动态热插拔挂载插件与侧边栏...", en: "Live hot-mounting plugin & sidebar workspace...", locale: locale)
    }
    
    public static func installSuccess(locale: PluginLocale = .current()) -> String {
        text(zh: "安装成功！已激活并挂载。", en: "Installed successfully! Active & mounted.", locale: locale)
    }
    
    public static func installFailed(reason: String, locale: PluginLocale = .current()) -> String {
        text(zh: "安装失败: \(reason)", en: "Installation failed: \(reason)", locale: locale)
    }
    
    // Credentials Sheet
    public static func configTitle(locale: PluginLocale = .current()) -> String {
        text(zh: "配置插件凭证 (Credentials)", en: "Configure Plugin Credentials", locale: locale)
    }
    
    public static func configDesc(locale: PluginLocale = .current()) -> String {
        text(
            zh: "凭证由 macOS Keychain 加密隔离保护，插件仅受控安全读取。",
            en: "Credentials are encrypted in macOS Keychain and accessed via tenant-scoped isolation.",
            locale: locale
        )
    }
    
    public static func saveToKeychain(locale: PluginLocale = .current()) -> String {
        text(zh: "保存凭证至 Keychain", en: "Save to Keychain", locale: locale)
    }
    
    public static func cancel(locale: PluginLocale = .current()) -> String {
        text(zh: "取消", en: "Cancel", locale: locale)
    }
}
