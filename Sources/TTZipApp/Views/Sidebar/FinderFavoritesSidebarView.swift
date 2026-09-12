// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI
import AppKit

/// Native macOS Finder favorites and locations sidebar adhering to the Zen x WSJ Editorial design system.
public struct FinderFavoritesSidebarView: View {
    public let currentDirectory: URL
    public var isIconRail: Bool
    public let onSelectDirectory: (URL) -> Void
    
    @ObservedObject private var l10n = AppLocalizationState.shared
    @ObservedObject private var licenseManager = AppLicenseManager.shared
    @State private var dynamicFinderFavorites: [FinderFavoriteItem] = []
    @State private var hoveredItemPath: String? = nil
    
    @AppStorage("TTZipCustomShortcutFolderPaths") private var customPinnedPathsJSON: String = "[]"
    
    public init(
        currentDirectory: URL,
        isIconRail: Bool = false,
        onSelectDirectory: @escaping (URL) -> Void
    ) {
        self.currentDirectory = currentDirectory
        self.isIconRail = isIconRail
        self.onSelectDirectory = onSelectDirectory
    }
    
    private var customPinnedPaths: [String] {
        guard let data = customPinnedPathsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }
    
    private func saveCustomPinnedPaths(_ paths: [String]) {
        if let data = try? JSONEncoder().encode(paths),
           let jsonStr = String(data: data, encoding: .utf8) {
            customPinnedPathsJSON = jsonStr
        }
    }
    
    public var body: some View {
        VStack(alignment: isIconRail ? .center : .leading, spacing: 0) {
            // MARK: - 1. Brand Header (Height 52pt, Golden Line strictly at Y = 90pt)
            headerSection
            
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: TTZipTheme.Layout.kintsugiGoldLineHeight)
            
            // MARK: - 2. Scrollable Favorites & Locations List
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: isIconRail ? .center : .leading, spacing: isIconRail ? 6 : 14) {
                    // Group 0: Custom Pinned Directories (if any)
                    if !customPinnedPaths.isEmpty && !isIconRail {
                        VStack(alignment: .leading, spacing: 2) {
                            sectionHeader(title: l10n.currentLanguage == .zhHans ? "常用" : "PINNED")
                            
                            ForEach(customPinnedPaths, id: \.self) { path in
                                let url = URL(fileURLWithPath: path)
                                sidebarRow(
                                    title: url.lastPathComponent,
                                    icon: "folder.fill",
                                    path: path,
                                    isCustom: true
                                )
                            }
                        }
                    }
                    
                    // Group 1: Favorites
                    VStack(alignment: isIconRail ? .center : .leading, spacing: isIconRail ? 4 : 2) {
                        if !isIconRail {
                            sectionHeader(title: l10n.currentLanguage == .zhHans ? "个人收藏" : "FAVORITES")
                        }
                        
                        ForEach(dynamicFinderFavorites.filter { !isVolumePath($0.path) }) { item in
                            sidebarRow(
                                title: item.name,
                                icon: item.systemImage,
                                path: item.path,
                                isCustom: false
                            )
                        }
                    }
                    
                    // Group 2: Locations
                    let volumeItems = dynamicFinderFavorites.filter { isVolumePath($0.path) }
                    if !volumeItems.isEmpty {
                        if isIconRail {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 24, height: 0.8)
                                .padding(.vertical, 4)
                        }
                        
                        VStack(alignment: isIconRail ? .center : .leading, spacing: isIconRail ? 4 : 2) {
                            if !isIconRail {
                                sectionHeader(title: l10n.currentLanguage == .zhHans ? "位置" : "LOCATIONS")
                            }
                            
                            ForEach(volumeItems) { item in
                                sidebarRow(
                                    title: item.name,
                                    icon: item.systemImage,
                                    path: item.path,
                                    isCustom: false
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, isIconRail ? 4 : 8)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: isIconRail ? .center : .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            
            // MARK: - 3. Apple Silicon Hardware & Engine Footer
            sidebarHardwareFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TTZipTheme.paperWhite.opacity(0.85))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredItemPath = nil
            }
        }
        .task {
            loadFavorites()
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        Group {
            if isIconRail {
                HStack {
                    Spacer(minLength: 0)
                    if let logo = AppLogoCache.sharedLogoImage {
                        Image(nsImage: logo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .help(licenseManager.currentTier.isPro ? "TTZip Pro" : "TTZip")
            } else {
                HStack(alignment: .center, spacing: 6) {
                    HStack(alignment: .center, spacing: 7) {
                        if let logo = AppLogoCache.sharedLogoImage {
                            Image(nsImage: logo)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                        } else {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                        }
                        
                        Text("TTZip")
                            .font(.system(size: 14.5, weight: .bold, design: .serif))
                            .tracking(0.5)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        
                        if licenseManager.currentTier.isPro {
                            Text("PRO")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundStyle(TTZipTheme.kintsugiGold)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .background(TTZipTheme.kintsugiGold.opacity(0.12))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().strokeBorder(TTZipTheme.kintsugiGold.opacity(0.35), lineWidth: 0.6)
                                )
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    
                    Spacer(minLength: 4)
                    
                    Button(action: addCustomPinnedFolder) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(Circle())
                            .overlay(
                                Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(l10n.currentLanguage == .zhHans ? "添加自定常用文件夹到侧边栏" : "Pin custom folder to sidebar")
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: TTZipTheme.Layout.headerBarHeight)
        .padding(.top, TTZipTheme.Layout.topBarOffset)
    }
    
    private var sidebarHardwareFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.6)
            
            Group {
                if isIconRail {
                    HStack {
                        Spacer(minLength: 0)
                        Image(systemName: "cpu")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TTZipTheme.bambooGreen.opacity(0.85))
                            .help(hardwareChipSummary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 30)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                        
                        Text(hardwareChipSummary)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Text("·")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        
                        Text(currentDateBadge)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.85))
                            .lineLimit(1)
                        
                        Spacer(minLength: 0)
                        
                        Circle()
                            .fill(TTZipTheme.bambooGreen)
                            .frame(width: 5, height: 5)
                            .help("Apple Silicon Engine Online")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                }
            }
            .background(Color.primary.opacity(0.015))
        }
    }
    
    private var hardwareChipSummary: String {
        let raw = AppleSiliconTuner.shared.topology.chipName
        if raw.hasPrefix("Apple ") {
            return String(raw.dropFirst(6))
        }
        return raw
    }
    
    private var currentDateBadge: String {
        DateFormatterCache.shared.string(from: Date(), format: "MM/dd")
    }
    
    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .serif))
            .tracking(1.8)
            .foregroundStyle(.secondary.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
    
    private func sidebarRow(title: String, icon: String, path: String, isCustom: Bool) -> some View {
        let isSelected = isCurrentPath(path)
        let isHovered = hoveredItemPath == path
        
        return Button(action: {
            let targetURL = URL(fileURLWithPath: path)
            onSelectDirectory(targetURL)
        }) {
            if isIconRail {
                ZStack(alignment: .leading) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(iconColor(isSelected: isSelected))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    
                    if isSelected {
                        Capsule()
                            .fill(TTZipTheme.bambooGreen)
                            .frame(width: 2.5, height: 18)
                            .padding(.leading, 2)
                    }
                }
                .frame(width: 36, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconRailRowBackgroundColor(isSelected: isSelected, isHovered: isHovered))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.3) : Color.clear, lineWidth: 0.8)
                )
                .help(title)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(iconColor(isSelected: isSelected))
                        .frame(width: 18, alignment: .center)
                    
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer(minLength: 0)
                    
                    if isCustom {
                        Button(action: { removeCustomPinnedFolder(path: path) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovered ? 1.0 : 0.0)
                        .help(l10n.currentLanguage == .zhHans ? "移除此快捷方式" : "Unpin shortcut")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(rowBackgroundColor(isSelected: isSelected, isHovered: isHovered))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.3) : Color.clear, lineWidth: 0.8)
                )
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                if hovering {
                    hoveredItemPath = path
                } else if hoveredItemPath == path {
                    hoveredItemPath = nil
                }
            }
        }
        .contextMenu {
            Button(l10n.currentLanguage == .zhHans ? "在访达中显示" : "Reveal in Finder") {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
            
            Button(l10n.currentLanguage == .zhHans ? "在终端中打开" : "Open in Terminal") {
                openTerminal(at: path)
            }
            
            Divider()
            
            if isCustom {
                Button(l10n.currentLanguage == .zhHans ? "从常用中移除" : "Remove from Favorites") {
                    removeCustomPinnedFolder(path: path)
                }
            }
        }
    }
    
    // MARK: - Helpers & Styling
    
    private func isCurrentPath(_ path: String) -> Bool {
        return currentDirectory.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }
    
    private func isVolumePath(_ path: String) -> Bool {
        return path == "/" || path.lowercased().hasPrefix("/volumes/")
    }
    
    private func rowBackgroundColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return TTZipTheme.bambooGreen.opacity(0.14)
        } else if isHovered {
            // Delicate hover tint adhering to macOS HIG to prevent double-selection illusion
            return Color.primary.opacity(0.02)
        } else {
            return Color.clear
        }
    }
    
    private func iconRailRowBackgroundColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return TTZipTheme.bambooGreen.opacity(0.16)
        } else if isHovered {
            return Color.primary.opacity(0.05)
        } else {
            return Color.clear
        }
    }
    
    private func iconColor(isSelected: Bool) -> Color {
        if isSelected {
            return TTZipTheme.bambooGreen
        }
        // Zen minimalist grayscale for unselected items to eliminate rainbow toybox clutter
        return .secondary.opacity(0.85)
    }
    
    private func loadFavorites() {
        Task.detached(priority: .userInitiated) {
            let favs = FinderFavoritesReader.fetchFavorites()
            await MainActor.run {
                self.dynamicFinderFavorites = favs
            }
        }
    }
    
    private func addCustomPinnedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = l10n.currentLanguage == .zhHans ? "固定为常用" : "Pin Folder"
        panel.message = l10n.currentLanguage == .zhHans ? "请选择要常驻至侧边栏的目录：" : "Select folder to pin to sidebar:"
        
        if panel.runModal() == .OK {
            var current = customPinnedPaths
            for url in panel.urls {
                if !current.contains(url.path) {
                    current.append(url.path)
                }
            }
            saveCustomPinnedPaths(current)
        }
    }
    
    private func removeCustomPinnedFolder(path: String) {
        var current = customPinnedPaths
        current.removeAll { $0 == path }
        saveCustomPinnedPaths(current)
    }
    
    private func openTerminal(at path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }
}
