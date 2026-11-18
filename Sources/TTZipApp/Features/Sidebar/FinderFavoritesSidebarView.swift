// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import QuickLook
import SwiftUI
import TTZipCore
import TTZipUI

/// Top-level sidebar container managing layout scaffolding, focus state machines,
/// and full-keyboard navigation for the TTZip desktop file explorer.
public struct FinderFavoritesSidebarView: View {
    public let currentDirectory: URL
    public let activeAndroidDeviceID: String?
    public let onSelectDirectory: (URL) -> Void
    public var onSelectAndroidDevice: ((AndroidDevice) -> Void)? = nil
    public var onOpenSettings: (() -> Void)? = nil
    public var onOpenInNewWindow: ((URL) -> Void)? = nil
    public var onToggleSidebar: (() -> Void)? = nil
    public var isIconRail: Bool = false

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("TTZipSidebar_PinnedCollapsed") private var isPinnedCollapsed: Bool = false
    @AppStorage("TTZipSidebar_FavoritesCollapsed") private var isFavoritesCollapsed: Bool = false
    @AppStorage("TTZipSidebar_LocationsCollapsed") private var isLocationsCollapsed: Bool = false

    private var viewModel = FinderFavoritesViewModel.shared
    private var volumeManager = MountedVolumeManager.shared
    private var androidViewModel = AndroidDeviceViewModel.shared
    private var l10n = AppLocalizationState.shared

    @State private var quickLookURL: URL?
    @FocusState private var focusedItem: SidebarRowIdentifier?
    @State private var keyboardCoordinator = SidebarKeyboardCoordinator()
    @State private var lastNavigationTime: ContinuousClock.Instant = .now
    @State private var directorySelectionDebounceTask: Task<Void, Never>? = nil
    @State private var isFullScreen: Bool = false
    @State private var scrollToRequestToken: UUID = UUID()
    @State private var scrollToTarget: SidebarRowIdentifier? = nil
    @State private var sidebarHeight: CGFloat = 600
    @State private var shouldScrollToFocusedItem: Bool = false

    public init(
        currentDirectory: URL,
        activeAndroidDeviceID: String? = nil,
        onSelectDirectory: @escaping (URL) -> Void,
        onSelectAndroidDevice: ((AndroidDevice) -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onOpenInNewWindow: ((URL) -> Void)? = nil,
        onToggleSidebar: (() -> Void)? = nil,
        isIconRail: Bool = false
    ) {
        self.currentDirectory = currentDirectory
        self.activeAndroidDeviceID = activeAndroidDeviceID
        self.onSelectDirectory = onSelectDirectory
        self.onSelectAndroidDevice = onSelectAndroidDevice
        self.onOpenSettings = onOpenSettings
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onToggleSidebar = onToggleSidebar
        self.isIconRail = isIconRail
    }

    public var body: some View {
        VStack(alignment: isIconRail ? .center : .leading, spacing: 0) {
            // Fixed 52pt Header strictly aligning with the global 52pt navigation bar baseline
            SidebarBrandHeaderView(isIconRail: isIconRail, onToggleSidebar: onToggleSidebar)
                .frame(height: TTZipTheme.Layout.headerBarHeight)

            // Specular hairline divider aligned with Y=52pt golden baseline across all 3 columns
            TTKintsugiDivider(.horizontal, falloff: false)
                .frame(height: TTZipTheme.Layout.kintsugiGoldLineHeight)

            // Permanent brand identity bar per ADR-058
            SidebarBrandIdentityView(isIconRail: isIconRail, onOpenSettings: onOpenSettings)

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: isIconRail ? .center : .leading, spacing: isIconRail ? 8 : 14) {
                        SidebarPinnedSectionView(
                            currentDirectory: currentDirectory,
                            isLocalLocationActive: activeAndroidDeviceID == nil,
                            isIconRail: isIconRail,
                            focusedItem: $focusedItem,
                            onSelectDirectory: { handleDirectorySelection(url: $0, section: .pinned) },
                            onQuickLook: { quickLookURL = $0 },
                            onOpenInNewWindow: { openInNewWindow(url: $0) }
                        )

                        SidebarFavoritesSectionView(
                            currentDirectory: currentDirectory,
                            isLocalLocationActive: activeAndroidDeviceID == nil,
                            isIconRail: isIconRail,
                            focusedItem: $focusedItem,
                            onSelectDirectory: { handleDirectorySelection(url: $0, section: .favorites) },
                            onQuickLook: { quickLookURL = $0 },
                            onOpenInNewWindow: { openInNewWindow(url: $0) }
                        )

                        SidebarLocationsSectionView(
                            currentDirectory: currentDirectory,
                            activeAndroidDeviceID: activeAndroidDeviceID,
                            isIconRail: isIconRail,
                            focusedItem: $focusedItem,
                            onSelectDirectory: { handleDirectorySelection(url: $0, section: .locations) },
                            onSelectAndroidDevice: { dev in
                                focusedItem = SidebarRowIdentifier(section: .locations, id: dev.deviceId)
                                viewModel.activeSection = .locations
                                onSelectAndroidDevice?(dev)
                            },
                            onOpenInNewWindow: { openInNewWindow(url: $0) }
                        )
                    }
                    .padding(.horizontal, isIconRail ? 4 : 10)
                    .padding(.top, 6)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: isIconRail ? .center : .leading)
                }
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 8)
                        Color.black
                    }
                )
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollContentBackground(.hidden)
                .background(ConfigureNSScrollView())
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newH in
                    sidebarHeight = newH
                }
                .onChange(of: scrollToRequestToken) { _, _ in
                    guard let target = scrollToTarget else { return }
                    var transaction = Transaction()
                    if reduceMotion {
                        transaction.disablesAnimations = true
                    } else {
                        transaction.animation = .ttMicro
                    }
                    withTransaction(transaction) {
                        scrollProxy.scrollTo(target)
                    }
                }
                .onChange(of: focusedItem) { _, newItem in
                    guard let newItem, shouldScrollToFocusedItem else { return }
                    shouldScrollToFocusedItem = false
                    let now = ContinuousClock.now
                    let isRapidNavigation = (now - lastNavigationTime) < .milliseconds(110)
                    lastNavigationTime = now

                    var transaction = Transaction()
                    if isRapidNavigation || reduceMotion {
                        transaction.disablesAnimations = true
                    } else {
                        transaction.animation = .ttMicro
                    }

                    withTransaction(transaction) {
                        scrollProxy.scrollTo(newItem)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .focusSection()
        .speechAnnouncementsQueued(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Sidebar"))
        .quickLookPreview($quickLookURL)
        .onAppear {
            if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow || $0.isVisible }) {
                isFullScreen = window.styleMask.contains(.fullScreen)
            }
            if focusedItem == nil {
                let initialPath = currentDirectory.scheme == "ttzip" ? currentDirectory.absoluteString : currentDirectory.path
                focusedItem = resolveRowIdentifier(for: initialPath)
            }
        }
        .onDisappear {
            directorySelectionDebounceTask?.cancel()
            directorySelectionDebounceTask = nil
        }
        .onChange(of: currentDirectory) { _, newDir in
            let newPath = newDir.scheme == "ttzip" ? newDir.absoluteString : newDir.path
            if focusedItem?.id != newPath {
                focusedItem = resolveRowIdentifier(for: newPath)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            withAnimation(.ttMicro) { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation(.ttMicro) { isFullScreen = false }
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            if press.modifiers.contains(.command) {
                return .ignored
            }
            navigateFocus(direction: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            if press.modifiers.contains(.command) {
                if press.modifiers.contains(.option) {
                    if let current = focusedItem {
                        openInNewWindow(url: makeSidebarURL(for: current.id))
                        return .handled
                    }
                }
                return handleReturnKey()
            }
            navigateFocus(direction: 1)
            return .handled
        }
        .onKeyPress(.home) {
            jumpToBoundary(toFirst: true)
            return .handled
        }
        .onKeyPress(.end) {
            jumpToBoundary(toFirst: false)
            return .handled
        }
        .onKeyPress(.pageUp) {
            let rowHeight: CGFloat = isIconRail ? 42 : 30
            let step = max(3, Int((sidebarHeight - 40) / rowHeight))
            navigateFocus(direction: -step)
            return .handled
        }
        .onKeyPress(.pageDown) {
            let rowHeight: CGFloat = isIconRail ? 42 : 30
            let step = max(3, Int((sidebarHeight - 40) / rowHeight))
            navigateFocus(direction: step)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            handleLeftArrow()
        }
        .onKeyPress(.rightArrow) {
            handleRightArrow()
        }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) {
                if let current = focusedItem {
                    openInNewWindow(url: makeSidebarURL(for: current.id))
                    return .handled
                }
            }
            return handleReturnKey()
        }
        .onKeyPress(KeyEquivalent("o"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if press.modifiers.contains(.option) {
                if let current = focusedItem {
                    openInNewWindow(url: makeSidebarURL(for: current.id))
                    return .handled
                }
            }
            return handleReturnKey()
        }
        .onKeyPress(.space) {
            handleSpaceKey()
        }
        .onKeyPress(.delete) {
            handleDeleteKey()
        }
        .onKeyPress(phases: .down) { press in
            keyboardCoordinator.handleKeyPress(press, candidates: collectNavigationCandidates()) { matchedTarget in
                shouldScrollToFocusedItem = true
                focusedItem = matchedTarget
                viewModel.activeSection = matchedTarget.section
                if matchedTarget.section == .locations, let dev = androidViewModel.connectedDevices.first(where: { $0.deviceId == matchedTarget.id }) {
                    directorySelectionDebounceTask?.cancel()
                    androidViewModel.selectDevice(dev)
                    onSelectAndroidDevice?(dev)
                } else {
                    handleDirectorySelection(url: makeSidebarURL(for: matchedTarget.id), section: matchedTarget.section)
                }
            }
        }
    }

    // MARK: - Private Subviews & Key Handlers



    private func resolveRowIdentifier(for path: String) -> SidebarRowIdentifier {
        if path == StorageInspectorView.storageInspectorId || path == StorageInspectorView.storageInspectorURL.absoluteString {
            return SidebarRowIdentifier(section: .locations, id: StorageInspectorView.storageInspectorId)
        }
        let mountedPaths = volumeManager.mountedPathSet
        if viewModel.activeSection == .pinned && viewModel.pinnedRecords.contains(where: { $0.path == path }) {
            return SidebarRowIdentifier(section: .pinned, id: path)
        } else if viewModel.activeSection == .favorites && viewModel.dynamicFinderFavorites.contains(where: { $0.path == path && !mountedPaths.contains($0.path) }) {
            return SidebarRowIdentifier(section: .favorites, id: path)
        } else if viewModel.activeSection == .locations && volumeManager.mountedVolumes.contains(where: { $0.path == path }) {
            return SidebarRowIdentifier(section: .locations, id: path)
        } else if viewModel.pinnedRecords.contains(where: { $0.path == path }) {
            return SidebarRowIdentifier(section: .pinned, id: path)
        } else if viewModel.dynamicFinderFavorites.contains(where: { $0.path == path && !mountedPaths.contains($0.path) }) {
            return SidebarRowIdentifier(section: .favorites, id: path)
        } else {
            return SidebarRowIdentifier(section: .locations, id: path)
        }
    }

    private func makeSidebarURL(for id: String) -> URL {
        if id == StorageInspectorView.storageInspectorId || id == StorageInspectorView.storageInspectorURL.absoluteString {
            return StorageInspectorView.storageInspectorURL
        }
        if id.hasPrefix("ttzip://") || id.hasPrefix("http://") || id.hasPrefix("https://") {
            if let customURL = URL(string: id) {
                return customURL
            }
        }
        return URL(fileURLWithPath: id)
    }

    private func handleDirectorySelection(url: URL, section: SidebarSection) {
        let identifierId = url.scheme == "ttzip" ? url.absoluteString : url.path
        focusedItem = SidebarRowIdentifier(section: section, id: identifierId)
        viewModel.activeSection = section
        if quickLookURL != nil {
            quickLookURL = url
        }
        onSelectDirectory(url)
    }

    private func navigateFocus(direction: Int) {
        let candidates = collectVisibleIdentifiers()
        guard !candidates.isEmpty else { return }

        let nextItem: SidebarRowIdentifier
        if let current = focusedItem, let idx = candidates.firstIndex(of: current) {
            let nextIdx = min(max(0, idx + direction), candidates.count - 1)
            nextItem = candidates[nextIdx]
        } else {
            nextItem = direction > 0 ? candidates.first! : candidates.last!
        }

        shouldScrollToFocusedItem = true
        focusedItem = nextItem
        viewModel.activeSection = nextItem.section

        if nextItem.section == .locations, let dev = androidViewModel.connectedDevices.first(where: { $0.deviceId == nextItem.id }) {
            directorySelectionDebounceTask?.cancel()
            androidViewModel.selectDevice(dev)
            onSelectAndroidDevice?(dev)
            return
        }

        let nextURL = makeSidebarURL(for: nextItem.id)

        if quickLookURL != nil {
            quickLookURL = nextURL
        }

        directorySelectionDebounceTask?.cancel()
        directorySelectionDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            onSelectDirectory(nextURL)
        }
    }

    private func jumpToBoundary(toFirst: Bool) {
        let candidates = collectVisibleIdentifiers()
        guard let target = toFirst ? candidates.first : candidates.last else { return }
        shouldScrollToFocusedItem = true
        focusedItem = target
        viewModel.activeSection = target.section
        scrollToTarget = target
        scrollToRequestToken = UUID()

        if target.section == .locations, let dev = androidViewModel.connectedDevices.first(where: { $0.deviceId == target.id }) {
            directorySelectionDebounceTask?.cancel()
            androidViewModel.selectDevice(dev)
            onSelectAndroidDevice?(dev)
            return
        }

        let url = makeSidebarURL(for: target.id)
        if quickLookURL != nil { quickLookURL = url }
        directorySelectionDebounceTask?.cancel()
        onSelectDirectory(url)
    }

    private func handleLeftArrow() -> KeyPress.Result {
        guard let current = focusedItem else { return .ignored }
        return collapseCurrentSection(current.section)
    }

    private func collapseCurrentSection(_ section: SidebarSection) -> KeyPress.Result {
        let oldItems = collectVisibleIdentifiers()
        let current = focusedItem

        switch section {
        case .pinned:
            guard !isPinnedCollapsed else { return .ignored }
            withAnimation(.ttMicro) { isPinnedCollapsed = true }
        case .favorites:
            guard !isFavoritesCollapsed else { return .ignored }
            withAnimation(.ttMicro) { isFavoritesCollapsed = true }
        case .locations:
            guard !isLocationsCollapsed else { return .ignored }
            withAnimation(.ttMicro) { isLocationsCollapsed = true }
        }

        let newItems = collectVisibleIdentifiers()
        guard !newItems.isEmpty else {
            focusedItem = nil
            return .handled
        }

        let targetItem: SidebarRowIdentifier
        if let current, let oldIdx = oldItems.firstIndex(of: current) {
            let targetIdx = min(oldIdx, newItems.count - 1)
            targetItem = newItems[targetIdx]
        } else {
            targetItem = newItems[0]
        }

        focusedItem = targetItem
        viewModel.activeSection = targetItem.section

        if targetItem.section == .locations, let dev = androidViewModel.connectedDevices.first(where: { $0.deviceId == targetItem.id }) {
            androidViewModel.selectDevice(dev)
            onSelectAndroidDevice?(dev)
        } else {
            handleDirectorySelection(url: makeSidebarURL(for: targetItem.id), section: targetItem.section)
        }
        return .handled
    }

    private func handleRightArrow() -> KeyPress.Result {
        guard let current = focusedItem else { return .ignored }
        switch current.section {
        case .pinned:
            if isPinnedCollapsed {
                withAnimation(.ttMicro) { isPinnedCollapsed = false }
                return .handled
            }
        case .favorites:
            if isFavoritesCollapsed {
                withAnimation(.ttMicro) { isFavoritesCollapsed = false }
                return .handled
            }
        case .locations:
            if isLocationsCollapsed {
                withAnimation(.ttMicro) { isLocationsCollapsed = false }
                return .handled
            }
        }
        return .ignored
    }

    private func handleReturnKey() -> KeyPress.Result {
        guard let current = focusedItem else { return .ignored }
        if current.section == .locations, let dev = androidViewModel.connectedDevices.first(where: { $0.deviceId == current.id }) {
            androidViewModel.selectDevice(dev)
            onSelectAndroidDevice?(dev)
            return .handled
        }
        directorySelectionDebounceTask?.cancel()
        onSelectDirectory(makeSidebarURL(for: current.id))
        return .handled
    }

    private func handleSpaceKey() -> KeyPress.Result {
        guard let current = focusedItem else { return .ignored }
        if current.section == .locations && androidViewModel.connectedDevices.contains(where: { $0.deviceId == current.id }) {
            return .ignored
        }
        if current.id == StorageInspectorView.storageInspectorId || current.id == StorageInspectorView.storageInspectorURL.absoluteString {
            return .ignored
        }
        let url = makeSidebarURL(for: current.id)
        quickLookURL = (quickLookURL == url) ? nil : url
        return .handled
    }

    private func handleDeleteKey() -> KeyPress.Result {
        guard let current = focusedItem, current.section == .pinned else { return .ignored }
        let pinned = viewModel.pinnedRecords
        guard let recordIndex = pinned.firstIndex(where: { $0.path == current.id }) else {
            return .ignored
        }

        let nextFocusedItem: SidebarRowIdentifier?
        if pinned.count > 1 {
            let nextRecord = (recordIndex < pinned.count - 1)
                ? pinned[recordIndex + 1]
                : pinned[recordIndex - 1]
            nextFocusedItem = SidebarRowIdentifier(section: .pinned, id: nextRecord.path)
        } else {
            let mountedPaths = volumeManager.mountedPathSet
            if let fav = viewModel.dynamicFinderFavorites.first(where: { !mountedPaths.contains($0.path) }) {
                nextFocusedItem = SidebarRowIdentifier(section: .favorites, id: fav.path)
            } else {
                nextFocusedItem = nil
            }
        }

        viewModel.removeCustomPinnedFolder(path: current.id)
        focusedItem = nextFocusedItem
        if let nextFocusedItem {
            viewModel.activeSection = nextFocusedItem.section
            handleDirectorySelection(url: makeSidebarURL(for: nextFocusedItem.id), section: nextFocusedItem.section)
        }
        return .handled
    }

    private func collectVisibleIdentifiers() -> [SidebarRowIdentifier] {
        let mounted = volumeManager.mountedVolumes
        let androidDevices = androidViewModel.connectedDevices
        let showPinned = !isPinnedCollapsed || isIconRail
        let showFavorites = !isFavoritesCollapsed || isIconRail
        let showLocations = !isLocationsCollapsed || isIconRail

        var totalCapacity = 0
        if showPinned { totalCapacity += viewModel.pinnedRecords.count }
        if showFavorites { totalCapacity += viewModel.dynamicFinderFavorites.count }
        if showLocations { totalCapacity += 1 + mounted.count + androidDevices.count }

        var items: [SidebarRowIdentifier] = []
        items.reserveCapacity(totalCapacity)

        if showPinned {
            for record in viewModel.pinnedRecords {
                items.append(SidebarRowIdentifier(section: .pinned, id: record.path))
            }
        }
        if showFavorites {
            let mountedPaths = volumeManager.mountedPathSet
            for fav in viewModel.dynamicFinderFavorites where !mountedPaths.contains(fav.path) {
                items.append(SidebarRowIdentifier(section: .favorites, id: fav.path))
            }
        }
        if showLocations {
            items.append(SidebarRowIdentifier(section: .locations, id: StorageInspectorView.storageInspectorId))
            for vol in mounted {
                items.append(SidebarRowIdentifier(section: .locations, id: vol.path))
            }
            for dev in androidDevices {
                items.append(SidebarRowIdentifier(section: .locations, id: dev.deviceId))
            }
        }
        return items
    }

    private func collectNavigationCandidates() -> [(title: String, target: SidebarRowIdentifier)] {
        let mounted = volumeManager.mountedVolumes
        let androidDevices = androidViewModel.connectedDevices
        let showPinned = !isPinnedCollapsed || isIconRail
        let showFavorites = !isFavoritesCollapsed || isIconRail
        let showLocations = !isLocationsCollapsed || isIconRail

        var candidates: [(title: String, target: SidebarRowIdentifier)] = []
        if showPinned {
            for record in viewModel.pinnedRecords {
                candidates.append((title: record.displayName, target: SidebarRowIdentifier(section: .pinned, id: record.path)))
            }
        }
        if showFavorites {
            let mountedPaths = volumeManager.mountedPathSet
            for item in viewModel.dynamicFinderFavorites where !mountedPaths.contains(item.path) {
                candidates.append((title: item.name, target: SidebarRowIdentifier(section: .favorites, id: item.path)))
            }
        }
        if showLocations {
            candidates.append((title: "Storage Inspector", target: SidebarRowIdentifier(section: .locations, id: StorageInspectorView.storageInspectorId)))
            for vol in mounted {
                candidates.append((title: vol.name, target: SidebarRowIdentifier(section: .locations, id: vol.path)))
            }
            for dev in androidDevices {
                candidates.append((title: dev.displayName, target: SidebarRowIdentifier(section: .locations, id: dev.deviceId)))
            }
        }
        return candidates
    }

    private func openInNewWindow(url: URL) {
        if let onOpenInNewWindow {
            onOpenInNewWindow(url)
        } else {
            BrowserWindowRouter.shared.openInNewWindow(url: url)
        }
    }
}
