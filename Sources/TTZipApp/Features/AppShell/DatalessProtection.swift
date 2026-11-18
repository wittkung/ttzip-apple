// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation

/// Low-level Darwin kernel protection against accidental dataless file materialization.
/// Guarantees that thread operations touching evicted or cloud stubs fail fast with EDEADLK
/// instead of triggering silent on-demand cloud downloads or hanging thread pools.
public enum DatalessProtection {
    /// Executes a synchronous closure with dataless file materialization strictly disabled on the calling thread.
    /// Any kernel attempt to materialize cloud stubs will fail immediately with EDEADLK (errno 11).
    /// Restores the original thread I/O policy upon exit to maintain thread-pool cleanliness.
    @inlinable
    public static func withMaterializationDisabled<T>(_ body: () throws -> T) rethrows -> T {
        let prevPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
        defer {
            _ = setiopolicy_np(
                IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                IOPOL_SCOPE_THREAD,
                prevPolicy
            )
        }
        return try body()
    }

    /// Fast, zero-heap-allocation probe to verify whether a file or directory is dataless (evicted).
    /// Uses POSIX lstat to inspect st_flags against SF_DATALESS.
    @inlinable
    public static func isDataless(atPath path: String) -> Bool {
        var st = stat()
        if lstat(path, &st) == 0 {
            return (st.st_flags & UInt32(SF_DATALESS)) != 0
        }
        // If stat failed with EDEADLK, an ancestor directory or file is dataless and materialization was blocked
        return errno == EDEADLK
    }
}
