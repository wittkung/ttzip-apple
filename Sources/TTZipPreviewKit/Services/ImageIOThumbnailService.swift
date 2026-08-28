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

/// Actor managing background CoreGraphics image downsampling and thumbnail generation with in-flight deduplication.
public actor ImageIOThumbnailService {
    public static let shared = ImageIOThumbnailService()
    
    private let cache = NSCache<NSString, CGImage>()
    private var inFlightTasks: [String: Task<CGImage?, Never>] = [:]
    
    public init(countLimit: Int = 300, totalCostLimitMB: Int = 128) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimitMB * 1024 * 1024
    }
    
    /// Asynchronously retrieves or generates downsampled CGImage on detached background task.
    public func getThumbnail(for url: URL, maxPixelSize: CGFloat = 2048) async -> CGImage? {
        let key = "\(url.path)_\(Int(maxPixelSize))" as NSString
        
        if let cached = cache.object(forKey: key) {
            return cached
        }
        
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
    
    public func purgeCache() {
        cache.removeAllObjects()
    }
}
