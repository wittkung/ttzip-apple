// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import ImageIO
import CoreGraphics

/// Zero-copy CoreGraphics downsampling and flyweight thumbnail cache keyed by resource version metadata and bounded content fingerprint.
public actor ImageIOThumbnailCache {
    public static let shared = ImageIOThumbnailCache()

    /// Maximum sample window (first 16 KB + last 16 KB) hashed for same-path equal-length overwrite detection.
    private static let fingerprintWindowBytes: Int = 16 * 1024

    nonisolated(unsafe) private let cache = NSCache<NSString, NSImage>()
    private let statsLock = NSLock()
    nonisolated(unsafe) private var _hitCount: Int = 0
    nonisolated(unsafe) private var _missCount: Int = 0
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    public var hitCount: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _hitCount
    }

    public var missCount: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _missCount
    }

    public init(countLimit: Int = 200, totalCostLimitMB: Int = 128) {
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
            self.purgeCacheSync()
        }
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    /// Constructs a resource-versioned cache key incorporating standardized path, inode, byte size, nanosecond modification timestamp,
    /// bounded content fingerprint (first/last 16 KB FNV-1a), and pixel dimension.
    public nonisolated static func versionedCacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        let standardizedPath = url.standardizedFileURL.path
        var st = stat()
        if stat(standardizedPath, &st) == 0 {
            let fileSize = st.st_size
            let mtimeSec = st.st_mtimespec.tv_sec
            let mtimeNsec = st.st_mtimespec.tv_nsec
            let inode = st.st_ino
            let fingerprint = boundedContentFingerprint(atPath: standardizedPath, fileSize: fileSize)
            return "\(standardizedPath)|ino:\(inode)|size:\(fileSize)|mtime:\(mtimeSec).\(mtimeNsec)|fp:\(String(fingerprint, radix: 16))|px:\(Int(maxPixelSize))" as NSString
        }
        return "\(standardizedPath)|size:-1|mtime:-1|px:\(Int(maxPixelSize))" as NSString
    }

    private nonisolated static func boundedContentFingerprint(atPath path: String, fileSize: off_t) -> UInt64 {
        guard fileSize > 0, let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }

        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        let window = fingerprintWindowBytes

        if let headData = try? handle.read(upToCount: window) {
            for byte in headData {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
        }
        if fileSize > off_t(window) {
            let tailOffset = UInt64(max(off_t(window), fileSize - off_t(window)))
            try? handle.seek(toOffset: tailOffset)
            if let tailData = try? handle.read(upToCount: window) {
                for byte in tailData {
                    hash ^= UInt64(byte)
                    hash = hash &* prime
                }
            }
        }
        return hash
    }

    /// Thread-safe nonisolated lookup and downsampling used by synchronous and background detection pipelines.
    public nonisolated func cachedOrDownsampledThumbnail(for url: URL, maxPixelSize: CGFloat = 2048) -> NSImage? {
        let key = Self.versionedCacheKey(for: url, maxPixelSize: maxPixelSize)

        if let cached = cache.object(forKey: key) {
            recordHit()
            return cached
        }
        recordMiss()

        guard let downsampled = downsample(url: url, maxPixelSize: maxPixelSize) else {
            return nil
        }

        let cost = max(1, Int(downsampled.size.width * downsampled.size.height * 4))
        cache.setObject(downsampled, forKey: key, cost: cost)
        return downsampled
    }

    /// Retrieves downsampled thumbnail for specified URL with memory cache fallback.
    public func thumbnail(for url: URL, maxPixelSize: CGFloat = 2048) -> NSImage? {
        cachedOrDownsampledThumbnail(for: url, maxPixelSize: maxPixelSize)
    }

    public func getThumbnail(for url: URL, maxPixelSize: CGFloat = 2048) -> NSImage? {
        cachedOrDownsampledThumbnail(for: url, maxPixelSize: maxPixelSize)
    }

    public func getThumbnailAsync(for url: URL, maxPixelSize: CGFloat = 2048) async -> NSImage? {
        let key = Self.versionedCacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            recordHit()
            return cached
        }
        if let cgImage = await ImageIOThumbnailService.shared.getThumbnail(for: url, maxPixelSize: maxPixelSize) {
            recordMiss()
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            let nsImage = NSImage(cgImage: cgImage, size: size)
            let cost = max(1, cgImage.bytesPerRow * cgImage.height)
            cache.setObject(nsImage, forKey: key, cost: cost)
            return nsImage
        }
        recordMiss()
        return nil
    }

    /// Downsamples image directly from URL via CoreGraphics without intermediate bitmap allocation.
    public nonisolated func downsample(url: URL, maxPixelSize: CGFloat = 2048) -> NSImage? {
        DownsampledImageLoader.loadDownsampledImage(from: url, maxPixelSize: maxPixelSize)
    }

    /// Downsamples image directly from Data via CoreGraphics without intermediate bitmap allocation.
    public nonisolated func downsample(data: Data, maxPixelSize: CGFloat = 2048) -> NSImage? {
        DownsampledImageLoader.loadDownsampledImage(from: data, maxPixelSize: maxPixelSize)
    }

    public func resetStatistics() {
        statsLock.lock()
        _hitCount = 0
        _missCount = 0
        statsLock.unlock()
    }

    public func purgeCache() {
        purgeCacheSync()
    }

    public nonisolated func purgeCacheSync() {
        cache.removeAllObjects()
        statsLock.lock()
        _hitCount = 0
        _missCount = 0
        statsLock.unlock()
    }

    private nonisolated func recordHit() {
        statsLock.lock()
        _hitCount += 1
        statsLock.unlock()
    }

    private nonisolated func recordMiss() {
        statsLock.lock()
        _missCount += 1
        statsLock.unlock()
    }
}
