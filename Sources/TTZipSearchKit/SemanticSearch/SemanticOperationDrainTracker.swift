// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

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
