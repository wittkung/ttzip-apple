// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
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
        XCTAssertEqual(activeTab.customTitle, "存储透视")
        XCTAssertTrue(activeTab.isStorageInspector)
        XCTAssertTrue(navState.isStorageInspectorActive, "isStorageInspectorActive must report true")

        let firstTabIndex = navState.activeTabIndex

        // 2. Open Storage Inspector again - must be idempotent (re-activate existing tab without duplicate)
        navState.openStorageInspectorTab()

        XCTAssertEqual(navState.directoryTabs.count, initialTabCount + 1, "Tab count must not increase on subsequent activations")
        XCTAssertEqual(navState.activeTabIndex, firstTabIndex, "Previously created tab index must be re-activated")
        XCTAssertTrue(navState.isStorageInspectorActive)
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
        XCTAssertFalse(ForensicPathGuard.isProtectedSystemPath("\(home)/Downloads/test_folder"))
        XCTAssertFalse(ForensicPathGuard.isProtectedSystemPath("\(home)/Documents/my_code_project"))
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
