// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore

extension AppViewState {
    // MARK: - Task State Control
    
    public func pauseCurrentTask() {
        if let id = self.currentTaskID {
            ArchiveTaskCoordinator.shared.pauseTask(id: id)
        }
        self.canPauseTask = false
        self.canResumeTask = true
        self.taskStateName = "Paused"
    }
    
    public func resumeCurrentTask() {
        if let id = self.currentTaskID {
            ArchiveTaskCoordinator.shared.resumeTask(id: id)
        }
        self.canPauseTask = true
        self.canResumeTask = false
        self.taskStateName = "Processing"
    }
    
    public func cancelCurrentTask() {
        if let id = self.currentTaskID {
            ArchiveTaskCoordinator.shared.cancelTask(id: id)
        }
        self.canPauseTask = false
        self.canResumeTask = false
        self.canCancelTask = false
        self.taskStateName = "Cancelled"
    }
    
    public func updateTaskStateUI() {
        self.taskStateName = "Idle"
        self.canPauseTask = false
        self.canResumeTask = false
        self.canCancelTask = false
        self.currentTaskID = nil
    }
}
