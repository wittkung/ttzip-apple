// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTZipCore
import TTZipUI

/// Dedicated section view managing local mounted volumes, external drives, Android devices,
/// and the persistent Storage Space Inspector navigation entry.
public struct SidebarLocationsSectionView: View {
    public let currentDirectory: URL
    public let activeAndroidDeviceID: String?
    public let isIconRail: Bool
    @FocusState.Binding var focusedItem: SidebarRowIdentifier?
    public let onSelectDirectory: (URL) -> Void
    public var onSelectAndroidDevice: ((AndroidDevice) -> Void)? = nil
    public var onOpenInNewWindow: ((URL) -> Void)? = nil

    @AppStorage("TTZipSidebar_LocationsCollapsed") private var isLocationsCollapsed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showWirelessDiscoverySheet: Bool = false

    private var viewModel = FinderFavoritesViewModel.shared
    private var volumeManager = MountedVolumeManager.shared
    private var androidViewModel = AndroidDeviceViewModel.shared
    private var l10n = AppLocalizationState.shared

    public init(
        currentDirectory: URL,
        activeAndroidDeviceID: String? = nil,
        isIconRail: Bool,
        focusedItem: FocusState<SidebarRowIdentifier?>.Binding,
        onSelectDirectory: @escaping (URL) -> Void,
        onSelectAndroidDevice: ((AndroidDevice) -> Void)? = nil,
        onOpenInNewWindow: ((URL) -> Void)? = nil
    ) {
        self.currentDirectory = currentDirectory
        self.activeAndroidDeviceID = activeAndroidDeviceID
        self.isIconRail = isIconRail
        self._focusedItem = focusedItem
        self.onSelectDirectory = onSelectDirectory
        self.onSelectAndroidDevice = onSelectAndroidDevice
        self.onOpenInNewWindow = onOpenInNewWindow
    }

    public var body: some View {
        let volumes = volumeManager.mountedVolumes
        let androidDevices = androidViewModel.connectedDevices

        let currentIdentity = viewModel.currentIdentity
        let mountedPaths = volumeManager.mountedPathSet

        VStack(alignment: isIconRail ? .center : .leading, spacing: 2) {
            if !isIconRail {
                SidebarSectionHeaderView(
                    title: String(localized: "LOCATIONS"),
                    isCollapsed: $isLocationsCollapsed
                ) {
                    Button(action: { showWirelessDiscoverySheet = true }) {
                        Image(systemName: "wifi.badge.plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.secondary)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Discover & Pair Wireless Android"))
                    .accessibilityLabel(String(localized: "Discover & Pair Wireless Android"))
                }
            }

            if !isLocationsCollapsed || isIconRail {
                // 1. Persistent Storage Space Inspector Entry
                let storageRowIdentifier = SidebarRowIdentifier(section: .locations, id: StorageInspectorView.storageInspectorId)
                let isStorageSelected = (focusedItem?.id == StorageInspectorView.storageInspectorId)
                    || (currentDirectory.absoluteString == StorageInspectorView.storageInspectorURL.absoluteString)
                let currentId = currentDirectory.scheme == "ttzip" ? currentDirectory.absoluteString : currentDirectory.path
                let isStorageRovingTarget = (focusedItem?.id ?? currentId) == StorageInspectorView.storageInspectorId
                    && (focusedItem?.section == .locations || focusedItem == nil)

                SidebarStorageInspectorRowView(
                    isSelected: activeAndroidDeviceID == nil && isStorageSelected,
                    isIconRail: isIconRail,
                    isKeyboardFocused: focusedItem == storageRowIdentifier,
                    onSelect: {
                        viewModel.activeSection = .locations
                        focusedItem = storageRowIdentifier
                        NotificationCenter.default.post(
                            name: NSNotification.Name("TTZipOpenStorageInspectorNotification"),
                            object: nil
                        )
                        onSelectDirectory(StorageInspectorView.storageInspectorURL)
                    },
                    onOpenInNewWindow: {
                        onOpenInNewWindow?(StorageInspectorView.storageInspectorURL)
                    }
                )
                .focused($focusedItem, equals: storageRowIdentifier)
                .focusable(isStorageRovingTarget)
                .focusEffectDisabled()
                .id(storageRowIdentifier)
                .accessibilityIdentifier(StorageInspectorView.storageInspectorId)

                // 2. Mounted Volumes
                ForEach(volumes) { volume in
                    let rowIdentifier = SidebarRowIdentifier(section: .locations, id: volume.path)
                    let isRovingTabTarget = (focusedItem?.id ?? currentDirectory.path) == volume.path
                        && (focusedItem?.section == .locations || focusedItem == nil)
                    SidebarVolumeRowView(
                        volume: volume,
                        isSelected: isVolumeSelected(volume: volume, currentIdentity: currentIdentity, mountedPaths: mountedPaths),
                        isIconRail: isIconRail,
                        isKeyboardFocused: focusedItem == rowIdentifier,
                        onSelect: { url in
                            viewModel.activeSection = .locations
                            onSelectDirectory(url)
                        },
                        onOpenInNewWindow: onOpenInNewWindow
                    )
                    .equatable()
                    .focused($focusedItem, equals: rowIdentifier)
                    .focusable(isRovingTabTarget)
                    .focusEffectDisabled()
                    .id(rowIdentifier)
                    .accessibilityIdentifier(volume.path)
                }

                // 3. Connected Android Devices
                ForEach(androidDevices) { device in
                    let rowIdentifier = SidebarRowIdentifier(section: .locations, id: device.deviceId)
                    let isRovingTabTarget = (focusedItem?.id ?? currentDirectory.path) == device.deviceId
                        && (focusedItem?.section == .locations || focusedItem == nil)
                    SidebarAndroidDeviceRowView(
                        device: device,
                        isSelected: activeAndroidDeviceID == device.deviceId,
                        isIconRail: isIconRail,
                        isKeyboardFocused: focusedItem == rowIdentifier,
                        onSelect: { dev in
                            viewModel.activeSection = .locations
                            androidViewModel.selectDevice(dev)
                            onSelectAndroidDevice?(dev)
                        },
                        onEject: { dev in
                            androidViewModel.ejectDevice(dev)
                        }
                    )
                    .equatable()
                    .focused($focusedItem, equals: rowIdentifier)
                    .focusable(isRovingTabTarget)
                    .focusEffectDisabled()
                    .id(rowIdentifier)
                    .accessibilityIdentifier(device.deviceId)
                }
            }
        }
        .animation(reduceMotion ? nil : .ttMicro, value: isLocationsCollapsed)
        .accessibilityRotor(String(localized: "Locations")) {
            AccessibilityRotorEntry("Storage Inspector", id: StorageInspectorView.storageInspectorId)
            ForEach(volumes) { volume in
                AccessibilityRotorEntry(volume.name, id: volume.id)
            }
        }
        .sheet(isPresented: $showWirelessDiscoverySheet) {
            WirelessDeviceDiscoveryView()
        }
        .task(id: currentDirectory) {
            viewModel.updateCurrentIdentity(for: currentDirectory)
        }
    }

    private func isVolumeSelected(volume: MountedVolumeItem, currentIdentity: FileIdentity?, mountedPaths: Set<String>) -> Bool {
        guard activeAndroidDeviceID == nil else { return false }
        if let currentIdentity {
            return viewModel.isRowSelected(
                identity: volume.identity,
                section: .locations,
                currentIdentity: currentIdentity,
                mountedPaths: mountedPaths
            )
        }
        return volume.knownPaths.contains(currentDirectory.standardizedFileURL.path)
    }
}

// MARK: - Persistent Storage Space Inspector Row View

/// Dedicated persistent navigation item representing the Storage Space Inspector within the Locations sidebar.
public struct SidebarStorageInspectorRowView: View {
    public let isSelected: Bool
    public var isIconRail: Bool = false
    public var isKeyboardFocused: Bool = false
    public let onSelect: () -> Void
    public var onOpenInNewWindow: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var lastClickUptime: TimeInterval = 0
    private var l10n = AppLocalizationState.shared

    public init(
        isSelected: Bool,
        isIconRail: Bool = false,
        isKeyboardFocused: Bool = false,
        onSelect: @escaping () -> Void,
        onOpenInNewWindow: (() -> Void)? = nil
    ) {
        self.isSelected = isSelected
        self.isIconRail = isIconRail
        self.isKeyboardFocused = isKeyboardFocused
        self.onSelect = onSelect
        self.onOpenInNewWindow = onOpenInNewWindow
    }

    public var body: some View {
        Button(action: handleRowClick) {
            if isIconRail {
                iconRailContent
            } else {
                standardRowContent
            }
        }
        .buttonStyle(.plain)
        .onRightClickSelect {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if let onOpenInNewWindow {
                Button(l10n.t(MultiWindowLocaleKey.openInNewWindow)) {
                    onOpenInNewWindow()
                }
            }
        }
    }

    private func handleRowClick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - lastClickUptime
        if delta > 0 && delta <= NSEvent.doubleClickInterval, let onOpenInNewWindow {
            lastClickUptime = 0
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            onOpenInNewWindow()
        } else {
            lastClickUptime = now
            onSelect()
        }
    }

    @ViewBuilder
    private var standardRowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TTKitTheme.bambooGreen : .secondary)
                .frame(width: 18, height: 18, alignment: .center)

            L10nText(L10n.Sidebar.storageInspector)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconRailContent: some View {
        Image(systemName: "sparkles.rectangle.stack")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isSelected ? TTZipTheme.bambooGreen : .secondary)
            .frame(width: 32, height: 32)
            .background(rowBackground)
            .contentShape(Rectangle())
            .l10nHelp(L10n.Sidebar.storageInspector)
    }

    @ViewBuilder
    private var rowBackground: some View {
        let cornerRadius: CGFloat = 6.0
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(TTKitTheme.bambooGreen.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isKeyboardFocused ? TTKitTheme.kintsugiGoldEditorial.opacity(0.7) : Color.clear,
                            lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth
                        )
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        } else if isKeyboardFocused {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(TTKitTheme.kintsugiGoldEditorial.opacity(0.7), lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth)
        } else {
            Color.clear
        }
    }
}
