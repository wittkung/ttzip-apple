// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
@testable import TTZipApp
@testable import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTKitUI

// MARK: - Test Doubles for Dock Menu & Server Mount Acceptance

@MainActor
private final class MockDockFavoritesProvider: DockMenuFavoritesProviding {
    var pinnedRecords: [PinnedFolderRecord] = []
    var dynamicFinderFavorites: [FinderFavoriteItem] = []
    var locatedMissingIDs: [UUID] = []

    func locateMissingRecord(recordId: UUID) {
        locatedMissingIDs.append(recordId)
    }
}

final class ControlledServerMountTransport: ServerMountTransport, @unchecked Sendable {
    enum Behavior {
        case succeed(mountPoints: [URL])
        case fail(ServerConnectionFailureReason)
        case waitUntilCancelled
    }

    var behavior: Behavior
    private(set) var mountCallCount: Int = 0
    private(set) var lastRequestedEndpoint: ValidatedServerEndpoint?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func mountShare(
        endpoint: ValidatedServerEndpoint,
        allowAuthenticationUI: Bool
    ) async throws -> [URL] {
        mountCallCount += 1
        lastRequestedEndpoint = endpoint
        switch behavior {
        case .succeed(let mountPoints):
            return mountPoints
        case .fail(let reason):
            throw reason
        case .waitUntilCancelled:
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
    }
}

private struct MockSystemFileSearchProvider: SystemFileSearchProviding {
    var stubbedResults: [GlobalSearchResultItem] = []

    func searchAllAccessibleItems(
        query: String,
        maxResults: Int,
        additionalScopes: [URL]
    ) async -> [GlobalSearchResultItem] {
        stubbedResults
    }
}

// MARK: - Dock Application Menu Acceptance Suite (Slices A, B, C)

@MainActor
final class DockApplicationMenuAcceptanceTests: XCTestCase {
    private var isolatedDefaults: UserDefaults!
    private var isolatedSuiteName: String!
    private var customSmartFolderFileURL: URL!
    private var recentStore: RecentLocationsStore!
    private var smartFolderStore: SmartFolderStore!
    private var favoritesProvider: MockDockFavoritesProvider!
    private var dockController: DockMenuController!
    private var previousLanguage: TTZipCore.AppLanguage = .zhHans

    private func resetTestFixturesOnMainActor() {
        previousLanguage = AppLocalizationState.shared.currentLanguage
        BrowserWindowRegistry.shared.resetForTesting()
        BrowserWindowRouter.shared.resetForTesting()

        isolatedSuiteName = "com.metastudyline.ttzip.docktests.\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: isolatedSuiteName)!

        customSmartFolderFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart_folders_\(UUID().uuidString).json")
        smartFolderStore = SmartFolderStore(
            userDefaults: isolatedDefaults,
            customStorageFileURL: customSmartFolderFileURL
        )
        recentStore = RecentLocationsStore(
            userDefaults: isolatedDefaults,
            loadOnInit: false
        )
        favoritesProvider = MockDockFavoritesProvider()
        dockController = DockMenuController(
            favoritesProvider: favoritesProvider,
            router: .shared,
            recentStore: recentStore,
            smartFolderStore: smartFolderStore
        )
    }

    private func tearDownTestFixturesOnMainActor() {
        BrowserWindowRegistry.shared.resetForTesting()
        BrowserWindowRouter.shared.resetForTesting()
        AppLocalizationState.shared.setLanguage(previousLanguage)
        if let suite = isolatedSuiteName {
            isolatedDefaults?.removePersistentDomain(forName: suite)
        }
        if let customSmartFolderFileURL {
            try? FileManager.default.removeItem(at: customSmartFolderFileURL)
        }
    }

    // MARK: - Helpers

    private func invokeMenuItem(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target else {
            XCTFail("Expected enabled NSMenuItem with target and action: \(item.title)")
            return
        }
        _ = (target as AnyObject).perform(action, with: item)
    }

    // MARK: - Slice A.1: Exact Dock Menu Ordering, Separators & Localization

    func testDockReopenCreatesBrowserWhenOnlyLogicalEntryAndUnrelatedWindowRemain() {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }
        let logicalBrowser = AppViewState(fileViewer: NoOpFileViewer())
        BrowserWindowRegistry.shared.register(logicalBrowser)
        let unrelatedWindow = DockReopenWindowSpy(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
        )
        unrelatedWindow.isReleasedWhenClosed = false
        defer { unrelatedWindow.close() }
        var openRequests = 0
        BrowserWindowRouter.shared.swiftUIWindowOpener = { openRequests += 1 }

        let delegate = AppDelegate(modelManager: .shared)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))

        XCTAssertEqual(openRequests, 1, "A logical browser entry must not prevent creating a real browser window")
        XCTAssertEqual(unrelatedWindow.orderFrontCount, 0, "An unregistered window must not satisfy browser recovery")
        XCTAssertEqual(BrowserWindowRegistry.shared.pendingLaunchSeeds.count, 1)
        XCTAssertFalse(logicalBrowser.isWindowClosing)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(openRequests, 1, "AppKit handles activation when a window is already visible")
    }

    func testDockReopenRestoresRegisteredBrowserBeforeCreatingAnother() {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }
        let browser = AppViewState(fileViewer: NoOpFileViewer())
        let window = DockReopenWindowSpy(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.simulatesMiniaturizedWindow = true
        defer { window.close() }
        BrowserWindowRegistry.shared.register(browser, nsWindow: window)
        let logicalBrowser = AppViewState(fileViewer: NoOpFileViewer())
        BrowserWindowRegistry.shared.register(logicalBrowser)
        XCTAssertNil(BrowserWindowRegistry.shared.restorableBrowserWindow(in: []))
        XCTAssertTrue(BrowserWindowRegistry.shared.restorableBrowserWindow(in: [window]) === window)
        var openRequests = 0
        BrowserWindowRouter.shared.swiftUIWindowOpener = { openRequests += 1 }

        let delegate = AppDelegate(modelManager: .shared)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))

        XCTAssertEqual(window.orderFrontCount, 1)
        XCTAssertEqual(window.deminiaturizeCount, 1)
        XCTAssertEqual(openRequests, 0)
        XCTAssertEqual(BrowserWindowRegistry.shared.activeWindowID, browser.windowID)
    }

    func testDockReopenRestoresOwnedStandalonePreviewWithoutCreatingBrowser() {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }
        let window = DockReopenWindowSpy(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = StandalonePreviewWindowManager.shared
        defer {
            window.delegate = nil
            window.close()
        }
        var openRequests = 0
        BrowserWindowRouter.shared.swiftUIWindowOpener = { openRequests += 1 }

        let delegate = AppDelegate(modelManager: .shared)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))

        XCTAssertEqual(window.orderFrontCount, 1)
        XCTAssertEqual(openRequests, 0)
    }

    func testDockMenuStructureExactFinderOrderingAndLocalization() throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let dir1 = try makeTemporaryDirectory(prefix: "FavPodcast")
        let dir2 = try makeTemporaryDirectory(prefix: "FavDaily")
        favoritesProvider.pinnedRecords = [
            PinnedFolderRecord(path: dir1.path),
            PinnedFolderRecord(path: dir2.path)
        ]

        let recentDir = try makeTemporaryDirectory(prefix: "RecentWork")
        let recentZip = recentDir.appendingPathComponent("bundle.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18)).write(to: recentZip)
        recentStore.recordDirectory(url: recentDir)
        recentStore.recordArchive(url: recentZip)

        let menuZh = dockController.buildDockMenu(language: .zhHans)
        let itemsZh = menuZh.items
        XCTAssertGreaterThanOrEqual(itemsZh.count, 10)

        // Group 1: New TTZip Window; New Smart Folder…; Find…
        XCTAssertEqual(itemsZh[0].title, "新建 TTZip 窗口")
        XCTAssertEqual(itemsZh[1].title, "新建智能文件夹…")
        XCTAssertEqual(itemsZh[2].title, "查找…")
        XCTAssertTrue(itemsZh[3].isSeparatorItem)

        // Group 2: Go to Folder…; Connect to Server…
        XCTAssertEqual(itemsZh[4].title, "前往文件夹…")
        XCTAssertEqual(itemsZh[5].title, "连接服务器…")
        XCTAssertTrue(itemsZh[6].isSeparatorItem)

        // Group 3: Dynamic Favorites & Recent Items
        XCTAssertEqual(itemsZh[7].title, MultiWindowLocaleKey.favoriteLocationsHeader.translation(for: .zhHans))
        XCTAssertFalse(itemsZh[7].isEnabled)
        XCTAssertEqual(itemsZh[8].title, dir1.lastPathComponent)
        XCTAssertEqual(itemsZh[9].title, dir2.lastPathComponent)

        // Verify English localization rebuilds freshly on next open
        let menuEn = dockController.buildDockMenu(language: .en)
        XCTAssertEqual(menuEn.items[0].title, "New TTZip Window")
        XCTAssertEqual(menuEn.items[1].title, "New Smart Folder…")
        XCTAssertEqual(menuEn.items[2].title, "Find…")
        XCTAssertEqual(menuEn.items[4].title, "Go to Folder…")
        XCTAssertEqual(menuEn.items[5].title, "Connect to Server…")

        // Verify AppDelegate.applicationDockMenu(_:) returns native NSMenu without spoofing private window items
        let appDelegate = AppDelegate()
        AppLocalizationState.shared.setLanguage(.zhHans)
        let delegateMenu = appDelegate.applicationDockMenu(NSApplication.shared)
        XCTAssertNotNil(delegateMenu)
        XCTAssertEqual(delegateMenu?.items.first?.title, "新建 TTZip 窗口")
    }

    // MARK: - Slice A.2: Real NSMenuItem Action -> Active Window, Closed Window & Zero-Window One-Shot Delivery

    func testDockMenuActionDeliversToMostRecentActiveWindowAndSkipsClosingWindows() throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let dirA = try makeTemporaryDirectory(prefix: "WinA")
        let dirB = try makeTemporaryDirectory(prefix: "WinB")

        let winA = AppViewState(fileViewer: NoOpFileViewer())
        let winB = AppViewState(fileViewer: NoOpFileViewer())
        winA.navigateToDirectory(dirA)
        winB.navigateToDirectory(dirB)

        BrowserWindowRegistry.shared.register(winA)
        BrowserWindowRegistry.shared.register(winB)
        BrowserWindowRegistry.shared.activateWindow(id: winA.windowID)

        let menu = dockController.buildDockMenu(language: .zhHans)
        // Trigger "Find..." (index 2)
        let findItem = menu.items[2]
        let initialGenA = winA.overlayState.findFocusRequestGeneration
        let initialGenB = winB.overlayState.findFocusRequestGeneration

        invokeMenuItem(findItem)
        XCTAssertEqual(winA.overlayState.findFocusRequestGeneration, initialGenA &+ 1)
        XCTAssertEqual(winB.overlayState.findFocusRequestGeneration, initialGenB)

        // Now close winA (`prepareForWindowClose()`); subsequent command must route to winB and never mutate closed winA
        winA.prepareForWindowClose()
        XCTAssertTrue(winA.isWindowClosing)

        let goToFolderItem = menu.items[4]
        invokeMenuItem(goToFolderItem)
        XCTAssertFalse(winA.overlayState.showGoToFolderModal)
        XCTAssertTrue(winB.overlayState.showGoToFolderModal)
    }

    func testDockMenuZeroWindowDeferredCommandDeliveredExactlyOnceUponWindowRegistration() throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        XCTAssertEqual(BrowserWindowRegistry.shared.windowCount, 0)

        var swiftUIOpenCount = 0
        BrowserWindowRouter.shared.swiftUIWindowOpener = {
            swiftUIOpenCount += 1
        }

        let favDir = try makeTemporaryDirectory(prefix: "ZeroWinFav")
        favoritesProvider.pinnedRecords = [PinnedFolderRecord(path: favDir.path)]

        let menu = dockController.buildDockMenu(language: .zhHans)
        guard let favItem = menu.items.first(where: { $0.representedObject as? DockMenuFavoriteEntry != nil }) else {
            XCTFail("Expected favorite menu item")
            return
        }

        // Invoke favorite item while zero windows exist
        invokeMenuItem(favItem)
        XCTAssertEqual(swiftUIOpenCount, 1)

        // Simulate SwiftUI creating the new window and registering its AppViewState controller
        let createdWindow = AppViewState(fileViewer: NoOpFileViewer())
        BrowserWindowRegistry.shared.register(createdWindow)

        // Command must be delivered automatically on registration
        XCTAssertEqual(createdWindow.currentDirectoryURL.standardizedFileURL, favDir.standardizedFileURL)

        // Registering a second window later must NOT re-deliver the already-consumed command
        let secondWindow = AppViewState(fileViewer: NoOpFileViewer())
        let defaultDir = secondWindow.currentDirectoryURL
        BrowserWindowRegistry.shared.register(secondWindow)
        XCTAssertEqual(secondWindow.currentDirectoryURL, defaultDir)
    }

    // MARK: - Slice A.3: Favorites Deduplication by FileIdentity, Duplicate Name Disambiguation & Offline Handling

    func testFavoritesDeduplicationByFileIdentityAndDuplicateDisplayNameDisambiguation() throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let rootA = try makeTemporaryDirectory(prefix: "WorkspaceA")
        let rootB = try makeTemporaryDirectory(prefix: "WorkspaceB")
        let docsA = rootA.appendingPathComponent("Docs", isDirectory: true)
        let docsB = rootB.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docsB, withIntermediateDirectories: true)

        // Pin `docsA` AND include `docsA` again in dynamicFinderFavorites (same FileIdentity) plus `docsB` (same leaf name, different path)
        favoritesProvider.pinnedRecords = [PinnedFolderRecord(path: docsA.path)]
        favoritesProvider.dynamicFinderFavorites = [
            FinderFavoriteItem(name: "Docs", path: docsA.path, systemImage: "folder"),
            FinderFavoriteItem(name: "Docs", path: docsB.path, systemImage: "folder")
        ]

        let snapshot = dockController.snapshotFavoriteEntries()
        XCTAssertEqual(snapshot.count, 2, "Duplicate FileIdentity for docsA must be deduplicated")
        XCTAssertNotEqual(snapshot[0].disambiguatedTitle, snapshot[1].disambiguatedTitle, "Same leaf name 'Docs' at different paths must be disambiguated")
        XCTAssertTrue(snapshot[0].disambiguatedTitle.contains("Docs — "))
        XCTAssertTrue(snapshot[1].disambiguatedTitle.contains("Docs — "))
    }

    func testStaleOrOfflineFavoriteDoesNotDeleteFilesAndReportsGracefully() throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let win = AppViewState(fileViewer: NoOpFileViewer())
        let startingDir = try makeTemporaryDirectory(prefix: "StartingDir")
        let survivorFile = startingDir.appendingPathComponent("keep_me.txt")
        try Data("important".utf8).write(to: survivorFile)
        win.navigateToDirectory(startingDir)
        BrowserWindowRegistry.shared.register(win)

        let missingPath = startingDir.appendingPathComponent("NonExistentMount").path
        favoritesProvider.pinnedRecords = [
            PinnedFolderRecord(
                path: missingPath,
                lastKnownHealthState: .unmountedVolume(volumeName: "BackupNAS", volumeUUID: nil)
            )
        ]

        let menu = dockController.buildDockMenu(language: .zhHans)
        guard let item = menu.items.first(where: { $0.representedObject as? DockMenuFavoriteEntry != nil }) else {
            XCTFail("Expected offline favorite menu item")
            return
        }
        XCTAssertTrue(item.title.contains("离线"))

        invokeMenuItem(item)
        // Must not navigate away to a dead path, must set informative status message, and never delete existing files
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, startingDir.standardizedFileURL)
        XCTAssertNotEqual(win.taskState.statusMessage, "Ready")
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivorFile.path))
    }

    // MARK: - Slice A.4: Dedicated Go to Folder Service & Modal Routing

    func testGoToFolderSupportsAbsoluteTildeAndFileURLWhileKeepingErrorInPanelAndCancelNoOp() async throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let baseDir = try makeTemporaryDirectory(prefix: "GoBase")
        let subDir = baseDir.appendingPathComponent("TargetSub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let service = GoToFolderNavigationService()
        service.accessCheckOverride = { _ in true }

        // 1. Absolute path
        service.updateInput(subDir.path, baseDirectory: baseDir)
        let absOutcome = await service.validateAndAuthorize(baseDirectory: baseDir)
        XCTAssertEqual(absOutcome, .success(.directory(subDir.standardizedFileURL)))

        // 2. ~/ home path
        service.updateInput("~", baseDirectory: baseDir)
        let homeOutcome = await service.validateAndAuthorize(baseDirectory: baseDir)
        let expectedHome = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        XCTAssertEqual(homeOutcome, .success(.directory(expectedHome)))

        // 3. Local file:// URL
        service.updateInput(subDir.absoluteString, baseDirectory: baseDir)
        let urlOutcome = await service.validateAndAuthorize(baseDirectory: baseDir)
        XCTAssertEqual(urlOutcome, .success(.directory(subDir.standardizedFileURL)))

        // 4. Non-existent path stays in error state without altering window currentDirectory
        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(baseDir)
        BrowserWindowRegistry.shared.register(win)

        service.updateInput(baseDir.appendingPathComponent("NoSuchDirectory").path, baseDirectory: baseDir)
        let missingOutcome = await service.validateAndAuthorize(baseDirectory: baseDir)
        if case .failure(.pathDoesNotExist) = missingOutcome {
            XCTAssertNotNil(service.inlineErrorMessage)
        } else {
            XCTFail("Expected .pathDoesNotExist for non-existent path")
        }
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, baseDir.standardizedFileURL)

        // 5. Unauthorized path routes through authorization callback and reports required permission on denial
        var promptedForAuth = false
        service.accessCheckOverride = { _ in
            promptedForAuth = true
            return false
        }
        service.updateInput(subDir.path, baseDirectory: baseDir)
        let deniedOutcome = await service.validateAndAuthorize(baseDirectory: baseDir)
        XCTAssertTrue(promptedForAuth)
        if case .failure(.accessDenied) = deniedOutcome {
            XCTAssertNotNil(service.inlineErrorMessage)
        } else {
            XCTFail("Expected .accessDenied when access is denied")
        }
    }

    // MARK: - Slice B: Smart Folders (Saved Search Persistence, Dynamic Re-Query, No Model Required, Safe Delete)

    func testSmartFolderSaveReloadDynamicUpdateWithoutModelAndSafeDelete() async throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let workspaceDir = try makeTemporaryDirectory(prefix: "SmartFolderDynamic")
        let alphaZip = workspaceDir.appendingPathComponent("alpha_report.zip")
        let betaTxt = workspaceDir.appendingPathComponent("beta_notes.txt")
        try Data("zip-placeholder".utf8).write(to: alphaZip)
        try Data("notes-placeholder".utf8).write(to: betaTxt)

        // 1. Save Smart Folder
        let created = try smartFolderStore.createSmartFolder(
            name: "Report Archives",
            criteria: SmartFolderCriteria(
                nameQuery: "report",
                fileExtension: "zip",
                kindFilter: .archivesOnly
            ),
            scope: .directory(path: workspaceDir.path, bookmarkData: nil)
        )
        XCTAssertEqual(smartFolderStore.records.count, 1)

        // 2. Simulate app restart by creating a new store instance backed by the same persistence file
        let reloadedStore = SmartFolderStore(
            userDefaults: isolatedDefaults,
            customStorageFileURL: customSmartFolderFileURL
        )
        XCTAssertEqual(reloadedStore.records.count, 1)
        let restored = try XCTUnwrap(reloadedStore.record(for: created.id))
        XCTAssertEqual(restored.name, "Report Archives")
        XCTAssertEqual(restored.criteria.nameQuery, "report")
        XCTAssertEqual(restored.criteria.fileExtension, "zip")

        // 3. Evaluate dynamically (with no Gemma AI model required)
        let initialEval = await reloadedStore.evaluate(
            record: restored,
            systemSearchProvider: MockSystemFileSearchProvider(),
            checkAccess: { _ in true }
        )
        XCTAssertFalse(initialEval.isScopeUnauthorized)
        XCTAssertEqual(initialEval.items.map(\.title), ["alpha_report.zip"])

        // 4. Add a new matching file on disk -> re-query reflects addition
        let gammaZip = workspaceDir.appendingPathComponent("gamma_report.zip")
        try Data("zip-2".utf8).write(to: gammaZip)

        let afterAddEval = await reloadedStore.evaluate(
            record: restored,
            systemSearchProvider: MockSystemFileSearchProvider(),
            checkAccess: { _ in true }
        )
        XCTAssertEqual(Set(afterAddEval.items.map(\.title)), Set(["alpha_report.zip", "gamma_report.zip"]))

        // 5. Remove original file -> re-query reflects removal
        try FileManager.default.removeItem(at: alphaZip)
        let afterRemoveEval = await reloadedStore.evaluate(
            record: restored,
            systemSearchProvider: MockSystemFileSearchProvider(),
            checkAccess: { _ in true }
        )
        XCTAssertEqual(afterRemoveEval.items.map(\.title), ["gamma_report.zip"])

        // 6. Rename Smart Folder
        let renamed = try reloadedStore.renameSmartFolder(id: restored.id, newName: "Renamed Reports")
        XCTAssertEqual(renamed.name, "Renamed Reports")

        // 7. Delete Smart Folder MUST NOT delete physical files on disk
        reloadedStore.deleteSmartFolder(id: restored.id)
        XCTAssertNil(reloadedStore.record(for: restored.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gammaZip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: betaTxt.path))
    }

    func testSmartFolderEmptyConditionCorruptedStorageUnauthorizedAndZeroMatches() async throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let workspaceDir = try makeTemporaryDirectory(prefix: "SmartFolderEdge")

        // Empty condition rejected
        XCTAssertThrowsError(
            try smartFolderStore.createSmartFolder(
                name: "Invalid Empty",
                criteria: SmartFolderCriteria(nameQuery: "   ", fileExtension: "", kindFilter: .any),
                scope: .directory(path: workspaceDir.path, bookmarkData: nil)
            )
        ) { error in
            XCTAssertEqual(error as? SmartFolderOperationError, .emptyCriteria)
        }

        // Unauthorized directory scope clearly reports authorization requirement
        let NonReadableDir = URL(fileURLWithPath: "/private/var/root/ttzip_restricted_nonexistent")
        let restrictedRecord = try smartFolderStore.createSmartFolder(
            name: "Restricted Search",
            criteria: SmartFolderCriteria(nameQuery: "anything"),
            scope: .directory(path: NonReadableDir.path, bookmarkData: nil)
        )
        let unauthorizedEval = await smartFolderStore.evaluate(
            record: restrictedRecord,
            systemSearchProvider: MockSystemFileSearchProvider(),
            checkAccess: { _ in false }
        )
        XCTAssertTrue(unauthorizedEval.isScopeUnauthorized)
        XCTAssertTrue(unauthorizedEval.items.isEmpty)

        // Zero match returns empty list cleanly
        let validRecord = try smartFolderStore.createSmartFolder(
            name: "Valid Zero Match",
            criteria: SmartFolderCriteria(nameQuery: "nonexistent_token_xyz"),
            scope: .directory(path: workspaceDir.path, bookmarkData: nil)
        )
        let zeroMatchEval = await smartFolderStore.evaluate(
            record: validRecord,
            systemSearchProvider: MockSystemFileSearchProvider(),
            checkAccess: { _ in true }
        )
        XCTAssertFalse(zeroMatchEval.isScopeUnauthorized)
        XCTAssertTrue(zeroMatchEval.items.isEmpty)
        XCTAssertEqual(zeroMatchEval.phase, .empty)

        // Corrupted JSON storage recovers gracefully without crashing
        try Data("{corrupted-json-payload".utf8).write(to: customSmartFolderFileURL, options: .atomic)
        smartFolderStore.loadFromStorage()
        XCTAssertTrue(smartFolderStore.records.isEmpty)
        XCTAssertNotNil(smartFolderStore.lastCorruptedRecordLoadError)
    }

    // MARK: - Slice C: Connect to Server (Protocol Validation, Credential Scrubbing, Lifecycle & Volume Coalescing)

    func testServerValidationSupportsSMBAndScrubsEmbeddedPasswordsFromURLsAndRecents() throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let mountDir = try makeTemporaryDirectory(prefix: "MountedSMBShare")
        let transport = ControlledServerMountTransport(behavior: .succeed(mountPoints: [mountDir]))
        let service = ServerConnectionService(
            transport: transport,
            userDefaults: isolatedDefaults,
            loadRecentsOnInit: false
        )

        // 1. Rejects unsupported schemes (http, ftp, ssh) and empty input
        XCTAssertEqual(ServerConnectionService.validateServerInput("   "), .failure(.emptyInput))
        XCTAssertEqual(
            ServerConnectionService.validateServerInput("http://example.com/share"),
            .failure(.unsupportedScheme("http"))
        )
        XCTAssertEqual(
            ServerConnectionService.validateServerInput("ftp://files.local/pub"),
            .failure(.unsupportedScheme("ftp"))
        )
        XCTAssertEqual(
            ServerConnectionService.validateServerInput("ssh://root@box.local"),
            .failure(.unsupportedScheme("ssh"))
        )
        XCTAssertEqual(ServerConnectionService.validateServerInput("smb://"), .failure(.missingHost))

        // 2. Bare host/share defaults to smb://
        let bareEndpoint = try ServerConnectionService.validateServerInput("nas.local/media").get()
        XCTAssertEqual(bareEndpoint.scheme, .smb)
        XCTAssertEqual(bareEndpoint.host, "nas.local")
        XCTAssertEqual(bareEndpoint.sanitizedAddressString, "smb://nas.local/media")

        // 3. Embedded password MUST be stripped from sanitizedURL, sanitizedAddressString, and UserDefaults recents
        let secretInput = "smb://kevin:SuperSecretPassword123!@nas.local:445/studio_share"
        let validated = try ServerConnectionService.validateServerInput(secretInput).get()
        XCTAssertFalse(validated.sanitizedAddressString.contains("SuperSecretPassword123"))
        XCTAssertFalse(validated.sanitizedURL?.absoluteString.contains("SuperSecretPassword123") ?? true)
        XCTAssertEqual(validated.sanitizedAddressString, "smb://nas.local:445/studio_share")
        XCTAssertEqual(validated.username, "kevin")

        service.recordRecentServer(endpoint: validated)
        XCTAssertEqual(service.recentServerAddresses, ["smb://nas.local:445/studio_share"])
        let rawStored = isolatedDefaults.stringArray(forKey: ServerConnectionService.recentServersKey) ?? []
        XCTAssertFalse(rawStored.joined(separator: "|").contains("SuperSecretPassword123"))
    }

    func testServerConnectionLifecycleSuccessFailureCancelAndAlreadyMountedReuse() async throws {
        resetTestFixturesOnMainActor()
        defer { tearDownTestFixturesOnMainActor() }

        let originalDir = try makeTemporaryDirectory(prefix: "OriginalBrowserDir")
        let mountedShareDir = try makeTemporaryDirectory(prefix: "MountedShareVolume")

        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(originalDir)
        BrowserWindowRegistry.shared.register(win)

        let transport = ControlledServerMountTransport(behavior: .succeed(mountPoints: [mountedShareDir]))
        let service = ServerConnectionService(
            transport: transport,
            userDefaults: isolatedDefaults,
            loadRecentsOnInit: false
        )
        service.volumeAccessCheckOverride = { _ in true }

        // 1. Authentication failure leaves active browser window directory untouched
        var dismissedCount = 0
        transport.behavior = .fail(.authenticationFailed("nas.local"))
        let failOutcome = await service.connectAndNavigate(
            rawInput: "smb://nas.local/private",
            allowAuthenticationUI: false,
            in: win,
            onDismiss: { dismissedCount += 1 }
        )
        XCTAssertEqual(failOutcome, .failure(.authenticationFailed("nas.local")))
        XCTAssertEqual(service.state, .failed(.authenticationFailed("nas.local")))
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, originalDir.standardizedFileURL)
        XCTAssertEqual(dismissedCount, 0)

        // 2. Cancellation transitions cleanly to .cancelled without polluting browser window
        transport.behavior = .waitUntilCancelled
        let connectTask = Task { @MainActor in
            await service.connectAndNavigate(
                rawInput: "smb://slow-nas.local/archive",
                allowAuthenticationUI: false,
                in: win,
                onDismiss: { dismissedCount += 1 }
            )
        }
        await Task.yield()
        service.cancelActiveConnection()
        _ = await connectTask.value
        XCTAssertEqual(service.state, .cancelled)
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, originalDir.standardizedFileURL)
        XCTAssertEqual(dismissedCount, 0)

        // 3. Successful mount returns mounted URL, records credential-free recent, and navigates browser window via production wiring
        transport.behavior = .succeed(mountPoints: [mountedShareDir])
        let successOutcome = await service.connectAndNavigate(
            rawInput: "smb://admin:topsecret@nas.local/projects",
            allowAuthenticationUI: false,
            in: win,
            onDismiss: { dismissedCount += 1 }
        )
        let mountURL = try successOutcome.get()
        XCTAssertEqual(mountURL.standardizedFileURL, mountedShareDir.standardizedFileURL)
        XCTAssertEqual(service.state, .connected(mountPointURL: mountedShareDir.standardizedFileURL, reusedExistingMount: false))
        XCTAssertFalse(service.recentServerAddresses.joined().contains("topsecret"))
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, mountedShareDir.standardizedFileURL)
        XCTAssertEqual(dismissedCount, 1)

        // 4. Already-mounted volume reuse skips transport remount and sets reusedExistingMount = true
        win.navigateToDirectory(originalDir)
        let callsBeforeReuse = transport.mountCallCount
        service.existingMountLookupOverride = { _ in mountedShareDir.standardizedFileURL }
        let reuseOutcome = await service.connectAndNavigate(
            rawInput: "smb://nas.local/projects",
            allowAuthenticationUI: false,
            in: win,
            onDismiss: { dismissedCount += 1 }
        )
        XCTAssertEqual(try reuseOutcome.get(), mountedShareDir.standardizedFileURL)
        XCTAssertEqual(transport.mountCallCount, callsBeforeReuse, "Must reuse existing mount without calling transport again")
        XCTAssertEqual(service.state, .connected(mountPointURL: mountedShareDir.standardizedFileURL, reusedExistingMount: true))
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, mountedShareDir.standardizedFileURL)
        XCTAssertEqual(dismissedCount, 2)
    }
}

@MainActor
private final class DockReopenWindowSpy: NSWindow {
    private(set) var orderFrontCount = 0
    private(set) var deminiaturizeCount = 0
    var simulatesMiniaturizedWindow = false

    override var canBecomeMain: Bool { true }
    override var isMiniaturized: Bool { simulatesMiniaturizedWindow }

    override func deminiaturize(_ sender: Any?) {
        deminiaturizeCount += 1
        simulatesMiniaturizedWindow = false
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontCount += 1
    }
}
