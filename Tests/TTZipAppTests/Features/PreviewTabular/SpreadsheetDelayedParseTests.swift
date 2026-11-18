// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import os
import SwiftUI
import TTMediaKit
import XCTest
@testable import TTZipApp
@testable import TTZipPreviewKit

enum SpreadsheetParseStage: Hashable, Sendable {
    case csvFirstScreen
    case csvFullBudget
    case workbookFirstScreen
    case workbookFull
    case selectedSheet(String)
}

enum SpreadsheetParseHarnessError: Error, LocalizedError, Equatable, Sendable {
    case waitTimedOut(kind: String, stage: SpreadsheetParseStage, expectedCount: Int, observedCount: Int)

    var errorDescription: String? {
        switch self {
        case let .waitTimedOut(kind, stage, expectedCount, observedCount):
            return "Timed out waiting for \(kind) \(expectedCount) of \(stage) (observed \(observedCount))"
        }
    }
}

actor ControlledSpreadsheetParsePipeline: TTZipSpreadsheetParsePipeline {
    private struct CountWaiter {
        let id: UInt64
        let targetCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let forwarder = DefaultTTZipSpreadsheetParsePipeline()
    private var gatedStages: Set<SpreadsheetParseStage>
    private var isClosed = false
    private var nextWaiterID: UInt64 = 1
    private var expiredWaiterIDs: Set<UInt64> = []
    private var arrivals: [SpreadsheetParseStage] = []
    private var departures: [SpreadsheetParseStage] = []
    private var arrivalWaiters: [SpreadsheetParseStage: [CountWaiter]] = [:]
    private var departureWaiters: [SpreadsheetParseStage: [CountWaiter]] = [:]
    private var releaseWaiters: [SpreadsheetParseStage: [CheckedContinuation<Void, Never>]] = [:]
    private var pendingPermits: [SpreadsheetParseStage: Int] = [:]

    init(gatedStages: Set<SpreadsheetParseStage>) {
        self.gatedStages = gatedStages
    }

    func setGatedStages(_ stages: Set<SpreadsheetParseStage>) {
        guard !isClosed else { return }
        gatedStages = stages
    }

    func recordedArrivals() -> [SpreadsheetParseStage] {
        arrivals
    }

    func arrivalCount(for stage: SpreadsheetParseStage) -> Int {
        arrivals.reduce(into: 0) { count, item in
            if item == stage { count += 1 }
        }
    }

    func departureCount(for stage: SpreadsheetParseStage) -> Int {
        departures.reduce(into: 0) { count, item in
            if item == stage { count += 1 }
        }
    }

    func heldGateCount() -> Int {
        releaseWaiters.values.reduce(0) { $0 + $1.count }
    }

    func waitForArrival(
        _ stage: SpreadsheetParseStage,
        count: Int = 1,
        timeout: Duration = .seconds(4),
        file: StaticString = #filePath,
        line: UInt = #line,
        fail: @Sendable (String, StaticString, UInt) -> Void = { message, file, line in
            XCTFail(message, file: file, line: line)
        }
    ) async throws {
        let satisfied = await waitForCount(stage: stage, targetCount: count, isArrival: true, timeout: timeout)
        guard !satisfied else { return }
        let observed = arrivalCount(for: stage)
        let err = SpreadsheetParseHarnessError.waitTimedOut(
            kind: "arrival", stage: stage, expectedCount: count, observedCount: observed
        )
        fail(err.localizedDescription, file, line)
        throw err
    }

    func waitForDeparture(
        _ stage: SpreadsheetParseStage,
        count: Int = 1,
        timeout: Duration = .seconds(4),
        file: StaticString = #filePath,
        line: UInt = #line,
        fail: @Sendable (String, StaticString, UInt) -> Void = { message, file, line in
            XCTFail(message, file: file, line: line)
        }
    ) async throws {
        let satisfied = await waitForCount(stage: stage, targetCount: count, isArrival: false, timeout: timeout)
        guard !satisfied else { return }
        let observed = departureCount(for: stage)
        let err = SpreadsheetParseHarnessError.waitTimedOut(
            kind: "departure", stage: stage, expectedCount: count, observedCount: observed
        )
        fail(err.localizedDescription, file, line)
        throw err
    }

    func release(_ stage: SpreadsheetParseStage) {
        if var waiters = releaseWaiters[stage], !waiters.isEmpty {
            let next = waiters.removeFirst()
            releaseWaiters[stage] = waiters
            next.resume()
        } else if !isClosed {
            pendingPermits[stage, default: 0] += 1
        }
    }

    func releaseAllAndUngate() {
        isClosed = true
        gatedStages.removeAll()
        pendingPermits.removeAll()
        let gated = releaseWaiters
        releaseWaiters.removeAll()
        for waiters in gated.values {
            for continuation in waiters {
                continuation.resume()
            }
        }
        let pendingArrivals = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiters in pendingArrivals.values {
            for waiter in waiters {
                waiter.continuation.resume(returning: false)
            }
        }
        let pendingDepartures = departureWaiters
        departureWaiters.removeAll()
        for waiters in pendingDepartures.values {
            for waiter in waiters {
                waiter.continuation.resume(returning: false)
            }
        }
    }

    private func waitForCount(
        stage: SpreadsheetParseStage,
        targetCount: Int,
        isArrival: Bool,
        timeout: Duration
    ) async -> Bool {
        let current = isArrival ? arrivalCount(for: stage) : departureCount(for: stage)
        if current >= targetCount { return true }
        if isClosed || Task.isCancelled { return false }

        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.expireCountWaiter(id: waiterID, stage: stage, isArrival: isArrival)
        }
        defer {
            timeoutTask.cancel()
            expiredWaiterIDs.remove(waiterID)
        }

        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    self.enqueueCountWaiter(
                        id: waiterID,
                        stage: stage,
                        targetCount: targetCount,
                        isArrival: isArrival,
                        deadline: deadline,
                        continuation: continuation
                    )
                }
            },
            onCancel: {
                Task {
                    await self.expireCountWaiter(id: waiterID, stage: stage, isArrival: isArrival)
                }
            },
            isolation: self
        )
    }

    private func enqueueCountWaiter(
        id waiterID: UInt64,
        stage: SpreadsheetParseStage,
        targetCount: Int,
        isArrival: Bool,
        deadline: ContinuousClock.Instant,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        let latest = isArrival ? arrivalCount(for: stage) : departureCount(for: stage)
        if latest >= targetCount {
            continuation.resume(returning: true)
            return
        }
        if isClosed || Task.isCancelled || ContinuousClock.now >= deadline
            || expiredWaiterIDs.remove(waiterID) != nil
        {
            continuation.resume(returning: false)
            return
        }
        let waiter = CountWaiter(id: waiterID, targetCount: targetCount, continuation: continuation)
        if isArrival {
            arrivalWaiters[stage, default: []].append(waiter)
        } else {
            departureWaiters[stage, default: []].append(waiter)
        }
    }

    private func expireCountWaiter(id: UInt64, stage: SpreadsheetParseStage, isArrival: Bool) {
        if isArrival {
            if let index = arrivalWaiters[stage]?.firstIndex(where: { $0.id == id }) {
                let waiter = arrivalWaiters[stage]!.remove(at: index)
                waiter.continuation.resume(returning: false)
                return
            }
        } else if let index = departureWaiters[stage]?.firstIndex(where: { $0.id == id }) {
            let waiter = departureWaiters[stage]!.remove(at: index)
            waiter.continuation.resume(returning: false)
            return
        }
        expiredWaiterIDs.insert(id)
    }

    private func notifyWaiters(
        in map: inout [SpreadsheetParseStage: [CountWaiter]],
        stage: SpreadsheetParseStage,
        currentCount: Int
    ) {
        guard let waiters = map[stage] else { return }
        var remaining: [CountWaiter] = []
        for entry in waiters {
            if currentCount >= entry.targetCount {
                entry.continuation.resume(returning: true)
            } else {
                remaining.append(entry)
            }
        }
        map[stage] = remaining
    }

    private func recordAndPauseIfGated(_ stage: SpreadsheetParseStage) async {
        arrivals.append(stage)
        notifyWaiters(in: &arrivalWaiters, stage: stage, currentCount: arrivalCount(for: stage))
        defer {
            departures.append(stage)
            notifyWaiters(in: &departureWaiters, stage: stage, currentCount: departureCount(for: stage))
        }
        guard !isClosed, gatedStages.contains(stage) else { return }
        if let permits = pendingPermits[stage], permits > 0 {
            pendingPermits[stage] = permits - 1
        } else {
            await withCheckedContinuation { continuation in
                if self.isClosed || !self.gatedStages.contains(stage) {
                    continuation.resume()
                    return
                }
                self.releaseWaiters[stage, default: []].append(continuation)
            }
        }
    }

    func computeFirstScreenSnapshot(
        content: String,
        overrideDelimiter: Character?,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxUTF8Bytes: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        let snapshot = await forwarder.computeFirstScreenSnapshot(
            content: content,
            overrideDelimiter: overrideDelimiter,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxUTF8Bytes: maxUTF8Bytes
        )
        await recordAndPauseIfGated(.csvFirstScreen)
        return snapshot
    }

    func computeFullBudgetedSnapshot(
        content: String,
        stage1: SpreadsheetComputedTableSnapshot,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int,
        maxUTF8Bytes: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        let snapshot = await forwarder.computeFullBudgetedSnapshot(
            content: content,
            stage1: stage1,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxRows: maxRows,
            maxUTF8Bytes: maxUTF8Bytes
        )
        await recordAndPauseIfGated(.csvFullBudget)
        return snapshot
    }

    func computeWorkbookFirstScreenSnapshot(
        sheet: TTMediaSheetData,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        let snapshot = await forwarder.computeWorkbookFirstScreenSnapshot(
            sheet: sheet,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxRows: maxRows
        )
        await recordAndPauseIfGated(.workbookFirstScreen)
        return snapshot
    }

    func computeWorkbookFullSnapshot(
        sheet: TTMediaSheetData,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> (snapshot: SpreadsheetComputedTableSnapshot, csv: String)? {
        let full = await forwarder.computeWorkbookFullSnapshot(
            sheet: sheet,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxRows: maxRows
        )
        await recordAndPauseIfGated(.workbookFull)
        return full
    }

    func loadAndComputeSelectedSheet(
        sheetName: String,
        workbook: OfficeSpreadsheetWorkbook,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> (result: SpreadsheetParseResult, state: SpreadsheetTableState, isTruncated: Bool)? {
        let loaded = await forwarder.loadAndComputeSelectedSheet(
            sheetName: sheetName,
            workbook: workbook,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery,
            maxRows: maxRows
        )
        await recordAndPauseIfGated(.selectedSheet(sheetName))
        return loaded
    }
}

extension SpreadsheetTablePreviewTests {
    func testDelayedCSVFirstScreenAndFullParsePreserveLatestSearchAndHeaderControls() async throws {
        var lines = ["City,Score", "Tokyo,10"]
        for index in 2...209 {
            lines.append("Item \(index),\(index)")
        }
        lines.append("Zurich,210")
        let csv = lines.joined(separator: "\n")
        let pipeline = ControlledSpreadsheetParsePipeline(gatedStages: [.csvFirstScreen, .csvFullBudget])
        let preview = MediaPreviewView(
            fileData: Data(csv.utf8),
            fileName: "cities.csv",
            showsFloatingFullScreenButton: false
        ).environment(\.ttZipSpreadsheetParsePipeline, pipeline)

        try await withControlledSpreadsheetPreview(preview, pipeline: pipeline, width: 860) { host in
            _ = try await spreadsheetControls(in: host)
            try await pipeline.waitForArrival(.csvFirstScreen)

            try await enterSearchQuery("Tokyo", in: host)
            let afterFirstEdits = try await spreadsheetControls(in: host)
            try XCTUnwrap(afterFirstEdits.toggleHeader)()
            _ = try await spreadsheetControls(in: host) {
                $0.searchQuery == "Tokyo" && $0.useFirstRowAsHeader
            }

            await pipeline.release(.csvFirstScreen)
            try await pipeline.waitForArrival(.csvFullBudget)

            let stage1Grid = try await spreadsheetGrid(in: host) { !$0.allRows.isEmpty }
            XCTAssertEqual(stage1Grid.headers, ["City", "Score"])
            XCTAssertEqual(stage1Grid.allRows, [["Tokyo", "10"]])
            XCTAssertEqual(stage1Grid.renderedRowNumbers, [2])

            try await enterSearchQuery("Zurich", in: host)
            let beforeSecondRelease = try await spreadsheetControls(in: host)
            try XCTUnwrap(beforeSecondRelease.toggleHeader)()
            _ = try await spreadsheetControls(in: host) {
                $0.searchQuery == "Zurich" && !$0.useFirstRowAsHeader
            }

            await pipeline.release(.csvFullBudget)
            let stage2Grid = try await spreadsheetGrid(in: host) { !$0.allRows.isEmpty }
            XCTAssertEqual(stage2Grid.headers, ["A", "B"])
            XCTAssertEqual(stage2Grid.allRows, [["Zurich", "210"]])
            XCTAssertEqual(stage2Grid.renderedRowNumbers, [211])
            let arrivals = await pipeline.recordedArrivals()
            XCTAssertEqual(arrivals, [.csvFirstScreen, .csvFullBudget])
        }
    }

    func testDelayedWorkbookParsePreservesControlsAndDiscardsLateSheetCompletions() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DelayedWorkbookPreview")
        defer { try? FileManager.default.removeItem(at: directory) }
        let workbookURL = try makeMultiRowTwoSheetWorkbook(in: directory)
        let pipeline = ControlledSpreadsheetParsePipeline(gatedStages: [.workbookFull, .selectedSheet("Totals")])
        let preview = MediaPreviewView(
            fileURL: workbookURL,
            fileName: workbookURL.lastPathComponent,
            showsFloatingFullScreenButton: false
        ).environment(\.ttZipSpreadsheetParsePipeline, pipeline)

        try await withControlledSpreadsheetPreview(preview, pipeline: pipeline, width: 860) { host in
            _ = try await spreadsheetGrid(in: host) { $0.allRows.first == ["City", "Country"] }
            try await pipeline.waitForArrival(.workbookFull)

            let initialControls = try await spreadsheetControls(in: host) { $0.selectedSheetName == "Cities" }
            try XCTUnwrap(initialControls.selectSheet)("Totals")
            try await pipeline.waitForArrival(.selectedSheet("Totals"))

            try await enterSearchQuery("Grand", in: host)
            let totalsControls = try await spreadsheetControls(in: host) { $0.selectedSheetName == "Totals" }
            try XCTUnwrap(totalsControls.toggleHeader)()
            _ = try await spreadsheetControls(in: host) {
                $0.searchQuery == "Grand" && $0.useFirstRowAsHeader
            }

            await pipeline.release(.workbookFull)
            await pipeline.release(.selectedSheet("Totals"))

            let totalsGrid = try await spreadsheetGrid(in: host) { !$0.allRows.isEmpty && $0.allRows.first != ["Tokyo", "Japan"] }
            XCTAssertEqual(totalsGrid.headers, ["Metric", "Total"])
            XCTAssertEqual(totalsGrid.allRows, [["Grand total", "42"]])
            XCTAssertEqual(totalsGrid.renderedRowNumbers, [2])
            let settledTotals = try await spreadsheetControls(in: host)
            XCTAssertFalse(settledTotals.canSaveInPlace)

            await pipeline.setGatedStages([.selectedSheet("Cities")])
            try await enterSearchQuery("", in: host)
            try XCTUnwrap(settledTotals.selectSheet)("Cities")
            try await pipeline.waitForArrival(.selectedSheet("Cities"))

            let midSwitchControls = try await spreadsheetControls(in: host) { $0.selectedSheetName == "Cities" }
            try XCTUnwrap(midSwitchControls.selectSheet)("Totals")
            let restoredTotalsGrid = try await spreadsheetGrid(in: host) {
                $0.allRows == [["Grand total", "42"], ["Draft count", "7"]]
            }
            XCTAssertEqual(restoredTotalsGrid.headers, ["Metric", "Total"])

            await pipeline.release(.selectedSheet("Cities"))
            try await pipeline.waitForDeparture(.selectedSheet("Cities"))
            await Task.yield()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            let finalControls = try await spreadsheetControls(in: host)
            let finalGrid = try XCTUnwrap(findSpreadsheetGrid(in: host))
            XCTAssertEqual(finalControls.selectedSheetName, "Totals")
            XCTAssertEqual(finalGrid.headers, ["Metric", "Total"])
            XCTAssertEqual(finalGrid.allRows, [["Grand total", "42"], ["Draft count", "7"]])
        }
    }

    func testPendingWorkbookSheetSelectionSurvivesTableModeAndDelimiterReparseRequests() async throws {
        let directory = try makeTemporaryDirectory(prefix: "PendingSheetContentReparse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let workbookURL = try makeMultiRowTwoSheetWorkbook(in: directory)
        let pipeline = ControlledSpreadsheetParsePipeline(gatedStages: [.workbookFull, .selectedSheet("Totals")])
        let preview = MediaPreviewView(
            fileURL: workbookURL,
            fileName: workbookURL.lastPathComponent,
            showsFloatingFullScreenButton: false
        ).environment(\.ttZipSpreadsheetParsePipeline, pipeline)

        try await withControlledSpreadsheetPreview(preview, pipeline: pipeline, width: 860) { host in
            _ = try await spreadsheetGrid(in: host) { $0.allRows.first == ["City", "Country"] }
            try await pipeline.waitForArrival(.workbookFull)
            let initialPending = try await spreadsheetControls(in: host) { $0.selectedSheetName == "Cities" }
            try XCTUnwrap(initialPending.selectMode)(.table)
            try XCTUnwrap(initialPending.selectDelimiter)(.semicolon)
            await pipeline.release(.workbookFull)
            try await pipeline.waitForDeparture(.workbookFull)
            _ = try await spreadsheetGrid(in: host) {
                $0.allRows == [["City", "Country"], ["Tokyo", "Japan"], ["Osaka", "Japan"]]
            }

            let citiesControls = try await spreadsheetControls(in: host) { $0.selectedSheetName == "Cities" }
            try XCTUnwrap(citiesControls.selectSheet)("Totals")
            try await pipeline.waitForArrival(.selectedSheet("Totals"))

            let pendingTotals = try await spreadsheetControls(in: host) { $0.selectedSheetName == "Totals" }
            try XCTUnwrap(pendingTotals.selectMode)(.table)
            try XCTUnwrap(pendingTotals.selectMode)(.source)
            try XCTUnwrap(pendingTotals.selectMode)(.table)
            try XCTUnwrap(pendingTotals.selectDelimiter)(.semicolon)
            try XCTUnwrap(pendingTotals.toggleHeader)()
            _ = try await spreadsheetControls(in: host) {
                $0.selectedSheetName == "Totals" && $0.useFirstRowAsHeader
            }

            await pipeline.release(.selectedSheet("Totals"))
            try await pipeline.waitForDeparture(.selectedSheet("Totals"))

            let settledGrid = try await spreadsheetGrid(in: host) {
                $0.allRows == [["Grand total", "42"], ["Draft count", "7"]]
            }
            let settledControls = try await spreadsheetControls(in: host)
            XCTAssertEqual(settledControls.selectedSheetName, "Totals")
            XCTAssertEqual(settledGrid.headers, ["Metric", "Total"])
            XCTAssertEqual(settledGrid.allRows, [["Grand total", "42"], ["Draft count", "7"]])
            try XCTUnwrap(settledControls.selectSheet)("Totals")
            let totalsArrivals = await pipeline.arrivalCount(for: .selectedSheet("Totals"))
            let csvArrivals = await pipeline.arrivalCount(for: .csvFirstScreen)
            XCTAssertEqual(totalsArrivals, 1)
            XCTAssertEqual(csvArrivals, 0)
        }
    }

    func testDelayedParsePreservesWritableDiskAndTruncatedReadOnlyPermissions() async throws {
        let directory = try makeTemporaryDirectory(prefix: "DelayedBudgetPermissions")
        defer { try? FileManager.default.removeItem(at: directory) }

        let writableURL = directory.appendingPathComponent("writable.csv")
        let writableRows = (["Title,Count"] + (1...205).map { "Row \($0),\($0)" }).joined(separator: "\n")
        try Data(writableRows.utf8).write(to: writableURL)
        let writablePipeline = ControlledSpreadsheetParsePipeline(gatedStages: [.csvFirstScreen, .csvFullBudget])
        let writablePreview = MediaPreviewView(
            fileURL: writableURL,
            fileName: writableURL.lastPathComponent,
            showsFloatingFullScreenButton: false,
            resourceContext: .diskFile(url: writableURL)
        ).environment(\.ttZipSpreadsheetParsePipeline, writablePipeline)

        try await withControlledSpreadsheetPreview(writablePreview, pipeline: writablePipeline, width: 860) { host in
            try await writablePipeline.waitForArrival(.csvFirstScreen)
            let beforeStage1 = try await spreadsheetControls(in: host)
            XCTAssertTrue(beforeStage1.canSaveInPlace)
            try await enterSearchQuery("Row 205", in: host)
            try XCTUnwrap(beforeStage1.toggleHeader)()
            await writablePipeline.release(.csvFirstScreen)
            try await writablePipeline.waitForArrival(.csvFullBudget)

            let midStages = try await spreadsheetControls(in: host)
            XCTAssertTrue(midStages.canSaveInPlace)
            await writablePipeline.release(.csvFullBudget)
            let finalGrid = try await spreadsheetGrid(in: host) { !$0.allRows.isEmpty }
            XCTAssertEqual(finalGrid.headers, ["Title", "Count"])
            XCTAssertEqual(finalGrid.allRows, [["Row 205", "205"]])
            let afterStage2 = try await spreadsheetControls(in: host)
            XCTAssertTrue(afterStage2.canSaveInPlace)
        }

        let cappedURL = directory.appendingPathComponent("capped.csv")
        let cappedRows = (["Metric"] + (1...50_005).map { "V\($0)" }).joined(separator: "\n")
        try Data(cappedRows.utf8).write(to: cappedURL)
        let cappedPipeline = ControlledSpreadsheetParsePipeline(gatedStages: [.csvFirstScreen, .csvFullBudget])
        let cappedPreview = MediaPreviewView(
            fileURL: cappedURL,
            fileName: cappedURL.lastPathComponent,
            showsFloatingFullScreenButton: false,
            resourceContext: .diskFile(url: cappedURL)
        ).environment(\.ttZipSpreadsheetParsePipeline, cappedPipeline)

        try await withControlledSpreadsheetPreview(cappedPreview, pipeline: cappedPipeline, width: 860) { host in
            try await cappedPipeline.waitForArrival(.csvFirstScreen)
            let beforeStage1 = try await spreadsheetControls(in: host)
            XCTAssertFalse(beforeStage1.canSaveInPlace)
            try await enterSearchQuery("V49999", in: host)
            try XCTUnwrap(beforeStage1.toggleHeader)()
            await cappedPipeline.release(.csvFirstScreen)
            try await cappedPipeline.waitForArrival(.csvFullBudget)

            let midStages = try await spreadsheetControls(in: host)
            XCTAssertFalse(midStages.canSaveInPlace)
            await cappedPipeline.release(.csvFullBudget)
            let cappedGrid = try await spreadsheetGrid(in: host) { !$0.allRows.isEmpty }
            XCTAssertEqual(cappedGrid.headers, ["Metric"])
            XCTAssertEqual(cappedGrid.allRows, [["V49999"]])
            XCTAssertEqual(cappedGrid.renderedRowNumbers, [50_000])
            try await enterSearchQuery("V50000", in: host)
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(findSpreadsheetGrid(in: host))
            let afterStage2 = try await spreadsheetControls(in: host)
            XCTAssertFalse(afterStage2.canSaveInPlace)
        }
    }

    func testControlledParsePipelineBoundsMissingStageWaitsAndDrainsGatesOnThrow() async throws {
        let timeoutPipeline = ControlledSpreadsheetParsePipeline(gatedStages: [])
        let failSink = OSAllocatedUnfairLock(initialState: [String]())

        await XCTAssertThrowsErrorAsync {
            try await timeoutPipeline.waitForArrival(.csvFirstScreen, timeout: .milliseconds(25)) { msg, _, _ in
                failSink.withLock { $0.append(msg) }
            }
        }
        await XCTAssertThrowsErrorAsync {
            try await timeoutPipeline.waitForDeparture(.workbookFull, timeout: .milliseconds(25)) { msg, _, _ in
                failSink.withLock { $0.append(msg) }
            }
        }
        XCTAssertEqual(failSink.withLock { $0.count }, 2)

        let drainPipeline = ControlledSpreadsheetParsePipeline(gatedStages: [.csvFirstScreen])
        let preview = MediaPreviewView(
            fileData: Data("A,B\n1,2".utf8),
            fileName: "drain.csv",
            showsFloatingFullScreenButton: false
        ).environment(\.ttZipSpreadsheetParsePipeline, drainPipeline)

        struct IntentionalEarlyFailure: Error {}
        await XCTAssertThrowsErrorAsync {
            try await withControlledSpreadsheetPreview(preview, pipeline: drainPipeline, width: 860) { _ in
                try await drainPipeline.waitForArrival(.csvFirstScreen)
                let heldBeforeThrow = await drainPipeline.heldGateCount()
                XCTAssertEqual(heldBeforeThrow, 1)
                throw IntentionalEarlyFailure()
            }
        }
        let heldAfterThrow = await drainPipeline.heldGateCount()
        XCTAssertEqual(heldAfterThrow, 0)
        try await drainPipeline.waitForDeparture(.csvFirstScreen)
    }

    private func withControlledSpreadsheetPreview<Content: View>(
        _ preview: Content,
        pipeline: ControlledSpreadsheetParsePipeline,
        width: CGFloat = 860,
        exercise: (NSHostingView<Content>) async throws -> Void
    ) async throws {
        do {
            try await withSpreadsheetPreview(preview, width: width) { host in
                do {
                    try await exercise(host)
                    await pipeline.releaseAllAndUngate()
                } catch {
                    await pipeline.releaseAllAndUngate()
                    throw error
                }
            }
        } catch {
            await pipeline.releaseAllAndUngate()
            throw error
        }
    }

    private func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected async expression to throw an error", file: file, line: line)
        } catch {}
    }

    private func enterSearchQuery(_ query: String, in host: NSView) async throws {
        let filter = try await waitForSpreadsheetFilter(in: host)
        let window = try XCTUnwrap(host.window)
        XCTAssertTrue(window.makeFirstResponder(filter))
        let editor = try XCTUnwrap(filter.currentEditor() as? NSTextView)
        let fullRange = NSRange(location: 0, length: (editor.string as NSString).length)
        if editor.shouldChangeText(in: fullRange, replacementString: query) {
            editor.replaceCharacters(in: fullRange, with: query)
            editor.didChangeText()
        }
        _ = try await spreadsheetControls(in: host) { $0.searchQuery == query }
    }

    private func waitForSpreadsheetFilter(in host: NSView) async throws -> NSTextField {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let filter = findSpreadsheetFilter(in: host) {
                return filter
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(nil, "Expected inline spreadsheet search field to mount")
    }

    private func makeMultiRowTwoSheetWorkbook(in directory: URL) throws -> URL {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet>
            <table:table table:name="Cities">
              <table:table-row><table:table-cell><text:p>City</text:p></table:table-cell><table:table-cell><text:p>Country</text:p></table:table-cell></table:table-row>
              <table:table-row><table:table-cell><text:p>Tokyo</text:p></table:table-cell><table:table-cell><text:p>Japan</text:p></table:table-cell></table:table-row>
              <table:table-row><table:table-cell><text:p>Osaka</text:p></table:table-cell><table:table-cell><text:p>Japan</text:p></table:table-cell></table:table-row>
            </table:table>
            <table:table table:name="Totals">
              <table:table-row><table:table-cell><text:p>Metric</text:p></table:table-cell><table:table-cell><text:p>Total</text:p></table:table-cell></table:table-row>
              <table:table-row><table:table-cell><text:p>Grand total</text:p></table:table-cell><table:table-cell><text:p>42</text:p></table:table-cell></table:table-row>
              <table:table-row><table:table-cell><text:p>Draft count</text:p></table:table-cell><table:table-cell><text:p>7</text:p></table:table-cell></table:table-row>
            </table:table>
          </office:spreadsheet></office:body>
        </office:document-content>
        """
        let archiveURL = directory.appendingPathComponent("multi-sheet.ods")
        let contentURL = directory.appendingPathComponent("content.xml")
        try Data(content.utf8).write(to: contentURL)
        defer { try? FileManager.default.removeItem(at: contentURL) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", archiveURL.lastPathComponent, "content.xml"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return archiveURL
    }
}
