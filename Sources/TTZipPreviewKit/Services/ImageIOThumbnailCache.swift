// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import ImageIO
import CoreGraphics
import TTZipUI

/// Zero-copy CoreGraphics downsampling and flyweight thumbnail cache.
public final class ImageIOThumbnailCache: @unchecked Sendable {
    public static let shared = ImageIOThumbnailCache()
    
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    
    private(set) public var hitCount: Int = 0
    private(set) public var missCount: Int = 0
    
    public init(countLimit: Int = 200, totalCostLimitMB: Int = 128) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimitMB * 1024 * 1024
    }
    
    /// Retrieves downsampled thumbnail for specified URL with memory cache fallback.
    public func thumbnail(for url: URL, maxPixelSize: CGFloat = 2048) -> NSImage? {
        let key = "\(url.path)_\(Int(maxPixelSize))" as NSString
        
        lock.lock()
        if let cached = cache.object(forKey: key) {
            hitCount += 1
            lock.unlock()
            return cached
        }
        missCount += 1
        lock.unlock()
        
        guard let downsampled = downsample(url: url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        
        lock.lock()
        let cost = Int(downsampled.size.width * downsampled.size.height * 4)
        cache.setObject(downsampled, forKey: key, cost: cost)
        lock.unlock()
        
        return downsampled
    }

    public func getThumbnail(for url: URL, maxPixelSize: CGFloat = 2048) -> NSImage? {
        return thumbnail(for: url, maxPixelSize: maxPixelSize)
    }

    public func getThumbnailAsync(for url: URL, maxPixelSize: CGFloat = 2048) async -> NSImage? {
        if let cgImage = await ImageIOThumbnailService.shared.getThumbnail(for: url, maxPixelSize: maxPixelSize) {
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            return NSImage(cgImage: cgImage, size: size)
        }
        return nil
    }
    
    /// Downsamples image directly from URL via CoreGraphics without intermediate bitmap allocation.
    public func downsample(url: URL, maxPixelSize: CGFloat = 2048) -> NSImage? {
        return DownsampledImageLoader.loadDownsampledImage(from: url, maxPixelSize: maxPixelSize)
    }
    
    /// Downsamples image directly from Data via CoreGraphics without intermediate bitmap allocation.
    public func downsample(data: Data, maxPixelSize: CGFloat = 2048) -> NSImage? {
        return DownsampledImageLoader.loadDownsampledImage(from: data, maxPixelSize: maxPixelSize)
    }
    
    public func resetStatistics() {
        lock.lock()
        hitCount = 0
        missCount = 0
        lock.unlock()
    }
    
    public func purgeCache() {
        lock.lock()
        cache.removeAllObjects()
        hitCount = 0
        missCount = 0
        lock.unlock()
    }
}
