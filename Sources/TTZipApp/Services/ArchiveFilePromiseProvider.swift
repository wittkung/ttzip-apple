// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import UniformTypeIdentifiers
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Helper factory to generate NSItemProviders for in-archive entries and disk items.
public enum ArchiveDragItemProviderFactory {
    public static func createItemProvider(
        archivePath: String,
        entryPath: String,
        suggestedFileName: String,
        password: String? = nil
    ) -> NSItemProvider {
        let utType = UTType(filenameExtension: (suggestedFileName as NSString).pathExtension) ?? .data
        let itemProvider = NSItemProvider()
        itemProvider.suggestedName = suggestedFileName
        
        itemProvider.registerFileRepresentation(
            forTypeIdentifier: utType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ttzip_drag_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            Task.detached(priority: .userInitiated) {
                do {
                    let outcome = try await ArchiveSelectiveExtractor.shared.extractSelected(
                        archivePath: archivePath,
                        targetEntryPaths: [entryPath],
                        destinationDir: tempDir.path,
                        password: password,
                        handling: .policy(.keepBoth)
                    )
                    guard outcome.extracted + outcome.replaced + outcome.keptBoth > 0 else {
                        let err = NSError(domain: "TTZip", code: -2, userInfo: [NSLocalizedDescriptionKey: "Entry not found in archive"])
                        completion(nil, false, err)
                        return
                    }
                    
                    let extractedURL = tempDir.appendingPathComponent((entryPath as NSString).lastPathComponent)
                    let targetURL = tempDir.appendingPathComponent(suggestedFileName)
                    if FileManager.default.fileExists(atPath: extractedURL.path) && extractedURL != targetURL {
                        try? FileManager.default.moveItem(at: extractedURL, to: targetURL)
                    }
                    let finalURL = FileManager.default.fileExists(atPath: targetURL.path) ? targetURL : extractedURL
                    completion(finalURL, true, nil)
                    
                    // Register a termination observer to clean up the temporary directory on app exit
                    _ = NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil,
                        queue: nil
                    ) { _ in
                        try? FileManager.default.removeItem(at: tempDir)
                    }
                } catch {
                    completion(nil, false, error)
                }
            }
            return Progress(totalUnitCount: 1)
        }
        
        return itemProvider
    }
}
