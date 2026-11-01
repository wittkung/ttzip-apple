// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

extension AppViewState {
    // MARK: - Command Undo / Redo
    
    public func refreshUndoRedoState() async {
        self.taskState.canUndo = await historyManager.canUndo
        self.taskState.canRedo = await historyManager.canRedo
        self.taskState.lastCommandDescription = await historyManager.undoHistoryDescriptions.last
    }
    
    public func updateUndoRedoState() {
        Task { @MainActor [weak self] in
            await self?.refreshUndoRedoState()
        }
    }
    
    @discardableResult
    public func executeCommand(_ command: ArchiveCommandProtocol) async throws -> CommandResult {
        guard !self.taskState.isLoading else {
            throw CommandError.invalidState(reason: "Another task is in progress.")
        }
        // MM49: the command holds its own busy identity while it awaits. Other operations may
        // join the window in the meantime; the command releases only its own identity.
        let busyOperationID = self.taskState.beginBusyOperation()
        defer {
            self.taskState.endBusyOperation(id: busyOperationID)
        }
        do {
            let result = try await historyManager.execute(command: command)
            self.taskState.statusMessage = "Command succeeded: [\(command.description)]"
            await refreshUndoRedoState()
            if let um = self.undoManager {
                um.registerUndo(withTarget: self) { $0.performUndo() }
                um.setActionName(command.description)
            }
            return result
        } catch {
            self.taskState.statusMessage = "Command failed: \(error.localizedDescription)"
            await refreshUndoRedoState()
            throw error
        }
    }
    
    public func performUndo() {
        if let um = self.undoManager {
            let actionDesc = self.taskState.lastCommandDescription ?? ""
            um.registerUndo(withTarget: self) { $0.performRedo() }
            if !actionDesc.isEmpty {
                um.setActionName(actionDesc)
            }
        }
        Task { @MainActor [weak self] in
            await self?.performUndoAsync()
        }
    }
    
    public func performUndoAsync() async {
        guard !self.taskState.isLoading else { return }
        // MM49: see `executeCommand` — the undo holds its own busy identity.
        let busyOperationID = self.taskState.beginBusyOperation()
        defer {
            self.taskState.endBusyOperation(id: busyOperationID)
        }
        guard await historyManager.canUndo else { return }
        do {
            if let res = try await historyManager.undo() {
                self.taskState.statusMessage = "Undone: \(res.message)"
            }
        } catch {
            self.taskState.statusMessage = "Undo failed: \(error.localizedDescription)"
        }
        await self.refreshUndoRedoState()
    }
    
    public func performRedo() {
        if let um = self.undoManager {
            let actionDesc = self.taskState.lastCommandDescription ?? ""
            um.registerUndo(withTarget: self) { $0.performUndo() }
            if !actionDesc.isEmpty {
                um.setActionName(actionDesc)
            }
        }
        Task { @MainActor [weak self] in
            await self?.performRedoAsync()
        }
    }
    
    public func performRedoAsync() async {
        guard !self.taskState.isLoading else { return }
        // MM49: see `executeCommand` — the redo holds its own busy identity.
        let busyOperationID = self.taskState.beginBusyOperation()
        defer {
            self.taskState.endBusyOperation(id: busyOperationID)
        }
        guard await historyManager.canRedo else { return }
        do {
            if let res = try await historyManager.redo() {
                self.taskState.statusMessage = "Redone: \(res.message)"
            }
        } catch {
            self.taskState.statusMessage = "Redo failed: \(error.localizedDescription)"
        }
        await self.refreshUndoRedoState()
    }

}
