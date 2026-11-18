// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipPreviewKit
import TTZipUI

/// Root preferences workspace supporting adaptive sidebar/compact navigation across all 6 settings categories.
public struct SettingsView: View {
    public static let sidebarLayoutBreakpoint: CGFloat = 540
    public static let sidebarWidth: CGFloat = 216
    public static let maxFormContentWidth: CGFloat = 600
    public static let rendersInternalWorkspaceHeader: Bool = false
    public static let rendersFullPageEnclosedCard: Bool = false

    public static func usesSidebarNavigation(forWidth width: CGFloat) -> Bool {
        let resolvedWidth = width > 0 ? width : 720
        return resolvedWidth >= sidebarLayoutBreakpoint
    }

    public static func adjacentTab(from current: SettingsTab, offset: Int) -> SettingsTab {
        let all = SettingsTab.allCases
        guard let currentIndex = all.firstIndex(of: current), !all.isEmpty else {
            return current
        }
        let targetIndex = max(0, min(all.count - 1, currentIndex + offset))
        return all[targetIndex]
    }

    public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
        case general
        case localization
        case presets
        case vault
        case localModels
        case license

        public var id: String { rawValue }

        public var titleKey: any LocaleKeyProtocol {
            switch self {
            case .general: return L10n.Settings.general
            case .localization: return L10n.Settings.localization
            case .presets: return L10n.Presets.title
            case .vault: return L10n.Vault.title
            case .localModels: return L10n.LocalModel.tabTitle
            case .license: return L10n.Settings.licenseStatus
            }
        }

        public var title: String {
            switch self {
            case .localModels:
                return L10n.Settings.localModels
            default:
                return TTZipLocalizationManager.shared.string(for: titleKey)
            }
        }

        @MainActor
        public func localizedTitle(using l10n: AppLocalizationState) -> String {
            self == .localModels ? l10n.t(L10n.LocalModel.tabTitle) : l10n.t(titleKey)
        }

        public var icon: String {
            switch self {
            case .general: return "gearshape"
            case .localization: return "globe"
            case .presets: return "slider.horizontal.3"
            case .vault: return "lock.shield"
            case .localModels: return "square.stack.3d.up"
            case .license: return "checkmark.seal"
            }
        }

        public var systemImage: String {
            icon
        }
    }

    @Bindable var l10n = AppLocalizationState.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var selectedTab: SettingsTab
    @State private var hoveredTab: SettingsTab?
    @State private var compressionDefaultsStore: CompressionDefaultsStore

    private let initialTab: SettingsTab
    private let modelManager: LocalModelManager
    public let appearanceStore: ApplicationAppearanceStore
    private let defaults: UserDefaults
    private let textReadingStore: TTTextReadingPreferenceStore
    private let presetManager: PresetManager
    private let vaultManager: PasswordVaultManager
    private let onOpenWorkspaceTool: ((WorkspaceTab) -> Void)?

    public init(
        initialTab: SettingsTab = .general,
        modelManager: LocalModelManager = .shared,
        appearanceStore: ApplicationAppearanceStore = .shared,
        defaults: UserDefaults = .standard,
        compressionDefaultsStore: CompressionDefaultsStore? = nil,
        textReadingStore: TTTextReadingPreferenceStore = .shared,
        presetManager: PresetManager = .shared,
        vaultManager: PasswordVaultManager = .shared,
        onOpenWorkspaceTool: ((WorkspaceTab) -> Void)? = nil
    ) {
        self.initialTab = initialTab
        self._selectedTab = State(initialValue: initialTab)
        self.modelManager = modelManager
        self.appearanceStore = appearanceStore
        self.defaults = defaults
        let fallbackOpenFinder = !RootFolderAccessManager.isIsolatedVerificationProcess
        self._compressionDefaultsStore = State(
            initialValue: compressionDefaultsStore
                ?? CompressionDefaultsStore(defaults: defaults, defaultOpenFinder: fallbackOpenFinder)
        )
        self.textReadingStore = textReadingStore
        self.presetManager = presetManager
        self.vaultManager = vaultManager
        self.onOpenWorkspaceTool = onOpenWorkspaceTool
    }

    var visualStyle: SettingsVisualStyle {
        SettingsVisualStyle(
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency,
            colorSchemeContrast: colorSchemeContrast
        )
    }

    @ViewBuilder
    private var currentTabView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsPane(
                appearanceStore: appearanceStore,
                textReadingStore: textReadingStore,
                defaults: defaults,
                style: visualStyle
            )
        case .localization:
            LocalizationSettingsPane(style: visualStyle)
        case .presets:
            CompressionDefaultsSettingsPane(
                store: compressionDefaultsStore,
                presetManager: presetManager,
                style: visualStyle,
                onOpenPresets: onOpenWorkspaceTool.map { callback in { callback(.presets) } }
            )
        case .vault:
            VaultSettingsPane(
                vaultManager: vaultManager,
                style: visualStyle,
                onOpenVault: onOpenWorkspaceTool.map { callback in { callback(.vault) } }
            )
        case .localModels:
            LocalModelSettingsSectionView(modelManager: modelManager)
        case .license:
            LicenseAndSystemSettingsPane(style: visualStyle)
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let isSidebarMode = Self.usesSidebarNavigation(forWidth: proxy.size.width)
            Group {
                if isSidebarMode {
                    wideSidebarContainer
                } else {
                    narrowCompactContainer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: initialTab) { _, newValue in
            selectedTab = newValue
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.rootContainer")
    }

    private var wideSidebarContainer: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebarNavigationColumn
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(navigationSurfaceBackground)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.navigation.sidebar")

            Rectangle()
                .fill(visualStyle.borderColor)
                .frame(width: visualStyle.borderWidth)

            settingsContentScrollPane(horizontalPadding: 24, verticalPadding: 20)
        }
    }

    private var narrowCompactContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactTopNavigationBar
                .background(navigationSurfaceBackground)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.navigation.compactBar")

            Rectangle()
                .fill(visualStyle.borderColor)
                .frame(height: visualStyle.borderWidth)

            settingsContentScrollPane(horizontalPadding: 16, verticalPadding: 16)
        }
    }

    private var sidebarNavigationColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                navigationTabButton(for: tab, isCompactHorizontal: false)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .onKeyPress(.upArrow) {
            selectTab(Self.adjacentTab(from: selectedTab, offset: -1))
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectTab(Self.adjacentTab(from: selectedTab, offset: 1))
            return .handled
        }
    }

    private var compactTopNavigationBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    navigationTabButton(for: tab, isCompactHorizontal: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .onKeyPress(.leftArrow) {
            selectTab(Self.adjacentTab(from: selectedTab, offset: -1))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selectTab(Self.adjacentTab(from: selectedTab, offset: 1))
            return .handled
        }
    }

    private func navigationTabButton(for tab: SettingsTab, isCompactHorizontal: Bool) -> some View {
        let isSelected = (selectedTab == tab)
        let titleText = tab.localizedTitle(using: l10n)
        return tabLabelContent(
            tab: tab,
            titleText: titleText,
            isSelected: isSelected,
            isCompactHorizontal: isCompactHorizontal
        )
        .padding(.horizontal, isCompactHorizontal ? 10 : 8)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .frame(maxWidth: isCompactHorizontal ? nil : .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tabFillColor(for: tab, isSelected: isSelected))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tabBorderColor(isSelected: isSelected), lineWidth: visualStyle.borderWidth)
        )
        .overlay(
            SettingsNativeButtonBridge(
                identifier: "settings.nav.tab.\(tab.rawValue)",
                title: titleText,
                isSelected: isSelected,
                onPress: { selectTab(tab) },
                onStep: { selectTab(Self.adjacentTab(from: selectedTab, offset: $0)) },
                onHoverChange: { updateHoverState(for: tab, isHovering: $0) }
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(TTZipTheme.Motion.micro, value: selectedTab)
        .animation(TTZipTheme.Motion.micro, value: hoveredTab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.nav.tab.\(tab.rawValue)")
    }

    private func tabLabelContent(
        tab: SettingsTab,
        titleText: String,
        isSelected: Bool,
        isCompactHorizontal: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if !isCompactHorizontal {
                Capsule()
                    .fill(isSelected ? TTZipTheme.bambooGreen : Color.clear)
                    .frame(width: 3, height: 15)
            }
            Image(systemName: tab.systemImage)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : visualStyle.inactiveNavTextColor)
                .frame(width: 16, alignment: .center)
            Text(titleText)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? visualStyle.primaryTextColor : visualStyle.inactiveNavTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.84)
            if !isCompactHorizontal {
                Spacer(minLength: 0)
            }
        }
    }

    private func tabFillColor(for tab: SettingsTab, isSelected: Bool) -> Color {
        if isSelected {
            return TTZipTheme.bambooGreen.opacity(visualStyle.selectedTabFillOpacity)
        }
        if hoveredTab == tab {
            return Color.primary.opacity(visualStyle.hoverTabFillOpacity)
        }
        return Color.clear
    }

    private func tabBorderColor(isSelected: Bool) -> Color {
        guard isSelected, visualStyle.increasedContrast else {
            return Color.clear
        }
        return TTZipTheme.bambooGreen.opacity(0.85)
    }

    private func updateHoverState(for tab: SettingsTab, isHovering: Bool) {
        if isHovering {
            hoveredTab = tab
        } else if hoveredTab == tab {
            hoveredTab = nil
        }
    }

    private func selectTab(_ nextTab: SettingsTab) {
        selectedTab = nextTab
    }

    @ViewBuilder
    private var navigationSurfaceBackground: some View {
        if visualStyle.reduceTransparency {
            visualStyle.navigationCanvasColor
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                visualStyle.navigationCanvasColor
            }
        }
    }

    private func settingsContentScrollPane(
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
                currentTabView
            }
            .frame(maxWidth: Self.maxFormContentWidth, alignment: .topLeading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                visualStyle.contentCanvasColor
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("settings.content.scrollView")
    }
}
