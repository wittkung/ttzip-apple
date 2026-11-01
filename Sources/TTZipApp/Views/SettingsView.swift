// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

/// Resolved optical and accessibility tokens adapted from TTZipTheme / TTKitDesign semantic tokens.
public struct SettingsVisualStyle: Equatable, Sendable {
    public let isDark: Bool
    public let reduceTransparency: Bool
    public let increasedContrast: Bool

    public init(
        colorScheme: ColorScheme,
        reduceTransparency: Bool,
        colorSchemeContrast: ColorSchemeContrast
    ) {
        self.isDark = (colorScheme == .dark)
        self.reduceTransparency = reduceTransparency
        self.increasedContrast = (colorSchemeContrast == .increased)
    }

    public var borderWidth: CGFloat {
        increasedContrast
            ? (TTZipTheme.Layout.hairlineBorderWidth * 2.0)
            : TTZipTheme.Layout.hairlineBorderWidth
    }

    public var borderColor: Color {
        increasedContrast ? Color(nsColor: .separatorColor) : TTZipTheme.hairlineBorder
    }

    public var groupBackgroundColor: Color {
        if reduceTransparency {
            return Color(nsColor: .controlBackgroundColor)
        }
        return increasedContrast ? TTZipTheme.plateSurfaceL3 : TTZipTheme.cardBackground
    }

    public var contentCanvasColor: Color {
        reduceTransparency ? Color(nsColor: .windowBackgroundColor) : TTZipTheme.plateSurfaceL2
    }

    public var navigationCanvasColor: Color {
        reduceTransparency ? Color(nsColor: .underPageBackgroundColor) : TTZipTheme.plateSurfaceL1
    }

    public var primaryTextColor: Color {
        Color(nsColor: .labelColor)
    }

    public var inactiveNavTextColor: Color {
        Color(nsColor: increasedContrast ? .labelColor : .secondaryLabelColor)
    }

    public var selectedTabFillOpacity: Double {
        if increasedContrast {
            return isDark ? 0.28 : 0.20
        }
        return isDark ? 0.20 : 0.14
    }

    public var secondaryTextColor: Color {
        Color(nsColor: increasedContrast ? .labelColor : .secondaryLabelColor)
    }
}

public struct SettingsView: View {
    public static let sidebarLayoutBreakpoint: CGFloat = 540
    public static let sidebarWidth: CGFloat = 200
    public static let maxFormContentWidth: CGFloat = 580
    public static let rendersInternalWorkspaceHeader: Bool = false
    public static let rendersFullPageEnclosedCard: Bool = false

    public static func usesSidebarNavigation(forWidth width: CGFloat) -> Bool {
        let resolvedWidth = width > 0 ? width : 660
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

    @Bindable var l10n = AppLocalizationState.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public enum SettingsTab: String, CaseIterable, Identifiable {
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
            case .license: return "cpu"
            }
        }

        public var systemImage: String {
            icon
        }
    }

    @State var selectedTab: SettingsTab = .general
    @State var licenseKeyInput = ""
    @State var activationStatus = ""
    @AppStorage("ttzip_default_compression_format") var defaultFormat: ArchiveCompressionFormat = .zip
    @AppStorage("ttzip_default_compression_level") var defaultLevel: ArchiveCompressionLevel = .normal
    @State var isPro = Ed25519LicenseManager.shared.isPro
    @AppStorage("isSmartStoreBypassEnabled") var isSmartStoreBypassEnabled: Bool = true
    @AppStorage("ttzip_collision_default") var collisionDefault: String = "ask"
    private let initialTab: SettingsTab
    private let modelManager: LocalModelManager
    public let appearanceStore: ApplicationAppearanceStore

    public init(
        initialTab: SettingsTab = .general,
        modelManager: LocalModelManager = .shared,
        appearanceStore: ApplicationAppearanceStore = .shared
    ) {
        self.initialTab = initialTab
        self._selectedTab = State(initialValue: initialTab)
        self.modelManager = modelManager
        self.appearanceStore = appearanceStore
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
            generalSection
        case .localization:
            localizationSection
        case .presets:
            presetsSection
        case .vault:
            vaultSection
        case .localModels:
            LocalModelSettingsSectionView(modelManager: modelManager)
        case .license:
            licenseAndHardwareSection
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
            selectedTab = Self.adjacentTab(from: selectedTab, offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedTab = Self.adjacentTab(from: selectedTab, offset: 1)
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
            selectedTab = Self.adjacentTab(from: selectedTab, offset: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selectedTab = Self.adjacentTab(from: selectedTab, offset: 1)
            return .handled
        }
    }

    private func navigationTabButton(for tab: SettingsTab, isCompactHorizontal: Bool) -> some View {
        let isSelected = (selectedTab == tab)
        let titleText = tab.localizedTitle(using: l10n)
        return HStack(spacing: 8) {
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
                .minimumScaleFactor(0.90)
            if !isCompactHorizontal {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, isCompactHorizontal ? 10 : 8)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .frame(maxWidth: isCompactHorizontal ? nil : .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? TTZipTheme.bambooGreen.opacity(visualStyle.selectedTabFillOpacity) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected && visualStyle.increasedContrast
                        ? TTZipTheme.bambooGreen.opacity(0.85)
                        : Color.clear,
                    lineWidth: 1
                )
        )
        .overlay(
            SettingsTabInteractiveBridge(
                identifier: "settings.nav.tab.\(tab.rawValue)",
                title: titleText,
                isSelected: isSelected,
                onSelect: { selectedTab = tab },
                onStepTab: { offset in
                    selectedTab = Self.adjacentTab(from: selectedTab, offset: offset)
                }
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.nav.tab.\(tab.rawValue)")
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

    #if !MAS_BUILD && !STEAM_BUILD
    func activateLicense() {
        let result = Ed25519LicenseManager.shared.activate(licenseKey: licenseKeyInput)
        switch result {
        case .valid(let payload):
            isPro = true
            activationStatus = "✓ Verified: \(payload.email) (\(payload.order_id))"
            licenseKeyInput = ""
        case .invalidSignature:
            activationStatus = "✗ Invalid License Signature"
        case .malformedKey(let reason):
            activationStatus = "✗ \(reason)"
        }
    }
    #endif
}

private final class SettingsTabNativeButton: NSButton {
    var onStepTab: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126, 123: // Up Arrow or Left Arrow
            onStepTab?(-1)
        case 125, 124: // Down Arrow or Right Arrow
            onStepTab?(1)
        case 36, 49: // Return or Space
            performClick(self)
        default:
            super.keyDown(with: event)
        }
    }
}

private struct SettingsTabInteractiveBridge: NSViewRepresentable {
    let identifier: String
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onStepTab: (Int) -> Void

    final class Coordinator: NSObject {
        var onSelect: () -> Void

        init(onSelect: @escaping () -> Void) {
            self.onSelect = onSelect
        }

        @MainActor
        @objc func handleSelect(_ sender: NSButton) {
            onSelect()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> SettingsTabNativeButton {
        let button = SettingsTabNativeButton(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(Coordinator.handleSelect(_:))
        button.isBordered = false
        button.title = ""
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.focusRingType = .default
        configure(button)
        return button
    }

    func updateNSView(_ nsView: SettingsTabNativeButton, context: Context) {
        context.coordinator.onSelect = onSelect
        configure(nsView)
    }

    private func configure(_ button: SettingsTabNativeButton) {
        button.onStepTab = onStepTab
        button.toolTip = title
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.setAccessibilitySelected(isSelected)
    }
}
