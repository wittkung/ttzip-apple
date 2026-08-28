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

/// Static utility for POSIX path normalization, shell unescaping, tilde expansion, and prefix parsing.
/// Delegated directly to the high-performance Rust core engine via Mozilla UniFFI.
public enum POSIXPathSanitizer: Sendable {
    
    /// Determines whether the raw user input is intended as a filesystem path rather than a keyword search.
    public static func isPathInput(_ rawInput: String) -> Bool {
        let trimmed = rawInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") || trimmed.hasPrefix("file://") {
            return true
        }
        
        if trimmed.contains("/") || trimmed.contains("\\") {
            return true
        }
        
        return false
    }
    
    public static func isPathLike(input: String) -> Bool {
        return isPathInput(input)
    }
    
    /// Normalizes and resolves a raw user input path into a canonical POSIX path.
    public static func sanitize(rawInput: String, relativeTo baseDirectory: URL? = nil) -> String {
        return TTZipCore.sanitizePosixPath(rawInput: rawInput, baseDirectory: baseDirectory?.path)
    }
    
    public static func sanitize(input: String, relativeTo baseDirectory: URL? = nil) -> String {
        return sanitize(rawInput: input, relativeTo: baseDirectory)
    }
    
    /// Extracts the parent directory to query and the trailing prefix for real-time autocompletion.
    public static func extractParentAndPrefix(input: String, relativeTo baseDirectory: URL? = nil) -> (parentDirectory: String, prefix: String) {
        let result = TTZipCore.extractParentAndPrefix(rawInput: input, baseDirectory: baseDirectory?.path)
        return (parentDirectory: result.parentDirectory, prefix: result.prefix)
    }
    
    public static func extractParentAndPrefix(rawInput: String, baseDirectory: URL? = nil) -> (parentDirectory: String, prefix: String) {
        return extractParentAndPrefix(input: rawInput, relativeTo: baseDirectory)
    }
}
