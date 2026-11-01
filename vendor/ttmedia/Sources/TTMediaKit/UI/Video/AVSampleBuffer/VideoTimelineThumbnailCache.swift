// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0
// Doc twin: products/ttzip/docs/twin/preview/video-timeline-thumbnails.md

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Disk I/O and JPEG conversion never run on the UI actor.
actor VideoTimelineThumbnailCache {
    static let shared = VideoTimelineThumbnailCache()
    static let maximumFileBytes = 20 * 1024 * 1024
    static let maximumTotalBytes = 256 * 1024 * 1024
    struct Identity: Codable, Equatable, Sendable {
        let version: Int
        let path: String
        let size: Int
        let modified: Date
        let duration: Double
        let sampleCount: Int
        var key: String {
            SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    private struct Entry: Codable { let seconds: Double; let jpeg: Data }
    private struct Archive: Codable { let identity: Identity; let entries: [Entry] }
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.metastudyline.ttmedia/timeline-v1", isDirectory: true)
    }

    func identity(for url: URL, duration: Double, sampleCount: Int) -> Identity? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        // URL resourceValues can retain stale attributes across in-place edits.
        guard url.isFileURL, duration.isFinite, duration > 0,
              let values = try? FileManager.default.attributesOfItem(atPath: path),
              values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? Int,
              let modified = values[.modificationDate] as? Date else { return nil }
        return Identity(version: 1, path: path, size: size, modified: modified,
                        duration: duration, sampleCount: sampleCount)
    }

    func read(_ identity: Identity) -> [VideoTimelineFrame]? {
        let file = directory.appendingPathComponent(identity.key + ".json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: file),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.identity == identity,
              !archive.entries.isEmpty, archive.entries.count <= identity.sampleCount else { return nil }
        var frames: [VideoTimelineFrame] = []
        for entry in archive.entries {
            guard entry.seconds.isFinite, entry.seconds >= 0,
                  entry.seconds <= identity.duration + 1,
                  let source = CGImageSourceCreateWithData(entry.jpeg as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 240, height <= 160,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            frames.append(VideoTimelineFrame(image: image, seconds: entry.seconds))
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return frames.sorted { $0.seconds < $1.seconds }
    }

    func write(_ frames: [VideoTimelineFrame], identity: Identity) {
        guard !Task.isCancelled, !frames.isEmpty, frames.count <= identity.sampleCount else { return }
        var entries: [Entry] = []
        for frame in frames {
            guard !Task.isCancelled else { return }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, frame.image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return }
            entries.append(Entry(seconds: frame.seconds, jpeg: data as Data))
        }
        guard let data = try? JSONEncoder().encode(Archive(identity: identity, entries: entries)),
              data.count <= Self.maximumFileBytes, !Task.isCancelled else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(identity.key + ".json"), options: .atomic)
            evict()
        } catch { /* A cache write failure must never interrupt playback. */ }
    }

    private func evict() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in entries where total > Self.maximumTotalBytes {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= bytes }
        }
    }
}
