// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Carbon.HIToolbox
import Foundation
import XCTest
@testable import TTZipApp

final class GlobalSearchActivationTests: XCTestCase {
    func testGlobalKeyComboParsing() {
        let combo = GlobalKeyCombo("cmd+shift+space")
        XCTAssertNotNil(combo)
        XCTAssertEqual(combo?.keyCode, UInt32(kVK_Space))
        XCTAssertTrue((combo?.carbonModifiers ?? 0) & UInt32(cmdKey) != 0)
        XCTAssertTrue((combo?.carbonModifiers ?? 0) & UInt32(shiftKey) != 0)
        XCTAssertEqual(combo?.display, "⇧⌘Space")

        let invalid = GlobalKeyCombo("not_a_valid_combo")
        XCTAssertNil(invalid)
    }

    func testDefaultGlobalSearchKeyCombo() {
        let def = GlobalKeyCombo.defaultGlobalSearch
        XCTAssertEqual(def.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(def.display, "⇧⌘Space")
    }

    @MainActor
    func testGlobalSearchPanelControllerLifecycle() {
        let controller = GlobalSearchPanelController.shared
        XCTAssertEqual(controller.query, "")
        XCTAssertTrue(controller.results.isEmpty)
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertFalse(controller.isSearching)

        // Setting query should trigger state update
        controller.query = "test"
        XCTAssertEqual(controller.query, "test")

        // Reset query
        controller.query = ""
        XCTAssertEqual(controller.query, "")
        XCTAssertTrue(controller.results.isEmpty)
    }

    func testGlobalSearchResultItemModel() {
        let item = GlobalSearchResultItem(
            id: "archive:/path/to/archive.zip",
            title: "archive.zip",
            subtitle: "/path/to/archive.zip",
            hitType: .archiveFile,
            archivePath: "/path/to/archive.zip",
            isDirectory: false,
            byteSize: 1024,
            score: 0.95,
            matchBadge: "Active Archive"
        )

        XCTAssertEqual(item.id, "archive:/path/to/archive.zip")
        XCTAssertEqual(item.title, "archive.zip")
        XCTAssertEqual(item.hitType, .archiveFile)
        XCTAssertEqual(item.byteSize, 1024)
        XCTAssertEqual(item.matchBadge, "Active Archive")
    }

    func testSpotlightArchiveSearchProviderExtensions() {
        let provider = SpotlightArchiveSearchProvider.shared
        XCTAssertNotNil(provider)
        XCTAssertTrue(SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains("zip"))
        XCTAssertTrue(SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains("7z"))
        XCTAssertTrue(SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains("tar"))
        XCTAssertTrue(SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains("gz"))
        XCTAssertFalse(SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains("txt"))
    }

    func testSpotlightArchiveSearchEmptyQuery() async {
        let provider = SpotlightArchiveSearchProvider.shared
        let emptyHits = await provider.search(query: "")
        XCTAssertTrue(emptyHits.isEmpty)
        let whitespaceHits = await provider.search(query: "   \t\n  ")
        XCTAssertTrue(whitespaceHits.isEmpty)
    }

    @MainActor
    func testGlobalSearchNavigationBounds() {
        let controller = GlobalSearchPanelController.shared
        // Mock results
        let itemA = GlobalSearchResultItem(id: "1", title: "Archive A", subtitle: "/a.zip", hitType: .archiveFile)
        let itemB = GlobalSearchResultItem(id: "2", title: "Archive B", subtitle: "/b.zip", hitType: .archiveFile)
        controller.results = [itemA, itemB]
        controller.selectedIndex = 0

        controller.selectPrevious()
        XCTAssertEqual(controller.selectedIndex, 0)

        controller.selectNext()
        XCTAssertEqual(controller.selectedIndex, 1)

        controller.selectNext()
        XCTAssertEqual(controller.selectedIndex, 1)

        controller.selectPrevious()
        XCTAssertEqual(controller.selectedIndex, 0)

        controller.results = []
        controller.selectedIndex = 0
    }

    func testGlobalSearchHitTypeCodable() throws {
        let types: [GlobalSearchHitType] = [.archiveFile, .archiveEntry, .recentArchive, .quickAction]
        for t in types {
            let data = try JSONEncoder().encode(t)
            let decoded = try JSONDecoder().decode(GlobalSearchHitType.self, from: data)
            XCTAssertEqual(t, decoded)
        }
    }
}
