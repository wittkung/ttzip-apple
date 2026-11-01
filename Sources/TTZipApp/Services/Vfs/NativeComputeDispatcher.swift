// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import TTZipCore

/// Opaque pointer handle representing C-ABI `ttdevice_cancel_token_t`.
public typealias TtDeviceCancelToken = OpaquePointer

private typealias CancelTokenCreateFunc = @convention(c) () -> OpaquePointer?
private typealias CancelTokenDestroyFunc = @convention(c) (OpaquePointer) -> Void
private typealias CancelTokenCancelFunc = @convention(c) (OpaquePointer) -> Void
private typealias CancelTokenIsCancelledFunc = @convention(c) (OpaquePointer) -> UInt8

private let _cabiCancelTokenCreate: CancelTokenCreateFunc? = {
    let handle = dlopen(nil as String?, RTLD_LAZY)
    guard let sym = dlsym(handle, "ttdevice_cancel_token_create") else { return nil }
    return unsafeBitCast(sym, to: CancelTokenCreateFunc.self)
}()

private let _cabiCancelTokenDestroy: CancelTokenDestroyFunc? = {
    let handle = dlopen(nil as String?, RTLD_LAZY)
    guard let sym = dlsym(handle, "ttdevice_cancel_token_destroy") else { return nil }
    return unsafeBitCast(sym, to: CancelTokenDestroyFunc.self)
}()

private let _cabiCancelTokenCancel: CancelTokenCancelFunc? = {
    let handle = dlopen(nil as String?, RTLD_LAZY)
    guard let sym = dlsym(handle, "ttdevice_cancel_token_cancel") else { return nil }
    return unsafeBitCast(sym, to: CancelTokenCancelFunc.self)
}()

private let _cabiCancelTokenIsCancelled: CancelTokenIsCancelledFunc? = {
    let handle = dlopen(nil as String?, RTLD_LAZY)
    guard let sym = dlsym(handle, "ttdevice_cancel_token_is_cancelled") else { return nil }
    return unsafeBitCast(sym, to: CancelTokenIsCancelledFunc.self)
}()

/// Safe RAII wrapper around C-ABI `ttdevice_cancel_token_t` with fallback atomic state.
/// Propagates Swift cooperative cancellation across the FFI boundary to long-running Rust/C tasks.
public final class FfiCancelToken: @unchecked Sendable {
    public let rawToken: TtDeviceCancelToken?
    private let fallbackCancelled = OSAllocatedUnfairLock(initialState: false)
    private let isDestroyed = OSAllocatedUnfairLock(initialState: false)

    public init() {
        self.rawToken = _cabiCancelTokenCreate?()
    }

    /// Signals cancellation across the FFI boundary.
    public func cancel() {
        fallbackCancelled.withLock { $0 = true }
        if let token = rawToken {
            _cabiCancelTokenCancel?(token)
        }
    }

    /// Returns true if cancellation has been requested.
    public var isCancelled: Bool {
        if let token = rawToken, let fn = _cabiCancelTokenIsCancelled {
            return fn(token) != 0 || fallbackCancelled.withLock({ $0 })
        }
        return fallbackCancelled.withLock { $0 }
    }

    deinit {
        let shouldDestroy = isDestroyed.withLock { destroyed -> Bool in
            guard !destroyed else { return false }
            destroyed = true
            return true
        }
        if shouldDestroy, let token = rawToken {
            _cabiCancelTokenDestroy?(token)
        }
    }
}

// MARK: - NativeComputeDispatcher Cooperative FFI Cancellation Extension

extension NativeComputeDispatcher {
    /// Dispatches compute workload wiring Swift `Task.isCancelled` across FFI via C-ABI cancel token.
    /// When Swift Task cancellation occurs, the underlying atomic flag in the C-ABI cancel token
    /// is immediately asserted, notifying Rust loops to break early (e.g. every 128 items).
    public func dispatchFfiCompute<T: Sendable>(
        qos: ExecutionQoSProfile = .userInitiated,
        cancellationPolicy: CancellationCompletionPolicy = .detachCallerOnCancel,
        _ work: @escaping @Sendable (FfiCancelToken) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let token = FfiCancelToken()

        return try await withTaskCancellationHandler {
            try await dispatchCompute(
                qos: qos,
                cancellationPolicy: cancellationPolicy
            ) { (_: OSAllocatedUnfairLock<Bool>) in
                if token.isCancelled {
                    throw CancellationError()
                }
                return try work(token)
            }
        } onCancel: {
            token.cancel()
        }
    }
}

/// Static ergonomic convenience helpers for cooperative FFI compute dispatch.
public enum VfsComputeDispatcher {
    public static func dispatchFfiCompute<T: Sendable>(
        qos: ExecutionQoSProfile = .userInitiated,
        cancellationPolicy: CancellationCompletionPolicy = .detachCallerOnCancel,
        _ work: @escaping @Sendable (FfiCancelToken) throws -> T
    ) async throws -> T {
        try await NativeComputeDispatcher.shared.dispatchFfiCompute(
            qos: qos,
            cancellationPolicy: cancellationPolicy,
            work
        )
    }
}
