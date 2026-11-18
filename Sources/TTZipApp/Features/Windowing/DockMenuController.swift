// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipCore
import TTZipUI

/// Protocol bridging `FinderFavoritesViewModel` (which resides in `TTZipAppViewModels`)
/// into `DockMenuController` (in `TTZipAppServices`) without circular module dependencies
/// or duplicating `UserDefaults` caches.
@MainActor
public protocol DockMenuFavoritesProviding: AnyObject {
    var pinnedRecords: [PinnedFolderRecord] { get }
    var dynamicFinderFavorites: [FinderFavoriteItem] { get }
    func locateMissingRecord(recordId: UUID)
}

/// Builds and dispatches the native macOS application Dock menu (`NSApplicationDelegate.applicationDockMenu(_:)`)
/// following Apple HIG and Finder's Dock menu topology.
///
/// Exact User-Visible Order:
/// 1. `New TTZip Window`
/// 2. `New Smart Folder...`
/// 3. `Find...`
/// 4. Separator
/// 5. `Go to Folder...`
/// 6. `Connect to Server...`
/// 7. Separator
/// 8. Dynamic Favorite Locations (user's pinned & Finder favorite folders, deduplicated by `FileIdentity`,
///    disambiguated when names collide) and Recent Items (recent folders & archives).
/// 9. (macOS automatically appends open window list, Show All Windows, Hide, and Quit to the returned `NSMenu`.)
///
/// Performance Invariant:
/// `buildDockMenu(language:)` only reads in-memory state from `favoritesProvider`, `RecentLocationsStore`,
/// and `SmartFolderStore`. It NEVER performs synchronous disk scans, model loading, or network waits.
@MainActor
public final class DockMenuController: NSObject {
    public static let shared = DockMenuController()

    public enum ItemTag: Int {
        case newWindow = 9101
        case newSmartFolder = 9102
        case find = 9103
        case goToFolder = 9104
        case connectToServer = 9105
        case favoritesHeader = 9200
        case favoriteItem = 9201
        case smartFoldersHeader = 9250
        case smartFolderItem = 9251
        case recentHeader = 9300
        case recentItem = 9301
        case clearRecents = 9302
    }

    public weak var favoritesProvider: (any DockMenuFavoritesProviding)?
    public var router: BrowserWindowRouter
    public var recentStore: RecentLocationsStore
    public var smartFolderStore: SmartFolderStore

    public init(
        favoritesProvider: (any DockMenuFavoritesProviding)? = nil,
        router: BrowserWindowRouter = .shared,
        recentStore: RecentLocationsStore = .shared,
        smartFolderStore: SmartFolderStore = .shared
    ) {
        self.favoritesProvider = favoritesProvider
        self.router = router
        self.recentStore = recentStore
        self.smartFolderStore = smartFolderStore
        super.init()
    }

    // MARK: - NSMenu Construction (Pure In-Memory Snapshot)

    public func buildDockMenu(language: TTZipCore.AppLanguage? = nil) -> NSMenu {
        let lang = language ?? AppLocalizationState.shared.currentLanguage
        let menu = NSMenu(title: "TTZip Dock Menu")
        menu.autoenablesItems = false

        appendPrimaryActionItems(to: menu, language: lang)
        appendNavigationActionItems(to: menu, language: lang)
        appendDynamicSectionItems(to: menu, language: lang)

        return menu
    }

    private func appendPrimaryActionItems(to menu: NSMenu, language lang: TTZipCore.AppLanguage) {
        menu.addItem(
            makeActionItem(
                title: MultiWindowLocaleKey.newWindowDock.translation(for: lang),
                action: #selector(handleNewWindowAction(_:)),
                tag: .newWindow
            )
        )
        menu.addItem(
            makeActionItem(
                title: MultiWindowLocaleKey.newSmartFolder.translation(for: lang),
                action: #selector(handleNewSmartFolderAction(_:)),
                tag: .newSmartFolder
            )
        )
        menu.addItem(
            makeActionItem(
                title: MultiWindowLocaleKey.findInWindow.translation(for: lang),
                action: #selector(handleFindAction(_:)),
                tag: .find
            )
        )
    }

    private func appendNavigationActionItems(to menu: NSMenu, language lang: TTZipCore.AppLanguage) {
        menu.addItem(.separator())
        menu.addItem(
            makeActionItem(
                title: MultiWindowLocaleKey.goToFolder.translation(for: lang),
                action: #selector(handleGoToFolderAction(_:)),
                tag: .goToFolder
            )
        )
        menu.addItem(
            makeActionItem(
                title: MultiWindowLocaleKey.connectToServer.translation(for: lang),
                action: #selector(handleConnectToServerAction(_:)),
                tag: .connectToServer
            )
        )
    }

    private func appendDynamicSectionItems(to menu: NSMenu, language lang: TTZipCore.AppLanguage) {
        let favoriteEntries = snapshotFavoriteEntries()
        let savedSmartFolders = smartFolderStore.records
        let recentEntries = recentStore.dockMenuSnapshot(limit: 10)

        guard !favoriteEntries.isEmpty || !savedSmartFolders.isEmpty || !recentEntries.isEmpty else {
            return
        }
        menu.addItem(.separator())

        if !favoriteEntries.isEmpty {
            appendFavoritesSection(favoriteEntries, to: menu, language: lang)
        }
        if !savedSmartFolders.isEmpty {
            if !favoriteEntries.isEmpty { menu.addItem(.separator()) }
            appendSmartFoldersSection(savedSmartFolders, to: menu, language: lang)
        }
        if !recentEntries.isEmpty {
            if !favoriteEntries.isEmpty || !savedSmartFolders.isEmpty { menu.addItem(.separator()) }
            appendRecentsSection(recentEntries, to: menu, language: lang)
        }
    }

    private func appendFavoritesSection(
        _ entries: [DockMenuFavoriteEntry],
        to menu: NSMenu,
        language lang: TTZipCore.AppLanguage
    ) {
        let favHeader = NSMenuItem.sectionHeader(
            title: MultiWindowLocaleKey.favoriteLocationsHeader.translation(for: lang)
        )
        favHeader.tag = ItemTag.favoritesHeader.rawValue
        favHeader.isEnabled = false
        menu.addItem(favHeader)

        for entry in entries {
            let item = NSMenuItem(
                title: Self.decoratedFavoriteTitle(for: entry, language: lang),
                action: #selector(handleOpenFavoriteItemAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = ItemTag.favoriteItem.rawValue
            item.representedObject = entry
            item.toolTip = entry.path
            item.isEnabled = true
            if let icon = NSImage(systemSymbolName: entry.systemImage, accessibilityDescription: entry.title) {
                icon.isTemplate = true
                item.image = icon
            }
            menu.addItem(item)
        }
    }

    private func appendSmartFoldersSection(
        _ records: [SmartFolderRecord],
        to menu: NSMenu,
        language lang: TTZipCore.AppLanguage
    ) {
        let smartHeader = NSMenuItem.sectionHeader(
            title: MultiWindowLocaleKey.smartFoldersHeader.translation(for: lang)
        )
        smartHeader.tag = ItemTag.smartFoldersHeader.rawValue
        smartHeader.isEnabled = false
        menu.addItem(smartHeader)

        for record in records.prefix(8) {
            let title = RecentLocationsStore.middleTruncate(record.name, maxCharacters: 56)
            let item = NSMenuItem(
                title: title,
                action: #selector(handleOpenSmartFolderItemAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = ItemTag.smartFolderItem.rawValue
            item.representedObject = record.id
            item.toolTip = record.criteria.effectiveScannerQuery
            item.isEnabled = true
            if let icon = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: record.name) {
                icon.isTemplate = true
                item.image = icon
            }
            menu.addItem(item)
        }
    }

    private func appendRecentsSection(
        _ entries: [DockMenuRecentEntry],
        to menu: NSMenu,
        language lang: TTZipCore.AppLanguage
    ) {
        let recHeader = NSMenuItem.sectionHeader(
            title: MultiWindowLocaleKey.recentItemsHeader.translation(for: lang)
        )
        recHeader.tag = ItemTag.recentHeader.rawValue
        recHeader.isEnabled = false
        menu.addItem(recHeader)

        for entry in entries {
            let item = NSMenuItem(
                title: entry.disambiguatedTitle,
                action: #selector(handleOpenRecentItemAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = ItemTag.recentItem.rawValue
            item.representedObject = entry.item
            item.toolTip = entry.item.path
            item.isEnabled = true
            if let icon = NSImage(systemSymbolName: entry.systemImage, accessibilityDescription: entry.item.displayName) {
                icon.isTemplate = true
                item.image = icon
            }
            menu.addItem(item)
        }
    }

    // MARK: - In-Memory Favorites Deduplication & Name Disambiguation

    private struct RawFavoriteCandidate {
        let id: String
        let baseTitle: String
        let path: String
        let canonicalPath: String
        let systemImage: String
        let identity: FileIdentity
        let healthState: SidebarItemHealthState
        let bookmarkData: Data?
        let isCustomPinned: Bool
    }

    /// Builds a deduplicated list of favorite locations from `favoritesProvider` in memory.
    /// Deduplicates by `FileIdentity` (with raw canonical path fallback) so display names are never used as unique keys.
    /// Disambiguates entries that share the same display name but point to different paths.
    public func snapshotFavoriteEntries() -> [DockMenuFavoriteEntry] {
        guard let provider = favoritesProvider else { return [] }
        let candidates = collectUniqueFavoriteCandidates(from: provider)

        var titleCounts: [String: Int] = [:]
        for c in candidates {
            titleCounts[c.baseTitle, default: 0] += 1
        }

        return candidates.map { c in
            let disambiguate = (titleCounts[c.baseTitle] ?? 0) > 1
            let formatted = RecentLocationsStore.formatMenuTitle(
                baseTitle: c.baseTitle,
                fullPath: c.path,
                disambiguateWithParent: disambiguate
            )
            return DockMenuFavoriteEntry(
                id: c.id,
                title: c.baseTitle,
                disambiguatedTitle: formatted,
                path: c.path,
                canonicalPath: c.canonicalPath,
                systemImage: c.systemImage,
                identity: c.identity,
                healthState: c.healthState,
                bookmarkData: c.bookmarkData,
                isCustomPinned: c.isCustomPinned
            )
        }
    }

    private func collectUniqueFavoriteCandidates(
        from provider: any DockMenuFavoritesProviding
    ) -> [RawFavoriteCandidate] {
        let mountedPaths = MountedVolumeManager.shared.mountedPathSet
        var candidates: [RawFavoriteCandidate] = []
        var seenIdentities: Set<FileIdentity> = []
        var seenCanonicalPaths: Set<String> = []

        for record in provider.pinnedRecords {
            let canonical = record.identity.canonicalPath
            guard seenIdentities.insert(record.identity).inserted,
                  seenCanonicalPaths.insert(canonical).inserted else { continue }
            candidates.append(
                RawFavoriteCandidate(
                    id: "pinned:\(record.id.uuidString)",
                    baseTitle: record.displayName,
                    path: record.path,
                    canonicalPath: canonical,
                    systemImage: "folder",
                    identity: record.identity,
                    healthState: record.lastKnownHealthState,
                    bookmarkData: record.bookmarkData,
                    isCustomPinned: true
                )
            )
        }

        for fav in provider.dynamicFinderFavorites where !mountedPaths.contains(fav.path) {
            let canonical = fav.identity.canonicalPath
            guard seenIdentities.insert(fav.identity).inserted,
                  seenCanonicalPaths.insert(canonical).inserted else { continue }
            candidates.append(
                RawFavoriteCandidate(
                    id: "fav:\(fav.path)",
                    baseTitle: fav.name,
                    path: fav.path,
                    canonicalPath: canonical,
                    systemImage: fav.systemImage,
                    identity: fav.identity,
                    healthState: fav.healthState,
                    bookmarkData: fav.bookmarkData,
                    isCustomPinned: false
                )
            )
        }
        return candidates
    }

    private static func decoratedFavoriteTitle(
        for entry: DockMenuFavoriteEntry,
        language: TTZipCore.AppLanguage
    ) -> String {
        switch entry.healthState {
        case .accessible, .datalessCloud, .warning:
            return entry.disambiguatedTitle
        case .unmountedVolume:
            let suffix = language == .en ? " (Offline)" : "（离线）"
            return entry.disambiguatedTitle + suffix
        case .mounting:
            let suffix = language == .en ? " (Mounting…)" : "（正在挂载…）"
            return entry.disambiguatedTitle + suffix
        case .missing:
            let suffix = language == .en ? " (Unavailable)" : "（不可用）"
            return entry.disambiguatedTitle + suffix
        }
    }

    private func makeActionItem(
        title: String,
        action: Selector,
        tag: ItemTag
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag.rawValue
        item.isEnabled = true
        return item
    }

    // MARK: - Objective-C Action Selectors (Real Production Dispatch)

    @objc public func handleNewWindowAction(_ sender: Any?) {
        _ = router.dispatchApplicationCommand(.openNewWindow)
    }

    @objc public func handleNewSmartFolderAction(_ sender: Any?) {
        let initialDir = router.registry.activeController?.currentDirectoryURL
        _ = router.dispatchApplicationCommand(.presentNewSmartFolder(initialScopeDirectory: initialDir))
    }

    @objc public func handleFindAction(_ sender: Any?) {
        _ = router.dispatchApplicationCommand(.focusFind(initialQuery: nil))
    }

    @objc public func handleGoToFolderAction(_ sender: Any?) {
        let initialPath = router.registry.activeController?.currentDirectoryURL.path
        _ = router.dispatchApplicationCommand(.presentGoToFolder(initialPath: initialPath))
    }

    @objc public func handleConnectToServerAction(_ sender: Any?) {
        _ = router.dispatchApplicationCommand(.presentConnectToServer(initialAddress: nil))
    }

    @objc public func handleOpenFavoriteItemAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? DockMenuFavoriteEntry else { return }
        _ = router.dispatchApplicationCommand(
            .navigateToFavoriteLocation(
                path: entry.path,
                bookmarkData: entry.bookmarkData,
                healthState: entry.healthState
            )
        )
    }

    @objc public func handleOpenSmartFolderItemAction(_ sender: NSMenuItem) {
        guard let recordID = sender.representedObject as? UUID else { return }
        _ = router.dispatchApplicationCommand(.openSmartFolder(id: recordID))
    }

    @objc public func handleOpenRecentItemAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? RecentLocationItem else { return }
        _ = router.dispatchApplicationCommand(.openRecentItem(item))
    }
}
