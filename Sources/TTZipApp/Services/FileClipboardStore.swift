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
        let urlsToPaste: [URL] = {
            if !copiedURLs.isEmpty { return copiedURLs }
            return (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        }()
        
        guard !urlsToPaste.isEmpty else {
            return Task {}
        }
        let isCut = self.isCutOperation
        
        return Task.detached(priority: .userInitiated) {
            var succeededURLs: [URL] = []
            var failedItems: [(URL, Error)] = []
            
            for srcURL in urlsToPaste {
                if srcURL.path == targetDir.path || targetDir.path.hasPrefix(srcURL.path + "/") {
                    continue
                }
                let destURL = Self.uniqueDestinationURLStatic(for: srcURL, in: targetDir)
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
            
            await MainActor.run {
                if isCut {
                    let succeededPaths = Set(succeededURLs.map { $0.standardizedFileURL.path })
                    self.copiedURLs.removeAll { succeededPaths.contains($0.standardizedFileURL.path) }
                    
                    if self.copiedURLs.isEmpty {
                        self.isCutOperation = false
                        NSPasteboard.general.clearContents()
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects(self.copiedURLs as [NSURL])
                    }
                }
                
                if !failedItems.isEmpty {
                    let operationName = isCut ? "Move" : "Copy"
                    let errorDetails = failedItems.map { "\($0.0.lastPathComponent): \($0.1.localizedDescription)" }.joined(separator: "\n")
                    let error = NSError(
                        domain: "com.metastudyline.ttzip.clipboard",
                        code: 1001,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Failed to \(operationName.lowercased()) \(failedItems.count) item(s):\n\(errorDetails)"
                        ]
                    )
                    AppErrorReporter.shared.reportError(error, contextTitle: "\(operationName) Operation Failed")
                }
                
                if !succeededURLs.isEmpty {
                    NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
                }
            }
        }
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
