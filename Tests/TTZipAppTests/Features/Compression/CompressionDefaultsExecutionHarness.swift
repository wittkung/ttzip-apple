// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import TTZipCore

struct RecordedCompressExecution: Equatable, Sendable {
    let outputPath: String
    let format: ArchiveCompressionFormat
    let level: ArchiveCompressionLevel
    let skipMacJunk: Bool
    var advancedZstdLevel: Int? = nil
}

final class SequentialCompressHarness: Sendable {
    private struct State: Sendable {
        var enteredFirst = false
        var releasedFirst = false
        var releaseTimedOut = false
        var activeExecutions = 0
        var enteredWaiters: [SafeContinuation<Bool, Never>] = []
        var releaseWaiters: [SafeContinuation<Bool, Never>] = []
        var idleWaiters: [SafeContinuation<Bool, Never>] = []
        var recorded: [RecordedCompressExecution] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func beginExecution() {
        state.withLock { $0.activeExecutions += 1 }
    }

    func endExecution() {
        let waiters: [SafeContinuation<Bool, Never>] = state.withLock { state in
            state.activeExecutions = max(0, state.activeExecutions - 1)
            guard state.activeExecutions == 0 else { return [] }
            let drained = state.idleWaiters
            state.idleWaiters.removeAll()
            return drained
        }
        for waiter in waiters {
            _ = waiter.resume(returning: true)
        }
    }

    func recordAndGateFirstIfNeeded(
        _ execution: RecordedCompressExecution,
        holdOutputPath: String,
        releaseTimeoutSeconds: TimeInterval = 10.0
    ) async {
        let arrivalAction: (shouldHold: Bool, waiters: [SafeContinuation<Bool, Never>]) = state.withLock { state in
            state.recorded.append(execution)
            guard execution.outputPath == holdOutputPath, !state.enteredFirst else {
                return (false, [])
            }
            state.enteredFirst = true
            let drained = state.enteredWaiters
            state.enteredWaiters.removeAll()
            return (!state.releasedFirst, drained)
        }
        for waiter in arrivalAction.waiters {
            _ = waiter.resume(returning: true)
        }
        guard arrivalAction.shouldHold else { return }

        let releasedExplicitly = await waitBounded(seconds: releaseTimeoutSeconds) { [state] safe in
            let alreadyReleased = state.withLock { state in
                if state.releasedFirst {
                    return true
                }
                state.releaseWaiters.append(safe)
                return false
            }
            if alreadyReleased {
                _ = safe.resume(returning: true)
            }
        }
        if !releasedExplicitly {
            state.withLock { state in
                if !state.releasedFirst {
                    state.releaseTimedOut = true
                }
            }
        }
    }

    func waitUntilFirstEntered(timeoutSeconds: TimeInterval = 5.0) async -> Bool {
        await waitBounded(seconds: timeoutSeconds) { [state] safe in
            let immediateResult: Bool? = state.withLock { state in
                if state.enteredFirst {
                    return true
                }
                if state.releasedFirst {
                    return false
                }
                state.enteredWaiters.append(safe)
                return nil
            }
            if let immediateResult {
                _ = safe.resume(returning: immediateResult)
            }
        }
    }

    func releaseFirst() {
        let action: (
            entered: Bool,
            enteredWaiters: [SafeContinuation<Bool, Never>],
            releaseWaiters: [SafeContinuation<Bool, Never>]
        ) = state.withLock { state in
            state.releasedFirst = true
            let enteredWaiters = state.enteredWaiters
            state.enteredWaiters.removeAll()
            let releaseWaiters = state.releaseWaiters
            state.releaseWaiters.removeAll()
            return (state.enteredFirst, enteredWaiters, releaseWaiters)
        }
        for waiter in action.enteredWaiters {
            _ = waiter.resume(returning: action.entered)
        }
        for waiter in action.releaseWaiters {
            _ = waiter.resume(returning: true)
        }
    }

    func waitUntilIdle(timeoutSeconds: TimeInterval = 5.0) async -> Bool {
        await waitBounded(seconds: timeoutSeconds) { [state] safe in
            let isIdle = state.withLock { state in
                if state.activeExecutions == 0 {
                    return true
                }
                state.idleWaiters.append(safe)
                return false
            }
            if isIdle {
                _ = safe.resume(returning: true)
            }
        }
    }

    func didReleaseTimeOut() -> Bool {
        state.withLock { $0.releaseTimedOut }
    }

    func executions() -> [RecordedCompressExecution] {
        state.withLock { $0.recorded }
    }

    private enum BoundedWaitPhase: Sendable {
        case pending
        case registered(SafeContinuation<Bool, Never>)
        case armed(SafeContinuation<Bool, Never>, Task<Void, Never>)
        case closed
    }

    private static func closeWait(
        _ phase: inout BoundedWaitPhase
    ) -> (continuation: SafeContinuation<Bool, Never>?, timer: Task<Void, Never>?) {
        switch phase {
        case .pending, .closed:
            phase = .closed
            return (nil, nil)
        case .registered(let safe):
            phase = .closed
            return (safe, nil)
        case .armed(let safe, let timer):
            phase = .closed
            return (safe, timer)
        }
    }

    private func waitBounded(
        seconds: TimeInterval,
        register: @escaping @Sendable (SafeContinuation<Bool, Never>) -> Void
    ) async -> Bool {
        if Task.isCancelled {
            return false
        }
        let phase = OSAllocatedUnfairLock<BoundedWaitPhase>(initialState: .pending)
        defer {
            phase.withLock { Self.closeWait(&$0) }.timer?.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (raw: CheckedContinuation<Bool, Never>) in
                let safe = SafeContinuation(raw)
                let canRegister = phase.withLock { state -> Bool in
                    guard case .pending = state else { return false }
                    state = .registered(safe)
                    return true
                }
                guard canRegister, !Task.isCancelled else {
                    _ = safe.resume(returning: false)
                    return
                }
                register(safe)
                guard !safe.isResumed else { return }
                let timer = Task {
                    guard (try? await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000))) != nil else {
                        return
                    }
                    _ = safe.resume(returning: false)
                }
                let armed = phase.withLock { state -> Bool in
                    guard case .registered = state else { return false }
                    state = .armed(safe, timer)
                    return true
                }
                if !armed || safe.isResumed {
                    timer.cancel()
                }
            }
        } onCancel: {
            let closed = phase.withLock { Self.closeWait(&$0) }
            closed.timer?.cancel()
            _ = closed.continuation?.resume(returning: false)
        }
    }
}
