// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

extension AppViewState {
    // MARK: - Task State Control
    
    public func pauseCurrentTask() {
        if let id = self.taskState.currentTaskID {
            ArchiveTaskCoordinator.shared.pauseTask(id: id)
        }
        self.taskState.canPauseTask = false
        self.taskState.canResumeTask = true
        self.taskState.taskStateName = "Paused"
    }
    
    public func resumeCurrentTask() {
        if let id = self.taskState.currentTaskID {
            ArchiveTaskCoordinator.shared.resumeTask(id: id)
        }
        self.taskState.canPauseTask = true
        self.taskState.canResumeTask = false
        self.taskState.taskStateName = "Processing"
    }
    
    public func cancelCurrentTask() {
        if let id = self.taskState.currentTaskID {
            ArchiveTaskCoordinator.shared.cancelTask(id: id)
        }
        self.taskState.canPauseTask = false
        self.taskState.canResumeTask = false
        self.taskState.canCancelTask = false
        self.taskState.taskStateName = "Cancelled"
    }
    
    public func updateTaskStateUI() {
        self.taskState.taskStateName = "Idle"
        self.taskState.canPauseTask = false
        self.taskState.canResumeTask = false
        self.taskState.canCancelTask = false
        self.taskState.currentTaskID = nil
    }
}
