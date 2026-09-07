// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
@testable import TTZipApp

final class OmniSearchEngineDefaultRecommendationsTests: XCTestCase {

    @MainActor
    func testEmptyQueryPopulatesDefaultRecommendations() {
        let engine = OmniSearchEngine()
        
        // Assert items/flatResults are populated with rich default recommendations
        XCTAssertFalse(engine.items.isEmpty, "Default recommendations should not be empty on initial empty query")
        XCTAssertFalse(engine.flatResults.isEmpty, "flatResults should not be empty on initial empty query")
        
        // Check presence of expected categories
        XCTAssertNotNil(engine.categorizedResults[.applications], "Applications category should be populated")
        XCTAssertNotNil(engine.categorizedResults[.commands], "Commands category should be populated")
        XCTAssertNotNil(engine.categorizedResults[.directories], "Directories category should be populated")
        
        // Assert selectedItem defaults to the first item
        XCTAssertNotNil(engine.selectedItem, "selectedItem should default to first recommendation")
        XCTAssertEqual(engine.selectedItem?.id, engine.flatResults.first?.id)
    }

    @MainActor
    func testSelectionSynchronization() {
        let engine = OmniSearchEngine()
        guard engine.flatResults.count >= 2 else {
            XCTFail("Engine should have at least 2 default items for selection test")
            return
        }
        
        let firstItem = engine.flatResults[0]
        let secondItem = engine.flatResults[1]
        
        XCTAssertEqual(engine.selectedItem?.id, firstItem.id)
        
        engine.selectIndex(1)
        XCTAssertEqual(engine.selectedItem?.id, secondItem.id)
        
        engine.selectIndex(0)
        XCTAssertEqual(engine.selectedItem?.id, firstItem.id)
    }

    @MainActor
    func testQuickCommandsContainCoreOperationalActions() {
        let engine = OmniSearchEngine()
        guard let commands = engine.categorizedResults[.commands] else {
            XCTFail("Commands category should exist")
            return
        }
        
        let commandIds = commands.map { $0.id }
        XCTAssertTrue(commandIds.contains("cmd:new_archive"), "Should contain new archive wizard command")
        XCTAssertTrue(commandIds.contains("cmd:reveal_finder"), "Should contain reveal in finder command")
        XCTAssertTrue(commandIds.contains("cmd:open_terminal"), "Should contain open in terminal command")
    }

    @MainActor
    func testCommonDirectoriesContainStandardLocations() {
        let engine = OmniSearchEngine()
        guard let dirs = engine.categorizedResults[.directories] else {
            XCTFail("Directories category should exist")
            return
        }
        
        let titles = dirs.map { $0.title }
        XCTAssertTrue(titles.contains("Downloads") || titles.contains("Home (~)"), "Should include user standard directories")
    }

    @MainActor
    func testCommandPrefixModeFiltersOnlyCommands() async throws {
        let engine = OmniSearchEngine()
        engine.updateQuery(">new")
        
        try await Task.sleep(nanoseconds: 150_000_000)
        
        XCTAssertEqual(engine.categorizedResults.keys.count, 1)
        XCTAssertNotNil(engine.categorizedResults[.commands])
        XCTAssertFalse(engine.flatResults.isEmpty)
        XCTAssertTrue(engine.flatResults.allSatisfy { $0.category == .commands })
    }
}
