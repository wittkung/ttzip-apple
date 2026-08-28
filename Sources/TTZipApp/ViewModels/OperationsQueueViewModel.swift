// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Operations queue ViewModel bridging UI views to the global ArchiveOperationsQueueCenter singleton.
@Observable
@MainActor
public final class OperationsQueueViewModel {
    public var center: ArchiveOperationsQueueCenter {
        ArchiveOperationsQueueCenter.shared
    }

    public var tasks: [QueuedArchiveOperation] {
        center.tasks
    }
    
    public var activeTasksCount: Int {
        center.activeTasksCount
    }
    
    public var overallProgress: Double {
        center.overallProgress
    }
    
    public var overallThroughputMBs: Double {
        center.overallThroughputMBs
    }
    
    public init() {}
    
    public func pauseTask(id: UUID) {
        center.pause(id: id)
    }

    public func resumeTask(id: UUID) {
        center.resume(id: id)
    }

    public func cancelTask(id: UUID) {
        center.cancel(id: id)
    }

    public func clearFinishedTasks() {
        center.clearFinishedTasks()
    }
}
