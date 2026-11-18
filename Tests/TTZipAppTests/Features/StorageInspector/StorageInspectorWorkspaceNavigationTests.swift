// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipWorkspace
import SwiftUI
import TTZipUI
@testable import TTZipApp
@testable import TTZipCore

@MainActor
final class StorageInspectorWorkspaceNavigationTests: XCTestCase {

    // MARK: - 1. Tab Lifecycle & Idempotent Navigation

    func testStorageInspectorTabLifecycleAndIdempotency() {
        let navState = NavigationState()
        let initialTabCount = navState.directoryTabs.count

        // 1. Open Storage Inspector tab for the first time
        navState.openStorageInspectorTab()

        XCTAssertEqual(navState.directoryTabs.count, initialTabCount + 1, "Storage Inspector tab must be appended to the directoryTabs collection")
        guard let activeTab = navState.activeDirectoryTab else {
            XCTFail("An active tab must exist after opening Storage Inspector")
            return
        }

        XCTAssertEqual(activeTab.url, StorageInspectorView.storageInspectorURL)
        XCTAssertNil(activeTab.customTitle, "Storage Inspector tab must not hardcode customTitle so titleKey localizes dynamically")
        XCTAssertEqual(navState.activeTabSession?.titleKey?.rawKey, L10n.Sidebar.storageInspector.rawKey)
        XCTAssertTrue(activeTab.isStorageInspector)
        XCTAssertTrue(navState.isStorageInspectorActive, "isStorageInspectorActive must report true")

        let firstTabIndex = navState.activeTabIndex

        // 2. Open Storage Inspector again - must be idempotent (re-activate existing tab without duplicate)
        navState.openStorageInspectorTab()

        XCTAssertEqual(navState.directoryTabs.count, initialTabCount + 1, "Tab count must not increase on subsequent activations")
        XCTAssertEqual(navState.activeTabIndex, firstTabIndex, "Previously created tab index must be re-activated")
        XCTAssertTrue(navState.isStorageInspectorActive)
    }

    func testStorageInspectorTabTitleDynamicLocalization() {
        let navState = NavigationState()
        let l10n = AppLocalizationState.shared
        let originalLanguage = l10n.currentLanguage
        defer { l10n.setLanguage(originalLanguage) }

        navState.openStorageInspectorTab()
        guard let session = navState.activeTabSession else {
            XCTFail("Expected active Storage Inspector tab session")
            return
        }

        XCTAssertNil(session.customTitle)
        XCTAssertEqual(session.titleKey?.rawKey, L10n.Sidebar.storageInspector.rawKey)

        l10n.setLanguage(.en)
        let enTitle = navState.activeDirectoryTab?.title
        XCTAssertEqual(enTitle, l10n.t(L10n.Sidebar.storageInspector))
        XCTAssertNotEqual(enTitle, "存储透视")

        l10n.setLanguage(.zhHans)
        let zhTitle = navState.activeDirectoryTab?.title
        XCTAssertEqual(zhTitle, l10n.t(L10n.Sidebar.storageInspector))
    }

    func testStorageInspectorCloseActionClosesWorkspaceTabAndCancelsWork() {
        let navState = NavigationState()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCloseTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        navState.currentDirectory = tempDir
        navState.openStorageInspectorTab()
        XCTAssertTrue(navState.isStorageInspectorActive)

        let vm = StorageInspectorViewModel(initialDirectory: tempDir)
        vm.isPresented = true
        vm.state = .scanning(currentPath: tempDir.lastPathComponent, scannedItems: 3, itemsPerSec: 10)

        var closeCallbackCount = 0
        let view = StorageInspectorView(
            isPresented: Binding(
                get: { navState.isStorageInspectorActive },
                set: { isPresented in
                    if !isPresented {
                        vm.handleExplicitClose()
                        navState.closeStorageInspectorTab()
                    }
                }
            ),
            viewModel: vm,
            onClose: {
                closeCallbackCount += 1
                vm.handleExplicitClose()
                navState.closeStorageInspectorTab()
            }
        )

        view.closeInspector()

        XCTAssertEqual(closeCallbackCount, 1)
        XCTAssertFalse(navState.isStorageInspectorActive, "Closing Storage Inspector must deactivate the inspector tab")
        XCTAssertFalse(navState.tabSessions.contains(where: { $0.kind.isStorageInspector }))
        XCTAssertEqual(navState.currentDirectory.standardizedFileURL.path, tempDir.standardizedFileURL.path)
        XCTAssertFalse(vm.isPresented)
        XCTAssertEqual(vm.state, .cancelled)
    }

    func testStorageInspectorResumesStrandedCancelledScanOnAppearAndPreservesTabSwitchState() {
        let navState = NavigationState()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageResumeTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let regularTabIndex = navState.activeTabIndex
        navState.openStorageInspectorTab()

        let vm = StorageInspectorViewModel(initialDirectory: tempDir)
        XCTAssertTrue(vm.shouldStartScanOnAppear, "Idle state with empty tiles must start scan on appear")

        vm.state = .cancelled
        XCTAssertTrue(vm.rootTiles.isEmpty)
        XCTAssertTrue(vm.shouldStartScanOnAppear, "Cancelled state with empty rootTiles must resume scanning on appear")

        navState.selectTab(at: regularTabIndex)
        XCTAssertFalse(navState.isStorageInspectorActive)
        XCTAssertTrue(
            navState.tabSessions.contains(where: { $0.kind.isStorageInspector }),
            "Switching tabs must keep the Storage Inspector session alive instead of closing it"
        )

        vm.handleViewAppear()
        XCTAssertNotEqual(vm.state, .cancelled, "Re-appearing with empty rootTiles must restart scan from .cancelled")
        vm.handleExplicitClose()

        let populatedTile = TreemapTile(
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            nodeId: 1,
            category: .others,
            bytes: 4096,
            name: "file.bin",
            relativePath: "/tmp/file.bin"
        )
        vm.tiles = [populatedTile]
        vm.state = .cancelled
        XCTAssertFalse(vm.shouldStartScanOnAppear, "Cancelled state with already populated tiles must not auto-restart")

        vm.state = .completed(totalBytes: 4096, reclaimableBytes: 0, durationSec: 0.05)
        XCTAssertFalse(vm.shouldStartScanOnAppear, "Completed scan must not restart on tab re-activation")
    }

    func testReclaimReviewBadgeShownOnlyWhenScanCompletedOrEmptyWithZeroCandidates() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageBadgeTest_\(UUID().uuidString)")
        let vm = StorageInspectorViewModel(initialDirectory: tempDir)

        vm.state = .idle
        XCTAssertFalse(vm.showsNoReclaimableFoundBadge)

        vm.state = .scanning(currentPath: "node_modules", scannedItems: 42, itemsPerSec: 100)
        XCTAssertFalse(vm.showsNoReclaimableFoundBadge, "Must not show green no-reclaimable badge while scan is in progress")

        vm.state = .cancelled
        XCTAssertFalse(vm.showsNoReclaimableFoundBadge, "Must not show green no-reclaimable badge when scan was cancelled")

        vm.state = .permissionDenied(path: "/private/var/root")
        XCTAssertFalse(vm.showsNoReclaimableFoundBadge, "Must not show green no-reclaimable badge on permissionDenied")

        vm.state = .failed(message: "Disk read error")
        XCTAssertFalse(vm.showsNoReclaimableFoundBadge, "Must not show green no-reclaimable badge on scan failure")

        vm.state = .empty(rootPath: tempDir.path)
        XCTAssertTrue(vm.showsNoReclaimableFoundBadge, "Empty directory scan with zero candidates should show badge")

        vm.state = .completed(totalBytes: 8192, reclaimableBytes: 0, durationSec: 0.02)
        XCTAssertTrue(vm.showsNoReclaimableFoundBadge, "Completed scan with zero candidates should show badge")

        vm.unverifiedItems = [
            ReclaimableStorageItem(
                name: "build",
                url: tempDir.appendingPathComponent("build"),
                sizeBytes: 1024,
                reason: "Unverified",
                verification: .nameOnly
            )
        ]
        XCTAssertFalse(vm.showsNoReclaimableFoundBadge, "Completed scan with unverified items must render candidate list instead of empty badge")
    }

    // MARK: - 2. Workspace State Switching & Isolation

    func testSwitchingBetweenStorageInspectorAndDirectoryTab() {
        let navState = NavigationState()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageNavTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Set up initial regular directory tab
        navState.currentDirectory = tempDir
        let regularTabIndex = navState.activeTabIndex

        XCTAssertFalse(navState.isStorageInspectorActive)
        XCTAssertEqual(navState.currentDirectory, tempDir)

        // Open Storage Inspector
        navState.openStorageInspectorTab()
        XCTAssertTrue(navState.isStorageInspectorActive)
        XCTAssertEqual(navState.currentDirectory, StorageInspectorView.storageInspectorURL)

        // Switch back to regular directory tab
        navState.selectTab(at: regularTabIndex)
        XCTAssertFalse(navState.isStorageInspectorActive, "Storage inspector must become inactive when switching to a regular folder tab")
        XCTAssertEqual(navState.currentDirectory.scheme, "file", "Scheme must be local file system, preventing ttzip:// protocol leakage")
        XCTAssertEqual(navState.currentDirectory.standardizedFileURL.path, tempDir.standardizedFileURL.path, "Local file system directory must match exactly")
    }

    // MARK: - 3. Forensic System Path Protection Guard

    func testForensicPathGuardBoundaryProtection() {
        // Protected root system paths
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("/System"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("/System/Library"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("/usr"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("/usr/bin"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("/bin"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("/Library"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("/Applications"))

        // Sensitive user directories
        let home = NSHomeDirectory()
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("\(home)/.ssh"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("\(home)/.ssh/id_rsa"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("\(home)/.gnupg"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("\(home)/Library/Keychains"))
        XCTAssertTrue(ForensicPathGuard.isProtectedSystemPath("\(home)/Library/Safari"))

        // Unprotected user working directories
        XCTAssertFalse(
            ForensicPathGuard.isProtectedSystemPath("\(home)/Downloads/test_folder"),
            "User Downloads working directory under HOME must not be treated as a protected system path"
        )
        XCTAssertFalse(
            ForensicPathGuard.isProtectedSystemPath("\(home)/Documents/my_code_project"),
            "User Documents working directory under HOME must not be treated as a protected system path"
        )
    }

    // MARK: - 4. Safety Guard for Xcode Archives & Evidence-Backed Reclaim Classification

    func testStorageInspectorReclaimClassificationSafety() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageClassifyTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Xcode Archives must NEVER be classified as reclaimable cache
        let archivesURL = tempRoot.appendingPathComponent("Archives")
        try FileManager.default.createDirectory(at: archivesURL, withIntermediateDirectories: true)
        let (archiveCat, archiveReclaim, _) = StorageInspectorViewModel.classifyEntry(
            name: "Archives",
            isDir: true,
            url: archivesURL
        )
        XCTAssertNotEqual(archiveCat, .reclaimCache, "Archives folder must not be classified as reclaimable cache")
        XCTAssertFalse(archiveReclaim, "Archives must not be marked as reclaimable space")

        // Non-existent synthetic path must never be marked reclaimable by name alone
        let (_, syntheticReclaim, _) = StorageInspectorViewModel.classifyEntry(
            name: "node_modules",
            isDir: true,
            url: tempRoot.appendingPathComponent("non_existent_project/node_modules")
        )
        XCTAssertFalse(syntheticReclaim, "Non-existent synthetic path must not be marked reclaimable by name alone")

        // Node modules with sibling package.json must be classified as reclaimCache
        let jsProject = tempRoot.appendingPathComponent("project")
        let nmURL = jsProject.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nmURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: jsProject.appendingPathComponent("package.json"))
        let (nmCat, nmReclaim, _) = StorageInspectorViewModel.classifyEntry(
            name: "node_modules",
            isDir: true,
            url: nmURL
        )
        XCTAssertEqual(nmCat, .reclaimCache)
        XCTAssertTrue(nmReclaim)

        // DerivedData with ModuleCache.noindex evidence must be classified as reclaimCache
        let ddURL = tempRoot.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(
            at: ddURL.appendingPathComponent("ModuleCache.noindex"),
            withIntermediateDirectories: true
        )
        let (ddCat, ddReclaim, _) = StorageInspectorViewModel.classifyEntry(
            name: "DerivedData",
            isDir: true,
            url: ddURL
        )
        XCTAssertEqual(ddCat, .reclaimCache)
        XCTAssertTrue(ddReclaim)

        // Cargo target directory with sibling Cargo.toml and CACHEDIR.TAG must be classified as reclaimCache
        let rustProject = tempRoot.appendingPathComponent("rust_project")
        let targetURL = rustProject.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try Data("[package]\nname = \"demo\"\n".utf8).write(to: rustProject.appendingPathComponent("Cargo.toml"))
        try Data("\(ForensicPathGuard.cacheDirTagSignature)\n".utf8).write(to: targetURL.appendingPathComponent("CACHEDIR.TAG"))
        let (targetCat, targetReclaim, _) = StorageInspectorViewModel.classifyEntry(
            name: "target",
            isDir: true,
            url: targetURL
        )
        XCTAssertEqual(targetCat, .reclaimCache)
        XCTAssertTrue(targetReclaim)
    }

    // MARK: - 5. Squarified Treemap Layout Unit Coordinates

    func testSquarifiedLayoutPointCoordinates() {
        let entries: [(name: String, path: String, bytes: UInt64, category: TileCategory, isReclaim: Bool)] = [
            (name: "large_file.zip", path: "/tmp/large_file.zip", bytes: 100_000_000, category: .compressedArchive, isReclaim: false),
            (name: "medium_video.mov", path: "/tmp/medium_video.mov", bytes: 50_000_000, category: .mediaVideo, isReclaim: false),
            (name: "small_code.rs", path: "/tmp/small_code.rs", bytes: 25_000_000, category: .generalCode, isReclaim: false),
        ]
        let total = entries.reduce(0) { $0 + $1.bytes }

        let tiles = StorageInspectorViewModel.computeSquarifiedLayout(entries: entries, totalBytes: total)
        XCTAssertEqual(tiles.count, 3)

        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.x, 0.0)
            XCTAssertLessThanOrEqual(tile.x, 1.0)
            XCTAssertGreaterThanOrEqual(tile.y, 0.0)
            XCTAssertLessThanOrEqual(tile.y, 1.0)
            XCTAssertGreaterThan(tile.width, 0.0)
            XCTAssertGreaterThan(tile.height, 0.0)
        }
        let tileSum = tiles.reduce(0 as UInt64) { $0 + $1.bytes }
        XCTAssertEqual(tileSum, total, "Bruls squarified layout must conserve exact byte totals")
    }
}
