// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Global task lifecycle coordinator bridging Swift concurrency and UniFFI cooperative cancellation tokens.
@MainActor
public final class ArchiveTaskCoordinator {
    public static let shared = ArchiveTaskCoordinator()

    private var activeHandles: [UUID: TaskExecutionHandle] = [:]

    private init() {}

    /// Registers a new active task and returns its execution handle.
    @discardableResult
    public func registerTask(
        id: UUID = UUID()
    ) -> TaskExecutionHandle {
        let handle = TaskExecutionHandle()
        activeHandles[id] = handle
        return handle
    }

    /// Retrieves an active execution handle by ID.
    public func handle(for id: UUID) -> TaskExecutionHandle? {
        return activeHandles[id]
    }

    /// Cooperatively cancels the execution associated with the given task ID.
    public func cancelTask(id: UUID) {
        if let handle = activeHandles[id] {
            handle.cancel()
        }
    }

    /// Pauses execution for the given task ID.
    public func pauseTask(id: UUID) {
        activeHandles[id]?.pause()
    }

    /// Resumes execution for the given task ID.
    public func resumeTask(id: UUID) {
        activeHandles[id]?.resume()
    }

    /// Unregisters and releases the task handle upon completion or termination.
    public func unregisterTask(id: UUID) {
        activeHandles.removeValue(forKey: id)
    }

    /// Returns the number of currently active task handles.
    public var activeCount: Int {
        return activeHandles.count
    }
}
