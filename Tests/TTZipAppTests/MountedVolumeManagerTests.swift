// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import TTZipApp

@MainActor
final class MountedVolumeManagerTests: XCTestCase {

    func testMountedVolumeItemDataModel() {
        let testURL = URL(fileURLWithPath: "/Volumes/TestDrive")
        let item = MountedVolumeItem(
            name: "Test Drive",
            path: "/Volumes/TestDrive",
            url: testURL,
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            systemImage: "externaldrive.fill",
            isCloudStorage: false
        )

        XCTAssertEqual(item.id, "/Volumes/TestDrive")
        XCTAssertEqual(item.name, "Test Drive")
        XCTAssertEqual(item.path, "/Volumes/TestDrive")
        XCTAssertEqual(item.url, testURL)
        XCTAssertFalse(item.isInternal)
        XCTAssertTrue(item.isRemovable)
        XCTAssertTrue(item.isEjectable)
        XCTAssertEqual(item.systemImage, "externaldrive.fill")
        XCTAssertFalse(item.isCloudStorage)

        let duplicate = MountedVolumeItem(
            name: "Test Drive",
            path: "/Volumes/TestDrive",
            url: testURL,
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            systemImage: "externaldrive.fill",
            isCloudStorage: false
        )
        XCTAssertEqual(item, duplicate)
        XCTAssertEqual(item.hashValue, duplicate.hashValue)
    }

    func testMountedVolumeManagerInitializationAndRootVolume() {
        let manager = MountedVolumeManager.shared
        manager.refresh()

        let volumes = manager.mountedVolumes
        XCTAssertFalse(volumes.isEmpty, "Mounted volumes list must include at least root volume.")

        guard let root = volumes.first(where: { $0.path == "/" }) else {
            XCTFail("Root volume '/' must be present in mounted volumes list.")
            return
        }

        XCTAssertFalse(root.name.isEmpty, "Root volume name should not be empty.")
        XCTAssertTrue(root.isInternal, "Root volume must be marked as internal.")
        XCTAssertFalse(root.isRemovable, "Root volume must not be marked as removable.")
        XCTAssertFalse(root.isEjectable, "Root volume must not be ejectable.")
        XCTAssertEqual(root.systemImage, "internaldrive.fill")
        XCTAssertFalse(root.isCloudStorage)
    }

    func testDeduplicationByPath() {
        let manager = MountedVolumeManager.shared
        manager.refresh()

        let volumes = manager.mountedVolumes
        let paths = volumes.map(\.path)
        let uniquePaths = Set(paths)

        XCTAssertEqual(paths.count, uniquePaths.count, "Mounted volume paths must be strictly unique.")
    }

    func testEjectGuardsAgainstNonEjectableVolumes() {
        let manager = MountedVolumeManager.shared
        let nonEjectableItem = MountedVolumeItem(
            name: "Protected Volume",
            path: "/Volumes/Protected",
            url: URL(fileURLWithPath: "/Volumes/Protected"),
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            systemImage: "internaldrive.fill",
            isCloudStorage: false
        )

        XCTAssertNoThrow(try manager.ejectVolume(nonEjectableItem), "Ejecting a non-ejectable volume must safely no-op.")
    }

    func testCloudStorageDetectionProperties() {
        let manager = MountedVolumeManager.shared
        manager.refresh()

        let cloudVolumes = manager.mountedVolumes.filter(\.isCloudStorage)
        for item in cloudVolumes {
            XCTAssertFalse(item.isEjectable, "Cloud storage items must not be ejectable.")
            XCTAssertTrue(
                item.systemImage == "cloud.fill" || item.systemImage == "icloud.fill",
                "Cloud storage item must use cloud SF symbols."
            )
        }
    }

    func testStartAndStopMonitoringLifecycle() {
        let manager = MountedVolumeManager.shared
        manager.stopMonitoring()
        manager.startMonitoring()
        // Idempotent restarts
        manager.startMonitoring()
        manager.stopMonitoring()
    }

    func testSidebarVolumeRowViewInstantiation() {
        let item = MountedVolumeItem(
            name: "External USB",
            path: "/Volumes/ExternalUSB",
            url: URL(fileURLWithPath: "/Volumes/ExternalUSB"),
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            systemImage: "externaldrive.fill",
            isCloudStorage: false
        )

        var selectedURL: URL?
        let rowView = SidebarVolumeRowView(
            volume: item,
            isSelected: true,
            isIconRail: false,
            onSelect: { url in
                selectedURL = url
            }
        )

        XCTAssertNotNil(rowView.body)
        rowView.onSelect(item.url)
        XCTAssertEqual(selectedURL, item.url)

        let railView = SidebarVolumeRowView(
            volume: item,
            isSelected: false,
            isIconRail: true,
            onSelect: { _ in }
        )
        XCTAssertNotNil(railView.body)
    }

    func testFinderFavoritesSidebarViewIntegration() {
        let sidebar = FinderFavoritesSidebarView(
            currentDirectory: URL(fileURLWithPath: "/"),
            onSelectDirectory: { _ in }
        )
        XCTAssertNotNil(sidebar.body)
    }

    // MARK: - Production Scan & Coalescing Verification (Real Entrypoints)

    func testSameEntityPOSIXSymlinkAndExplicitICloudCoalesceIntoSingleRowWithAliasCoverage() throws {
        let tempRoot = try makeSandboxRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let cloudStorageURL = tempRoot.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let iCloudDocsURL = tempRoot.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudStorageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iCloudDocsURL, withIntermediateDirectories: true)

        let iCloudSymlinkURL = cloudStorageURL.appendingPathComponent("iCloud云盘-iC123456")
        try FileManager.default.createSymbolicLink(at: iCloudSymlinkURL, withDestinationURL: iCloudDocsURL)

        let env = MountedVolumeManager.VolumeScanEnvironment(
            mountedVolumeURLs: [],
            homeDirectoryURL: tempRoot,
            includeRootVolume: false
        )
        let snapshot = MountedVolumeManager.scanVolumesBackground(environment: env)

        XCTAssertEqual(snapshot.volumes.count, 1, "Same physical iCloud entity exposed via CloudStorage symlink and CloudDocs must coalesce into a single row.")
        let merged = try XCTUnwrap(snapshot.volumes.first)
        XCTAssertEqual(merged.sourceKind, .icloudDrive)
        XCTAssertEqual(merged.systemImage, "icloud.fill")
        XCTAssertTrue(merged.isCloudStorage)
        XCTAssertEqual(merged.path, iCloudDocsURL.path)

        // Verify alias coverage for Favorites filtering and single-row selection
        XCTAssertTrue(snapshot.pathSet.contains(iCloudDocsURL.path))
        XCTAssertTrue(snapshot.pathSet.contains(iCloudSymlinkURL.path))

        let viewModel = FinderFavoritesViewModel.shared
        let selectedAtTarget = viewModel.isRowSelected(
            identity: merged.identity,
            section: .locations,
            currentIdentity: FileIdentity(url: iCloudDocsURL),
            mountedPaths: snapshot.pathSet
        )
        let selectedAtSymlink = viewModel.isRowSelected(
            identity: merged.identity,
            section: .locations,
            currentIdentity: FileIdentity(url: iCloudSymlinkURL),
            mountedPaths: snapshot.pathSet
        )
        XCTAssertTrue(selectedAtTarget)
        XCTAssertTrue(selectedAtSymlink)
    }

    func testDistinctMultiAccountAndSameNameDirectoriesOnSameVolumeArePreserved() throws {
        let tempRoot = try makeSandboxRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let cloudStorageURL = tempRoot.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let nextcloudA = cloudStorageURL.appendingPathComponent("Nextcloud-47a8b9c0", isDirectory: true)
        let nextcloudB = cloudStorageURL.appendingPathComponent("Nextcloud-9f1e2d3c", isDirectory: true)
        let siblingFolder = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: nextcloudA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nextcloudB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingFolder, withIntermediateDirectories: true)

        let env = MountedVolumeManager.VolumeScanEnvironment(
            mountedVolumeURLs: [],
            homeDirectoryURL: tempRoot,
            includeRootVolume: false
        )
        let snapshot = MountedVolumeManager.scanVolumesBackground(environment: env)

        XCTAssertEqual(snapshot.volumes.count, 2, "Distinct provider directories on the same volume must never be merged.")
        XCTAssertEqual(snapshot.volumes.map(\.name), ["Nextcloud-47a8b9c0", "Nextcloud-9f1e2d3c"])
        XCTAssertFalse(snapshot.pathSet.contains(siblingFolder.path), "Unrelated directories on the same volume must not be swallowed.")

        // Also verify two distinct physical directories with identical display names are never merged
        let sameNameCandidates = [
            MountedVolumeItem(
                name: "Nextcloud",
                path: nextcloudA.path,
                url: nextcloudA,
                isInternal: true,
                isRemovable: false,
                isEjectable: false,
                systemImage: "folder.fill",
                isCloudStorage: false,
                sourceKind: .cloudStorageLocation
            ),
            MountedVolumeItem(
                name: "Nextcloud",
                path: nextcloudB.path,
                url: nextcloudB,
                isInternal: true,
                isRemovable: false,
                isEjectable: false,
                systemImage: "folder.fill",
                isCloudStorage: false,
                sourceKind: .cloudStorageLocation
            )
        ]
        let sameNameSnapshot = MountedVolumeManager.coalesceCandidates(sameNameCandidates)
        XCTAssertEqual(sameNameSnapshot.volumes.count, 2, "Identical displayName with distinct physical inodes must not merge.")
    }

    func testHyphenatedNamesAndUnknownSuffixesPreserveNameAndNeutralClassification() throws {
        let tempRoot = try makeSandboxRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let cloudStorageURL = tempRoot.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let macDroidURL = cloudStorageURL.appendingPathComponent("MacDroid-err987654", isDirectory: true)
        let hyphenReadableURL = cloudStorageURL.appendingPathComponent("Project-Alpha-Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: macDroidURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hyphenReadableURL, withIntermediateDirectories: true)

        let env = MountedVolumeManager.VolumeScanEnvironment(
            mountedVolumeURLs: [],
            homeDirectoryURL: tempRoot,
            includeRootVolume: false
        )
        let snapshot = MountedVolumeManager.scanVolumesBackground(environment: env)

        XCTAssertEqual(snapshot.volumes.map(\.name), ["MacDroid-err987654", "Project-Alpha-Workspace"])
        for item in snapshot.volumes {
            XCTAssertEqual(item.sourceKind, .cloudStorageLocation)
            XCTAssertFalse(item.isCloudStorage, "Unverified CloudStorage entries must not claim confirmed Cloud badge.")
            XCTAssertEqual(item.systemImage, "folder.fill")
        }
    }

    func testUnresolvedFinderAliasDeadSymlinkCircularSymlinkAndOfflineFallbackBehavior() throws {
        let tempRoot = try makeSandboxRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let cloudStorageURL = tempRoot.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let targetDirURL = tempRoot.appendingPathComponent("RealTargetDir", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudStorageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirURL, withIntermediateDirectories: true)

        // 1. Finder Alias file pointing to targetDirURL
        let aliasFileURL = cloudStorageURL.appendingPathComponent("iCloud-FinderAlias")
        let bookmarkData = try targetDirURL.bookmarkData(
            options: [.suitableForBookmarkFile],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmarkData, to: aliasFileURL)

        // 2. Dead symlink
        let deadLinkURL = cloudStorageURL.appendingPathComponent("Stale-DeadLink")
        try FileManager.default.createSymbolicLink(
            at: deadLinkURL,
            withDestinationURL: tempRoot.appendingPathComponent("MissingTarget")
        )

        // 3. Circular symlink
        let loopA = cloudStorageURL.appendingPathComponent("Loop-A")
        let loopB = cloudStorageURL.appendingPathComponent("Loop-B")
        try FileManager.default.createSymbolicLink(at: loopA, withDestinationURL: loopB)
        try FileManager.default.createSymbolicLink(at: loopB, withDestinationURL: loopA)

        let env = MountedVolumeManager.VolumeScanEnvironment(
            mountedVolumeURLs: [],
            homeDirectoryURL: tempRoot,
            includeRootVolume: false
        )
        let snapshot = MountedVolumeManager.scanVolumesBackground(environment: env)
        XCTAssertTrue(snapshot.volumes.isEmpty, "Unresolved Finder alias, dead symlinks, and circular symlinks must not enter live CloudStorage volumes.")

        // 4. Direct coalescing fallback check: offline / dead-link candidates never merge across distinct paths
        let offlineA = MountedVolumeItem(
            name: "Offline",
            path: tempRoot.appendingPathComponent("Offline-A").path,
            url: tempRoot.appendingPathComponent("Offline-A"),
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            systemImage: "externaldrive.fill",
            isCloudStorage: false
        )
        let offlineB = MountedVolumeItem(
            name: "Offline",
            path: tempRoot.appendingPathComponent("Offline-B").path,
            url: tempRoot.appendingPathComponent("Offline-B"),
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            systemImage: "externaldrive.fill",
            isCloudStorage: false
        )
        XCTAssertFalse(MountedVolumeManager.hasConfirmedTargetPhysicalIdentity(offlineA.identity))
        XCTAssertFalse(MountedVolumeManager.hasConfirmedTargetPhysicalIdentity(FileIdentity(url: deadLinkURL)))
        XCTAssertFalse(MountedVolumeManager.hasConfirmedTargetPhysicalIdentity(FileIdentity(url: loopA)))

        let offlineSnapshot = MountedVolumeManager.coalesceCandidates([offlineA, offlineB])
        XCTAssertEqual(offlineSnapshot.volumes.count, 2, "Offline fallback candidates without confirmed physical identity must not merge.")
    }

    func testSidebarVolumeRowHelpTextAndCopyFullPathAction() throws {
        let tempRoot = try makeSandboxRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let externalDir = tempRoot.appendingPathComponent("MountedExternal", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)

        let env = MountedVolumeManager.VolumeScanEnvironment(
            rootURL: tempRoot,
            mountedVolumeURLs: [externalDir],
            homeDirectoryURL: tempRoot,
            includeRootVolume: true,
            userFacingVolumeFilter: { _ in true }
        )
        let snapshot = MountedVolumeManager.scanVolumesBackground(environment: env)
        XCTAssertEqual(snapshot.volumes.count, 2)

        let item = try XCTUnwrap(snapshot.volumes.first(where: { $0.path == externalDir.path }))

        // Use an isolated named pasteboard and release it on teardown so user clipboard (NSPasteboard.general) is never touched.
        let isolatedPasteboardName = NSPasteboard.Name("com.metastudyline.ttzip.tests.sidebar-volume.\(UUID().uuidString)")
        let isolatedPasteboard = NSPasteboard(name: isolatedPasteboardName)
        defer { isolatedPasteboard.releaseGlobally() }

        var openedInNewWindowURL: URL?
        var rowView = SidebarVolumeRowView(
            volume: item,
            isSelected: false,
            isIconRail: false,
            onSelect: { _ in },
            onOpenInNewWindow: { url in
                openedInNewWindowURL = url
            }
        )
        rowView.pasteboard = isolatedPasteboard

        // Verify computed help text (name + full path); note: offscreen NSHostingView does not materialize SwiftUI .help() into NSView.toolTip.
        XCTAssertEqual(rowView.rowHelpText, "\(item.name)\n\(item.path)")

        let hostingView = NSHostingView(rootView: rowView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 220, height: 32)
        hostingView.layoutSubtreeIfNeeded()

        // Verify context menu actions generated by the row view and invoke the Copy Full Path menu action through its descriptor.
        let actions = rowView.contextMenuActions
        XCTAssertTrue(actions.contains(where: { $0.kind == .openInNewWindow }))
        XCTAssertTrue(actions.contains(where: { $0.kind == .revealInFinder }))

        let copyAction = try XCTUnwrap(actions.first(where: { $0.kind == .copyFullPath }))
        XCTAssertFalse(copyAction.title.isEmpty)
        copyAction.perform()

        XCTAssertEqual(isolatedPasteboard.string(forType: .string), item.path)
        let copiedURLs = isolatedPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(copiedURLs?.first?.standardizedFileURL.path, externalDir.standardizedFileURL.path)

        let openWindowAction = try XCTUnwrap(actions.first(where: { $0.kind == .openInNewWindow }))
        openWindowAction.perform()
        XCTAssertEqual(openedInNewWindowURL, item.url)
    }

    private func makeSandboxRoot() throws -> URL {
        var rootStat = Darwin.stat()
        let baseTmp = URL(fileURLWithPath: NSTemporaryDirectory())
        _ = baseTmp.path.withCString { Darwin.lstat($0, &rootStat) }
        let rootURL = URL(fileURLWithPath: "/private/var/tmp")
            .appendingPathComponent("ttzip-mounted-vol-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}
