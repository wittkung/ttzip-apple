// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Darwin
import CoreMedia
import XCTest
@testable import TTMediaKit

@MainActor
final class PlaybackExperiencePersistenceTests: XCTestCase {
    func testCompleteProfileSurvivesDiskRoundTripAndRestoresIntoSession() async throws {
        let previousResolver = PlaybackExperiencePolicy.resourceIdentity
        defer { PlaybackExperiencePolicy.resourceIdentity = previousResolver }
        PlaybackExperiencePolicy.resourceIdentity = { "profile-test#" + $0.absoluteString }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = directory.appendingPathComponent("profile.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(fileURLWithPath: "/playback-test/profile.mov")
        let store = PlaybackExperienceStore(storageURL: destination)
        var record = PlaybackExperienceRecord()
        record.position = 37
        record.duration = 120
        record.rotationDegrees = 270
        record.volume = 0.37
        record.muted = true
        record.rate = 1.75
        record.primarySubtitle = "embedded:3"
        record.secondarySubtitle = "embedded:8"
        record.subtitleStyle = SubtitleStyleConfiguration(
            fontFamilyName: "Helvetica Neue", scale: 1.25, isBold: true, isItalic: true,
            textColor: .yellow, borderWidth: 1.5, backgroundOpacity: 0.6,
            verticalPosition: 83, delay: 1.4, relativeFontRatio: 0.05
        )
        store.save(record, for: url)
        await store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let reloaded = PlaybackExperienceStore(storageURL: destination)
        XCTAssertEqual(reloaded.record(for: url), record)
        let session = VideoPlaybackSession(url: url, experienceStore: reloaded)
        session.duration = CMTime(seconds: 120, preferredTimescale: 600)
        XCTAssertEqual(CMTimeGetSeconds(session.restoredExperienceTime(or: .zero)), 37)
        XCTAssertEqual(session.userRotationDegrees, 270)
        XCTAssertEqual(session.volume, 0.37)
        XCTAssertTrue(session.isMuted)
        XCTAssertEqual(session.playbackRate, 1.75)
        XCTAssertEqual(session.selectedSubtitleID, "embedded:3")
        XCTAssertEqual(session.selectedSecondarySubtitleID, "embedded:8")
        XCTAssertEqual(session.subtitleStyle, record.subtitleStyle)
    }

    func testAtomicReplacementWithSameSizeAndMTimeCannotReuseCachedIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("same.mov")
        try Data("old-data".utf8).write(to: url)
        let original = try XCTUnwrap(PlaybackExperienceStore.fileVersionIdentity(for: url))
        let cached = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let modified = try XCTUnwrap(cached.contentModificationDate)
        try Data("new-data".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url).count, cached.fileSize)
        XCTAssertNotEqual(PlaybackExperienceStore.fileVersionIdentity(for: url), original)
        XCTAssertNil(PlaybackExperienceStore.localIdentity(for: url), "Low-level fingerprints must not relax temporary-file persistence policy")
    }

    func testInPlaceRewritePreservingExactMTimeChangesFreshVersionAndRejectsOldCheckpoint() async throws {
        let previousResolver = PlaybackExperiencePolicy.resourceIdentity
        defer { PlaybackExperiencePolicy.resourceIdentity = previousResolver }
        PlaybackExperiencePolicy.resourceIdentity = { PlaybackExperienceStore.fileVersionIdentity(for: $0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("same.mov")
        try Data("old-data".utf8).write(to: url)
        var before = stat()
        XCTAssertEqual(url.path.withCString { Darwin.lstat($0, &before) }, 0)
        let original = try XCTUnwrap(PlaybackExperienceStore.fileVersionIdentity(for: url))
        let store = PlaybackExperienceStore(storageURL: directory.appendingPathComponent("profile.json"))
        var record = PlaybackExperienceRecord()
        record.position = 20
        record.duration = 100
        store.save(record, for: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("new-data".utf8))
        try handle.close()
        let times = [before.st_atimespec, before.st_mtimespec]
        let result = times.withUnsafeBufferPointer { buffer in
            url.path.withCString { Darwin.utimensat(AT_FDCWD, $0, buffer.baseAddress, 0) }
        }
        XCTAssertEqual(result, 0)
        var after = stat()
        XCTAssertEqual(url.path.withCString { Darwin.lstat($0, &after) }, 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertNotEqual(PlaybackExperienceStore.fileVersionIdentity(for: url), original)
        XCTAssertNil(store.record(for: url))
        store.save(record, for: url, matching: original)
        XCTAssertNil(store.record(for: url))
        await store.flush()
    }
}
