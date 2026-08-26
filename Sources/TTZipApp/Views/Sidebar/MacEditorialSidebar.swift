// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipPluginKit

/// Editorial style sidebar (WSJ Editorial Sidebar).
public struct MacEditorialSidebar: View {
    @ObservedObject private var l10n = AppLocalizationState.shared
    @ObservedObject private var registry = TTZipPluginRegistry.shared
    @Binding public var activeTab: WorkspaceTab
    public let currentArchivePath: String?
    public var isCompact: Bool = false
    
    private let tuner = AppleSiliconTuner.shared
    
    public init(activeTab: Binding<WorkspaceTab>, currentArchivePath: String?, isCompact: Bool = false) {
        self._activeTab = activeTab
        self.currentArchivePath = currentArchivePath
        self.isCompact = isCompact
    }
    
    public var body: some View {
        VStack(alignment: isCompact ? .center : .leading, spacing: 0) {
            if !isCompact {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("THE")
                            .font(.system(size: 9, weight: .bold, design: .serif))
                            .tracking(2.5)
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                        HStack(spacing: 7) {
                            if let logoImg = AppLogoCache.sharedLogoImage {
                                Image(nsImage: logoImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 22, height: 22)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
                            }
                            Text("TTZIP")
                                .font(.system(size: 18, weight: .bold, design: .serif))
                                .tracking(1.5)
                            Text(l10n.t(L10n.Sidebar.proBadge))
                                .font(.system(size: 10, weight: .heavy, design: .serif))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(TTZipTheme.kintsugiGold.opacity(0.18))
                                .foregroundStyle(TTZipTheme.kintsugiGold)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    
                    Rectangle()
                        .fill(TTZipTheme.kintsugiGold)
                        .frame(height: 1.5)
                }
                .padding(.top, 38)
                .padding(.bottom, 16)
            } else {
                VStack {
                    if let logoImg = AppLogoCache.sharedLogoImage {
                        Image(nsImage: logoImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 38)
                .padding(.bottom, 24)
            }
            
            VStack(alignment: isCompact ? .center : .leading, spacing: isCompact ? 4 : 2) {
                if !isCompact {
                    Text(l10n.t(L10n.Sidebar.indexHeader))
                        .font(.system(size: 9.5, weight: .bold, design: .serif))
                        .tracking(2)
                        .foregroundStyle(.secondary.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }
                
                // 1. 核心内置项
                SidebarItemView(title: l10n.t(L10n.Sidebar.homeAndExtract), icon: "archivebox", tab: .home, activeTab: $activeTab, isCompact: isCompact)
                SidebarItemView(title: l10n.t(L10n.Sidebar.newArchive), icon: "doc.badge.plus", tab: .compressWorkspace, activeTab: $activeTab, isCompact: isCompact)
                SidebarItemView(title: l10n.t(L10n.Sidebar.presets), icon: "slider.horizontal.3", tab: .presets, activeTab: $activeTab, isCompact: isCompact)
                SidebarItemView(title: l10n.t(L10n.Sidebar.benchmark), icon: "speedometer", tab: .benchmark, activeTab: $activeTab, isCompact: isCompact)
                SidebarItemView(title: l10n.t(L10n.Sidebar.vault), icon: "key.fill", tab: .vault, activeTab: $activeTab, isCompact: isCompact)
                
                // 2. 动态插件扩展项 (仅在已安装对应插件时渲染)
                ForEach(registry.sidebarItems, id: \.id) { (contribution: TTZipSidebarContribution) in
                    let isLark = contribution.id.contains("larksync")
                    SidebarItemView(
                        title: contribution.title,
                        icon: contribution.icon,
                        tab: isLark ? .larkSync : .plugins,
                        activeTab: $activeTab,
                        isCompact: isCompact
                    )
                }
                
                // 3. 插件中心与许可证
                let pluginsTitle = l10n.currentLanguage == .zhHans ? "插件中心" : "Extensions"
                SidebarItemView(title: pluginsTitle, icon: "puzzlepiece.extension.fill", tab: .plugins, activeTab: $activeTab, isCompact: isCompact)
                SidebarItemView(title: l10n.t(L10n.Sidebar.licensing), icon: "checkmark.seal.fill", tab: .settings, activeTab: $activeTab, isCompact: isCompact)
            }
            .padding(.horizontal, isCompact ? 0 : 8)
            
            if !isCompact, let path = currentArchivePath {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t(L10n.Sidebar.openArchiveHeader))
                        .font(.system(size: 9, weight: .bold, design: .serif))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    
                    Text((path as NSString).lastPathComponent)
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            
            Spacer(minLength: 16)
            
            if !isCompact {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                        Text(tuner.topology.chipName)
                            .font(.system(size: 11, weight: .semibold, design: .serif))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                    
                    Text("\(tuner.topology.totalCores) 核心 (\(tuner.topology.performanceCores) 性能核 + \(tuner.topology.efficiencyCores) 能效核) • \(Int(tuner.topology.unifiedMemoryGB)) GB 统一内存")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                        Text("零拷贝 SIMD 硬件加速")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                    }
                    .padding(.top, 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            
            if !isCompact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentDateString)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.8))
                    Text("原生 macOS 架构")
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity)
        .background(TTZipTheme.paperWhite.opacity(0.98))
    }
    
    private var currentDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: Date())
    }
}

private struct SidebarItemView: View {
    let title: String
    let icon: String
    let tab: WorkspaceTab
    @Binding var activeTab: WorkspaceTab
    let isCompact: Bool
    
    @State private var isHovered: Bool = false
    
    private var isSelected: Bool {
        activeTab == tab
    }
    
    var body: some View {
        Button(action: {
            activeTab = tab
        }) {
            if isCompact {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isSelected
                                ? TTZipTheme.bambooGreen.opacity(0.16)
                                : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                        )
                    
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.primary.opacity(0.75))
                }
                .frame(width: 36, height: 36)
                .help(title)
            } else {
                HStack(spacing: 8) {
                    Capsule(style: .continuous)
                        .fill(isSelected ? TTZipTheme.bambooGreen : Color.clear)
                        .frame(width: 3, height: 16)
                        .opacity(isSelected ? 1.0 : 0.0)
                    
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .frame(width: 18)
                        .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.primary.opacity(isHovered ? 0.85 : 0.6))
                    
                    Text(title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular, design: .serif))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(isHovered ? 0.95 : 0.75))
                        .lineLimit(1)
                    
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .padding(.trailing, 8)
                .padding(.leading, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isSelected
                                ? TTZipTheme.bambooGreen.opacity(0.10)
                                : (isHovered ? Color.primary.opacity(0.04) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? TTZipTheme.bambooGreen.opacity(0.20)
                                : (isHovered ? Color.primary.opacity(0.06) : Color.clear),
                            lineWidth: 0.5
                        )
                )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
