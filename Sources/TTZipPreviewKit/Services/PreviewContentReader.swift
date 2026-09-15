// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore

/// Headless service responsible for reading text payloads and inferring text encodings (UTF-8, GB18030, UTF-16, etc.)
/// completely decoupled from UI or View layers.
public enum PreviewContentReader {

    /// Maximum text safety budget (50 MB) before refusing full-text decoding to prevent OOM.
    public static let maxTextBudget: Int64 = 50 * 1024 * 1024

    /// Reads text content from a file URL or in-archive VFS scheme URL with binary sniffing and size budgeting.
    nonisolated public static func readTextContent(from url: URL, maxBudget: Int64 = maxTextBudget) -> String? {
        if url.scheme == TTZipVfsSchemeHandler.scheme {
            if let data = TTZipArchiveVfsProvider.shared.cachedData(for: url.absoluteString), !data.isEmpty {
                let sampleData = data.prefix(4096)
                if !sampleData.isEmpty {
                    if sampleData.first == 0 {
                        return nil
                    }
                    let nullCount = sampleData.filter { $0 == 0 }.count
                    if Double(nullCount) / Double(sampleData.count) > 0.01 {
                        return nil
                    }
                }
                return decodeText(data: data)
            }
            return nil
        }
        
        guard let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)) else {
            return nil
        }
        
        // 1. Binary sniffing on first 4KB
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }
        
        let sampleData = (try? fileHandle.read(upToCount: 4096)) ?? Data()
        if !sampleData.isEmpty {
            if sampleData.first == 0 {
                return nil
            }
            let nullCount = sampleData.filter { $0 == 0 }.count
            if Double(nullCount) / Double(sampleData.count) > 0.01 {
                // High concentration of null bytes indicates compiled/binary payload
                return nil
            }
        }
        
        // 2. Read full content up to safety budget without truncation
        guard fileSize <= maxBudget else { return nil }
        
        try? fileHandle.seek(toOffset: 0)
        guard let data = try? fileHandle.readToEnd(), !data.isEmpty else { return nil }
        return decodeText(data: data)
    }

    /// Decodes raw data to String using progressive encoding heuristic (UTF-8, CharsetDetector GB18030/Shift-JIS, UTF-16, ASCII, ISO-Latin-1, UTF-8 lossy fallback).
    nonisolated public static func decodeText(data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) {
            return s
        } else {
            let detectedStr = CharsetDetector.sanitizeFilename(bytes: data)
            if !detectedStr.isEmpty {
                return detectedStr
            } else if let s = String(data: data, encoding: .utf16) {
                return s
            } else if let s = String(data: data, encoding: .ascii) {
                return s
            } else if let s = String(data: data, encoding: .isoLatin1) {
                return s
            } else {
                return String(decoding: data, as: UTF8.self)
            }
        }
    }
}
