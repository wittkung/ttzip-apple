// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import TTZipCore

/// Owns synchronous native work on one dispatch lane, never on Swift's cooperative pool.
/// Cancellation skips queued calls; an already running native call must acknowledge its
/// existing Rust cancellation signal before its continuation and captured binding retire.
// All mutable admission bookkeeping is protected by lock.
final class SemanticCoreBlockingExecutor: @unchecked Sendable {
    fileprivate final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var started = false

        func cancelIfQueued() {
            lock.withLock {
                if !started {
                    cancelled = true
                }
            }
        }

        func tryBeginExecution() -> Bool {
            lock.withLock {
                guard !cancelled, !started else { return false }
                started = true
                return true
            }
        }
    }

    struct Ticket: Sendable {
        fileprivate let id: UUID
        let key: String
        fileprivate let generation: UInt64
        fileprivate let admission: Admission
    }

    private struct Entry {
        let key: String
        let generation: UInt64
        let admission: Admission
    }

    private let queue = DispatchQueue(label: "com.metastudyline.ttzip.semantic-native", qos: .utility)
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    var pendingAdmissionCount: Int {
        lock.withLock { entries.count }
    }

    /// Registers cancellation ownership synchronously in the caller's actor turn.
    func admit(generation: UInt64 = 0, key: String) -> Ticket {
        let ticket = Ticket(id: UUID(), key: key, generation: generation, admission: Admission())
        lock.withLock {
            entries[ticket.id] = Entry(key: key, generation: generation, admission: ticket.admission)
        }
        return ticket
    }

    /// Discards a ticket rejected by its session before run has been called.
    func discard(_ ticket: Ticket) {
        ticket.admission.cancelIfQueued()
        lock.withLock { _ = entries.removeValue(forKey: ticket.id) }
    }

    /// Executes each admitted ticket once; callers must run or discard every ticket.
    func run<Value: Sendable>(
        ticket: Ticket,
        cancelled: Value,
        operation: @escaping @Sendable () -> Value
    ) async -> Value {
        let id = ticket.id
        let admission = ticket.admission
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = admission.tryBeginExecution() ? operation() : cancelled
                    self.lock.withLock { _ = self.entries.removeValue(forKey: id) }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            admission.cancelIfQueued()
        }
    }

    func cancel(key: String) {
        lock.withLock {
            for entry in entries.values where entry.key == key {
                entry.admission.cancelIfQueued()
            }
        }
    }

    func cancelGeneration(_ maxGeneration: UInt64) {
        lock.withLock {
            for entry in entries.values where entry.generation <= maxGeneration {
                entry.admission.cancelIfQueued()
            }
        }
    }

    func cancelAll() {
        lock.withLock {
            for entry in entries.values {
                entry.admission.cancelIfQueued()
            }
        }
    }
}

/// Owns a single generation's `UniFFISemanticSearchEngineBindingProtocol` reference.
///
/// Guarantees:
/// - Async callers on `UniFFIRustSemanticCoreBridge` never hold strong references to the underlying
///   UniFFI binding across suspension points; they hold only this generation box.
/// - `executeOnNativeLane` borrows the binding inside an inner stack frame on `SemanticCoreBlockingExecutor`
///   and releases that borrow before the dispatch block resumes the Swift continuation.
/// - `finishAcceptedOperation` runs in the caller's post-`await` actor epilogue (`defer`); when the session
///   is retiring and both `acceptedCount == 0` and `runningCount == 0`, the sole remaining reference in
///   `self.engine` is cleared (`deinit` / Rust `Drop` completes synchronously) before resuming drain waiters.
final class SemanticBindingSessionBox: @unchecked Sendable {
    let generation: UInt64
    private let lock = NSLock()
    private var engine: (any UniFFISemanticSearchEngineBindingProtocol)?
    private var isRetiring: Bool = false
    private var isPrepared: Bool = false
    private var acceptedCount: Int = 0
    private var runningCount: Int = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(generation: UInt64, engine: (any UniFFISemanticSearchEngineBindingProtocol)?) {
        self.generation = generation
        self.engine = engine
    }

    var hasActiveEngine: Bool {
        lock.withLock { engine != nil || acceptedCount > 0 || runningCount > 0 }
    }

    var isRetiredOrDestroyed: Bool {
        lock.withLock { isRetiring || engine == nil }
    }

    func tryAcceptOperation() -> Bool {
        lock.withLock {
            guard !isRetiring, engine != nil else { return false }
            acceptedCount += 1
            return true
        }
    }

    func finishAcceptedOperation() {
        var releasedEngine: (any UniFFISemanticSearchEngineBindingProtocol)?
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            acceptedCount = max(0, acceptedCount - 1)
            if isRetiring && acceptedCount == 0 && runningCount == 0 {
                releasedEngine = engine
                engine = nil
                waiters = drainWaiters
                drainWaiters.removeAll()
            }
        }
        Self.releaseEngineOutsideLock(&releasedEngine)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func executeDirect<Value>(
        _ body: (any UniFFISemanticSearchEngineBindingProtocol) -> Value
    ) -> Value? {
        guard let borrowed = beginRunningBorrow() else { return nil }
        let result = Self.invokeDirectScoped(engine: borrowed, body: body)
        endRunningBorrow()
        return result
    }

    private static func invokeDirectScoped<Value>(
        engine: any UniFFISemanticSearchEngineBindingProtocol,
        body: (any UniFFISemanticSearchEngineBindingProtocol) -> Value
    ) -> Value {
        body(engine)
    }

    func prepareOnNativeLane() -> UniFFISemanticModelState? {
        guard let borrowed = beginRunningBorrow() else { return nil }
        let state = Self.invokePrepareScoped(engine: borrowed, session: self)
        endRunningBorrow()
        return state
    }

    private static func invokePrepareScoped(
        engine: any UniFFISemanticSearchEngineBindingProtocol,
        session: SemanticBindingSessionBox
    ) -> UniFFISemanticModelState? {
        guard !session.isMarkedRetiring else { return nil }
        let state = engine.prepareModelRuntime()
        if case .ready = state {
            session.markPrepared(true)
        } else {
            session.markPrepared(false)
        }
        return session.isMarkedRetiring ? nil : state
    }

    func executeOnNativeLane<Value>(
        ensurePrepared: Bool = false,
        _ body: (any UniFFISemanticSearchEngineBindingProtocol) -> Value
    ) -> Value? {
        guard let borrowed = beginRunningBorrow() else {
            return nil
        }
        let result = Self.invokeScoped(
            engine: borrowed,
            session: self,
            ensurePrepared: ensurePrepared,
            body: body
        )
        endRunningBorrow()
        return result
    }

    private static func invokeScoped<Value>(
        engine: any UniFFISemanticSearchEngineBindingProtocol,
        session: SemanticBindingSessionBox,
        ensurePrepared: Bool,
        body: (any UniFFISemanticSearchEngineBindingProtocol) -> Value
    ) -> Value? {
        if ensurePrepared {
            guard !session.isMarkedRetiring else { return nil }
            if session.claimPreparationNeed() {
                let state = engine.prepareModelRuntime()
                if case .ready = state {
                    session.markPrepared(true)
                } else {
                    session.markPrepared(false)
                }
            }
            guard !session.isMarkedRetiring else { return nil }
        }
        return body(engine)
    }

    func markPrepared(_ prepared: Bool) {
        lock.withLock { isPrepared = prepared }
    }

    private var isMarkedRetiring: Bool {
        lock.withLock { isRetiring }
    }

    private func claimPreparationNeed() -> Bool {
        lock.withLock {
            guard !isRetiring, !isPrepared else { return false }
            isPrepared = true
            return true
        }
    }

    private func beginRunningBorrow() -> (any UniFFISemanticSearchEngineBindingProtocol)? {
        lock.withLock {
            guard !isRetiring, let current = engine else { return nil }
            runningCount += 1
            return current
        }
    }

    private func endRunningBorrow() {
        var releasedEngine: (any UniFFISemanticSearchEngineBindingProtocol)?
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            runningCount = max(0, runningCount - 1)
            if isRetiring && acceptedCount == 0 && runningCount == 0 {
                releasedEngine = engine
                engine = nil
                waiters = drainWaiters
                drainWaiters.removeAll()
            }
        }
        Self.releaseEngineOutsideLock(&releasedEngine)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func releaseEngineOutsideLock(
        _ releasedEngine: inout (any UniFFISemanticSearchEngineBindingProtocol)?
    ) {
        guard let activeEngine = releasedEngine else { return }
        releasedEngine = nil
        withExtendedLifetime(activeEngine) {}
    }

    func beginRetire(activeScopeIds: Set<String>, activeSearchRequestIds: Set<UInt64>) {
        markRetiring()
        for scopeId in activeScopeIds {
            cancelIndexingIfRunning(scopeId: scopeId)
        }
        for requestId in activeSearchRequestIds {
            cancelSearchIfRunning(requestId: requestId)
        }
    }

    func cancelIndexingIfRunning(scopeId: String) {
        Self.invokeSignalScoped(session: self) { $0.cancelIndexing(scopeId: scopeId) }
    }

    func cancelSearchIfRunning(requestId: UInt64) {
        Self.invokeSignalScoped(session: self) { $0.cancelSearch(requestId: requestId) }
    }

    private static func invokeSignalScoped(
        session: SemanticBindingSessionBox,
        body: (any UniFFISemanticSearchEngineBindingProtocol) -> Void
    ) {
        guard let borrowed = session.lock.withLock({ session.engine }) else { return }
        body(borrowed)
    }

    func markRetiring() {
        var releasedEngine: (any UniFFISemanticSearchEngineBindingProtocol)?
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            isRetiring = true
            if acceptedCount == 0 && runningCount == 0 {
                releasedEngine = engine
                engine = nil
                waiters = drainWaiters
                drainWaiters.removeAll()
            }
        }
        Self.releaseEngineOutsideLock(&releasedEngine)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilDrained() async {
        markRetiring()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if acceptedCount == 0 && runningCount == 0 && engine == nil {
                    return true
                }
                drainWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }
}

/// Dedicated background file I/O executor for GGUF checksum and header verification,
/// ensuring 310 MB file hashing never blocks `@MainActor`, `SemanticSearchEngine` actor,
/// or Swift's cooperative thread pool.
final class SemanticModelFileIOExecutor: @unchecked Sendable {
    static let shared = SemanticModelFileIOExecutor()

    private let queue = DispatchQueue(label: "com.metastudyline.ttzip.semantic-model-io", qos: .utility)

    func runThrowing<Value: Sendable>(
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try operation()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public enum SemanticCheckpointStatus: String, Sendable, Equatable {
    case pass = "PASS"
    case blocked = "BLOCKED"
    case fail = "FAIL"
}

public struct SemanticRealModelCheckpointReport: Sendable, Equatable {
    public let status: SemanticCheckpointStatus
    public let modelPath: String
    public let verifiedSha256: String?
    public let reason: String
}

/// Verifies a local GGUF file against `PinnedSemanticModelConstants` (`309,855,456` bytes, `"GGUF"` magic, SHA-256).
/// Note: File checksum verification alone never constitutes a `PASS` for real model inference;
/// real inference checkpointing is executed by Rust `LlamaRuntimeEngine::run_real_model_checkpoint_with_references`.
public enum GGUFModelVerifier {
    public static func verifyModelFile(
        at url: URL,
        expectedBytes: UInt64 = PinnedSemanticModelConstants.ggufSizeBytes,
        expectedSha256: String = PinnedSemanticModelConstants.ggufSha256,
        requireExactChecksum: Bool = true
    ) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw SemanticQueryEncoderError.modelNotAvailable
        }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let actualSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if requireExactChecksum {
            guard actualSize == expectedBytes else {
                throw SemanticQueryEncoderError.invalidModelInput(
                    "GGUF size mismatch: expected \(expectedBytes), got \(actualSize)"
                )
            }
        } else {
            guard actualSize >= 16 else {
                throw SemanticQueryEncoderError.invalidModelInput(
                    "GGUF test fixture too small: got \(actualSize) bytes"
                )
            }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let magicData = try handle.read(upToCount: 4),
              magicData.count == 4,
              String(data: magicData, encoding: .ascii) == "GGUF"
        else {
            throw SemanticQueryEncoderError.invalidModelInput("Invalid GGUF magic header")
        }
        var hasher = SHA256()
        hasher.update(data: magicData)
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if requireExactChecksum {
            guard hex.lowercased() == expectedSha256.lowercased() else {
                throw SemanticQueryEncoderError.invalidModelInput(
                    "GGUF SHA-256 mismatch: expected \(expectedSha256), got \(hex)"
                )
            }
        }
        return hex
    }

    public static func verifyModelFileAsync(
        at url: URL,
        expectedBytes: UInt64 = PinnedSemanticModelConstants.ggufSizeBytes,
        expectedSha256: String = PinnedSemanticModelConstants.ggufSha256,
        requireExactChecksum: Bool = true
    ) async throws -> String {
        try await SemanticModelFileIOExecutor.shared.runThrowing {
            try verifyModelFile(
                at: url,
                expectedBytes: expectedBytes,
                expectedSha256: expectedSha256,
                requireExactChecksum: requireExactChecksum
            )
        }
    }

    public static func runCheckpoint(modelURL: URL? = nil) -> SemanticRealModelCheckpointReport {
        let targetURL = modelURL ?? defaultInstalledGGUFURL()
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return SemanticRealModelCheckpointReport(
                status: .blocked,
                modelPath: targetURL.path,
                verifiedSha256: nil,
                reason: "BLOCKED: Required GGUF model \(PinnedSemanticModelConstants.ggufFilename) not installed at \(targetURL.path)"
            )
        }
        do {
            let sha = try verifyModelFile(at: targetURL)
            return SemanticRealModelCheckpointReport(
                status: .blocked,
                modelPath: targetURL.path,
                verifiedSha256: sha,
                reason: "BLOCKED: GGUF file checksum verified (\(sha)); real llama.cpp inference must be verified via Rust UniFFISemanticSearchEngine"
            )
        } catch {
            return SemanticRealModelCheckpointReport(
                status: .fail,
                modelPath: targetURL.path,
                verifiedSha256: nil,
                reason: "FAIL: \(error.localizedDescription)"
            )
        }
    }

    public static func defaultInstalledGGUFURL() -> URL {
        let resolver = LocalModelPathResolver.defaultResolver()
        if FileManager.default.fileExists(atPath: resolver.canonicalModelFileURL.path) {
            return resolver.canonicalModelFileURL
        }
        if let legacy = resolver.legacyModelFileURL,
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return resolver.canonicalModelFileURL
    }
}

/// Strictly monotonic sequence tracker for actor operations and indexing run admissions.
///
/// Unified Partial-Order & Acyclicity Proof:
/// Every admitted operation and every `TrackedIndexingRun` receives a unique sequence number
/// $s(X) \in \mathbb{N}$ synchronously from `nextSequence` upon admission.
/// Every wait edge $W \to X$ in `SemanticSearchEngine` — including `waitForPriorOperationsToDrain`,
/// `drainRetiringIndexingRuns`, `drainIndexingRuns`, and same-scope `awaitPriorRetiringRuns` —
/// restricts targets to $s(X) < s(W)$. Because $(\mathbb{N}, <)$ is a strict well-order:
/// 1. Irreflexivity ($s(A) \not< s(A)$): no operation or run ever waits on itself.
/// 2. Acyclicity: in the same-scope `P -> cancel P -> A -> cancel A -> B -> cancel B -> release P`
///    transition ($s(P) < s(A) < s(B)$), $A$ only awaits retiring runs with $s(X) < s(A)$ and
///    never awaits the newer retiring run $B$, eliminating any $A \leftrightarrow B$ wait cycle.
struct SemanticOperationDrainTracker {
    private struct Waiter {
        let beforeSequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var nextSequence: UInt64 = 1
    private var activeSequences: Set<UInt64> = []
    private var waiters: [Waiter] = []

    mutating func beginOperation() -> UInt64 {
        let seq = nextSequence
        nextSequence &+= 1
        activeSequences.insert(seq)
        return seq
    }

    mutating func allocateCutoffSequence() -> UInt64 {
        let seq = nextSequence
        nextSequence &+= 1
        return seq
    }

    mutating func endOperation(_ sequence: UInt64) -> [CheckedContinuation<Void, Never>] {
        activeSequences.remove(sequence)
        let activeSnapshot = activeSequences
        var ready: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            if !activeSnapshot.contains(where: { $0 < waiter.beforeSequence }) {
                ready.append(waiter.continuation)
                return true
            }
            return false
        }
        return ready
    }

    func hasActiveOperations(beforeSequence cutoff: UInt64) -> Bool {
        activeSequences.contains { $0 < cutoff }
    }

    mutating func registerWaiter(
        beforeSequence cutoff: UInt64,
        continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        guard hasActiveOperations(beforeSequence: cutoff) else {
            return true
        }
        waiters.append(Waiter(beforeSequence: cutoff, continuation: continuation))
        return false
    }
}

struct SemanticTrackedIndexingRun {
    let runID: UUID
    let scopeId: String
    let scopeGeneration: UInt64
    let admissionSequence: UInt64
    let task: Task<SemanticIndexProgress, Never>
}
