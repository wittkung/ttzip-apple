// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTKitUI
import TTZipCore
@testable import TTZipApp

private final class OffsetTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _offsets: [UInt32] = []
    
    var offsets: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return _offsets
    }
    
    func record(_ offset: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        _offsets.append(offset)
    }
}

@MainActor
final class CollisionPromptPresenterTests: XCTestCase {

    private nonisolated static func makeDummyRecord(id: UInt32, path: String) -> CollisionRecord {
        let meta = ItemMeta(kind: .file, size: 1024, mtimeUnixNs: 1_700_000_000_000_000_000)
        return CollisionRecord(
            id: id,
            relativePath: path,
            existingName: (path as NSString).lastPathComponent,
            kind: .sameType,
            existing: meta,
            incoming: meta
        )
    }

    func testEmptyConflictsReturnsKeepBothDirectly() async {
        var displayedCount = 0
        let presenter = CollisionPromptPresenter(destinationRoot: "/tmp/dest") { prompt in
            if prompt != nil {
                displayedCount += 1
            }
        }

        let summary = ConflictSummary(total: 0, sameType: 0, typeMismatch: 0, phase: .preflight)
        let resolution = await presenter.decide(summary: summary) { _, _ in
            XCTFail("Fetch should not be called when summary.total is 0")
            return ConflictPage(records: [], totalConflicts: 0, hasMore: false)
        }

        XCTAssertNotNil(resolution)
        XCTAssertEqual(resolution?.defaultAction, .keepBoth)
        XCTAssertEqual(resolution?.overrides.count, 0)
        XCTAssertEqual(displayedCount, 0)
    }

    func testSingleConflictReplaceResolution() async {
        var displayedPrompt: CollisionPrompt? = nil
        let presenter = CollisionPromptPresenter(destinationRoot: "/tmp/dest") { prompt in
            displayedPrompt = prompt
        }

        let summary = ConflictSummary(total: 1, sameType: 1, typeMismatch: 0, phase: .preflight)
        let record = Self.makeDummyRecord(id: 42, path: "dir/sample.txt")

        let resolutionTask = Task {
            await presenter.decide(summary: summary) { offset, limit in
                ConflictPage(records: [record], totalConflicts: 1, hasMore: false)
            }
        }

        // Allow runloop to cycle to trigger promptUser
        for _ in 0..<20 {
            if displayedPrompt != nil { break }
            await Task.yield()
        }

        guard let prompt = displayedPrompt else {
            XCTFail("Prompt was not presented")
            return
        }

        XCTAssertEqual(prompt.sourceFile.fileName, "sample.txt")
        XCTAssertEqual(prompt.conflictIndex, 1)
        XCTAssertEqual(prompt.totalConflicts, 1)

        // Resolve single item as replace
        prompt.resolver(.replace, false)

        let resolution = await resolutionTask.value
        XCTAssertNotNil(resolution)
        XCTAssertNil(resolution?.defaultAction)
        XCTAssertEqual(resolution?.overrides.count, 1)
        XCTAssertEqual(resolution?.overrides.first?.conflictId, 42)
        XCTAssertEqual(resolution?.overrides.first?.action, .replace)
        XCTAssertNil(displayedPrompt, "Prompt must be cleared via defer")
    }

    func testSingleConflictKeepBothResolution() async {
        var displayedPrompt: CollisionPrompt? = nil
        let presenter = CollisionPromptPresenter(destinationRoot: "/tmp/dest") { prompt in
            displayedPrompt = prompt
        }

        let summary = ConflictSummary(total: 1, sameType: 1, typeMismatch: 0, phase: .preflight)
        let record = Self.makeDummyRecord(id: 101, path: "document.pdf")

        let resolutionTask = Task {
            await presenter.decide(summary: summary) { _, _ in
                ConflictPage(records: [record], totalConflicts: 1, hasMore: false)
            }
        }

        for _ in 0..<20 {
            if displayedPrompt != nil { break }
            await Task.yield()
        }

        guard let prompt = displayedPrompt else {
            XCTFail("Prompt was not presented")
            return
        }

        prompt.resolver(.keepBoth, false)

        let resolution = await resolutionTask.value
        XCTAssertNotNil(resolution)
        XCTAssertNil(resolution?.defaultAction)
        XCTAssertEqual(resolution?.overrides.count, 1)
        XCTAssertEqual(resolution?.overrides.first?.conflictId, 101)
        XCTAssertEqual(resolution?.overrides.first?.action, .keepBoth)
    }

    func testSingleConflictSkipResolution() async {
        var displayedPrompt: CollisionPrompt? = nil
        let presenter = CollisionPromptPresenter(destinationRoot: "/tmp/dest") { prompt in
            displayedPrompt = prompt
        }

        let summary = ConflictSummary(total: 1, sameType: 1, typeMismatch: 0, phase: .preflight)
        let record = Self.makeDummyRecord(id: 102, path: "skip_me.png")

        let resolutionTask = Task {
            await presenter.decide(summary: summary) { _, _ in
                ConflictPage(records: [record], totalConflicts: 1, hasMore: false)
            }
        }

        for _ in 0..<20 {
            if displayedPrompt != nil { break }
            await Task.yield()
        }

        guard let prompt = displayedPrompt else {
            XCTFail("Prompt was not presented")
            return
        }

        prompt.resolver(.skip, false)

        let resolution = await resolutionTask.value
        XCTAssertNotNil(resolution)
        XCTAssertNil(resolution?.defaultAction)
        XCTAssertEqual(resolution?.overrides.count, 1)
        XCTAssertEqual(resolution?.overrides.first?.conflictId, 102)
        XCTAssertEqual(resolution?.overrides.first?.action, .skip)
    }

    func testApplyToAllRemainingShortCircuits() async {
        var displayedPrompts: [CollisionPrompt] = []
        let presenter = CollisionPromptPresenter(destinationRoot: "/tmp/dest") { prompt in
            if let p = prompt {
                displayedPrompts.append(p)
            }
        }

        let summary = ConflictSummary(total: 3, sameType: 3, typeMismatch: 0, phase: .preflight)
        let records = [
            Self.makeDummyRecord(id: 1, path: "file1.txt"),
            Self.makeDummyRecord(id: 2, path: "file2.txt"),
            Self.makeDummyRecord(id: 3, path: "file3.txt")
        ]

        let resolutionTask = Task {
            await presenter.decide(summary: summary) { _, _ in
                ConflictPage(records: records, totalConflicts: 3, hasMore: false)
            }
        }

        for _ in 0..<20 {
            if !displayedPrompts.isEmpty { break }
            await Task.yield()
        }

        guard let firstPrompt = displayedPrompts.first else {
            XCTFail("No prompt was displayed")
            return
        }

        // Apply to all with replace
        firstPrompt.resolver(.replace, true)

        let resolution = await resolutionTask.value
        XCTAssertNotNil(resolution)
        XCTAssertEqual(resolution?.defaultAction, .replace)
        XCTAssertEqual(resolution?.overrides.count, 0)
        XCTAssertEqual(displayedPrompts.count, 1, "Subsequent prompts must not be shown when applyAll is true")
    }

    func testStopActionReturnsNil() async {
        var displayedPrompt: CollisionPrompt? = nil
        let presenter = CollisionPromptPresenter(destinationRoot: "/tmp/dest") { prompt in
            displayedPrompt = prompt
        }

        let summary = ConflictSummary(total: 2, sameType: 2, typeMismatch: 0, phase: .preflight)
        let records = [
            Self.makeDummyRecord(id: 1, path: "cancel1.txt"),
            Self.makeDummyRecord(id: 2, path: "cancel2.txt")
        ]

        let resolutionTask = Task {
            await presenter.decide(summary: summary) { _, _ in
                ConflictPage(records: records, totalConflicts: 2, hasMore: false)
            }
        }

        for _ in 0..<20 {
            if displayedPrompt != nil { break }
            await Task.yield()
        }

        guard let prompt = displayedPrompt else {
            XCTFail("Prompt was not presented")
            return
        }

        prompt.resolver(.stop, false)

        let resolution = await resolutionTask.value
        XCTAssertNil(resolution, "Stop action must return nil to trigger session abort")
    }

    func testPagingBeyondPageSize() async {
        let tracker = OffsetTracker()
        var promptCount = 0

        let presenter = CollisionPromptPresenter(destinationRoot: "/tmp/dest") { prompt in
            if let p = prompt {
                promptCount += 1
                // On prompt 1, apply to all to finish quickly after verifying paging logic
                p.resolver(.keepBoth, true)
            }
        }

        let summary = ConflictSummary(total: 1025, sameType: 1025, typeMismatch: 0, phase: .preflight)
        let resolution = await presenter.decide(summary: summary) { offset, limit in
            tracker.record(offset)
            let records = [Self.makeDummyRecord(id: offset, path: "entry_\(offset).txt")]
            return ConflictPage(records: records, totalConflicts: 1025, hasMore: offset < 1024)
        }

        XCTAssertNotNil(resolution)
        XCTAssertEqual(tracker.offsets, [0])
        XCTAssertEqual(promptCount, 1)
    }
}
