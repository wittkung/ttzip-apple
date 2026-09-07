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

/// Exhaustive state transition, boundary defense, and concurrency test suite for OmniSearchEngine.
final class OmniEngineStateMachineTests: XCTestCase {

    // MARK: - Test A: Initial State

    @MainActor
    func testInitialStateIsIdleWithRecommendations() {
        let engine = OmniSearchEngine()

        XCTAssertTrue(engine.state.isIdle, "Engine initial state must be idleWithRecommendations")
        XCTAssertFalse(engine.state.isLoading, "Engine should not be loading initially")
        XCTAssertFalse(engine.state.isPopulated, "Engine should not be populated with search results initially")
        XCTAssertFalse(engine.state.isNoMatches, "Engine should not be in noMatches initially")
        XCTAssertFalse(engine.state.isFailure, "Engine should not be in failure state initially")
        XCTAssertEqual(engine.state.query, "", "Initial query must be empty")

        if case .idleWithRecommendations(let categories) = engine.state {
            XCTAssertFalse(categories.isEmpty, "Initial state categories must not be empty")
            let totalItems = categories.reduce(0) { $0 + $1.items.count }
            XCTAssertGreaterThan(totalItems, 0, "Initial state must supply recommendations")
            XCTAssertEqual(engine.state.flatItemsCount, totalItems)
            XCTAssertEqual(engine.state.sections.count, categories.count)
        } else {
            XCTFail("Expected .idleWithRecommendations but got \(engine.state)")
        }

        XCTAssertFalse(engine.defaultRecommendations.isEmpty, "Cached default recommendations should be populated")
        XCTAssertFalse(engine.flatResults.isEmpty, "flatResults should not be empty initially")
        XCTAssertNotNil(engine.selectedItem, "selectedItem must default to first recommendation")
        XCTAssertEqual(engine.selectedIndex, 0, "selectedIndex must default to 0")
        XCTAssertEqual(engine.selectedItem?.id, engine.flatResults.first?.id)
    }

    // MARK: - Test B: Query Transitions to Searching and Populated

    @MainActor
    func testSearchQueryTransitionsToSearchingAndPopulated() async throws {
        let engine = OmniSearchEngine()
        let searchQuery = "new"

        engine.updateQuery(searchQuery)

        // Keystroke should enter typingDebounce immediately
        if case .typingDebounce(let q) = engine.state {
            XCTAssertEqual(q, searchQuery)
        } else {
            XCTFail("Expected .typingDebounce immediately after updateQuery, got \(engine.state)")
        }
        XCTAssertTrue(engine.state.isLoading, "Engine must indicate loading during debounce")

        // Wait for 80ms debouncing task plus margin
        try await Task.sleep(nanoseconds: 150_000_000)

        // After debounce, search should have executed and returned populated results
        XCTAssertTrue(engine.state.isPopulated, "State should be populated for matching query 'new'")
        XCTAssertEqual(engine.state.query, searchQuery)
        XCTAssertGreaterThan(engine.state.flatItemsCount, 0)
        XCTAssertFalse(engine.flatResults.isEmpty)
        XCTAssertNotNil(engine.selectedItem)
        XCTAssertEqual(engine.selectedIndex, 0)
    }

    // MARK: - Test C: Non-Existent Query Transitions to NoMatches

    @MainActor
    func testNonExistentQueryTransitionsToNoMatches() async throws {
        let engine = OmniSearchEngine()
        let nonExistentQuery = "xyz_nonexistent_command_token_9999999"

        engine.updateQuery(nonExistentQuery)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(engine.state.isNoMatches, "State must transition to noMatches for non-existent query")
        XCTAssertFalse(engine.state.isLoading)
        XCTAssertFalse(engine.state.isPopulated)
        XCTAssertEqual(engine.state.query, nonExistentQuery)

        if case .noMatches(let q) = engine.state {
            XCTAssertEqual(q, nonExistentQuery)
        } else {
            XCTFail("Expected .noMatches, got \(engine.state)")
        }

        XCTAssertTrue(engine.flatResults.isEmpty, "flatResults must be empty in noMatches state")
        XCTAssertTrue(engine.items.isEmpty, "items alias must be empty in noMatches state")
        XCTAssertNil(engine.selectedItem, "selectedItem must be nil in noMatches state")
        XCTAssertEqual(engine.selectedIndex, 0, "selectedIndex should reset to 0 in noMatches state")

        // Verify fallback recommendations remain intact for UI consumption
        XCTAssertFalse(engine.defaultRecommendations.isEmpty, "Cached default recommendations fallback must remain intact")
    }

    // MARK: - Test D: Empty or Whitespace Query Transitions Back to Idle

    @MainActor
    func testEmptyOrWhitespaceQueryTransitionsBackToIdle() async throws {
        let engine = OmniSearchEngine()

        // 1. First trigger a search to leave idle state
        engine.updateQuery("archive")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.state.isPopulated, "Should be populated after searching 'archive'")

        // 2. Reset with empty query
        engine.updateQuery("")
        XCTAssertTrue(engine.state.isIdle, "Empty query must immediately transition back to idleWithRecommendations")
        XCTAssertFalse(engine.flatResults.isEmpty, "Default recommendations should be restored")
        XCTAssertNotNil(engine.selectedItem, "Selection should be restored")

        // 3. Trigger search again
        engine.updateQuery("terminal")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.state.isPopulated, "Should be populated after searching 'terminal'")

        // 4. Reset with whitespace query
        engine.updateQuery("     ")
        XCTAssertTrue(engine.state.isIdle, "Whitespace query must immediately transition back to idleWithRecommendations")
        XCTAssertFalse(engine.flatResults.isEmpty, "Default recommendations should be restored")
        XCTAssertNotNil(engine.selectedItem, "Selection should be restored")
    }

    // MARK: - Test E: Malicious and Special Input Sanitization

    @MainActor
    func testMaliciousAndEdgeQueriesAreSanitizedSafely() async throws {
        let engine = OmniSearchEngine()

        // 1. Null byte injection
        engine.updateQuery("new\0archive\0test")
        if case .typingDebounce(let q) = engine.state {
            XCTAssertFalse(q.contains("\0"), "Null bytes must be stripped during sanitization")
            XCTAssertEqual(q, "newarchivetest")
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(engine.state.isFailure, "Null byte query must not cause crash or failure")

        // 2. Extremely large query (2000 characters buffer overflow defense)
        let largeQuery = String(repeating: "a", count: 2000)
        engine.updateQuery(largeQuery)
        if case .typingDebounce(let q) = engine.state {
            XCTAssertLessThanOrEqual(q.count, 1000, "Query length must be clamped to safe threshold")
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.state.isNoMatches, "Large random query should safely transition to noMatches")

        // 3. Path traversal attack input
        engine.updateQuery("../../../../../../../../../")
        try await Task.sleep(nanoseconds: 150_000_000)
        // Should resolve safely or yield noMatches/populated without throwing or crashing
        XCTAssertFalse(engine.state.isFailure, "Path traversal query must not throw unhandled error")

        // 4. Unknown command with prefix '>'
        engine.updateQuery(">unknown_system_cmd_98765")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.state.isNoMatches, "Unknown command must transition to noMatches")
        XCTAssertTrue(engine.flatResults.isEmpty)
        XCTAssertNil(engine.selectedItem)
        XCTAssertEqual(engine.selectedIndex, 0)
    }

    // MARK: - Test F: Selection Index Clamping

    @MainActor
    func testSelectionIndexClampingWhenResultsShrink() async throws {
        let engine = OmniSearchEngine()
        let initialCount = engine.flatResults.count
        guard initialCount >= 2 else {
            XCTFail("Initial state should have at least 2 items for clamping test")
            return
        }

        // 1. Select the last recommendation
        let lastIndex = initialCount - 1
        engine.selectIndex(lastIndex)
        XCTAssertEqual(engine.selectedIndex, lastIndex)
        XCTAssertEqual(engine.selectedItem?.id, engine.flatResults[lastIndex].id)

        // 2. Test clamping on excessive index
        engine.selectIndex(9999)
        XCTAssertEqual(engine.selectedIndex, lastIndex, "Overflown index must be clamped to count - 1")

        // 3. Test clamping on negative index
        engine.selectIndex(-50)
        XCTAssertEqual(engine.selectedIndex, 0, "Negative index must be clamped to 0")

        // 4. Select index 1 and narrow down to a single result
        engine.selectIndex(1)
        engine.updateQuery(">reveal")
        try await Task.sleep(nanoseconds: 150_000_000)

        // Verify only 1 command is returned and selection is clamped to 0
        XCTAssertEqual(engine.flatResults.count, 1, "Expected single result for '>reveal'")
        XCTAssertEqual(engine.selectedIndex, 0, "Index must clamp to 0 when count drops to 1")
        XCTAssertEqual(engine.selectedItem?.id, engine.flatResults[0].id)

        // 5. Narrow down to zero results
        engine.updateQuery(">nonexistent_cmd")
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(engine.flatResults.isEmpty)
        XCTAssertEqual(engine.selectedIndex, 0)
        XCTAssertNil(engine.selectedItem)
    }

    // MARK: - Test G: Failure Reporting

    @MainActor
    func testFailureReportingState() {
        let engine = OmniSearchEngine()
        let errorMsg = "Filesystem volume unmounted unexpectedly"

        engine.reportFailure(description: errorMsg)

        XCTAssertTrue(engine.state.isFailure)
        XCTAssertFalse(engine.state.isIdle)
        XCTAssertFalse(engine.state.isLoading)
        XCTAssertFalse(engine.state.isPopulated)
        XCTAssertFalse(engine.state.isNoMatches)
        XCTAssertEqual(engine.state.query, "")

        if case .failure(let desc) = engine.state {
            XCTAssertEqual(desc, errorMsg)
        } else {
            XCTFail("Expected .failure, got \(engine.state)")
        }
    }
}
