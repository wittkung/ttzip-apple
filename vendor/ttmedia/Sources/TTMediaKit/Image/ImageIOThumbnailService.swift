// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import ImageIO
import CoreGraphics

/// Actor managing background CoreGraphics image downsampling and thumbnail generation with in-flight deduplication and resource-versioned keys.
public actor ImageIOThumbnailService {
    public static let shared = ImageIOThumbnailService()

    private let cache = NSCache<NSString, CGImage>()
    private var inFlightTasks: [String: Task<CGImage?, Never>] = [:]
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private(set) public var hitCount: Int = 0
    private(set) public var missCount: Int = 0

    public init(countLimit: Int = 300, totalCostLimitMB: Int = 128) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimitMB * 1024 * 1024
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.resume()
        self.memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.purgeCache()
            }
        }
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    /// Constructs a resource-versioned cache key incorporating standardized path, byte size, modification timestamp, and pixel dimension.
    public nonisolated static func versionedCacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        ImageIOThumbnailCache.versionedCacheKey(for: url, maxPixelSize: maxPixelSize)
    }

    /// Asynchronously retrieves or generates downsampled CGImage on detached background task.
    public func getThumbnail(for url: URL, maxPixelSize: CGFloat = 2048) async -> CGImage? {
        let key = Self.versionedCacheKey(for: url, maxPixelSize: maxPixelSize)

        if let cached = cache.object(forKey: key) {
            hitCount += 1
            return cached
        }
        missCount += 1

        let keyStr = key as String
        if let existingTask = inFlightTasks[keyStr] {
            return await existingTask.value
        }

        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }
            let downsampleOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary)
        }

        inFlightTasks[keyStr] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: keyStr)

        if let cgImage = result {
            let cost = cgImage.bytesPerRow * cgImage.height
            cache.setObject(cgImage, forKey: key, cost: cost)
        }
        return result
    }

    public func resetStatistics() {
        hitCount = 0
        missCount = 0
    }

    public func purgeCache() {
        cache.removeAllObjects()
        hitCount = 0
        missCount = 0
    }
}
