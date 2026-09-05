// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

extension ArchiveExplorerView {
    
    // MARK: - In-Place Live Editing & Mutation Operations
    
    func openSelectedInExternalEditor(_ entry: ArchiveEntry) {
        Task {
            do {
                let session = try await InPlaceArchiveMutationEngine.shared.beginEditingSession(
                    archivePath: archivePath,
                    entryPath: entry.path,
                    password: password
                )
                
                await MainActor.run {
                    self.activeEditSessions[session.sessionId] = session
                    self.syncStatusMessage = "Watching '\(entry.name)' for external changes..."
                }
                
                // Open in default macOS application
                NSWorkspace.shared.open(URL(fileURLWithPath: session.stagedFilePath))
                
                // Start auto sync
                InPlaceArchiveMutationEngine.shared.startWatchingAndAutoSync(
                    session: session,
                    password: password
                ) { updatedSession, result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            self.syncStatusMessage = "⚡️ Saved & updated '\(entry.name)' in archive"
                            self.reloadArchiveEntries()
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if self.syncStatusMessage?.contains(entry.name) == true {
                                self.syncStatusMessage = nil
                            }
                        case .failure(let err):
                            self.syncStatusMessage = "❌ Sync failed: \(err.localizedDescription)"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.syncStatusMessage = "Error opening: \(error.localizedDescription)"
                }
            }
        }
    }
    
    final class PathAccumulator: @unchecked Sendable {
        private var paths: [String] = []
        private let lock = NSLock()
        
        func append(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }
        
        var allPaths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }
    
    func handleDropFiles(providers: [NSItemProvider]) {
        let accumulator = PathAccumulator()
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, url.isFileURL {
                    accumulator.append(url.path)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            let paths = accumulator.allPaths
            guard !paths.isEmpty else { return }
            self.isMutatingArchive = true
            self.syncStatusMessage = "Adding \(paths.count) items into archive..."
            
            Task {
                do {
                    try await InPlaceArchiveMutationEngine.shared.addFilesToArchive(
                        archivePath: self.archivePath,
                        sourceFilePaths: paths,
                        destinationVirtualFolder: nil,
                        password: self.password
                    )
                    await MainActor.run {
                        self.isMutatingArchive = false
                        self.syncStatusMessage = "Archive updated successfully"
                        self.reloadArchiveEntries()
                    }
                } catch {
                    await MainActor.run {
                        self.isMutatingArchive = false
                        self.syncStatusMessage = "Failed to add items: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    func replaceSelectedEntry(_ entry: ArchiveEntry) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Replace"
        if panel.runModal() == .OK, let chosenURL = panel.url {
            isMutatingArchive = true
            syncStatusMessage = "Replacing '\(entry.name)'..."
            Task {
                do {
                    try await InPlaceMutationCoordinator.shared.replaceEntry(
                        archivePath: archivePath,
                        entryPath: entry.path,
                        sourceFilePath: chosenURL.path,
                        password: password
                    )
                    await MainActor.run {
                        self.isMutatingArchive = false
                        self.syncStatusMessage = "Replaced '\(entry.name)'"
                        self.reloadArchiveEntries()
                    }
                } catch {
                    await MainActor.run {
                        self.isMutatingArchive = false
                        self.syncStatusMessage = "Failed to replace: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    func extractSelectedEntry(_ entry: ArchiveEntry) {
        let destDir = (archivePath as NSString).deletingLastPathComponent
        Task {
            try? await TTZipEngineFacade.shared.extractSingleEntry(
                archivePath: archivePath,
                entryPath: entry.path,
                destinationDir: destDir,
                password: password
            )
            NSWorkspace.shared.selectFile((destDir as NSString).appendingPathComponent(entry.name), inFileViewerRootedAtPath: "")
        }
    }
    
    func deleteSelectedEntry(_ entry: ArchiveEntry) {
        isMutatingArchive = true
        syncStatusMessage = "Deleting '\(entry.name)' from archive..."
        
        Task {
            do {
                try await InPlaceMutationCoordinator.shared.deleteEntries(
                    archivePath: archivePath,
                    entryPaths: [entry.path],
                    password: password
                )
                await MainActor.run {
                    self.isMutatingArchive = false
                    self.syncStatusMessage = "Deleted '\(entry.name)'"
                    self.selectedEntryID = nil
                    self.reloadArchiveEntries()
                }
            } catch {
                await MainActor.run {
                    self.isMutatingArchive = false
                    self.syncStatusMessage = "Failed to delete: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func reloadArchiveEntries() {
        Task {
            await InPlaceMutationCoordinator.shared.invalidateAndRefresh(archivePath: archivePath)
            let reader = ArchiveReader()
            if let newEntries = try? await reader.inspect(archivePath: archivePath, password: password) {
                await MainActor.run {
                    self.entries = newEntries
                    self.treeStore.updateEntries(newEntries, force: true)
                }
            }
        }
    }
    
    func moveSelectionUp() {
        if !searchText.isEmpty {
            let currentList = treeStore.filteredEntries
            guard let currentID = selectedEntryID, let idx = currentList.firstIndex(where: { $0.id == currentID || $0.path == currentID }) else {
                if let first = currentList.first {
                    selectedEntryID = first.id
                }
                return
            }
            if idx > 0 {
                selectedEntryID = currentList[idx - 1].id
            }
        } else {
            NotificationCenter.default.post(name: .archiveExplorerMoveUp, object: nil)
        }
    }
    
    func moveSelectionDown() {
        if !searchText.isEmpty {
            let currentList = treeStore.filteredEntries
            guard let currentID = selectedEntryID, let idx = currentList.firstIndex(where: { $0.id == currentID || $0.path == currentID }) else {
                if let first = currentList.first {
                    selectedEntryID = first.id
                }
                return
            }
            if idx < currentList.count - 1 {
                selectedEntryID = currentList[idx + 1].id
            }
        } else {
            NotificationCenter.default.post(name: .archiveExplorerMoveDown, object: nil)
        }
    }
    
    func extractSelectedForPreview(entryID: String?) {
        previewTask?.cancel()
        
        guard let entryID = entryID,
              let entry = entries.first(where: { $0.id == entryID || $0.path == entryID }),
              !entry.isDirectory else {
            previewFileURL = nil
            isExtractingTemp = false
            return
        }
        
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let isMedia = MediaPreviewFactory.videoExtensions.contains(ext) || MediaPreviewFactory.audioExtensions.contains(ext)
        
        isExtractingTemp = true
        
        if isMedia {
            previewTask = Task {
                do {
                    let cachedURL: URL
                    if let url = try? await ArchiveMediaCachePool.shared.getOrExtractMedia(
                        archivePath: self.archivePath,
                        entryPath: entry.path,
                        uncompressedSize: entry.uncompressedSize,
                        password: self.password
                    ) {
                        cachedURL = url
                    } else if let data = try await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
                        archivePath: self.archivePath,
                        entryPath: entry.path,
                        password: self.password
                    ) {
                        cachedURL = try ArchiveMediaCachePool.shared.stageData(data, fileName: entry.name)
                    } else {
                        throw ArchiveError.fileNotFound
                    }
                    
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.previewFileURL = cachedURL
                        self.isExtractingTemp = false
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.previewFileURL = nil
                        self.isExtractingTemp = false
                    }
                }
            }
        } else {
            let vfsURL = TTZipArchiveVfsProvider.shared.vfsURL(
                archivePath: archivePath,
                password: password,
                entryPath: entry.path
            )
            let targetArchiveId = TTZipArchiveVfsProvider.makeArchiveId(from: archivePath)
            
            previewTask = Task {
                do {
                    if let data = try await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
                        archivePath: archivePath,
                        entryPath: entry.path,
                        password: password
                    ) {
                        guard !Task.isCancelled else { return }
                        TTZipArchiveVfsProvider.shared.cacheEntryData(
                            archiveId: targetArchiveId,
                            entryPath: entry.path,
                            data: data
                        )
                        await MainActor.run {
                            self.previewFileURL = vfsURL
                            self.isExtractingTemp = false
                        }
                    } else {
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            self.previewFileURL = nil
                            self.isExtractingTemp = false
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.previewFileURL = nil
                        self.isExtractingTemp = false
                    }
                }
            }
        }
    }
    
    func formatBytes(_ bytes: Int64) -> String {
        return ByteCountFormatterCache.string(fromByteCount: bytes)
    }
}
