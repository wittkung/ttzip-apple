// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import TTZipCore
import AppKit
import TTZipUI
import TTKitDesign

// MARK: - 52pt Golden Baseline Layout Geometry Invariants

/// Canonical layout geometry metrics and HIG invariants for the 52.0pt main toolbar.
public enum MainToolbarLayoutMetrics {
    /// Strict 52.0pt topbar height conforming to WSJ Editorial typography and HIG.
    public static let toolbarHeight: CGFloat = TTZipUniversalTokens.Layout.headerBarHeight
    
    /// Native window controls (traffic lights) and drag safety clearance offset (38.0pt).
    public static let windowControlDragOffset: CGFloat = 38.0
    
    /// Global baseline alignment at Y = windowControlDragOffset + toolbarHeight = 38.0 + 52.0 = 90.0pt.
    public static let goldenBaselineY: CGFloat = windowControlDragOffset + toolbarHeight
    
    /// Minimum interactive control hit target dimension (Apple HIG >= 28.0pt).
    public static let minHitTarget: CGFloat = 28.0
}

// MARK: - Spring Damping Button Style

/// An Apple HIG-compliant button style applying dual-damping spring physics to pressed and hover states.
public struct ToolbarDampedButtonStyle: ButtonStyle {
    public init() {}
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.ttMicro, value: configuration.isPressed)
    }
}

// MARK: - Interactive Toolbar Icon Button

/// An Apple HIG-compliant toolbar icon button with 28pt minimum hit target and binary spring damping.
public struct ToolbarIconButton: View {
    public let systemImage: String
    public let isActive: Bool
    public let activeColor: Color
    public let inactiveColor: Color
    public let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    public init(
        systemImage: String,
        isActive: Bool = false,
        activeColor: Color = TTZipTheme.bambooGreen,
        inactiveColor: Color = .secondary,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.isActive = isActive
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isActive ? activeColor : inactiveColor)
                .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? TTZipUniversalTokens.Plate.surfaceL3.opacity(0.8) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHovered ? TTZipUniversalTokens.Border.specularHairline : Color.clear,
                            lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarDampedButtonStyle())
        .onHover { hovering in
            withAnimation(.ttMicro) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Toolbar Mode Switch Slider

/// An Apple HIG-compliant segmented mode switch slider with dual-damping spring dynamics.
public struct ToolbarModeSwitchSlider<T: Hashable>: View {
    public let options: [T]
    @Binding public var selection: T
    public let title: (T) -> String
    public let icon: ((T) -> String)?
    public let shortcut: ((T) -> KeyEquivalent)?
    
    @Namespace private var sliderNamespace
    
    public init(
        options: [T],
        selection: Binding<T>,
        title: @escaping (T) -> String,
        icon: ((T) -> String)? = nil,
        shortcut: ((T) -> KeyEquivalent)? = nil
    ) {
        self.options = options
        self._selection = selection
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
    }
    
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segmentButton(for: option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TTZipUniversalTokens.Plate.surfaceL1.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(TTZipUniversalTokens.Border.specularHairline, lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth)
        )
    }
    
    @ViewBuilder
    private func segmentButton(for option: T) -> some View {
        let isSelected = (selection == option)
        let optShortcut = shortcut?(option)
        let optTitle = title(option)
        let optHelp: String = {
            if let optShortcut {
                return "\(optTitle) (⌘\(optShortcut.character))"
            } else {
                return optTitle
            }
        }()
        
        Button {
            withAnimation(.ttMicro) {
                selection = option
            }
        } label: {
            HStack(spacing: 4) {
                if let iconName = icon?(option) {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(optTitle)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? TTZipUniversalTokens.Text.primary : Color.secondary)
            .padding(.horizontal, 8)
            .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
            .background(capsuleBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarDampedButtonStyle())
        .applyKeyboardShortcut(optShortcut)
        .ttButtonHelp(optHelp)
        .accessibilityLabel(optTitle)
    }
    
    @ViewBuilder
    private func capsuleBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(TTZipUniversalTokens.Plate.surfaceL3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(TTZipUniversalTokens.Border.specularHairline, lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth)
                )
                .matchedGeometryEffect(id: "SLIDER_CAPSULE", in: sliderNamespace)
                .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
        }
    }
}

private extension View {
    @ViewBuilder
    func applyKeyboardShortcut(_ key: KeyEquivalent?) -> some View {
        if let key {
            self.keyboardShortcut(key, modifiers: [.command])
        } else {
            self
        }
    }
}

// MARK: - Explorer View Mode Taxonomy

/// Canonical view mode classification conforming to Feature 233 and TTWorkspace Architecture Spec §6.8.
public enum ExplorerViewMode: String, CaseIterable, Identifiable, Sendable {
    /// Canonical persistent storage key for the active explorer view mode.
    public static let storageKey: String = "TTZip_ActiveExplorerViewMode"

    case column = "column"
    case list = "list"
    case treemap = "treemap"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .column: return "rectangle.split.3x1"
        case .list: return "list.bullet"
        case .treemap: return "square.grid.3x3.fill"
        }
    }

    public var keyboardKey: KeyEquivalent {
        switch self {
        case .column: return KeyEquivalent("1")
        case .list: return KeyEquivalent("2")
        case .treemap: return KeyEquivalent("3")
        }
    }

    public var titleKey: any LocaleKeyProtocol {
        switch self {
        case .column: return L10n.Explorer.columnsView
        case .list: return L10n.Explorer.listView
        case .treemap: return L10n.Explorer.treemapView
        }
    }

    @MainActor
    public var title: String {
        AppLocalizationState.shared.t(titleKey)
    }
}

// MARK: - Dedicated Toolbar View Mode Segmented Control

/// Segmented mode switch controller providing an exclusive closed loop between Column (⌘1), List (⌘2), and Treemap (⌘3).
public struct ToolbarViewModeSegmentedControl: View {
    @AppStorage(ExplorerViewMode.storageKey) private var viewModeRaw: String = ExplorerViewMode.column.rawValue
    private let externalBinding: Binding<ExplorerViewMode>?

    public init(selectedMode: Binding<ExplorerViewMode>? = nil) {
        self.externalBinding = selectedMode
    }

    private var activeModeBinding: Binding<ExplorerViewMode> {
        if let externalBinding {
            return externalBinding
        }
        return Binding(
            get: { ExplorerViewMode(rawValue: viewModeRaw) ?? .column },
            set: { viewModeRaw = $0.rawValue }
        )
    }

    public var body: some View {
        ToolbarModeSwitchSlider(
            options: ExplorerViewMode.allCases,
            selection: activeModeBinding,
            title: { $0.title },
            icon: { $0.iconName },
            shortcut: { $0.keyboardKey }
        )
    }
}

// MARK: - 52pt Standalone Top Toolbar View

/// Standalone 52.0pt topbar header container strictly adhering to Apple HIG,
/// 38.0pt window controls clearance offset, and Y = 90.0pt Golden Baseline alignment.
public struct MainTop52ptToolbarView<Leading: View, Center: View, Trailing: View>: View {
    public let topDragClearance: CGFloat
    public let leadingContent: Leading
    public let centerContent: Center
    public let trailingContent: Trailing
    
    public init(
        topDragClearance: CGFloat = MainToolbarLayoutMetrics.windowControlDragOffset,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.topDragClearance = topDragClearance
        self.leadingContent = leading()
        self.centerContent = center()
        self.trailingContent = trailing()
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Top safety zone clearance for traffic lights and window dragging (38.0pt)
            if topDragClearance > 0 {
                Color.clear
                    .frame(height: topDragClearance)
                    .contentShape(Rectangle())
            }
            
            // Core 52.0pt toolbar bar strictly locked at headerBarHeight
            HStack(alignment: .center, spacing: 10) {
                leadingContent
                
                Spacer(minLength: 8)
                
                centerContent
                
                Spacer(minLength: 8)
                
                trailingContent
            }
            .padding(.horizontal, 16)
            .frame(height: MainToolbarLayoutMetrics.toolbarHeight)
            
            // Kintsugi Gold Specular Hairline aligning the global golden rule line at Y = 90.0pt
            TTKintsugiDivider(.horizontal, falloff: false)
                .frame(height: TTZipUniversalTokens.Dimensions.hairlineWidth)
        }
        .frame(height: topDragClearance + MainToolbarLayoutMetrics.toolbarHeight + TTZipUniversalTokens.Dimensions.hairlineWidth)
    }
}

// MARK: - MainView Toolbar Extension

extension MainView {
    @ToolbarContentBuilder
    var mainToolbarContent: some ToolbarContent {
        if !viewModel.overlayState.showImmersiveMediaBrowser {
            ToolbarItem(placement: .navigation) {
                sidebarToggleItem
            }
            
            ToolbarItem(placement: .automatic) {
                openArchiveToolbarButton
            }
            
            ToolbarItem(placement: .automatic) {
                newArchiveToolbarButton
            }
            
            ToolbarItem(placement: .automatic) {
                ToolbarViewModeSegmentedControl()
            }
            
            archiveActionToolbarItems
            
            ToolbarItem(placement: .automatic) {
                toolboxMenuToolbarItem
            }
            
            ToolbarItem(placement: .primaryAction) {
                inspectorToggleItem
            }
        }
    }

    @ViewBuilder
    private var sidebarToggleItem: some View {
        Button {
            withAnimation(.ttMicro) {
                viewModel.navigationState.isLeftSidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(viewModel.navigationState.isLeftSidebarVisible ? TTZipTheme.bambooGreen : .secondary)
                .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarDampedButtonStyle())
        .ttButtonHelp(String(localized: "Toggle Favorites Sidebar (⌃⌘S)"))
        .accessibilityLabel(String(localized: "Toggle Favorites Sidebar"))
        .accessibilityHint(String(localized: "Show or hide favorites sidebar and mounted volumes"))
        .keyboardShortcut("s", modifiers: [.control, .command])
    }

    @ViewBuilder
    private var openArchiveToolbarButton: some View {
        Button { pickAndOpenArchive() } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarDampedButtonStyle())
        .keyboardShortcut("o", modifiers: [.command])
        .ttButtonHelp(l10n.t(L10n.Menu.openArchive) + " (⌘O)")
        .accessibilityLabel(l10n.t(L10n.Menu.openArchive))
    }

    @ViewBuilder
    private var newArchiveToolbarButton: some View {
        NewArchiveToolbarButton(
            title: l10n.t(L10n.Sidebar.newArchive)
        ) {
            withAnimation(.ttMicro) {
                viewModel.openCompressWorkspace()
            }
        }
        .keyboardShortcut("n", modifiers: [.command])
        .ttButtonHelp(l10n.t(L10n.Menu.newArchiveMenu) + " (⌘N)")
        .accessibilityLabel(l10n.t(L10n.Sidebar.newArchive))
    }

    @ToolbarContentBuilder
    private var archiveActionToolbarItems: some ToolbarContent {
        if viewModel.explorerState.currentArchivePath != nil && viewModel.navigationState.activeTab == .home {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    if let targetPath = viewModel.selectedDiskItem?.path ?? viewModel.explorerState.currentArchivePath {
                        Task { await viewModel.quickExtractArchive(archivePath: targetPath) }
                    } else {
                        viewModel.taskState.statusMessage = l10n.t(L10n.Explorer.extractToPrompt)
                    }
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ToolbarDampedButtonStyle())
                .keyboardShortcut("e", modifiers: [.command])
                .ttButtonHelp(l10n.t(L10n.Extract.action) + " (⌘E)")
                .accessibilityLabel(l10n.t(L10n.Extract.action))
                
                Button {
                    withAnimation(.ttMicro) {
                        PresentationCoordinator.shared.present(.extract)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ToolbarDampedButtonStyle())
                .keyboardShortcut("e", modifiers: [.option, .command])
                .ttButtonHelp(l10n.t(L10n.Explorer.extractToPrompt) + " (⌥⌘E)")
                .accessibilityLabel(l10n.t(L10n.Explorer.extractToPrompt))
                
                Button {
                    withAnimation(.ttMicro) {
                        viewModel.reset()
                        PresentationCoordinator.shared.dismiss()
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ToolbarDampedButtonStyle())
                .ttButtonHelp(l10n.t(L10n.Common.close))
                .accessibilityLabel(l10n.t(L10n.Common.close))
            }
        }
    }

    @ViewBuilder
    private var toolboxMenuToolbarItem: some View {
        Menu {
            Button {
                PresentationCoordinator.shared.present(.secondaryTool(.presets))
            } label: {
                Label(l10n.t(L10n.Sidebar.presets), systemImage: "slider.horizontal.3")
            }
            
            Button {
                PresentationCoordinator.shared.present(.secondaryTool(.benchmark))
            } label: {
                Label(l10n.t(L10n.Sidebar.benchmark), systemImage: "speedometer")
            }
            
            Button {
                PresentationCoordinator.shared.present(.secondaryTool(.vault))
            } label: {
                Label(l10n.t(L10n.Sidebar.vault), systemImage: "key.fill")
            }
            
            Divider()
            
            Button {
                PresentationCoordinator.shared.present(.secondaryTool(.settings))
            } label: {
                Label(l10n.t(L10n.Sidebar.settings), systemImage: "gearshape.fill")
            }
            .keyboardShortcut(",", modifiers: [.command])
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .ttButtonHelp(String(localized: "Toolbox"))
        .accessibilityLabel(String(localized: "Toolbox"))
    }

    @ViewBuilder
    private var inspectorToggleItem: some View {
        Button {
            viewModel.toggleInspector(animated: true)
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(viewModel.navigationState.isInspectorVisible ? TTZipTheme.bambooGreen : .secondary)
                .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarDampedButtonStyle())
        .ttButtonHelp(String(localized: "Toggle Inspector Panel (⌘I)"))
        .accessibilityLabel(String(localized: "Toggle Inspector Panel"))
        .accessibilityHint(String(localized: "Show or hide the inspector panel"))
        .keyboardShortcut("i", modifiers: [.command])
    }
    
    func openArchiveFromURL(_ url: URL) {
        let path = url.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            viewModel.openCompressWorkspace(paths: [path])
        } else {
            viewModel.openArchiveAsFolder(url: url)
        }
    }
    
    func pickAndOpenArchive() {
        if let firstPath = SystemDialogHelper.pickFiles(prompt: l10n.t(L10n.Menu.openArchive), canChooseDirectories: false, allowsMultipleSelection: false).first {
            viewModel.openArchiveAsFolder(url: URL(fileURLWithPath: firstPath))
        }
    }
}

// MARK: - New Archive Toolbar Prominent Button

/// A lightweight translucent action button conforming to Zen minimalist design and macOS HIG.
/// Renders an independent bamboo green accent control with delicate border and smooth transitions.
public struct NewArchiveToolbarButton: View {
    public let title: String
    public let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(TTZipTheme.bambooGreen)
            .padding(.horizontal, 9)
            .frame(minWidth: MainToolbarLayoutMetrics.minHitTarget, minHeight: MainToolbarLayoutMetrics.minHitTarget)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(TTZipTheme.bambooGreen.opacity(isHovered ? 0.16 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        TTZipTheme.bambooGreen.opacity(isHovered ? 0.32 : 0.18),
                        lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarDampedButtonStyle())
        .accessibilityLabel(title)
        .ttButtonHelp(title)
        .onHover { hovering in
            withAnimation(.ttMicro) {
                isHovered = hovering
            }
        }
    }
}
