// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipApp

// MARK: - Deterministic doubles
//
// Every double below is a stateless or lock-protected class: the mutable state a
// query would normally own lives in the production actor, so these doubles only
// record calls and replay events on demand. They never touch a real Spotlight
// index and never scan a user directory.

/// Thread-safe wrapper so expectations can be fulfilled from `@Sendable` hooks.
final class TestExpectation: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

/// Async gate that holds a query launch in flight until the test releases it.
final class SpotlightQueryTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Everything the fake launcher applies to the queries it creates.
struct SpotlightQueryTestConfiguration: Sendable {
    var startSucceeds = true
    var records: [SpotlightQueryRecord] = []
    var onLaunch: (@Sendable (String) -> Void)?
    var onStart: (@Sendable (String) -> Void)?
    var onStop: (@Sendable (String) -> Void)?
    var onObserverRemoval: (@Sendable (String) -> Void)?
}

/// Call counters for one fake query.
struct SpotlightQueryCounters: Equatable {
    var startCalls = 0
    var stopCalls = 0
    var observerRemovalCalls = 0
    var snapshotLimits: [Int] = []
}

/// Records everything that happens to one fake query and replays its completion.
final class SpotlightQueryProbe: @unchecked Sendable {
    let pattern: String

    private let lock = NSLock()
    private let startSucceeds: Bool
    private let records: [SpotlightQueryRecord]
    private let onStart: (@Sendable (String) -> Void)?
    private let onStop: (@Sendable (String) -> Void)?
    private let onObserverRemoval: (@Sendable (String) -> Void)?
    private var finishHandler: (@Sendable () -> Void)?
    private var startCalls = 0
    private var stopCalls = 0
    private var observerRemovalCalls = 0
    private var snapshotLimits: [Int] = []

    init(pattern: String, configuration: SpotlightQueryTestConfiguration) {
        self.pattern = pattern
        self.startSucceeds = configuration.startSucceeds
        self.records = configuration.records
        self.onStart = configuration.onStart
        self.onStop = configuration.onStop
        self.onObserverRemoval = configuration.onObserverRemoval
    }

    func install(finishHandler: @Sendable @escaping () -> Void) {
        lock.lock()
        self.finishHandler = finishHandler
        lock.unlock()
    }

    /// Delivers a gathering-completed notification. Safe to call repeatedly.
    func fireFinish() {
        lock.lock()
        let handler = finishHandler
        lock.unlock()
        handler?()
    }

    func recordStart() -> Bool {
        lock.lock()
        startCalls += 1
        let succeeds = startSucceeds
        let hook = onStart
        lock.unlock()
        hook?(pattern)
        return succeeds
    }

    func recordStop() {
        lock.lock()
        stopCalls += 1
        let hook = onStop
        lock.unlock()
        hook?(pattern)
    }

    func recordObserverRemoval() {
        lock.lock()
        observerRemovalCalls += 1
        let hook = onObserverRemoval
        lock.unlock()
        hook?(pattern)
    }

    func recordSnapshot(limit: Int) -> [SpotlightQueryRecord] {
        lock.lock()
        snapshotLimits.append(limit)
        let available = records
        lock.unlock()
        return Array(available.prefix(max(0, limit)))
    }

    var counters: SpotlightQueryCounters {
        lock.lock()
        defer { lock.unlock() }
        return SpotlightQueryCounters(
            startCalls: startCalls,
            stopCalls: stopCalls,
            observerRemovalCalls: observerRemovalCalls,
            snapshotLimits: snapshotLimits
        )
    }
}

/// Fake handle forwarding to its probe. Holds no mutable state of its own.
final class SpotlightQueryTestHandle: SpotlightQueryHandle, @unchecked Sendable {
    private let probe: SpotlightQueryProbe

    init(probe: SpotlightQueryProbe) {
        self.probe = probe
    }

    func start() async -> Bool {
        probe.recordStart()
    }

    func snapshot(limit: Int) async -> [SpotlightQueryRecord] {
        probe.recordSnapshot(limit: limit)
    }

    func stop() async {
        probe.recordStop()
    }

    func removeObserver() async {
        probe.recordObserverRemoval()
    }
}

/// Fake launcher: builds a fresh probe per query and never touches the disk.
final class SpotlightQueryTestLauncher: SpotlightQueryLaunching, @unchecked Sendable {
    var configuration = SpotlightQueryTestConfiguration()
    var gate: SpotlightQueryTestGate?

    private let lock = NSLock()
    private var probes: [SpotlightQueryProbe] = []
    private var scopes: [[URL]] = []

    func launch(
        scope: [URL],
        namePattern: String,
        onFinish: @Sendable @escaping () -> Void
    ) async -> any SpotlightQueryHandle {
        let (configuration, gate) = currentConfiguration()
        let probe = SpotlightQueryProbe(pattern: namePattern, configuration: configuration)
        register(probe, scope: scope)

        probe.install(finishHandler: onFinish)
        configuration.onLaunch?(namePattern)

        if let gate {
            await gate.wait()
        }
        return SpotlightQueryTestHandle(probe: probe)
    }

    var launchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes.count
    }

    var recordedScopes: [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return scopes
    }

    func probe(forPattern pattern: String) -> SpotlightQueryProbe? {
        lock.lock()
        defer { lock.unlock() }
        return probes.first { $0.pattern == pattern }
    }

    // Synchronous helpers: `NSLock` may not be taken directly in an async context.
    private func currentConfiguration() -> (SpotlightQueryTestConfiguration, SpotlightQueryTestGate?) {
        lock.lock()
        defer { lock.unlock() }
        return (configuration, gate)
    }

    private func register(_ probe: SpotlightQueryProbe, scope: [URL]) {
        lock.lock()
        probes.append(probe)
        scopes.append(scope)
        lock.unlock()
    }
}

/// Manual timeout scheduler: the test decides when, and whether, a query times out.
final class ManualSpotlightTimeoutScheduler: SpotlightTimeoutScheduling, @unchecked Sendable {
    var onSchedule: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var pending: [UUID: @Sendable () -> Void] = [:]
    private var scheduledCount = 0
    private var cancelledCount = 0

    func schedule(
        after duration: Duration,
        action: @Sendable @escaping () -> Void
    ) -> any SpotlightTimeoutToken {
        let identifier = UUID()
        lock.lock()
        pending[identifier] = action
        scheduledCount += 1
        let hook = onSchedule
        lock.unlock()
        hook?()
        return ManualSpotlightTimeoutToken(identifier: identifier, scheduler: self)
    }

    /// Fires every armed timeout that was not cancelled.
    func fireAll() {
        lock.lock()
        let actions = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for action in actions {
            action()
        }
    }

    func cancel(identifier: UUID) {
        lock.lock()
        let existed = pending.removeValue(forKey: identifier) != nil
        if existed { cancelledCount += 1 }
        lock.unlock()
    }

    var counters: (scheduled: Int, cancelled: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (scheduledCount, cancelledCount)
    }
}

/// Cancellation handle for `ManualSpotlightTimeoutScheduler`.
final class ManualSpotlightTimeoutToken: SpotlightTimeoutToken {
    private let identifier: UUID
    private let scheduler: ManualSpotlightTimeoutScheduler

    init(identifier: UUID, scheduler: ManualSpotlightTimeoutScheduler) {
        self.identifier = identifier
        self.scheduler = scheduler
    }

    func cancel() {
        scheduler.cancel(identifier: identifier)
    }
}

/// Sendable slot capturing what one search call returned.
final class SearchOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GlobalSearchResultItem]?
    private let expectation: TestExpectation

    init(expectation: TestExpectation) {
        self.expectation = expectation
    }

    func store(_ items: [GlobalSearchResultItem]) {
        lock.lock()
        stored = items
        lock.unlock()
        expectation.fulfill()
    }

    var items: [GlobalSearchResultItem]? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// MARK: - Tests

final class SpotlightArchiveSearchProviderLifecycleTests: XCTestCase {
    /// Scope handed to the provider. Never read from disk: the launcher is a double.
    private let testScope = [URL(fileURLWithPath: "/spotlight-test-scope/downloads", isDirectory: true)]

    // MARK: Harness

    private struct SearchHandle {
        let task: Task<Void, Never>
        let outcome: SearchOutcome
        let done: XCTestExpectation
    }

    private func makeProvider(
        launcher: SpotlightQueryTestLauncher,
        scheduler: ManualSpotlightTimeoutScheduler,
        scope: [URL]? = nil,
        timeout: Duration = .seconds(3)
    ) -> SpotlightArchiveSearchProvider {
        let resolvedScope = scope ?? testScope
        return SpotlightArchiveSearchProvider(
            launcher: launcher,
            timeoutScheduler: scheduler,
            timeout: timeout,
            scopeResolver: { resolvedScope }
        )
    }

    private func makeSession(
        launcher: SpotlightQueryTestLauncher,
        scheduler: ManualSpotlightTimeoutScheduler,
        namePattern: String = "zip",
        maxResults: Int = 20
    ) -> SpotlightQuerySession {
        SpotlightQuerySession(
            launcher: launcher,
            scheduler: scheduler,
            timeout: .seconds(3),
            scope: testScope,
            namePattern: namePattern,
            maxResults: maxResults,
            scanLimit: SpotlightArchiveSearchProvider.scanLimit(for: maxResults)
        )
    }

    private func startSearch(
        _ provider: SpotlightArchiveSearchProvider,
        query: String,
        maxResults: Int = 20
    ) -> SearchHandle {
        let done = expectation(description: "search \(query) returned")
        let outcome = SearchOutcome(expectation: TestExpectation(done))
        let task = Task { await outcome.store(provider.search(query: query, maxResults: maxResults)) }
        return SearchHandle(task: task, outcome: outcome, done: done)
    }

    private func startSession(
        _ session: SpotlightQuerySession
    ) -> SearchHandle {
        let done = expectation(description: "session run returned")
        let outcome = SearchOutcome(expectation: TestExpectation(done))
        let task = Task { await outcome.store(session.run()) }
        return SearchHandle(task: task, outcome: outcome, done: done)
    }

    private func awaitResult(
        _ handle: SearchHandle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [GlobalSearchResultItem] {
        await fulfillment(of: [handle.done], timeout: 2.0)
        guard let items = handle.outcome.items else {
            XCTFail("search never returned: a query lifecycle path failed to resume", file: file, line: line)
            return []
        }
        return items
    }

    private func startSignal(
        _ launcher: SpotlightQueryTestLauncher,
        pattern: String = "zip"
    ) -> XCTestExpectation {
        let started = expectation(description: "query started")
        let signal = TestExpectation(started)
        launcher.configuration.onStart = { observed in
            if observed == pattern { signal.fulfill() }
        }
        return started
    }

    // MARK: Guard clauses

    func testEmptyQueryDoesNotLaunchQuery() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        let provider = makeProvider(launcher: launcher, scheduler: scheduler)

        let empty = await provider.search(query: "")
        let whitespace = await provider.search(query: " \t\n ")

        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(whitespace.isEmpty)
        XCTAssertEqual(launcher.launchCount, 0, "an empty query must not start a metadata query")
        XCTAssertEqual(scheduler.counters.scheduled, 0, "an empty query must not arm a timeout")
    }

    func testNonPositiveMaxResultsDoesNotLaunchQuery() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        let provider = makeProvider(launcher: launcher, scheduler: scheduler)

        let zero = await provider.search(query: "zip", maxResults: 0)
        let negative = await provider.search(query: "zip", maxResults: -7)

        XCTAssertTrue(zero.isEmpty)
        XCTAssertTrue(negative.isEmpty)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(scheduler.counters.scheduled, 0)
    }

    func testEmptyScopeReturnsEmptyWithoutWideningToWholeDiskSearch() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        let provider = makeProvider(launcher: launcher, scheduler: scheduler, scope: [])

        let items = await provider.search(query: "zip")

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(launcher.launchCount, 0, "an empty scope must never be handed to NSMetadataQuery")
        XCTAssertTrue(launcher.recordedScopes.isEmpty)
        XCTAssertEqual(scheduler.counters.scheduled, 0)
    }

    // MARK: Completion

    func testCompletionStopsQueryRemovesObserverAndMapsArchiveResults() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        launcher.configuration.records = [
            SpotlightQueryRecord(path: "/scope/Photos.zip", byteSize: 1_024),
            SpotlightQueryRecord(path: "/scope/notes.txt", byteSize: 12),
            SpotlightQueryRecord(path: "/scope/backup.7z", byteSize: 2_048)
        ]
        let started = startSignal(launcher)
        let provider = makeProvider(launcher: launcher, scheduler: scheduler)

        let handle = startSearch(provider, query: "zip")
        await fulfillment(of: [started], timeout: 2.0)

        guard let probe = launcher.probe(forPattern: "zip") else {
            return XCTFail("the query must be launched through the injected launcher")
        }
        probe.fireFinish()

        let items = await awaitResult(handle)

        XCTAssertEqual(items.map(\.id), ["spotlight:/scope/Photos.zip", "spotlight:/scope/backup.7z"])
        XCTAssertEqual(items.first?.title, "Photos.zip")
        XCTAssertEqual(items.first?.subtitle, "/scope/Photos.zip")
        XCTAssertEqual(items.first?.hitType, .archiveFile)
        XCTAssertEqual(items.first?.archivePath, "/scope/Photos.zip")
        XCTAssertEqual(items.first?.isDirectory, false)
        XCTAssertEqual(items.first?.byteSize, 1_024)
        XCTAssertEqual(items.first?.score, 0.50)
        XCTAssertNil(items.first?.matchBadge)

        let counters = probe.counters
        XCTAssertEqual(counters.snapshotLimits, [60], "maxResults 20 scans at most 60 raw hits")
        XCTAssertEqual(counters.stopCalls, 1, "the query must be stopped exactly once")
        XCTAssertEqual(counters.observerRemovalCalls, 1, "the observer must be removed exactly once")
        XCTAssertEqual(scheduler.counters.cancelled, 1, "the pending timeout must be cancelled")
    }

    func testResultCountIsCappedAndOverScanIsBounded() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        launcher.configuration.records = (0..<10).map {
            SpotlightQueryRecord(path: "/scope/archive-\($0).zip", byteSize: Int64($0))
        }
        let started = startSignal(launcher, pattern: "archive")
        let provider = makeProvider(launcher: launcher, scheduler: scheduler)

        let handle = startSearch(provider, query: "archive", maxResults: 3)
        await fulfillment(of: [started], timeout: 2.0)
        launcher.probe(forPattern: "archive")?.fireFinish()

        let items = await awaitResult(handle)

        XCTAssertEqual(items.count, 3, "results must never exceed maxResults")
        XCTAssertEqual(launcher.probe(forPattern: "archive")?.counters.snapshotLimits, [9])
    }

    func testExtremeMaxResultsSaturatesInsteadOfOverflowing() async {
        XCTAssertEqual(SpotlightArchiveSearchProvider.scanLimit(for: 20), 60)
        XCTAssertEqual(SpotlightArchiveSearchProvider.scanLimit(for: Int.max), Int.max)
        XCTAssertEqual(
            SpotlightArchiveSearchProvider.scanLimit(for: Int.max / 2),
            Int.max,
            "maxResults * 3 must saturate instead of trapping on overflow"
        )

        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        launcher.configuration.records = [
            SpotlightQueryRecord(path: "/scope/one.tar", byteSize: 1),
            SpotlightQueryRecord(path: "/scope/two.dmg", byteSize: 2)
        ]
        let started = startSignal(launcher, pattern: "one")
        let provider = makeProvider(launcher: launcher, scheduler: scheduler)

        let handle = startSearch(provider, query: "one", maxResults: Int.max)
        await fulfillment(of: [started], timeout: 2.0)
        launcher.probe(forPattern: "one")?.fireFinish()

        let items = await awaitResult(handle)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(launcher.probe(forPattern: "one")?.counters.snapshotLimits, [Int.max])
    }

    // MARK: Start failure

    func testStartFailureEndsTheWaitAndTearsDownTheQuery() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        launcher.configuration.startSucceeds = false
        let provider = makeProvider(launcher: launcher, scheduler: scheduler)

        let handle = startSearch(provider, query: "zip")
        let items = await awaitResult(handle)

        XCTAssertTrue(items.isEmpty, "a refused start must end the wait instead of hanging")
        guard let probe = launcher.probe(forPattern: "zip") else {
            return XCTFail("the query must be launched through the injected launcher")
        }
        XCTAssertEqual(probe.counters.startCalls, 1)
        XCTAssertEqual(probe.counters.stopCalls, 1)
        XCTAssertEqual(probe.counters.observerRemovalCalls, 1)
        XCTAssertTrue(probe.counters.snapshotLimits.isEmpty, "a failed start must not harvest results")
        XCTAssertEqual(scheduler.counters.cancelled, 1)
    }

    // MARK: Cancellation

    func testCancellationAfterStartStopsQueryAndReturnsEmpty() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        launcher.configuration.records = [SpotlightQueryRecord(path: "/scope/Photos.zip", byteSize: 1)]
        let started = startSignal(launcher)
        let provider = makeProvider(launcher: launcher, scheduler: scheduler)

        let handle = startSearch(provider, query: "zip")
        await fulfillment(of: [started], timeout: 2.0)

        handle.task.cancel()
        let items = await awaitResult(handle)

        XCTAssertTrue(items.isEmpty)
        guard let probe = launcher.probe(forPattern: "zip") else {
            return XCTFail("the query must be launched through the injected launcher")
        }
        XCTAssertEqual(probe.counters.startCalls, 1)
        XCTAssertEqual(probe.counters.stopCalls, 1, "cancellation must stop the running query")
        XCTAssertEqual(probe.counters.observerRemovalCalls, 1, "cancellation must detach the observer")
        XCTAssertEqual(scheduler.counters.cancelled, 1, "cancellation must cancel the pending timeout")
    }

    func testCancellationBeforeRunNeverLaunchesQuery() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        let session = makeSession(launcher: launcher, scheduler: scheduler)

        await session.cancel()
        let items = await session.run()

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(launcher.launchCount, 0, "a pre-cancelled session must not build a query")
        XCTAssertEqual(scheduler.counters.scheduled, 0)
        let snapshot = await session.lifecycleSnapshot()
        XCTAssertEqual(snapshot.termination, .cancelled)
        XCTAssertEqual(snapshot.resumeCount, 0, "no continuation existed yet")
    }

    func testCancellationDuringLaunchDiscardsTheQueryBeforeStart() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        let gate = SpotlightQueryTestGate()
        launcher.gate = gate

        let launched = expectation(description: "launch entered")
        let launchSignal = TestExpectation(launched)
        launcher.configuration.onLaunch = { _ in launchSignal.fulfill() }

        let observerRemoved = expectation(description: "observer removed")
        let removalSignal = TestExpectation(observerRemoved)
        launcher.configuration.onObserverRemoval = { _ in removalSignal.fulfill() }

        let session = makeSession(launcher: launcher, scheduler: scheduler)
        let handle = startSession(session)

        await fulfillment(of: [launched], timeout: 2.0)
        await session.cancel()
        gate.open()

        let items = await awaitResult(handle)
        XCTAssertTrue(items.isEmpty)

        // The abandoned query is released by the launch path, not by the session.
        await fulfillment(of: [observerRemoved], timeout: 2.0)

        guard let probe = launcher.probe(forPattern: "zip") else {
            return XCTFail("the query must be launched through the injected launcher")
        }
        XCTAssertEqual(probe.counters.startCalls, 0, "the query must never start after cancellation")
        XCTAssertEqual(probe.counters.stopCalls, 1)
        XCTAssertEqual(probe.counters.observerRemovalCalls, 1)
        let snapshot = await session.lifecycleSnapshot()
        XCTAssertEqual(snapshot.termination, .cancelled)
        XCTAssertEqual(snapshot.resumeCount, 1, "the waiter must be resumed exactly once")
    }

    // MARK: Timeout

    func testMissingCompletionNotificationTimesOutAndTearsDown() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        let started = startSignal(launcher)
        let provider = makeProvider(launcher: launcher, scheduler: scheduler)

        let handle = startSearch(provider, query: "zip")
        await fulfillment(of: [started], timeout: 2.0)

        guard let probe = launcher.probe(forPattern: "zip") else {
            return XCTFail("the query must be launched through the injected launcher")
        }
        scheduler.fireAll()

        let items = await awaitResult(handle)

        XCTAssertTrue(items.isEmpty, "a query without a completion notification must still return")
        XCTAssertEqual(probe.counters.stopCalls, 1)
        XCTAssertEqual(probe.counters.observerRemovalCalls, 1)
        XCTAssertTrue(probe.counters.snapshotLimits.isEmpty, "a timed-out query must not harvest results")
        XCTAssertEqual(scheduler.counters.scheduled, 1)
    }

    func testLateCompletionAfterTimeoutIsIgnored() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        launcher.configuration.records = [SpotlightQueryRecord(path: "/scope/Photos.zip", byteSize: 1)]
        let started = startSignal(launcher)
        let session = makeSession(launcher: launcher, scheduler: scheduler)

        let handle = startSession(session)
        await fulfillment(of: [started], timeout: 2.0)

        guard let probe = launcher.probe(forPattern: "zip") else {
            return XCTFail("the query must be launched through the injected launcher")
        }
        scheduler.fireAll()
        let items = await awaitResult(handle)
        XCTAssertTrue(items.isEmpty)

        // A completion that arrives after the timeout must not resurrect the session.
        probe.fireFinish()
        for _ in 0..<8 { await Task.yield() }

        let snapshot = await session.lifecycleSnapshot()
        XCTAssertEqual(snapshot.termination, .timedOut)
        XCTAssertEqual(snapshot.resumeCount, 1)
        XCTAssertEqual(probe.counters.stopCalls, 1)
        XCTAssertEqual(probe.counters.observerRemovalCalls, 1)
    }

    // MARK: Duplicate notifications

    func testDuplicateCompletionNotificationResumesExactlyOnce() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        launcher.configuration.records = [
            SpotlightQueryRecord(path: "/scope/Photos.zip", byteSize: 1),
            SpotlightQueryRecord(path: "/scope/backup.7z", byteSize: 2)
        ]
        let started = startSignal(launcher)
        let session = makeSession(launcher: launcher, scheduler: scheduler)

        let handle = startSession(session)
        await fulfillment(of: [started], timeout: 2.0)

        guard let probe = launcher.probe(forPattern: "zip") else {
            return XCTFail("the query must be launched through the injected launcher")
        }
        probe.fireFinish()
        probe.fireFinish()

        let items = await awaitResult(handle)
        XCTAssertEqual(items.count, 2)

        probe.fireFinish()
        for _ in 0..<8 { await Task.yield() }

        let snapshot = await session.lifecycleSnapshot()
        XCTAssertEqual(snapshot.termination, .completed)
        XCTAssertEqual(snapshot.resumeCount, 1, "a duplicate notification must not resume twice")
        XCTAssertEqual(probe.counters.stopCalls, 1)
        XCTAssertEqual(probe.counters.observerRemovalCalls, 1)
    }

    // MARK: Isolation

    func testParallelQueriesDoNotAffectEachOther() async {
        let launcher = SpotlightQueryTestLauncher()
        let scheduler = ManualSpotlightTimeoutScheduler()
        launcher.configuration.records = [SpotlightQueryRecord(path: "/scope/shared.zip", byteSize: 1)]

        let alphaStarted = expectation(description: "alpha started")
        let betaStarted = expectation(description: "beta started")
        let alphaSignal = TestExpectation(alphaStarted)
        let betaSignal = TestExpectation(betaStarted)
        launcher.configuration.onStart = { pattern in
            if pattern == "alpha" {
                alphaSignal.fulfill()
            } else if pattern == "beta" {
                betaSignal.fulfill()
            }
        }

        let provider = makeProvider(launcher: launcher, scheduler: scheduler)
        let alpha = startSearch(provider, query: "alpha")
        let beta = startSearch(provider, query: "beta")

        await fulfillment(of: [alphaStarted, betaStarted], timeout: 2.0)

        guard let alphaProbe = launcher.probe(forPattern: "alpha"),
              let betaProbe = launcher.probe(forPattern: "beta")
        else {
            return XCTFail("both queries must be launched")
        }

        alpha.task.cancel()
        let alphaItems = await awaitResult(alpha)

        XCTAssertTrue(alphaItems.isEmpty)
        XCTAssertEqual(alphaProbe.counters.stopCalls, 1)
        XCTAssertEqual(betaProbe.counters.stopCalls, 0, "cancelling one query must not stop the other")
        XCTAssertTrue(betaProbe.counters.snapshotLimits.isEmpty)

        betaProbe.fireFinish()
        let betaItems = await awaitResult(beta)

        XCTAssertEqual(betaItems.count, 1)
        XCTAssertEqual(betaProbe.counters.stopCalls, 1)
        XCTAssertEqual(alphaProbe.counters.stopCalls, 1, "completing one query must not stop the other")
        XCTAssertEqual(betaProbe.counters.observerRemovalCalls, 1)
        XCTAssertEqual(alphaProbe.counters.observerRemovalCalls, 1)
        XCTAssertEqual(scheduler.counters.scheduled, 2, "each query arms its own timeout")
    }
}
