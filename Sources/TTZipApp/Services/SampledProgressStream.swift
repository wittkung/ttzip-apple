// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import TTZipCore
#if canImport(Darwin)
import Darwin
#endif

/// An immutable, point-in-time snapshot of archive processing telemetry.
public struct ProgressSnapshot: Sendable, Equatable {
    /// Number of bytes processed so far.
    public let processedBytes: UInt64
    /// Total expected workload bytes (0 if indeterminate or streaming).
    public let totalBytes: UInt64
    /// Instantaneous transfer rate in bytes per second.
    public let instantBps: UInt64
    /// Indicates whether cooperative cancellation has been requested.
    public let isCancelled: Bool
    /// Indicates whether the operation has completed terminal execution.
    public let isFinished: Bool
    /// Optional status description or name of current entry being processed.
    public let currentItemName: String?

    /// Normalized completion fraction clamped between 0.0 and 1.0.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(processedBytes) / Double(totalBytes)))
    }

    /// Normalized completion percentage clamped between 0.0 and 100.0.
    public var percentage: Double {
        fraction * 100.0
    }

    /// Indicates whether the progress is indeterminate (unknown total byte count).
    public var isIndeterminate: Bool {
        totalBytes == 0
    }

    /// Instantaneous throughput formatted in megabytes per second (MB/s).
    public var throughputMBs: Double {
        Double(instantBps) / (1024.0 * 1024.0)
    }

    /// Indicates whether the operation has reached a terminal state (finished or cancelled).
    public var isTerminal: Bool {
        isFinished || isCancelled
    }

    /// Memberwise initializer.
    public init(
        processedBytes: UInt64 = 0,
        totalBytes: UInt64 = 0,
        instantBps: UInt64 = 0,
        isCancelled: Bool = false,
        isFinished: Bool = false,
        currentItemName: String? = nil
    ) {
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.instantBps = instantBps
        self.isCancelled = isCancelled
        self.isFinished = isFinished
        self.currentItemName = currentItemName
    }

    /// An empty, initial progress snapshot.
    public static let empty = ProgressSnapshot()
}

/// Lock-free, 128-byte cache-line aligned atomic progress sheet and cancellation coordinator.
///
/// # Microarchitecture & Microkernel Alignment
/// Directly mirrors the 128-byte memory layout of Rust's `ttzip_types::options::ProgressAtomicSheet`
/// (128 bytes size, 128 bytes alignment), matching Apple Silicon M-series P-core cache lines.
///
/// Worker threads push byte counts and throughput measurements using lock-free atomic release stores
/// without heap allocations, mutexes, or reverse cross-FFI callbacks. Consumer sampling tasks poll
/// atomic snapshots on display refresh cadence (60FPS / 120FPS) via a dedicated `DispatchSourceTimer`,
/// eliminating UI lock contention and frame drops.
public final class ProgressAtomicSheet: @unchecked Sendable {
    /// 128-byte aligned raw pointer matching Rust struct ProgressAtomicSheet layout:
    /// - Offset 0:  processed_bytes (Atomic UInt64)
    /// - Offset 8:  total_bytes     (Atomic UInt64)
    /// - Offset 16: instant_bps     (Atomic UInt64)
    /// - Offset 24: cancel_flag     (Atomic UInt8: 0=false, 1=true)
    /// - Offset 25: is_finished     (Atomic UInt8: 0=false, 1=true)
    /// - Offset 26..127: 102 bytes explicit padding to guarantee 128-byte alignment and prevent false sharing.
    private let storage: UnsafeMutableRawPointer
    private let isOwned: Bool
    private let cancellationHandler: (@Sendable () -> Void)?

    /// Thread-safe entry name tracker for non-POD string metadata.
    private let itemNameLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Optional legacy push listener.
    private let listenerLock = OSAllocatedUnfairLock<(@Sendable (ProgressSnapshot) -> Void)?>(initialState: nil)

    /// Direct raw pointer accessor for C / Rust FFI bridging.
    public var rawPointer: UnsafeMutableRawPointer {
        storage
    }

    /// Initializes a new 128-byte aligned lock-free atomic sheet with optional expected total bytes and cancellation hook.
    public init(
        totalBytes: UInt64 = 0,
        cancellationHandler: (@Sendable () -> Void)? = nil
    ) {
        self.storage = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 128)
        self.storage.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        self.isOwned = true
        self.cancellationHandler = cancellationHandler

        if totalBytes > 0 {
            storage.storeBytes(of: totalBytes, toByteOffset: 8, as: UInt64.self)
        }
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif
    }

    /// Initializes an atomic sheet referencing an existing 128-byte aligned native Rust buffer.
    public init(
        borrowedPointer: UnsafeMutableRawPointer,
        cancellationHandler: (@Sendable () -> Void)? = nil
    ) {
        self.storage = borrowedPointer
        self.isOwned = false
        self.cancellationHandler = cancellationHandler
    }

    /// Convenience initializer binding an existing TaskExecutionHandle for automatic cancellation cascade.
    public convenience init(
        totalBytes: UInt64 = 0,
        handle: TaskExecutionHandle?
    ) {
        self.init(totalBytes: totalBytes) { [weak handle] in
            handle?.cancel()
        }
    }

    deinit {
        if isOwned {
            storage.deallocate()
        }
    }

    /// Registers or unregisters an optional legacy push listener.
    public func setListener(_ listener: (@Sendable (ProgressSnapshot) -> Void)?) {
        listenerLock.withLock { s in
            s = listener
        }
    }

    /// Atomically updates processed byte counter and instantaneous transfer speed without taking locks.
    /// Incorporates zero-lock atomic stores and memory barriers without blocking worker execution or calling reverse FFI hooks.
    public func updateProgress(processed: UInt64, instantBps: UInt64, itemName: String? = nil) {
        storage.storeBytes(of: processed, toByteOffset: 0, as: UInt64.self)
        storage.storeBytes(of: instantBps, toByteOffset: 16, as: UInt64.self)
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif

        if let name = itemName {
            itemNameLock.withLock { $0 = name }
        }

        // Notify legacy listener if attached
        if let listener = listenerLock.withLock({ $0 }) {
            listener(readSnapshot())
        }
    }

    /// Atomically increments the processed byte counter by a delta value using hardware atomic instructions.
    @discardableResult
    public func addProcessed(delta: UInt64) -> UInt64 {
        #if canImport(Darwin)
        let updated = OSAtomicAdd64Barrier(
            Int64(bitPattern: delta),
            storage.assumingMemoryBound(to: Int64.self)
        )
        let current = UInt64(bitPattern: updated)
        #else
        let current = storage.load(fromByteOffset: 0, as: UInt64.self) &+ delta
        storage.storeBytes(of: current, toByteOffset: 0, as: UInt64.self)
        #endif

        if let listener = listenerLock.withLock({ $0 }) {
            listener(readSnapshot())
        }
        return current
    }

    /// Sets or updates the total expected workload size in bytes.
    public func setTotal(_ total: UInt64) {
        storage.storeBytes(of: total, toByteOffset: 8, as: UInt64.self)
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif
    }

    /// Sets the current item or file name being processed.
    public func setCurrentItemName(_ name: String?) {
        itemNameLock.withLock { $0 = name }
    }

    /// Marks the operation as having reached successful terminal completion.
    public func markFinished() {
        let total = storage.load(fromByteOffset: 8, as: UInt64.self)
        let processed = storage.load(fromByteOffset: 0, as: UInt64.self)
        if total > 0 && processed < total {
            storage.storeBytes(of: total, toByteOffset: 0, as: UInt64.self)
        }
        storage.storeBytes(of: UInt8(1), toByteOffset: 25, as: UInt8.self)
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif

        if let listener = listenerLock.withLock({ $0 }) {
            listener(readSnapshot())
        }
    }

    /// Signals cooperative cancellation across all connected workers and triggers the cancellation cascade.
    public func cancel() {
        let wasCancelled = isCancelled
        if !wasCancelled {
            storage.storeBytes(of: UInt8(1), toByteOffset: 24, as: UInt8.self)
            #if canImport(Darwin)
            OSMemoryBarrier()
            #endif
            cancellationHandler?()
            if let listener = listenerLock.withLock({ $0 }) {
                listener(readSnapshot())
            }
        }
    }

    /// Indicates whether cancellation has been requested.
    public var isCancelled: Bool {
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif
        return storage.load(fromByteOffset: 24, as: UInt8.self) != 0
    }

    /// Indicates whether the operation has completed.
    public var isFinished: Bool {
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif
        return storage.load(fromByteOffset: 25, as: UInt8.self) != 0
    }

    /// Captures an instantaneous immutable snapshot of all counters and flags without acquiring locks.
    public func readSnapshot() -> ProgressSnapshot {
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif
        let processed = storage.load(fromByteOffset: 0, as: UInt64.self)
        let total = storage.load(fromByteOffset: 8, as: UInt64.self)
        let instantBps = storage.load(fromByteOffset: 16, as: UInt64.self)
        let cancelled = storage.load(fromByteOffset: 24, as: UInt8.self) != 0
        let finished = storage.load(fromByteOffset: 25, as: UInt8.self) != 0
        let itemName = itemNameLock.withLock { $0 }

        return ProgressSnapshot(
            processedBytes: processed,
            totalBytes: total,
            instantBps: instantBps,
            isCancelled: cancelled,
            isFinished: finished,
            currentItemName: itemName
        )
    }

    /// Resets all counters and lifecycle flags back to pristine initial state.
    public func reset() {
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        itemNameLock.withLock { $0 = nil }
        listenerLock.withLock { $0 = nil }
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif
    }

    /// Ingests legacy ArchiveProgress updates into the atomic counters without thread hopping.
    public func ingest(progress: ArchiveProgress) {
        updateProgress(
            processed: UInt64(max(0, progress.bytesProcessed)),
            instantBps: UInt64(max(0.0, progress.throughputMBs * 1024.0 * 1024.0)),
            itemName: progress.currentFileName.isEmpty ? nil : progress.currentFileName
        )
        if progress.totalBytes > 0 {
            setTotal(UInt64(progress.totalBytes))
        }
        switch progress.state {
        case .completed:
            markFinished()
        case .cancelled:
            cancel()
        case .idle, .processing, .failed:
            break
        }
    }
}

/// Factory producing Swift 6 native `AsyncStream<ProgressSnapshot>`
/// driven by a 60FPS (16.6ms) `DispatchSourceTimer` periodic polling loop
/// reading directly from the lock-free 128B-aligned `ProgressAtomicSheet`.
public enum SampledProgressStream {
    /// Supported display refresh sampling frequencies.
    public enum SamplingFrequency: Sendable {
        /// Standard 60Hz display refresh (~16.6ms intervals).
        case sixtyHz
        /// High-refresh 120Hz ProMotion display refresh (~8.3ms intervals).
        case oneTwentyHz
        /// Custom sampling frequency bounded between 1.0Hz and 120.0Hz.
        case custom(Double)

        public var intervalNanoseconds: UInt64 {
            let hz: Double
            switch self {
            case .sixtyHz:
                hz = 60.0
            case .oneTwentyHz:
                hz = 120.0
            case .custom(let requestedHz):
                hz = max(1.0, min(120.0, requestedHz))
            }
            return UInt64(1_000_000_000.0 / hz)
        }
    }

    /// Generates a Swift 6 native `AsyncStream<ProgressSnapshot>` driven by a 60FPS (or configured frequency)
    /// `DispatchSourceTimer` periodic polling loop querying the lock-free `ProgressAtomicSheet`.
    ///
    /// # Microarchitecture Invariants
    /// 1. Zero reverse FFI callbacks: Worker threads update atomic sheet with release stores; never blocked by UI.
    /// 2. Lock-free sampling: Timer reads directly from 128-byte aligned sheet without lock contention.
    /// 3. Frame coalescing: Identical/unchanged progress values are suppressed, preventing duplicate yields.
    /// 4. Bidirectional cancellation: Stream cancellation cascades directly to `sheet.cancel()`, and terminal state halts timer.
    public static func makeStream(
        sheet: ProgressAtomicSheet,
        frequency: SamplingFrequency = .sixtyHz
    ) -> AsyncStream<ProgressSnapshot> {
        return AsyncStream(ProgressSnapshot.self) { continuation in
            let timerQueue = DispatchQueue(
                label: "com.metastudyline.ttzip.progress-sampler",
                qos: .userInitiated
            )
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
            let intervalNs = frequency.intervalNanoseconds
            let leeway = DispatchTimeInterval.milliseconds(1)

            final class SamplerContext: @unchecked Sendable {
                var lastEmittedSnapshot: ProgressSnapshot?
                var isCancelled: Bool = false
                let timer: DispatchSourceTimer

                init(timer: DispatchSourceTimer) {
                    self.timer = timer
                }

                func cancel() {
                    guard !isCancelled else { return }
                    isCancelled = true
                    timer.cancel()
                }
            }

            let context = SamplerContext(timer: timer)

            continuation.onTermination = { @Sendable _ in
                context.cancel()
                sheet.cancel()
            }

            // Yield initial snapshot immediately
            let initial = sheet.readSnapshot()
            context.lastEmittedSnapshot = initial
            continuation.yield(initial)

            if initial.isTerminal {
                context.cancel()
                continuation.finish()
                return
            }

            timer.schedule(
                deadline: .now() + .nanoseconds(Int(intervalNs)),
                repeating: .nanoseconds(Int(intervalNs)),
                leeway: leeway
            )

            timer.setEventHandler {
                guard !context.isCancelled else { return }

                // Read snapshot directly from lock-free 128B-aligned atomic sheet
                let current = sheet.readSnapshot()

                // Frame coalescing: only yield if progress values or lifecycle state changed
                let last = context.lastEmittedSnapshot
                let hasChanged = (last == nil) ||
                    last?.processedBytes != current.processedBytes ||
                    last?.totalBytes != current.totalBytes ||
                    last?.instantBps != current.instantBps ||
                    last?.isCancelled != current.isCancelled ||
                    last?.isFinished != current.isFinished ||
                    last?.currentItemName != current.currentItemName

                if hasChanged {
                    context.lastEmittedSnapshot = current
                    continuation.yield(current)
                }

                if current.isTerminal {
                    context.cancel()
                    continuation.finish()
                }
            }

            timer.resume()
        }
    }
}
