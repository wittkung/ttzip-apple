// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit

/// Bounded cache for image dimensional metadata extracted asynchronously via ImageIO.
@MainActor
public final class ImageMetadataCache {
    public static let shared = ImageMetadataCache()

    /// Maximum number of cached image dimension entries before evicting the oldest entries.
    public let maxEntries: Int

    private var dimensionsCache: [String: String] = [:]
    private var insertionOrder: [String] = []

    public init(maxEntries: Int = 1000) {
        self.maxEntries = max(1, maxEntries)
    }

    public var count: Int {
        dimensionsCache.count
    }

    public func clear() {
        dimensionsCache.removeAll()
        insertionOrder.removeAll()
    }

    public func clearCache() {
        clear()
    }

    public func getDimensions(for path: String) -> String? {
        dimensionsCache[path]
    }

    public func storeDimensions(_ dimensions: String, for path: String) {
        if dimensionsCache[path] == nil {
            while dimensionsCache.count >= maxEntries, !insertionOrder.isEmpty {
                let oldestKey = insertionOrder.removeFirst()
                dimensionsCache.removeValue(forKey: oldestKey)
            }
            insertionOrder.append(path)
        }
        dimensionsCache[path] = dimensions
    }

    public func loadDimensionsAsync(path: String, url: URL) async -> String? {
        if let existing = dimensionsCache[path] {
            return existing
        }

        let formatted = await Task.detached(priority: .utility) { () -> String? in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                return nil
            }
            return "\(width) × \(height)"
        }.value

        if let formatted {
            storeDimensions(formatted, for: path)
        }
        return formatted
    }
}
