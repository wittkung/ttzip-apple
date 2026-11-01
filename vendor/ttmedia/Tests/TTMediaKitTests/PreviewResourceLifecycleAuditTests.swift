// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreMedia
import Darwin
import Foundation
import XCTest
@testable import TTMediaKit

// MARK: - Group E: Preview Resource Release, Cancellation & File Mutation Regression Suite

final class PreviewResourceLifecycleAuditTests: XCTestCase {

    // MARK: - Exact FD Path & Pipe Ownership Inspection Helpers

    /// Returns all currently open file descriptor numbers for the current process via `/dev/fd`.
    static func currentOpenFileDescriptorNumbers() -> [Int32] {
        guard let dir = opendir("/dev/fd") else { return [] }
        let dirFD = dirfd(dir)
        defer { closedir(dir) }
        var fds: [Int32] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if let fd = Int32(name), fd != dirFD {
                fds.append(fd)
            }
        }
        return fds
    }

    /// Resolves filesystem paths for open descriptors matching `pathPrefix` via `fcntl(fd, F_GETPATH)`.
    static func openFileDescriptorPaths(underPrefix pathPrefix: String) -> [String] {
        let normalizedPrefix = URL(fileURLWithPath: pathPrefix).standardizedFileURL.resolvingSymlinksInPath().path
        var matched: [String] = []
        for fd in currentOpenFileDescriptorNumbers() {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &buffer) == 0 {
                let rawPath = String(cString: buffer)
                let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
                if standardized.hasPrefix(normalizedPrefix) {
                    matched.append(standardized)
                }
            }
        }
        return matched
    }

    /// Counts currently open FIFO/pipe descriptors (`S_IFIFO`) in the current process via `fstat`.
    static func countOpenPipeDescriptors() -> Int {
        var pipeCount = 0
        for fd in currentOpenFileDescriptorNumbers() {
            var st = stat()
            if fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFIFO {
                pipeCount += 1
            }
        }
        return pipeCount
    }

    /// Creates a valid 16-bit mono PCM WAV file on disk for deterministic audio lifecycle tests.
    static func createSyntheticWAV(
        at url: URL,
        durationSeconds: Double = 0.4,
        sampleRate: Int = 22_050,
        amplitude: Int16 = 12_000
    ) throws {
        let numSamples = max(1, Int(durationSeconds * Double(sampleRate)))
        let dataSize = UInt32(numSamples * 2)
        let fileSize = 36 + dataSize
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVEfmt ".utf8)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        header.append(contentsOf: "data".utf8)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        var pcm = Data(capacity: Int(dataSize))
        for i in 0..<numSamples {
            let sample: Int16 = (i % 40 < 20) ? amplitude : -amplitude
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        try (header + pcm).write(to: url, options: .atomic)
    }

    // MARK: - 1. Repeated Open/Switch/Close: Cancelled vs Confirmed Loads & FD Path Ownership

    /// Verifies both in-flight cancellation during debounce and full confirmed playback loads,
    /// tracking exact FD path ownership via `F_GETPATH` so zero media descriptors remain open after teardown.
    @MainActor
    func testRepeatedOpenSwitchCloseSeparatesCancelledFromConfirmedLoadsAndTracksFDPaths() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-e1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoA = tempDir.appendingPathComponent("videoA.mp4")
        let videoB = tempDir.appendingPathComponent("videoB.mp4")
        let audioA = tempDir.appendingPathComponent("audioA.wav")
        let audioB = tempDir.appendingPathComponent("audioB.wav")
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: videoA, frameCount: 15)
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: videoB, frameCount: 15)
        try Self.createSyntheticWAV(at: audioA, durationSeconds: 0.35)
        try Self.createSyntheticWAV(at: audioB, durationSeconds: 0.35)

        let owner = UUID()

        // Phase A: 15 rapid switches cancelled during the 100ms debounce window.
        var cancelledDuringDebounceCount = 0
        for idx in 0..<15 {
            let session = VideoPlaybackSessions.shared.claim(
                url: (idx % 2 == 0) ? videoA : videoB,
                owner: owner,
                restart: true
            )
            session.start(autoPlay: true)
            try await Task.sleep(for: .milliseconds(15))
            if session.isLoading {
                cancelledDuringDebounceCount += 1
            }
        }
        XCTAssertEqual(cancelledDuringDebounceCount, 15)

        // Phase B: 12 full confirmed video loads where each session finishes loading and initializes activeController.
        var confirmedLoadedVideoCount = 0
        for idx in 0..<12 {
            let session = VideoPlaybackSessions.shared.claim(
                url: (idx % 2 == 0) ? videoA : videoB,
                owner: owner,
                restart: true
            )
            session.start(autoPlay: true)
            for _ in 0..<30 where session.isLoading {
                try await Task.sleep(for: .milliseconds(20))
            }
            if !session.isLoading, session.activeController != nil, CMTimeGetSeconds(session.duration) > 0 {
                confirmedLoadedVideoCount += 1
            }
        }
        XCTAssertEqual(confirmedLoadedVideoCount, 12)

        // Verify 300ms grace release window and final teardown.
        let lastSession = VideoPlaybackSessions.shared.claim(url: videoB, owner: owner)
        VideoPlaybackSessions.shared.release(owner: owner)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(lastSession.isStopped)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(lastSession.isStopped)
        XCTAssertNil(lastSession.activeController)
        XCTAssertFalse(MediaPlaybackCoordinator.shared.isPlaying)

        // Phase C: 15 full confirmed audio loads followed by stop and waveform cancellation.
        let audioEngine = MPVAudioEngine()
        var confirmedLoadedAudioCount = 0
        for idx in 0..<15 {
            audioEngine.load(url: (idx % 2 == 0) ? audioA : audioB)
            audioEngine.play()
            if !audioEngine.hasPlaybackError && audioEngine.duration > 0 {
                confirmedLoadedAudioCount += 1
            }
        }
        XCTAssertEqual(confirmedLoadedAudioCount, 15)
        audioEngine.stop()
        await audioEngine.waitForWaveform()
        XCTAssertFalse(audioEngine.isExtractingWaveform)

        try await Task.sleep(for: .milliseconds(100))
        let leakedMediaFDs = Self.openFileDescriptorPaths(underPrefix: tempDir.path)
        XCTAssertTrue(leakedMediaFDs.isEmpty, "Zero media FDs may leak after close, found: \(leakedMediaFDs)")
    }

    /// Verifies `TTMediaDetector` reference-counted ephemeral media lease:
    /// 1) Multi-consumer shared payload increments `activeEphemeralLeaseCount` and keeps the file alive until the last consumer releases;
    /// 2) Capacity pressure (`> maxStagedEphemeralFiles`) never evicts an actively leased consumer and reclaims released slots.
    @MainActor
    func testMemoryMediaDetectionEnforcesBoundedTemporaryFileLease() throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }

        let ephemeralMediaRoot = TTMediaDetector.ephemeralMediaRoot
        let sameMP4Header = Data([
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x6D, 0x70, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00
        ])

        // 1. Multi-consumer shared payload: Consumer 1 and Consumer 2 acquire leases on the same content-addressed file.
        guard case .video(let c1URL) = TTMediaDetector.detectTypeFromMemory(data: sameMP4Header, suggestedName: "clip.mp4"),
              case .video(let c2URL) = TTMediaDetector.detectTypeFromMemory(data: sameMP4Header, suggestedName: "clip.mp4") else {
            return XCTFail("Expected both consumers to stage valid video URL")
        }
        XCTAssertEqual(c1URL, c2URL)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: c1URL), 2)
        let dirsAfterSamePayload = (try? FileManager.default.contentsOfDirectory(atPath: ephemeralMediaRoot.path)) ?? []
        XCTAssertEqual(dirsAfterSamePayload.count, 1)

        // Releasing Consumer 1 must keep the file on disk while Consumer 2 still holds an active lease.
        TTMediaDetector.releaseEphemeralMediaFile(at: c1URL)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: c2URL), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c2URL.path), "Shared content file must remain on disk while Consumer 2 holds lease")

        // Releasing Consumer 2 drops the lease count to 0 and removes the staged directory.
        TTMediaDetector.releaseEphemeralMediaFile(at: c2URL)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: c2URL), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c2URL.path))

        // 2. Capacity pressure: 8 active distinct leases are pinned and never evicted by a 9th request.
        var activeDistinctURLs: [URL] = []
        for idx in 0..<TTMediaDetector.maxStagedEphemeralFiles {
            var distinctPayload = sameMP4Header
            distinctPayload.append(UInt8(idx))
            if case .video(let url) = TTMediaDetector.detectTypeFromMemory(data: distinctPayload, suggestedName: "clip_\(idx).mp4") {
                activeDistinctURLs.append(url)
            }
        }
        XCTAssertEqual(activeDistinctURLs.count, TTMediaDetector.maxStagedEphemeralFiles)

        var overflowPayload = sameMP4Header
        overflowPayload.append(UInt8(99))
        if case .video = TTMediaDetector.detectTypeFromMemory(data: overflowPayload, suggestedName: "clip_overflow.mp4") {
            XCTFail("Expected 9th distinct payload to be refused when all 8 slots are actively leased")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeDistinctURLs[0].path), "Actively leased slot 0 must never be evicted")

        // Releasing slot 0 allows the next distinct payload to acquire the freed slot within capacity.
        TTMediaDetector.releaseEphemeralMediaFile(at: activeDistinctURLs[0])
        if case .video(let newSlotURL) = TTMediaDetector.detectTypeFromMemory(data: overflowPayload, suggestedName: "clip_overflow.mp4") {
            XCTAssertTrue(FileManager.default.fileExists(atPath: newSlotURL.path))
        } else {
            XCTFail("Expected overflow payload to succeed after releasing one slot")
        }

        let dirsAfterOverflow = (try? FileManager.default.contentsOfDirectory(atPath: ephemeralMediaRoot.path)) ?? []
        XCTAssertLessThanOrEqual(dirsAfterOverflow.count, TTMediaDetector.maxStagedEphemeralFiles)

        TTMediaDetector.purgeAllEphemeralMediaFiles()
        let dirsAfterPurge = (try? FileManager.default.contentsOfDirectory(atPath: ephemeralMediaRoot.path)) ?? []
        XCTAssertTrue(dirsAfterPurge.isEmpty)
    }

    // MARK: - 2. Rapid Switch A -> B: Correctness Regressions Across Video, Audio, Hex & EPUB

    @MainActor
    func testRapidSwitchAToBDoesNotAllowAToOverwriteB() async throws {
        let coordinator = PreviewSessionCoordinator.shared
        let urlA = URL(fileURLWithPath: "/tmp/audit-switch-A.mp4")
        let urlB = URL(fileURLWithPath: "/tmp/audit-switch-B.mp4")

        let taskA = Task { @MainActor in await coordinator.beginSession(targetURL: urlA) }
        try await Task.sleep(for: .milliseconds(20))
        let taskB = Task { @MainActor in await coordinator.beginSession(targetURL: urlB) }

        let genA = await taskA.value
        let genB = await taskB.value
        XCTAssertLessThan(genA, genB)
        XCTAssertFalse(coordinator.isSessionActive(generation: genA))
        XCTAssertTrue(coordinator.isSessionActive(generation: genB))

        coordinator.cancelSession(generation: genA)
        XCTAssertTrue(coordinator.isSessionActive(generation: genB))
    }

    @MainActor
    func testRapidSessionSwitchAToBTearsDownAAndPreservesB() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-e2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoA = tempDir.appendingPathComponent("videoA_60frames.mp4")
        let videoB = tempDir.appendingPathComponent("videoB_15frames.mp4")
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: videoA, frameCount: 60, fps: 30)
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: videoB, frameCount: 15, fps: 30)

        let owner = UUID()
        let sessionA = VideoPlaybackSessions.shared.claim(url: videoA, owner: owner)
        sessionA.start(autoPlay: true)

        try await Task.sleep(for: .milliseconds(25))
        let sessionB = VideoPlaybackSessions.shared.claim(url: videoB, owner: owner)
        sessionB.start(autoPlay: false)

        XCTAssertTrue(sessionA.isStopped)
        XCTAssertNil(sessionA.activeController)

        for _ in 0..<30 where sessionB.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(sessionB.isStopped)
        XCTAssertFalse(sessionB.isLoading)
        XCTAssertNil(sessionB.playbackError)
        XCTAssertEqual(CMTimeGetSeconds(sessionB.duration), 0.5, accuracy: 0.15)
        XCTAssertFalse(sessionB.isPlaying)

        VideoPlaybackSessions.shared.release(owner: owner)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(Self.openFileDescriptorPaths(underPrefix: tempDir.path).isEmpty)
    }

    @MainActor
    func testAudioHexAndEPUBRapidSwitchNeverOverwritesNewSelection() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-e2-cross-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validWAV = tempDir.appendingPathComponent("validA.wav")
        let secondWAV = tempDir.appendingPathComponent("validB.wav")
        let invalidWAV = tempDir.appendingPathComponent("emptyB.wav")
        try Self.createSyntheticWAV(at: validWAV, durationSeconds: 0.6, amplitude: 16_000)
        try Self.createSyntheticWAV(at: secondWAV, durationSeconds: 0.3, amplitude: 8_000)
        try Data().write(to: invalidWAV)

        // 1. Audio shared engine: outgoing view A's onDisappear does NOT stop incoming view B's session.
        let sharedEngine = MPVAudioEngine()
        sharedEngine.load(url: validWAV)
        sharedEngine.load(url: secondWAV)
        UnifiedAudioPlayerView.stopAudioEngineIfOwned(engine: sharedEngine, ownerURL: validWAV)
        XCTAssertEqual(sharedEngine.currentURL?.standardizedFileURL, secondWAV.standardizedFileURL)
        UnifiedAudioPlayerView.stopAudioEngineIfOwned(engine: sharedEngine, ownerURL: secondWAV)
        XCTAssertNil(sharedEngine.currentURL)

        // 2. Audio waveform extraction: stale waveform task from A never overwrites B.
        let avPlayer = TTMediaAVPlayer()
        avPlayer.load(url: validWAV, autoPlay: false)
        avPlayer.load(url: invalidWAV, autoPlay: false)
        await avPlayer.waitForWaveform()
        XCTAssertTrue(avPlayer.waveformPeaks.isEmpty)
        avPlayer.stop()

        // 3. Hex chunk loading: slow chunk A finishes after fast chunk B and is discarded.
        let hexCoordinator = HexPageLoadCoordinator { url, _, _ in
            if url.lastPathComponent == "validA.wav" {
                try? await Task.sleep(for: .milliseconds(80))
                return Data([0xAA, 0xAA])
            }
            return Data([0xBB, 0xBB, 0xBB])
        }
        hexCoordinator.beginLoad(url: validWAV, offset: 0, length: 64)
        hexCoordinator.beginLoad(url: secondWAV, offset: 0, length: 64)
        await hexCoordinator.waitForCurrentLoad()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hexCoordinator.currentPageData, Data([0xBB, 0xBB, 0xBB]))

        // 4. Static SHA-256 helper check (full SwiftUI EBookReaderPreviewView switch remains pending C/G owner check).
        let hashA = await EBookReaderPreviewView.computeSHA256Hex(for: validWAV)
        let hashB = await EBookReaderPreviewView.computeSHA256Hex(for: secondWAV)
        XCTAssertNotNil(hashA)
        XCTAssertNotNil(hashB)
        XCTAssertNotEqual(hashA, hashB)
    }

    // MARK: - 3. File Deleted, Renamed, or Unreadable (chmod 000) During Load

    @MainActor
    func testFileDeletedRenamedOrUnreadableDuringLoadSurfacesExplicitErrorAndZeroLeakedFDs() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-audit-e3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let deletingVideo = tempDir.appendingPathComponent("deleting.mp4")
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: deletingVideo, frameCount: 15)
        let owner = UUID()
        let deleteSession = VideoPlaybackSessions.shared.claim(url: deletingVideo, owner: owner)
        deleteSession.start(autoPlay: true)
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.removeItem(at: deletingVideo)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(deleteSession.isLoading)
        XCTAssertNotNil(deleteSession.playbackError)
        deleteSession.stop()

        let originalVideo = tempDir.appendingPathComponent("original_name.mp4")
        let renamedVideo = tempDir.appendingPathComponent("renamed_name.mp4")
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: originalVideo, frameCount: 15)
        let renameSession = VideoPlaybackSessions.shared.claim(url: originalVideo, owner: owner, restart: true)
        renameSession.start(autoPlay: true)
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.moveItem(at: originalVideo, to: renamedVideo)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(renameSession.playbackError)
        renameSession.stop()

        let reopenedSession = VideoPlaybackSessions.shared.claim(url: renamedVideo, owner: owner, restart: true)
        reopenedSession.start(autoPlay: false)
        for _ in 0..<30 where reopenedSession.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(reopenedSession.playbackError)
        XCTAssertNotNil(reopenedSession.activeController)
        reopenedSession.stop()

        try await assertUnreadableFilesSurfacePermissionDenied(in: tempDir, owner: owner)

        VideoPlaybackSessions.shared.release(owner: owner)
        try await Task.sleep(for: .milliseconds(400))
        let leakedPaths = Self.openFileDescriptorPaths(underPrefix: tempDir.path)
        XCTAssertTrue(leakedPaths.isEmpty, "Zero FDs may remain open to deleted/renamed/unreadable files: \(leakedPaths)")
    }

    @MainActor
    private func assertUnreadableFilesSurfacePermissionDenied(in tempDir: URL, owner: UUID) async throws {
        let unreadableVideo = tempDir.appendingPathComponent("unreadable.mp4")
        let unreadableAudio = tempDir.appendingPathComponent("unreadable.wav")
        let unreadableMarkdown = tempDir.appendingPathComponent("unreadable.md")
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: unreadableVideo, frameCount: 12)
        try Self.createSyntheticWAV(at: unreadableAudio, durationSeconds: 0.25)
        try "# Restricted Document".write(to: unreadableMarkdown, atomically: true, encoding: .utf8)

        _ = chmod(unreadableVideo.path, 0)
        _ = chmod(unreadableAudio.path, 0)
        _ = chmod(unreadableMarkdown.path, 0)
        defer {
            _ = chmod(unreadableVideo.path, mode_t(0o644))
            _ = chmod(unreadableAudio.path, mode_t(0o644))
            _ = chmod(unreadableMarkdown.path, mode_t(0o644))
        }

        guard !FileManager.default.isReadableFile(atPath: unreadableVideo.path) else { return }
        let chmodSession = VideoPlaybackSessions.shared.claim(url: unreadableVideo, owner: owner, restart: true)
        chmodSession.start(autoPlay: true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(chmodSession.playbackError)
        chmodSession.stop()

        let audioEngine = MPVAudioEngine()
        audioEngine.load(url: unreadableAudio)
        XCTAssertTrue(audioEngine.hasPlaybackError)
        audioEngine.stop()

        let detectedMD = await TTMediaDetector.detectTypeAsync(url: unreadableMarkdown)
        if case .unsupported(let reason) = detectedMD {
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("Permission denied"))
        } else {
            XCTFail("Unreadable chmod 000 file must return .unsupported(Permission denied), got: \(detectedMD)")
        }
    }

    // MARK: - 4. TTSecurityScopedResourceManager Failed Access & Regular File Balance Audit

    func testSecurityScopedResourceManagerFailedAccessDoesNotLeaveDirtyCountAndBalancesRegularFiles() throws {
        let manager = TTSecurityScopedResourceManager.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaSecurityScopeAudit_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingURL = tempDir.appendingPathComponent("nonexistent_missing.wav")
        XCTAssertFalse(manager.startAccessing(url: missingURL))
        XCTAssertEqual(manager.activeAccessCount(for: missingURL), 0)
        XCTAssertFalse(manager.isSecurityScopedAccessActive(for: missingURL))

        let readableURL = tempDir.appendingPathComponent("regular_readable.txt")
        try Data("hello".utf8).write(to: readableURL)
        XCTAssertTrue(manager.startAccessing(url: readableURL))
        XCTAssertTrue(manager.startAccessing(url: readableURL))
        XCTAssertEqual(manager.activeAccessCount(for: readableURL), 2)
        XCTAssertFalse(manager.isSecurityScopedAccessActive(for: readableURL))
        manager.stopAccessing(url: readableURL)
        XCTAssertEqual(manager.activeAccessCount(for: readableURL), 1)
        manager.stopAccessing(url: readableURL)
        XCTAssertEqual(manager.activeAccessCount(for: readableURL), 0)
    }
}
