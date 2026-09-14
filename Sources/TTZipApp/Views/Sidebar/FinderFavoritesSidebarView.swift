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
    public var onSelectAndroidDevice: ((AndroidDevice) -> Void)? = nil
    
    private var l10n = AppLocalizationState.shared
    private var licenseManager = AppLicenseManager.shared
    @State private var androidViewModel = AndroidDeviceViewModel.shared
    @State private var dynamicFinderFavorites: [FinderFavoriteItem] = []
    @State private var hoveredItemPath: String? = nil
    @State private var showWirelessDiscoverySheet: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var hasResolvedCustomFavorites: Bool = false
    @State private var activeSection: SidebarSection? = nil
    
    private enum SidebarSection: Hashable {
        case pinned
        case favorites
        case locations
    }
    
    @AppStorage("TTZipCustomShortcutFolderPaths") private var customPinnedPathsJSON: String = "[]"
    
    public init(
        currentDirectory: URL,
        isIconRail: Bool = false,
        androidViewModel: AndroidDeviceViewModel = .shared,
        onSelectDirectory: @escaping (URL) -> Void,
        onSelectAndroidDevice: ((AndroidDevice) -> Void)? = nil
    ) {
        self.currentDirectory = currentDirectory
        self.isIconRail = isIconRail
        self.androidViewModel = androidViewModel
        self.onSelectDirectory = onSelectDirectory
        self.onSelectAndroidDevice = onSelectAndroidDevice
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
                    // Group 0: Custom Pinned Directories
                    if !isIconRail {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                sectionHeader(title: l10n.currentLanguage == .zhHans ? "常用" : "PINNED")
                                Spacer()
                                Button(action: addCustomFolder) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.secondary)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(l10n.currentLanguage == .zhHans ? "选择文件夹固定到侧边栏..." : "Pin folder to sidebar...")
                            }
                            .padding(.trailing, 8)
                            
                            ForEach(customPinnedPaths, id: \.self) { path in
                                let url = URL(fileURLWithPath: path)
                                sidebarRow(
                                    title: url.lastPathComponent,
                                    icon: "folder",
                                    path: path,
                                    section: .pinned
                                )
                            }
                        }
                    }
                    
                    // Group 1: Favorites
                    VStack(alignment: isIconRail ? .center : .leading, spacing: isIconRail ? 4 : 2) {
                        if !isIconRail {
                            HStack {
                                sectionHeader(title: l10n.currentLanguage == .zhHans ? "个人收藏" : "FAVORITES")
                                Spacer()
                                
                                Button(action: authorizeFinderFavorites) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(hasResolvedCustomFavorites ? Color.secondary.opacity(0.65) : TTZipTheme.bambooGreen)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(hasResolvedCustomFavorites
                                    ? (l10n.currentLanguage == .zhHans ? "已同步访达个人收藏 (点击重新同步)" : "Finder Favorites Synced (Click to re-sync)")
                                    : (l10n.currentLanguage == .zhHans ? "同步系统访达全部个人收藏..." : "Sync macOS Finder Favorites..."))
                            }
                            .padding(.trailing, 8)
                        }
                        
                        ForEach(dynamicFinderFavorites.filter { !isVolumePath($0.path) }) { item in
                            sidebarRow(
                                title: item.name,
                                icon: item.systemImage,
                                path: item.path,
                                section: .favorites
                            )
                        }
                    }
                    
                    // Group 2: Locations
                    let volumeItems = dynamicFinderFavorites.filter { isVolumePath($0.path) }
                    let androidDevices = androidViewModel.connectedDevices
                    if !volumeItems.isEmpty || !androidDevices.isEmpty {
                        if isIconRail {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 24, height: 0.8)
                                .padding(.vertical, 4)
                        }
                        
                        VStack(alignment: isIconRail ? .center : .leading, spacing: isIconRail ? 4 : 2) {
                            if !isIconRail {
                                HStack {
                                    sectionHeader(title: l10n.currentLanguage == .zhHans ? "位置" : "LOCATIONS")
                                    Spacer()
                                    Button(action: { showWirelessDiscoverySheet = true }) {
                                        Image(systemName: "wifi.badge.plus")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.secondary.opacity(0.75))
                                             .frame(width: 18, height: 18)
                                    }
                                    .buttonStyle(.plain)
                                    .help(l10n.currentLanguage == .zhHans ? "发现并配对无线安卓设备" : "Discover & Pair Wireless Android")
                                }
                                .padding(.trailing, 8)
                            }
                            
                            ForEach(volumeItems) { item in
                                sidebarRow(
                                    title: item.name,
                                    icon: item.systemImage,
                                    path: item.path,
                                    section: .locations
                                )
                            }
                            
                            ForEach(androidDevices) { device in
                                androidDeviceRow(device: device)
                            }
                        }
                    }
                }
                .padding(.horizontal, isIconRail ? 4 : 8)
                .padding(.top, 10)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: isIconRail ? .center : .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isDropTargeted ? TTZipTheme.bambooGreen.opacity(0.6) : Color.clear, lineWidth: 1.5)
                    .padding(2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleFolderDrop(providers)
            }
            
            // MARK: - 3. Apple Silicon Hardware & Engine Footer
            sidebarHardwareFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .sheet(isPresented: $showWirelessDiscoverySheet) {
            WirelessDeviceDiscoveryView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredItemPath = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loadFavorites()
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
                                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .background(TTZipTheme.kintsugiGoldEditorial.opacity(0.12))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().strokeBorder(TTZipTheme.kintsugiGoldEditorial.opacity(0.35), lineWidth: 0.6)
                                )
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    
                    Spacer(minLength: 4)
                    
                    Button(action: addCustomFolder) {
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
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.8)
            
            Group {
                if isIconRail {
                    HStack {
                        Spacer(minLength: 0)
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TTZipTheme.bambooGreen.opacity(0.85))
                            
                            Circle()
                                .fill(TTZipTheme.bambooGreen)
                                .frame(width: 4, height: 4)
                                .offset(x: 2, y: -2)
                        }
                        .help("\(hardwareChipSummary) · \(l10n.currentLanguage == .zhHans ? "加速就绪" : "Engine Online")")
                        Spacer(minLength: 0)
                    }
                    .frame(height: 32)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        
                        Text(hardwareChipSummary)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer(minLength: 4)
                        
                        HStack(spacing: 3.5) {
                            Circle()
                                .fill(TTZipTheme.bambooGreen)
                                .frame(width: 4.5, height: 4.5)
                            Text(l10n.currentLanguage == .zhHans ? "加速就绪" : "Online")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                        .help(l10n.currentLanguage == .zhHans ? "Apple Silicon 硬件加速引擎就绪" : "Apple Silicon Hardware Engine Online")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                }
            }
            .frame(height: 32)
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
    
    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
    
    private func sidebarRow(title: String, icon: String, path: String, section: SidebarSection) -> some View {
        let isSelected = isRowSelected(path: path, section: section)
        let isHovered = hoveredItemPath == path
        let isCustom = section == .pinned
        let displayIcon = standardizedSidebarIcon(icon)
        
        return Button(action: {
            activeSection = section
            let targetURL = URL(fileURLWithPath: path)
            onSelectDirectory(targetURL)
        }) {
            if isIconRail {
                ZStack(alignment: .leading) {
                    Image(systemName: displayIcon)
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
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconRailRowBackgroundColor(isSelected: isSelected, isHovered: isHovered))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.3) : Color.clear, lineWidth: 0.8)
                )
                .help(title)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 8) {
                    Image(systemName: displayIcon)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
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
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(rowBackgroundColor(isSelected: isSelected, isHovered: isHovered))
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
    
    private func isRowSelected(path: String, section: SidebarSection) -> Bool {
        guard isCurrentPath(path) else { return false }
        let currentNorm = currentDirectory.standardizedFileURL.path
        let inPinned = customPinnedPaths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == currentNorm }
        let inFavorites = dynamicFinderFavorites.contains { !isVolumePath($0.path) && URL(fileURLWithPath: $0.path).standardizedFileURL.path == currentNorm }
        if inPinned && inFavorites {
            return activeSection.map { $0 == section } ?? (section == .pinned)
        }
        return true
    }
    
    private func standardizedSidebarIcon(_ icon: String) -> String {
        if icon == "arrow.down.circle.fill" { return "arrow.down.circle" }
        if icon.hasSuffix(".fill") && !icon.contains("badge") {
            let outline = String(icon.dropLast(5))
            return outline.isEmpty ? icon : outline
        }
        return icon
    }
    
    private func isVolumePath(_ path: String) -> Bool {
        return path == "/" || path.lowercased().hasPrefix("/volumes/")
    }
    
    private func rowBackgroundColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.primary.opacity(0.08)
        } else if isHovered {
            return Color.primary.opacity(0.035)
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
            return .primary
        }
        return .secondary
    }
    
    private func loadFavorites() {
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                FinderFavoritesReader.fetchFavoritesResult()
            }.value
            self.dynamicFinderFavorites = result.items
            self.hasResolvedCustomFavorites = result.hasResolvedCustomFavorites
        }
    }
    
    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    Task { @MainActor in
                        var current = self.customPinnedPaths
                        let canonical = url.standardizedFileURL.path
                        if !current.contains(canonical) {
                            current.append(canonical)
                            self.saveCustomPinnedPaths(current)
                        }
                    }
                }
            }
        }
        return true
    }
    
    private func authorizeFinderFavorites() {
        let alert = NSAlert()
        alert.messageText = l10n.currentLanguage == .zhHans
            ? "同步访达个人收藏"
            : "Sync macOS Finder Favorites"
        alert.informativeText = l10n.currentLanguage == .zhHans
            ? "受 macOS 隐私与安全性机制保护，TTZip 需要读取您的访达共享文件列表。\n\n在接下来的系统窗口中已为您预选对应目录，请直接点击右下角「授权同步」即可完成导入。"
            : "Due to macOS privacy protections, TTZip needs access to your Finder shared file list.\n\nThe folder will be targeted in the dialog—simply click 'Authorize Sync' to import."
        alert.addButton(withTitle: l10n.currentLanguage == .zhHans ? "前往授权" : "Authorize")
        alert.addButton(withTitle: l10n.currentLanguage == .zhHans ? "取消" : "Cancel")
        alert.alertStyle = .informational
        
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        let home = NSHomeDirectory()
        let sflPath = (home as NSString).appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: sflPath)
        panel.prompt = l10n.currentLanguage == .zhHans ? "授权同步" : "Authorize Sync"
        panel.message = l10n.currentLanguage == .zhHans
            ? "请直接点击右下角「授权同步」完成访达个人收藏导入："
            : "Click 'Authorize Sync' to import your macOS Finder favorites:"
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            FinderFavoritesReader.saveSecurityScopedBookmark(for: selectedURL)
            loadFavorites()
        }
    }
    
    private func addCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = l10n.currentLanguage == .zhHans ? "固定到侧边栏" : "Pin to Sidebar"
        panel.message = l10n.currentLanguage == .zhHans
            ? "选择要固定到左侧边栏的常用文件夹："
            : "Choose folders to pin to sidebar:"
        if panel.runModal() == .OK {
            var current = customPinnedPaths
            for url in panel.urls {
                let path = url.path
                if !current.contains(path) {
                    current.append(path)
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
    
    // MARK: - Android Device Sidebar Rows
    
    private func androidDeviceRow(device: AndroidDevice) -> some View {
        let isSelected = androidViewModel.selectedDevice?.deviceId == device.deviceId
        let isHovered = hoveredItemPath == device.deviceId
        let deviceIcon = androidDeviceIcon(device)
        
        return Button(action: {
            androidViewModel.selectDevice(device)
            onSelectAndroidDevice?(device)
        }) {
            if isIconRail {
                ZStack(alignment: .leading) {
                    Image(systemName: deviceIcon)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : .secondary.opacity(0.85))
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
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconRailRowBackgroundColor(isSelected: isSelected, isHovered: isHovered))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.3) : Color.clear, lineWidth: 0.8)
                )
                .help("\(device.displayName) (\(device.connectionType.description))")
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 7) {
                    Image(systemName: deviceIcon)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : .secondary.opacity(0.85))
                        .frame(width: 18, alignment: .center)
                    
                    Text(device.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer(minLength: 2)
                    
                    connectionModeBadge(type: device.connectionType)
                    
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            androidViewModel.ejectDevice(device)
                        }
                    }) {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(isHovered ? 0.9 : 0.4))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.currentLanguage == .zhHans ? "弹出此安卓设备" : "Eject Android Device")
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(rowBackgroundColor(isSelected: isSelected, isHovered: isHovered))
                )
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                if hovering {
                    hoveredItemPath = device.deviceId
                } else if hoveredItemPath == device.deviceId {
                    hoveredItemPath = nil
                }
            }
        }
        .contextMenu {
            Button(l10n.currentLanguage == .zhHans ? "弹出设备" : "Eject Device") {
                androidViewModel.ejectDevice(device)
            }
            
            if device.connectionType == .usbMtp {
                Button(l10n.currentLanguage == .zhHans ? "切换至高速 ADB 模式..." : "Switch to High-Speed ADB Mode...") {
                    androidViewModel.showAdbGuideSheet = true
                }
            }
            
            Divider()
            
            Text("ID: \(device.deviceId)")
                .font(.caption)
            Text(l10n.currentLanguage == .zhHans ? "状态: \(device.status.description)" : "Status: \(device.status.description)")
                .font(.caption)
        }
    }
    
    private func androidDeviceIcon(_ device: AndroidDevice) -> String {
        if device.connectionType == .wirelessAdb {
            return "iphone.badge.play"
        }
        let lower = device.displayName.lowercased()
        if lower.contains("pad") || lower.contains("tablet") {
            return "ipad"
        }
        return "iphone"
    }
    
    private func connectionModeBadge(type: AndroidConnectionType) -> some View {
        let (title, bg, fg): (String, Color, Color) = {
            switch type {
            case .usbMtp:
                return ("MTP", Color.primary.opacity(0.06), Color.secondary)
            case .usbAdb:
                return ("ADB", TTZipTheme.bambooGreen.opacity(0.16), TTZipTheme.bambooGreen)
            case .wirelessAdb:
                return ("Wi-Fi", TTZipTheme.kintsugiGold.opacity(0.18), TTZipTheme.kintsugiGold)
            }
        }()
        
        return Text(title)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(fg)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(bg)
            .clipShape(Capsule())
    }
}
