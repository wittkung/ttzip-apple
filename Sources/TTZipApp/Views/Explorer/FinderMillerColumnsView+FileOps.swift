// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

extension FinderMillerColumnsView {
    
    func createNewFolder(in dir: URL, name: String) {
        guard !isArchiveLocation(dir) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled Folder" : trimmed
        var targetURL = dir.appendingPathComponent(baseName)
        
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = dir.appendingPathComponent("\(baseName) \(counter)")
            counter += 1
        }
        
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
            cachedColumnItems.removeAll()
            refreshKey = UUID()
            let createdItem = DiskItemInfo(url: targetURL)
            selectedItem = createdItem
            activeViewModel?.selectionState.select(createdItem)
            onSelectItem?(createdItem)
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
        } catch {
            TTLogger.error("Failed to create directory: \(error)")
        }
    }
    
    func createNewFile(in dir: URL, name: String) {
        guard !isArchiveLocation(dir) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled.txt" : trimmed
        
        let pathExtension = (baseName as NSString).pathExtension
        let nameWithoutExt = (baseName as NSString).deletingPathExtension
        
        var targetURL = dir.appendingPathComponent(baseName)
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let nextName = pathExtension.isEmpty ? "\(baseName) \(counter)" : "\(nameWithoutExt) \(counter).\(pathExtension)"
            targetURL = dir.appendingPathComponent(nextName)
            counter += 1
        }
        
        FileManager.default.createFile(atPath: targetURL.path, contents: Data(), attributes: nil)
        cachedColumnItems.removeAll()
        refreshKey = UUID()
        let createdItem = DiskItemInfo(url: targetURL)
        selectedItem = createdItem
        activeViewModel?.selectionState.select(createdItem)
        onSelectItem?(createdItem)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
    }
    
    // MARK: - Clipboard File Operations
    
    /// Copies currently selected files or directory to the system file clipboard.
    func copySelectedFiles() {
        let targets = resolveSelectedTargetURLs()
        guard !targets.isEmpty else { return }
        if targets.contains(where: { isVirtualItemURL($0) }) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                targets.map { parseVirtualURL($0.absoluteString).subpath }.joined(separator: "\n"),
                forType: .string
            )
            return
        }
        FileClipboardStore.shared.copy(urls: targets)
    }
    
    /// Cuts currently selected files or directory to the system file clipboard.
    func cutSelectedFiles() {
        let targets = resolveSelectedTargetURLs()
        guard !targets.isEmpty else { return }
        guard !targets.contains(where: { isVirtualItemURL($0) }) else { return }
        FileClipboardStore.shared.cut(urls: targets)
    }
    
    /// Pastes files from the clipboard into the active directory or selected folder.
    func pasteFiles() {
        guard columnPaths.indices.contains(activeColumnIndex) else { return }
        let column = columnPaths[activeColumnIndex]
        let ownerLocation = activeViewModel?.navigationState.currentDirectory
        guard !isArchiveLocation(column),
              ownerLocation.map({ !isArchiveLocation($0) }) != false,
              let targetDir = Self.physicalPasteDestination(
                ownerLocation: ownerLocation, activeColumn: column, selectedItem: selectedItem
              ) else { return }
        FileClipboardStore.shared.paste(to: targetDir)
    }

    /// Resolves a physical paste from the active column and its current selection only.
    public static func physicalPasteDestination(
        ownerLocation: URL?, activeColumn: URL, selectedItem: DiskItemInfo?
    ) -> URL? {
        guard MillerColumnItemRowView.isPhysicalDropSource(activeColumn),
              ownerLocation.map(MillerColumnItemRowView.isPhysicalDropSource) != false else { return nil }
        guard let selectedItem else { return activeColumn }
        let selected = URL(string: selectedItem.path).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(fileURLWithPath: selectedItem.path, isDirectory: selectedItem.isDirectory)
        guard MillerColumnItemRowView.isPhysicalDropSource(selected) else { return nil }
        if selectedItem.isDirectory,
           selected.deletingLastPathComponent().standardizedFileURL.path == activeColumn.standardizedFileURL.path {
            return selected
        }
        return activeColumn
    }
    
    private func selectedTargetURL(_ path: String) -> URL {
        if let url = URL(string: path), url.isFileURL { return url }
        return URL(fileURLWithPath: path)
    }

    private func isVirtualItemURL(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "subpath" }) == true
    }

    /// Resolves target URLs for clipboard operations based on multi-selection or single-selection.
    func resolveSelectedTargetURLs() -> [URL] {
        if !multiSelectedPaths.isEmpty {
            return multiSelectedPaths.map { selectedTargetURL($0) }
        } else if let selectedPath = selectedPaths.compactMap({ $0.value }).last {
            return [selectedTargetURL(selectedPath)]
        }
        return []
    }
}
