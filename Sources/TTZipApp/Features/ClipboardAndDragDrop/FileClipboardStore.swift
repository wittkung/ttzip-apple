// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import AppKit
import Observation
import TTZipUI
import TTZipPreviewKit

/// Global file clipboard dispatcher supporting copy, cut, paste, and automatic filename collision avoidance.
@Observable
@MainActor
public final class FileClipboardStore {
    public static let shared = FileClipboardStore()
    
    public var copiedURLs: [URL] = []
    public var isCutOperation: Bool = false
    
    private init() {}
    
    public var canPaste: Bool {
        if !copiedURLs.isEmpty { return true }
        if let items = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !items.isEmpty {
            return true
        }
        return false
    }
    
    public func copy(urls: [URL]) {
        self.copiedURLs = urls
        self.isCutOperation = false
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }
    
    public func cut(urls: [URL]) {
        self.copiedURLs = urls
        self.isCutOperation = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }
    
    @discardableResult
    public func paste(to targetDir: URL) -> Task<Void, Never> {
        let urlsToPaste = resolveURLsToPaste()
        guard !urlsToPaste.isEmpty else { return Task {} }
        let isCut = self.isCutOperation

        return Task.detached(priority: .userInitiated) {
            let outcome = Self.executePasteBatch(urls: urlsToPaste, targetDir: targetDir, isCut: isCut)
            await MainActor.run {
                self.finalizePasteOutcome(
                    succeededURLs: outcome.succeeded,
                    failedItems: outcome.failed,
                    isCut: isCut
                )
            }
        }
    }

    private func resolveURLsToPaste() -> [URL] {
        if !copiedURLs.isEmpty { return copiedURLs }
        return (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    nonisolated private static func executePasteBatch(
        urls: [URL],
        targetDir: URL,
        isCut: Bool
    ) -> (succeeded: [URL], failed: [(URL, Error)]) {
        var succeededURLs: [URL] = []
        var failedItems: [(URL, Error)] = []
        for srcURL in urls {
            if srcURL.path == targetDir.path || targetDir.path.hasPrefix(srcURL.path + "/") {
                continue
            }
            let destURL = uniqueDestinationURLStatic(for: srcURL, in: targetDir)
            do {
                if isCut {
                    try FileManager.default.moveItem(at: srcURL, to: destURL)
                } else {
                    try FileManager.default.copyItem(at: srcURL, to: destURL)
                }
                succeededURLs.append(srcURL)
            } catch {
                failedItems.append((srcURL, error))
            }
        }
        return (succeededURLs, failedItems)
    }

    private func finalizePasteOutcome(
        succeededURLs: [URL],
        failedItems: [(URL, Error)],
        isCut: Bool
    ) {
        if isCut {
            let succeededPaths = Set(succeededURLs.map { $0.standardizedFileURL.path })
            copiedURLs.removeAll { succeededPaths.contains($0.standardizedFileURL.path) }
            NSPasteboard.general.clearContents()
            if copiedURLs.isEmpty {
                isCutOperation = false
            } else {
                NSPasteboard.general.writeObjects(copiedURLs as [NSURL])
            }
        }
        if !failedItems.isEmpty {
            reportPasteFailures(failedItems, isCut: isCut)
        }
        if !succeededURLs.isEmpty {
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
        }
    }

    private func reportPasteFailures(_ failedItems: [(URL, Error)], isCut: Bool) {
        let operationName = isCut ? "Move" : "Copy"
        let errorDetails = failedItems
            .map { "\($0.0.lastPathComponent): \($0.1.localizedDescription)" }
            .joined(separator: "\n")
        let error = NSError(
            domain: "com.metastudyline.ttzip.clipboard",
            code: 1001,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to \(operationName.lowercased()) \(failedItems.count) item(s):\n\(errorDetails)"
            ]
        )
        AppErrorReporter.shared.reportError(error, contextTitle: "\(operationName) Operation Failed")
    }
    
    public func pasteAsync(to targetDir: URL) async {
        await paste(to: targetDir).value
    }
    
    nonisolated private static func uniqueDestinationURLStatic(for srcURL: URL, in targetDir: URL) -> URL {
        let fm = FileManager.default
        let ext = srcURL.pathExtension
        let baseName = srcURL.deletingPathExtension().lastPathComponent
        
        var candidateName = srcURL.lastPathComponent
        var candidateURL = targetDir.appendingPathComponent(candidateName)
        var counter = 1
        
        while fm.fileExists(atPath: candidateURL.path) {
            if ext.isEmpty {
                candidateName = "\(baseName) \(counter)"
            } else {
                candidateName = "\(baseName) \(counter).\(ext)"
            }
            candidateURL = targetDir.appendingPathComponent(candidateName)
            counter += 1
        }
        return candidateURL
    }
    
    private func uniqueDestinationURL(for srcURL: URL, in targetDir: URL) -> URL {
        let fm = FileManager.default
        let ext = srcURL.pathExtension
        let baseName = srcURL.deletingPathExtension().lastPathComponent
        
        var candidateName = srcURL.lastPathComponent
        var candidateURL = targetDir.appendingPathComponent(candidateName)
        var counter = 1
        
        while fm.fileExists(atPath: candidateURL.path) {
            if ext.isEmpty {
                candidateName = "\(baseName) (\(counter))"
            } else {
                candidateName = "\(baseName) (\(counter)).\(ext)"
            }
            candidateURL = targetDir.appendingPathComponent(candidateName)
            counter += 1
        }
        return candidateURL
    }
}
