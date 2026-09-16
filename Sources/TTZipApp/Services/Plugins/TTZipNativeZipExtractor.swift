// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore

/// Memory-safe ZIP archive extractor delegating to TTZipCore with Zip Slip defense and bundle resolution.
public enum TTZipNativeZipExtractor: Sendable {
    
    /// Extracts a ZIP archive safely into a staging root directory and returns the found `.ttplugin` bundle URL.
    @discardableResult
    public static func extract(archiveURL: URL, destinationDirectory: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw TTZipPluginSecurity.SecurityError.fileNotFound(archiveURL)
        }
        
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        
        // 1. Inspect archive entry paths via UniFFI microkernel and enforce Zip Slip defenses
        let entries: [UniFfiEntryMetadata]
        do {
            entries = try inspectArchiveEntries(archivePath: archiveURL.path, password: nil)
        } catch let secErr as TTZipPluginSecurity.SecurityError {
            throw secErr
        } catch {
            throw TTZipPluginSecurity.SecurityError.corruptArchive("Failed to inspect archive entries: \(error.localizedDescription)")
        }
        
        for entry in entries {
            guard !entry.path.isEmpty else { continue }
            _ = try TTZipPluginSecurity.validateSafeDestination(
                entryRelativePath: entry.path,
                stagingRoot: destinationDirectory
            )
        }
        
        // 2. Delegate extraction to TTZipCore.ArchiveExtractor
        do {
            let extractor = ArchiveExtractor()
            try extractor.extractSync(
                archivePath: archiveURL.path,
                destinationDir: destinationDirectory.path
            )
        } catch let secErr as TTZipPluginSecurity.SecurityError {
            throw secErr
        } catch {
            throw TTZipPluginSecurity.SecurityError.corruptArchive("Archive extraction failed: \(error.localizedDescription)")
        }
        
        // 3. Scan staging root for the extracted .ttplugin bundle
        let contents = try FileManager.default.contentsOfDirectory(at: destinationDirectory, includingPropertiesForKeys: nil)
        if let directBundle = contents.first(where: { $0.pathExtension == "ttplugin" }) {
            return directBundle
        }
        
        for item in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                let nested = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                if let nestedBundle = nested.first(where: { $0.pathExtension == "ttplugin" }) {
                    return nestedBundle
                }
            }
        }
        
        throw TTZipPluginSecurity.SecurityError.fileNotFound(destinationDirectory)
    }
}
