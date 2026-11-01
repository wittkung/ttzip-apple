// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CryptoKit
import Darwin
import os

/// Platform adapter for the cross-platform resume policy supplied by the host core.
@MainActor
public enum PlaybackExperiencePolicy {
    public static var resumePosition: @Sendable (Double, Double) -> Double = { position, duration in
        guard position.isFinite, duration.isFinite, duration > 0, position >= 0 else { return 0 }
        let endMargin = min(10, duration * 0.05)
        return position >= duration - endMargin ? 0 : min(position, duration)
    }
    /// The host may resolve archive-entry identity from its original archive resource context.
    public static var resourceIdentity: (@MainActor (URL) -> String?)?
}

public struct PlaybackExperienceRecord: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var position: Double = 0
    public var duration: Double = 0
    public var rotationDegrees: Int = 0
    public var volume: Float = 1
    public var muted = false
    public var rate: Float = 1
    public var primarySubtitle: String?
    public var secondarySubtitle = "off"
    public var subtitleStyle: SubtitleStyleConfiguration?
    public var updatedAt = Date()
    public init() {}
}

/// Persists bounded, atomic checkpoints independently of disposable preview URLs.
@MainActor
public final class PlaybackExperienceStore {
    public static let shared = PlaybackExperienceStore()
    public static let maximumRecords = 500
    private var records: [String: PlaybackExperienceRecord] = [:]
    private let destination: URL?
    private let queue = DispatchQueue(label: "com.metastudyline.ttmedia.experience", qos: .utility)
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "PlaybackExperience")

    public init(storageURL: URL? = nil) {
        destination = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("com.metastudyline.ttmedia/PlaybackExperience-v1.json")
        if let destination, let data = try? Data(contentsOf: destination),
           let decoded = try? JSONDecoder().decode([String: PlaybackExperienceRecord].self, from: data) {
            records = decoded.filter { $0.value.schemaVersion == 1 }
        }
    }

    public nonisolated static func localIdentity(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let excluded = [NSTemporaryDirectory(), "/tmp", "/var/tmp"].map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard !excluded.contains(where: { file.path == $0 || file.path.hasPrefix($0 + "/") }) else { return nil }
        return fileVersionIdentity(for: file)
    }

    /// Fresh metadata only. Callers still own temporary-resource persistence policy.
    public nonisolated static func fileVersionIdentity(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        var metadata = stat()
        guard file.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        let modified = "\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec)"
        let changed = "\(metadata.st_ctimespec.tv_sec):\(metadata.st_ctimespec.tv_nsec)"
        let born = "\(metadata.st_birthtimespec.tv_sec):\(metadata.st_birthtimespec.tv_nsec)"
        return "file-v2#\(file.path)#\(metadata.st_dev)#\(metadata.st_ino)#\(metadata.st_size)#\(modified)#\(changed)#\(born)"
    }

    public func identity(for url: URL) -> String? {
        PlaybackExperiencePolicy.resourceIdentity?(url) ?? Self.localIdentity(for: url)
    }

    private func key(for url: URL) -> String? {
        guard let identity = identity(for: url) else { return nil }
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func record(for url: URL) -> PlaybackExperienceRecord? {
        guard let key = key(for: url) else { return nil }
        return records[key]
    }

    /// Waits for all checkpoints queued before this call without blocking the main actor.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    public func save(_ record: PlaybackExperienceRecord, for url: URL, matching expectedIdentity: String? = nil) {
        if let expectedIdentity, identity(for: url) != expectedIdentity { return }
        guard record.position.isFinite, record.duration.isFinite, let key = key(for: url) else { return }
        records[key] = record
        while records.count > Self.maximumRecords, let oldest = records.min(by: { $0.value.updatedAt < $1.value.updatedAt }) {
            records.removeValue(forKey: oldest.key)
        }
        guard let destination, let encoded = try? JSONEncoder().encode(records) else { return }
        let logger = logger
        queue.async {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoded.write(to: destination, options: .atomic)
            } catch {
                logger.error("Playback checkpoint persistence failed: \(error.localizedDescription)")
            }
        }
    }
}
