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

extension AppViewState {
    // MARK: - Command Undo / Redo
    
    public func refreshUndoRedoState() async {
        self.canUndo = await historyManager.canUndo
        self.canRedo = await historyManager.canRedo
        self.lastCommandDescription = await historyManager.undoHistoryDescriptions.last
    }
    
    public func updateUndoRedoState() {
        Task { @MainActor [weak self] in
            await self?.refreshUndoRedoState()
        }
    }
    
    @discardableResult
    public func executeCommand(_ command: ArchiveCommandProtocol) async throws -> CommandResult {
        guard !self.isLoading else {
            throw CommandError.invalidState(reason: "Another task is in progress.")
        }
        self.isLoading = true
        defer {
            self.isLoading = false
        }
        do {
            let result = try await historyManager.execute(command: command)
            self.statusMessage = "Command succeeded: [\(command.description)]"
            await refreshUndoRedoState()
            return result
        } catch {
            self.statusMessage = "Command failed: \(error.localizedDescription)"
            await refreshUndoRedoState()
            throw error
        }
    }
    
    public func performUndo() {
        Task { @MainActor [weak self] in
            await self?.performUndoAsync()
        }
    }
    
    public func performUndoAsync() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer {
            self.isLoading = false
        }
        guard await historyManager.canUndo else { return }
        do {
            if let res = try await historyManager.undo() {
                self.statusMessage = "Undone: \(res.message)"
            }
        } catch {
            self.statusMessage = "Undo failed: \(error.localizedDescription)"
        }
        await self.refreshUndoRedoState()
    }
    
    public func performRedo() {
        Task { @MainActor [weak self] in
            await self?.performRedoAsync()
        }
    }
    
    public func performRedoAsync() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer {
            self.isLoading = false
        }
        guard await historyManager.canRedo else { return }
        do {
            if let res = try await historyManager.redo() {
                self.statusMessage = "Redone: \(res.message)"
            }
        } catch {
            self.statusMessage = "Redo failed: \(error.localizedDescription)"
        }
        await self.refreshUndoRedoState()
    }

}
