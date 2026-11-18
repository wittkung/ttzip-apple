// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTZipUI
import TTZipPreviewKit

public enum FileDragDropHelper {
    /// Asynchronously performs file move operations on a background thread, preventing UI beachball freezes during cross-volume moves.
    @discardableResult
    public static func performMove(sources: [URL], to destinationDir: URL) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var movedURLs: [URL] = []
            
            for src in sources {
                let dest = destinationDir.appendingPathComponent(src.lastPathComponent)
                if src.path == dest.path { continue }
                
                var finalDest = dest
                var counter = 2
                while fm.fileExists(atPath: finalDest.path) {
                    let nameWithoutExt = (src.lastPathComponent as NSString).deletingPathExtension
                    let ext = src.pathExtension
                    let newName = ext.isEmpty ? "\(nameWithoutExt) \(counter)" : "\(nameWithoutExt) \(counter).\(ext)"
                    finalDest = destinationDir.appendingPathComponent(newName)
                    counter += 1
                }
                
                try fm.moveItem(at: src, to: finalDest)
                movedURLs.append(finalDest)
            }
            
            return movedURLs
        }.value
    }
}
