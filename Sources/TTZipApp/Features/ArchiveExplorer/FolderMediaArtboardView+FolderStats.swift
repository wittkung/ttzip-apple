// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation
import SwiftUI
import TTZipBenchmarkKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI

extension FolderMediaArtboardView {
    func createNewFolder() {
        let parentPath = resolvedPhysicalPath
        let inputName = newSubfolderName
        newSubfolderName = "Untitled Folder"

        Task.detached(priority: .userInitiated) {
            let parentDir = URL(fileURLWithPath: parentPath, isDirectory: true)
            let trimmed = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = trimmed.isEmpty ? "Untitled Folder" : trimmed
            var targetURL = parentDir.appendingPathComponent(baseName)
            var counter = 2
            let fm = FileManager.default
            while fm.fileExists(atPath: targetURL.path) {
                targetURL = parentDir.appendingPathComponent("\(baseName) \(counter)")
                counter += 1
            }
            do {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
                }
            } catch {
                TTLogger.shared.log(
                    level: .error,
                    category: .general,
                    message: "[FolderMediaArtboardView] Failed to create directory at \(targetURL.path): \(error)"
                )
            }
        }
    }

    func createNewFile() {
        let parentPath = resolvedPhysicalPath
        let inputName = newSubfileName
        newSubfileName = "Untitled.txt"

        Task.detached(priority: .userInitiated) {
            let parentDir = URL(fileURLWithPath: parentPath, isDirectory: true)
            let trimmed = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = trimmed.isEmpty ? "Untitled.txt" : trimmed
            let pathExtension = (baseName as NSString).pathExtension
            let nameWithoutExt = (baseName as NSString).deletingPathExtension
            var targetURL = parentDir.appendingPathComponent(baseName)
            var counter = 2
            let fm = FileManager.default
            while fm.fileExists(atPath: targetURL.path) {
                let nextName = pathExtension.isEmpty ? "\(baseName) \(counter)" : "\(nameWithoutExt) \(counter).\(pathExtension)"
                targetURL = parentDir.appendingPathComponent(nextName)
                counter += 1
            }
            let success = fm.createFile(atPath: targetURL.path, contents: Data(), attributes: nil)
            if success {
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
                }
            } else {
                TTLogger.shared.log(
                    level: .error,
                    category: .general,
                    message: "[FolderMediaArtboardView] Failed to create file at \(targetURL.path)"
                )
            }
        }
    }

    package static func calculateFolderStats(
        at targetPath: String,
        maxDepth: Int = 16,
        cancellationBox: FolderScanCancellationBox? = nil
    ) async -> (totalSize: Int64, folderCount: Int, fileCount: Int, distribution: [(category: String, count: Int, sizeBytes: Int64?)]) {
        guard case .localDirectory(let validatedURL) = FolderSummaryAnalysisCoordinator.classifyPathIdentity(rawPath: targetPath) else {
            return (0, 0, 0, [])
        }
        if Task.isCancelled || cancellationBox?.isCancelled == true {
            return (0, 0, 0, [])
        }

        let detachedTask: Task<(Int64, Int, Int, [(category: String, count: Int, sizeBytes: Int64?)]), Never> = Task.detached(priority: .utility) {
            scanDirectoryDistribution(at: validatedURL, maxDepth: maxDepth, cancellationBox: cancellationBox)
        }

        cancellationBox?.registerOnCancel {
            detachedTask.cancel()
        }

        return await detachedTask.value
    }

    nonisolated private static func scanDirectoryDistribution(
        at validatedURL: URL,
        maxDepth: Int,
        cancellationBox: FolderScanCancellationBox?
    ) -> (Int64, Int, Int, [(category: String, count: Int, sizeBytes: Int64?)]) {
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: validatedURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return (0, 0, 0, [])
        }

        var folderCount = 0
        var accumulator = FolderDistributionAccumulator()
        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled || cancellationBox?.isCancelled == true {
                break
            }
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                continue
            }
            if resourceValues.isDirectory == true && resourceValues.isSymbolicLink != true {
                folderCount += 1
                if enumerator.level >= maxDepth {
                    enumerator.skipDescendants()
                }
            } else {
                if resourceValues.isSymbolicLink == true {
                    enumerator.skipDescendants()
                }
                accumulator.addFile(at: fileURL, values: resourceValues)
            }
        }

        return (accumulator.totalSize, folderCount, accumulator.fileCount, accumulator.entries)
    }

    func calculateStats() async {
        await analysisCoordinator.requestAnalysis()
    }
}

private struct FolderDistributionAccumulator {
    private(set) var totalSize: Int64 = 0
    private(set) var fileCount = 0
    private var categories: [String: (count: Int, sizeBytes: Int64?)] = [:]

    mutating func addFile(at url: URL, values: URLResourceValues) {
        fileCount += 1
        let ext = url.pathExtension.lowercased()
        let category = ext.isEmpty ? "other" : ext
        var entry = categories[category] ?? (count: 0, sizeBytes: 0)
        entry.count += 1
        if values.isSymbolicLink == true {
            entry.sizeBytes = nil
        } else if let rawSize = values.fileSize, rawSize >= 0 {
            if let previous = entry.sizeBytes {
                let (sum, overflow) = previous.addingReportingOverflow(Int64(rawSize))
                entry.sizeBytes = overflow ? nil : sum
            }
            let (total, totalOverflow) = totalSize.addingReportingOverflow(Int64(rawSize))
            totalSize = totalOverflow ? Int64.max : total
        } else {
            entry.sizeBytes = nil
        }
        categories[category] = entry
    }

    var entries: [(category: String, count: Int, sizeBytes: Int64?)] {
        var result: [(category: String, count: Int, sizeBytes: Int64?)] = []
        result.reserveCapacity(categories.count)
        for (category, entry) in categories {
            result.append((category: category, count: entry.count, sizeBytes: entry.sizeBytes))
        }
        result.sort { lhs, rhs in
            if lhs.count == rhs.count { return lhs.category < rhs.category }
            return lhs.count > rhs.count
        }
        return result
    }
}
