// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

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
}
