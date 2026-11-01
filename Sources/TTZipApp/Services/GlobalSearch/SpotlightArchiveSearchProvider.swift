// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation

// MARK: - Query seams (internal, non-public)

/// A single Spotlight hit reduced to the fields this provider consumes.
struct SpotlightQueryRecord: Sendable, Equatable {
    let path: String
    let byteSize: Int64
    let isDirectory: Bool

    init(path: String, byteSize: Int64, isDirectory: Bool = false) {
        self.path = path
        self.byteSize = byteSize
        self.isDirectory = isDirectory
    }
}

/// Filter policy applied when mapping `SpotlightQueryRecord` hits into `GlobalSearchResultItem`s.
public enum SpotlightResultFilterMode: Sendable, Equatable {
    /// Retains only files whose extension is in `SpotlightArchiveSearchProvider.supportedArchiveExtensions`.
    case archivesOnly
    /// Retains both general files/folders (`.diskItem`) and archives (`.archiveFile`).
    case allAccessibleItems
}

/// A launched metadata query narrowed to the four operations the lifecycle needs.
///
/// Every member is asynchronous so a concrete implementation can keep AppKit
/// objects confined to the main actor while the lifecycle state lives in an actor.
protocol SpotlightQueryHandle: Sendable {
    /// Starts the query. Returns `false` when the platform refused to start it.
    func start() async -> Bool
    /// Returns at most `limit` records gathered by the query.
    func snapshot(limit: Int) async -> [SpotlightQueryRecord]
    /// Stops the query. Must be safe on a query that never started.
    func stop() async
    /// Removes the completion observer. Must be idempotent.
    func removeObserver() async
}

/// Creates exactly one query bound to `scope`, reporting completion through `onFinish`.
protocol SpotlightQueryLaunching: Sendable {
    func launch(
        scope: [URL],
        namePattern: String,
        onFinish: @Sendable @escaping () -> Void
    ) async -> any SpotlightQueryHandle
}

/// Arms the liveness timeout. Abstracted so tests can advance it without sleeping.
protocol SpotlightTimeoutScheduling: Sendable {
    func schedule(
        after duration: Duration,
        action: @Sendable @escaping () -> Void
    ) -> any SpotlightTimeoutToken
}

/// Handle for one armed timeout.
protocol SpotlightTimeoutToken: Sendable {
    func cancel()
}

/// The single terminal state a query session can reach.
enum SpotlightQueryTermination: Sendable, Equatable {
    case completed
    case cancelled
    case timedOut
    case startFailed
}

/// Lifecycle counters exposed for tests; production callers never read them.
struct SpotlightQueryLifecycleSnapshot: Sendable, Equatable {
    let termination: SpotlightQueryTermination?
    let resumeCount: Int
}

// MARK: - Session

/// Owns the mutable lifecycle of exactly one Spotlight query.
///
/// The actor is the only isolation domain for the query handle, the completion
/// observer, the timeout token and the caller's continuation. Every terminal path
/// funnels through `terminate(_:items:)`, whose `running` guard turns a late
/// notification, a late timeout or a second cancellation into a no-op, so the
/// continuation is resumed exactly once.
actor SpotlightQuerySession {
    private enum Phase {
        case idle
        case running
        case terminated(SpotlightQueryTermination)
    }

    private let launcher: any SpotlightQueryLaunching
    private let scheduler: any SpotlightTimeoutScheduling
    private let timeout: Duration
    private let scope: [URL]
    private let namePattern: String
    private let maxResults: Int
    private let scanLimit: Int
    private let filterMode: SpotlightResultFilterMode

    private var phase: Phase = .idle
    private var continuation: CheckedContinuation<[GlobalSearchResultItem], Never>?
    private var handle: (any SpotlightQueryHandle)?
    private var timeoutToken: (any SpotlightTimeoutToken)?
    private var pendingCompletion = false
    private var resumeCount = 0

    init(
        launcher: any SpotlightQueryLaunching,
        scheduler: any SpotlightTimeoutScheduling,
        timeout: Duration,
        scope: [URL],
        namePattern: String,
        maxResults: Int,
        scanLimit: Int,
        filterMode: SpotlightResultFilterMode = .archivesOnly
    ) {
        self.launcher = launcher
        self.scheduler = scheduler
        self.timeout = timeout
        self.scope = scope
        self.namePattern = namePattern
        self.maxResults = maxResults
        self.scanLimit = scanLimit
        self.filterMode = filterMode
    }

    /// Drives the query to exactly one terminal state and returns its items.
    func run() async -> [GlobalSearchResultItem] {
        if case .terminated = phase { return [] }
        if Task.isCancelled {
            phase = .terminated(.cancelled)
            return []
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.phase = .running
            self.timeoutToken = self.scheduler.schedule(after: self.timeout) { [weak self] in
                guard let self else { return }
                Task { await self.timeoutElapsed() }
            }
            Task { await self.launchQuery() }
        }
    }

    /// Terminates the session because the caller's task was cancelled.
    func cancel() async {
        switch phase {
        case .idle:
            phase = .terminated(.cancelled)
        case .running:
            await terminate(.cancelled)
        case .terminated:
            return
        }
    }

    /// Current lifecycle counters. Test-only observation point.
    func lifecycleSnapshot() -> SpotlightQueryLifecycleSnapshot {
        let termination: SpotlightQueryTermination? = switch phase {
        case .terminated(let reason): reason
        case .idle, .running: nil
        }
        return SpotlightQueryLifecycleSnapshot(termination: termination, resumeCount: resumeCount)
    }

    // MARK: Private

    private func launchQuery() async {
        guard case .running = phase else { return }

        let handle = await launcher.launch(
            scope: scope,
            namePattern: namePattern
        ) { [weak self] in
            guard let self else { return }
            Task { await self.completionArrived() }
        }

        // A cancellation or timeout that landed while the query was being built
        // must still release the query and its observer.
        guard case .running = phase else {
            await handle.stop()
            await handle.removeObserver()
            return
        }

        self.handle = handle
        let didStart = await handle.start()

        // `terminate` already tore the handle down when the session ended mid-start.
        guard case .running = phase else { return }

        guard didStart else {
            await terminate(.startFailed)
            return
        }

        if pendingCompletion {
            await completionArrived()
        }
    }

    private func completionArrived() async {
        guard case .running = phase else { return }

        // Completion cannot precede `start()` in production; defer it so a double
        // still observes a handle it can stop and detach from.
        guard let handle else {
            pendingCompletion = true
            return
        }

        let records = await handle.snapshot(limit: scanLimit)

        // `snapshot` suspends; a cancellation or timeout may have won the race.
        guard case .running = phase else { return }

        let items = makeSpotlightResultItems(
            from: records,
            maxResults: maxResults,
            filterMode: filterMode
        )
        await terminate(.completed, items: items)
    }

    private func timeoutElapsed() async {
        await terminate(.timedOut)
    }

    /// The only place the continuation is resumed.
    private func terminate(
        _ reason: SpotlightQueryTermination,
        items: [GlobalSearchResultItem] = []
    ) async {
        guard case .running = phase else { return }
        phase = .terminated(reason)

        timeoutToken?.cancel()
        timeoutToken = nil

        let activeHandle = handle
        handle = nil
        if let activeHandle {
            await activeHandle.stop()
            await activeHandle.removeObserver()
        }

        guard let continuation else { return }
        self.continuation = nil
        resumeCount += 1
        continuation.resume(returning: items)
    }
}

// MARK: - Result mapping

/// Maps raw Spotlight records to result items, preserving the existing archive
/// extension filter when `filterMode == .archivesOnly` or retaining general files
/// and folders when `filterMode == .allAccessibleItems`. Never returns more than `maxResults`.
func makeSpotlightResultItems(
    from records: [SpotlightQueryRecord],
    maxResults: Int,
    filterMode: SpotlightResultFilterMode = .archivesOnly
) -> [GlobalSearchResultItem] {
    guard maxResults > 0 else { return [] }

    var items: [GlobalSearchResultItem] = []
    items.reserveCapacity(min(records.count, maxResults))

    for record in records {
        let path = record.path
        let fileExtension = (path as NSString).pathExtension.lowercased()
        let isArchive = !record.isDirectory
            && SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains(fileExtension)

        switch filterMode {
        case .archivesOnly:
            guard isArchive else { continue }
            items.append(
                GlobalSearchResultItem(
                    id: "spotlight:\(path)",
                    title: (path as NSString).lastPathComponent,
                    subtitle: path,
                    hitType: .archiveFile,
                    archivePath: path,
                    isDirectory: false,
                    byteSize: record.byteSize,
                    score: 0.50,
                    matchBadge: nil
                )
            )
        case .allAccessibleItems:
            if isArchive {
                items.append(
                    GlobalSearchResultItem(
                        id: "spotlight:\(path)",
                        title: (path as NSString).lastPathComponent,
                        subtitle: path,
                        hitType: .archiveFile,
                        archivePath: path,
                        isDirectory: false,
                        byteSize: record.byteSize,
                        score: 0.50,
                        matchBadge: nil
                    )
                )
            } else {
                items.append(
                    GlobalSearchResultItem(
                        id: "spotlight:file:\(path)",
                        title: (path as NSString).lastPathComponent,
                        subtitle: path,
                        hitType: .archiveEntry,
                        archivePath: nil,
                        entrySubpath: nil,
                        diskPath: path,
                        isDirectory: record.isDirectory,
                        byteSize: record.byteSize,
                        score: 0.50,
                        matchBadge: nil
                    )
                )
            }
        }

        if items.count >= maxResults { break }
    }

    return items
}

// MARK: - Production query handle

/// Production launcher: builds the real `NSMetadataQuery` and confines every
/// AppKit interaction to the main actor.
@MainActor
final class SpotlightMetadataQueryLauncher: SpotlightQueryLaunching {
    func launch(
        scope: [URL],
        namePattern: String,
        onFinish: @Sendable @escaping () -> Void
    ) async -> any SpotlightQueryHandle {
        let query = NSMetadataQuery()
        query.searchScopes = scope
        query.predicate = NSPredicate(
            format: "%K LIKE[cd] %@",
            NSMetadataItemFSNameKey,
            "*\(namePattern)*"
        )

        let operationQueue = OperationQueue()
        operationQueue.qualityOfService = .userInitiated
        operationQueue.maxConcurrentOperationCount = 1
        query.operationQueue = operationQueue

        return SpotlightMetadataQueryHandle(query: query, onFinish: onFinish)
    }
}

/// Production handle: owns one `NSMetadataQuery` plus its completion observer.
@MainActor
final class SpotlightMetadataQueryHandle: SpotlightQueryHandle {
    private let query: NSMetadataQuery
    private var observer: (any NSObjectProtocol)?

    init(query: NSMetadataQuery, onFinish: @Sendable @escaping () -> Void) {
        self.query = query
        // Registered before `start()` so a fast completion cannot be missed.
        self.observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { _ in
            onFinish()
        }
    }

    func start() async -> Bool {
        query.start()
        return query.isStarted
    }

    func snapshot(limit: Int) async -> [SpotlightQueryRecord] {
        query.disableUpdates()
        defer { query.enableUpdates() }

        let count = min(query.resultCount, max(0, limit))
        guard count > 0 else { return [] }

        var records: [SpotlightQueryRecord] = []
        records.reserveCapacity(count)

        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else {
                continue
            }
            let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
            let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            let isDir = contentType == "public.folder" || contentType == "public.directory"
            records.append(SpotlightQueryRecord(path: path, byteSize: size, isDirectory: isDir))
        }

        return records
    }

    func stop() async {
        query.stop()
    }

    func removeObserver() async {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }
}

// MARK: - Production timeout scheduler

/// Default timeout scheduler backed by a cancellable sleep task.
struct TaskSleepTimeoutScheduler: SpotlightTimeoutScheduling {
    func schedule(
        after duration: Duration,
        action: @Sendable @escaping () -> Void
    ) -> any SpotlightTimeoutToken {
        let task = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            action()
        }
        return TaskSleepTimeoutToken(task: task)
    }
}

/// Cancellation handle for `TaskSleepTimeoutScheduler`.
final class TaskSleepTimeoutToken: SpotlightTimeoutToken {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

// MARK: - Provider

/// Fast Spotlight file searching provider scoped specifically to archive files in user content directories.
public final class SpotlightArchiveSearchProvider: Sendable {
    public static let shared = SpotlightArchiveSearchProvider()

    public static let supportedArchiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "tbz2", "xz", "txz", "zst", "iso", "dmg"
    ]

    /// Upper bound on how long one query may keep its caller waiting.
    ///
    /// This is a liveness bound, not a latency target: it only guarantees that a
    /// wedged Spotlight query releases the caller. It is deliberately far above
    /// the interactive budget of the search panel and must not be read as a
    /// search performance metric.
    public static let defaultQueryTimeout: Duration = .seconds(3)

    /// Number of raw hits scanned per requested result, preserving the previous
    /// over-scan ratio used to survive non-archive hits inside the scope.
    private static let scanMultiplier = 3

    private let launcher: any SpotlightQueryLaunching
    private let timeoutScheduler: any SpotlightTimeoutScheduling
    private let timeout: Duration
    private let scopeResolver: @Sendable () -> [URL]

    public convenience init() {
        self.init(
            launcher: SpotlightMetadataQueryLauncher(),
            timeoutScheduler: TaskSleepTimeoutScheduler(),
            timeout: Self.defaultQueryTimeout,
            scopeResolver: Self.resolveDefaultScopes
        )
    }

    /// Test injection point. Not public: production callers use `init()`.
    init(
        launcher: any SpotlightQueryLaunching,
        timeoutScheduler: any SpotlightTimeoutScheduling,
        timeout: Duration,
        scopeResolver: @Sendable @escaping () -> [URL]
    ) {
        self.launcher = launcher
        self.timeoutScheduler = timeoutScheduler
        self.timeout = timeout
        self.scopeResolver = scopeResolver
    }

    /// Searches archive files matching `query` inside the resolved scope.
    ///
    /// Returns `[]` without starting a query for an empty query, a non-positive
    /// `maxResults`, or an empty scope. An empty scope is never widened to a
    /// whole-disk search: `NSMetadataQuery` would otherwise fall back to its
    /// default scopes.
    public func search(query: String, maxResults: Int = 20) async -> [GlobalSearchResultItem] {
        await search(query: query, maxResults: maxResults, filterMode: .archivesOnly)
    }

    /// Searches accessible files and folders (both general items and archives) matching `query`
    /// inside the resolved scope using the shared `SpotlightQuerySession` lifecycle.
    public func searchAllAccessibleItems(
        query: String,
        maxResults: Int = 30,
        additionalScopes: [URL] = []
    ) async -> [GlobalSearchResultItem] {
        await search(
            query: query,
            maxResults: maxResults,
            filterMode: .allAccessibleItems,
            additionalScopes: additionalScopes
        )
    }

    public func search(
        query: String,
        maxResults: Int = 20,
        filterMode: SpotlightResultFilterMode,
        additionalScopes: [URL] = []
    ) async -> [GlobalSearchResultItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard maxResults > 0 else { return [] }

        var scope = scopeResolver()
        for extra in additionalScopes where !scope.contains(where: { $0.standardizedFileURL == extra.standardizedFileURL }) {
            scope.append(extra)
        }
        guard !scope.isEmpty else { return [] }

        let session = SpotlightQuerySession(
            launcher: launcher,
            scheduler: timeoutScheduler,
            timeout: timeout,
            scope: scope,
            namePattern: trimmed,
            maxResults: maxResults,
            scanLimit: Self.scanLimit(for: maxResults),
            filterMode: filterMode
        )

        return await withTaskCancellationHandler {
            await session.run()
        } onCancel: {
            Task { await session.cancel() }
        }
    }

    /// Raw hits to scan for `maxResults`, saturating instead of overflowing.
    static func scanLimit(for maxResults: Int) -> Int {
        let (product, overflow) = maxResults.multipliedReportingOverflow(by: scanMultiplier)
        return overflow ? Int.max : product
    }

    /// Archive-bearing user directories that exist on this machine.
    static func resolveDefaultScopes() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["Downloads", "Desktop", "Documents"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
