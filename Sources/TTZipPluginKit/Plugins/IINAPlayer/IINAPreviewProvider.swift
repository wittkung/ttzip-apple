// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// Preview provider implementation intercepting all mainstream and specialized video formats.
@MainActor
public final class IINAPreviewProvider: TTZipPreviewProvider, @unchecked Sendable {
    public static let shared = IINAPreviewProvider()
    
    /// Comprehensive list of video container formats intercepted by IINAPlayer.
    public let supportedExtensions: [String] = [
        "mkv", "avi", "webm", "flv", "ts", "m2ts", "wmv", "rmvb", "vob",
        "mp4", "mov", "m4v", "qt", "ogv", "3gp", "divx", "asf", "m4s"
    ]
    
    private init() {}
    
    /// Evaluates whether the given URL is supported for preview by IINAPlayer.
    public func canPreview(fileURL: URL) -> Bool {
        if fileURL.scheme?.lowercased() == "ttzip" {
            // For ttzip:// virtual file streams, parse target entry extension
            let entryName = fileURL.queryParameters?["entry"] ?? fileURL.path
            let ext = (entryName as NSString).pathExtension.lowercased()
            return supportedExtensions.contains(ext)
        }
        
        let ext = fileURL.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }
    
    /// Constructs the SwiftUI preview view hierarchy powered by CAMetalLayer HDR viewport.
    public func makePreviewView(fileURL: URL) -> AnyView {
        AnyView(
            IINAPlayerContainerView(url: fileURL)
        )
    }
}

// MARK: - URL Query Parameter Extraction Helper

private extension URL {
    var queryParameters: [String: String]? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else { return nil }
        var dict: [String: String] = [:]
        for item in queryItems {
            dict[item.name] = item.value ?? ""
        }
        return dict
    }
}
