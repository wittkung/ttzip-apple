// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import ImageIO
import TTZipUI

/// High-performance memory-budgeted image downsampler and decoder using ImageIO.
public enum DownsampledImageLoader {
    /// Default maximum pixel dimension for preview rendering (e.g. 2048px for Retina screens).
    public static let defaultMaxPixelSize: CGFloat = 2048.0

    /// Loads a downsampled `NSImage` from a local file URL without decoding the full uncompressed bitmap.
    public static func loadDownsampledImage(
        from url: URL,
        maxPixelSize: CGFloat = defaultMaxPixelSize
    ) -> NSImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
            return nil
        }
        
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary
        
        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else {
            return nil
        }
        
        let normalized = normalizeColorSpace(downsampledImage)
        return NSImage(cgImage: normalized, size: NSSize(width: normalized.width, height: normalized.height))
    }

    /// Loads a downsampled `NSImage` from in-memory Data without decoding the full uncompressed bitmap.
    public static func loadDownsampledImage(
        from data: Data,
        maxPixelSize: CGFloat = defaultMaxPixelSize
    ) -> NSImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
            return nil
        }
        
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary
        
        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else {
            return nil
        }
        
        let normalized = normalizeColorSpace(downsampledImage)
        return NSImage(cgImage: normalized, size: NSSize(width: normalized.width, height: normalized.height))
    }

    /// Loads a downsampled `NSImage` asynchronously on a background cooperative thread.
    public static func loadDownsampledImageAsync(
        from url: URL,
        maxPixelSize: CGFloat = defaultMaxPixelSize
    ) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            loadDownsampledImage(from: url, maxPixelSize: maxPixelSize)
        }.value
    }
    
    /// Normalizes non-standard color spaces (such as CMYK) to standard sRGB to prevent SwiftUI Metal inverted rendering.
    private static func normalizeColorSpace(_ image: CGImage) -> CGImage {
        guard image.colorSpace?.model == .cmyk else { return image }
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

