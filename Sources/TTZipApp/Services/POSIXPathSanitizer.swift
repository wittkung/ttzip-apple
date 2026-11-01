// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Static utility for POSIX path normalization, shell unescaping, tilde expansion, and prefix parsing.
/// Delegated directly to the high-performance Rust core engine via Mozilla UniFFI.
public enum POSIXPathSanitizer: Sendable {
    
    /// Determines whether the raw user input is intended as a filesystem path rather than a keyword search.
    public static func isPathLike(input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") || trimmed.hasPrefix("file://") {
            return true
        }
        
        if trimmed.contains("/") || trimmed.contains("\\") {
            return true
        }
        
        return false
    }
    
    /// Normalizes and resolves a raw user input path into a canonical POSIX path.
    public static func sanitize(rawInput: String, relativeTo baseDirectory: URL? = nil) -> String {
        TTZipCore.sanitizePosixPath(rawInput: rawInput, baseDirectory: baseDirectory?.path)
    }
    
    /// Extracts the parent directory to query and the trailing prefix for real-time autocompletion.
    public static func extractParentAndPrefix(rawInput: String, relativeTo baseDirectory: URL? = nil) -> (parentDirectory: String, prefix: String) {
        let result = TTZipCore.extractParentAndPrefix(rawInput: rawInput, baseDirectory: baseDirectory?.path)
        return (parentDirectory: result.parentDirectory, prefix: result.prefix)
    }
}
