// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import Foundation
import XCTest
@testable import TTMediaKit

final class MOVTrackRoutingAndAuthenticityTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MOVRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Real-World Audio-First MOV Sample

    func testRealWorldAudioFirstMOVRoutesToVideoAcrossDiskAndMemory() async throws {
        let fileURL = try resolveRealWorldSampleURL()

        // 1. Synchronous disk detection
        let syncType = TTMediaDetector.detectType(url: fileURL)
        guard case .video(let syncURL) = syncType, syncURL == fileURL else {
            XCTFail("Expected .video(\(fileURL)), got: \(syncType)")
            return
        }

        // 2. Asynchronous disk detection
        let asyncType = await TTMediaDetector.detectTypeAsync(url: fileURL)
        guard case .video(let asyncURL) = asyncType, asyncURL == fileURL else {
            XCTFail("Expected .video(\(fileURL)), got: \(asyncType)")
            return
        }

        // 3. In-memory detection (read leading 250 KB containing ftyp and entire moov)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let headerData = (try? handle.read(upToCount: 250 * 1024)) ?? Data()
        XCTAssertFalse(headerData.isEmpty)

        let memType = TTMediaDetector.detectTypeFromMemory(
            data: headerData,
            suggestedName: "社交媒体恐惧.mov",
            sourceURL: fileURL
        )
        defer { memType.releaseEphemeralMediaLease() }
        guard case .video = memType else {
            XCTFail("Expected .video for in-memory detection of 社交媒体恐惧.mov header, got: \(memType)")
            return
        }
    }

    func testRealWorldAudioFirstMOVStartsReadingInitialFrames() async throws {
        let fileURL = try resolveRealWorldSampleURL()
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            XCTFail("Could not load video track from real sample")
            return
        }
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        XCTAssertTrue(reader.startReading())
        XCTAssertEqual(reader.status, .reading)
        var frameCount = 0
        while let _ = trackOutput.copyNextSampleBuffer() {
            frameCount += 1
            if frameCount >= 10 { break }
        }
        XCTAssertGreaterThanOrEqual(frameCount, 1)
    }

    private func resolveRealWorldSampleURL() throws -> URL {
        guard let samplePath = ProcessInfo.processInfo.environment["TTMEDIA_REAL_AUDIO_FIRST_MOV_FIXTURE"],
              !samplePath.isEmpty else {
            throw XCTSkip("MANUAL audio-first MOV verification not run; set TTMEDIA_REAL_AUDIO_FIRST_MOV_FIXTURE explicitly")
        }
        guard FileManager.default.fileExists(atPath: samplePath) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: samplePath])
        }
        return URL(fileURLWithPath: samplePath)
    }

    // MARK: - 2. Synthetic Audio-First MOV with Large Sample Table (stbl > 50 KB)

    func testSyntheticAudioFirstMOVWithHighOffsetVideoTrack() async throws {
        let data = buildSyntheticMOV(audioTracksCount: 1, videoTracksCount: 1, audioStblPadding: 60_000)
        let fileURL = tempDir.appendingPathComponent("audio_first_dual_track.mov")
        try data.write(to: fileURL, options: .atomic)

        // 1. Disk detection
        let diskResult = TTMediaDetector.detectType(url: fileURL)
        guard case .video = diskResult else {
            XCTFail("Expected .video for audio-first dual track MOV on disk, got \(diskResult)")
            return
        }

        // 2. Memory detection
        let memResult = TTMediaDetector.detectTypeFromMemory(
            data: data,
            suggestedName: "audio_first_dual_track.mov",
            sourceURL: fileURL
        )
        defer { memResult.releaseEphemeralMediaLease() }
        guard case .video = memResult else {
            XCTFail("Expected .video for audio-first dual track MOV in memory, got \(memResult)")
            return
        }
    }

    // MARK: - 3. Synthetic Track with edts Padding Placing Handler Beyond 2 KiB

    func testSyntheticTrackWithEdtsPaddingPlacingHandlerBeyondTwoKiB() async throws {
        let data = buildSyntheticMOV(audioTracksCount: 0, videoTracksCount: 1, edtsPadding: 4_096)
        let fileURL = tempDir.appendingPathComponent("edts_padded_video.mov")
        try data.write(to: fileURL, options: .atomic)

        // 1. Disk detection
        let diskResult = TTMediaDetector.detectType(url: fileURL)
        guard case .video = diskResult else {
            XCTFail("Expected .video for edts-padded MOV on disk, got \(diskResult)")
            return
        }

        // 2. Memory detection
        let memResult = TTMediaDetector.detectTypeFromMemory(
            data: data,
            suggestedName: "edts_padded_video.mov",
            sourceURL: fileURL
        )
        defer { memResult.releaseEphemeralMediaLease() }
        guard case .video = memResult else {
            XCTFail("Expected .video for edts-padded MOV in memory, got \(memResult)")
            return
        }
    }

    // MARK: - 4. Scan Completeness: Budget Exhaustion Must Not Misclassify as Pure Audio

    func testMultipleAudioTracksExceedingBudgetMustNotDowngradeToWaveform() async throws {
        // 17 audio tracks followed by 1 video track (exceeds maxTrackBudget = 16)
        let data = buildSyntheticMOV(audioTracksCount: 17, videoTracksCount: 1)
        let fileURL = tempDir.appendingPathComponent("multi_track_budget_exhausted.mov")
        try data.write(to: fileURL, options: .atomic)

        // 1. Disk detection: scanner reaches 16 tracks, isCompleteScan is false -> falls back to container video
        let diskResult = TTMediaDetector.detectType(url: fileURL)
        guard case .video = diskResult else {
            XCTFail("Expected .video fallback due to incomplete scan, got \(diskResult)")
            return
        }

        // 2. Memory detection
        let memResult = TTMediaDetector.detectTypeFromMemory(
            data: data,
            suggestedName: "multi_track_budget_exhausted.mov",
            sourceURL: fileURL
        )
        defer { memResult.releaseEphemeralMediaLease() }
        guard case .video = memResult else {
            XCTFail("Expected .video fallback in memory due to incomplete scan, got \(memResult)")
            return
        }
    }

    // MARK: - 4b. Audio Brand (M4A) with Incomplete Scan Must Not Route to Audio

    func testAudioBrandWithBudgetExhaustionAndTrailingVideoTrackMustNotRouteToAudio() async throws {
        // M4A brand with 17 audio tracks followed by 1 video track (exceeds budget 16)
        let data = buildSyntheticMOV(audioTracksCount: 17, videoTracksCount: 1, majorBrand: "M4A ")
        let fileURL = tempDir.appendingPathComponent("disguised_audio_brand.m4a")
        try data.write(to: fileURL, options: .atomic)

        // 1. Disk detection: isCompleteScan is false -> audio brand fallback MUST NOT return .audio
        let diskResult = TTMediaDetector.detectType(url: fileURL)
        guard case .video = diskResult else {
            XCTFail("Expected .video fallback for M4A brand when scan is incomplete, got \(diskResult)")
            return
        }

        // 2. Memory detection
        let memResult = TTMediaDetector.detectTypeFromMemory(
            data: data,
            suggestedName: "disguised_audio_brand.m4a",
            sourceURL: fileURL
        )
        defer { memResult.releaseEphemeralMediaLease() }
        guard case .video = memResult else {
            XCTFail("Expected .video fallback in memory for M4A brand when scan is incomplete, got \(memResult)")
            return
        }
    }

    func testAudioBrandWithCompleteScanRoutesToAudio() async throws {
        let data = buildSyntheticMOV(audioTracksCount: 1, videoTracksCount: 0, majorBrand: "M4A ")
        let fileURL = tempDir.appendingPathComponent("standard_voice.m4a")
        try data.write(to: fileURL, options: .atomic)

        let diskResult = TTMediaDetector.detectType(url: fileURL)
        guard case .audio = diskResult else {
            XCTFail("Expected .audio for confirmed pure audio M4A, got \(diskResult)")
            return
        }

        let memResult = TTMediaDetector.detectTypeFromMemory(
            data: data,
            suggestedName: "standard_voice.m4a",
            sourceURL: fileURL
        )
        defer { memResult.releaseEphemeralMediaLease() }
        guard case .audio = memResult else {
            XCTFail("Expected .audio for in-memory pure audio M4A, got \(memResult)")
            return
        }
    }

    // MARK: - 5. Pure Audio QuickTime / MOV Sample Confirmed as Audio

    func testSyntheticPureAudioMOVPreservedAsAudioAcrossEntryPoints() async throws {
        let audioOnlyData = buildSyntheticMOV(audioTracksCount: 1, videoTracksCount: 0, audioStblPadding: 512)
        let fileURL = tempDir.appendingPathComponent("voice_memo.mov")
        try audioOnlyData.write(to: fileURL, options: .atomic)

        // 1. Synchronous disk detection
        let diskResult = TTMediaDetector.detectType(url: fileURL)
        guard case .audio = diskResult else {
            XCTFail("Expected .audio for confirmed pure audio MOV, got: \(diskResult)")
            return
        }

        // 2. Asynchronous disk detection
        let asyncResult = await TTMediaDetector.detectTypeAsync(url: fileURL)
        guard case .audio = asyncResult else {
            XCTFail("Expected .audio for async pure audio MOV, got: \(asyncResult)")
            return
        }

        // 3. Memory detection
        let memResult = TTMediaDetector.detectTypeFromMemory(
            data: audioOnlyData,
            suggestedName: "voice_memo.mov",
            sourceURL: fileURL
        )
        defer { memResult.releaseEphemeralMediaLease() }
        guard case .audio = memResult else {
            XCTFail("Expected .audio for in-memory pure audio MOV, got: \(memResult)")
            return
        }
    }

    // MARK: - 6. Silent Video MOV Sample (No Audio Track)

    func testSyntheticSilentVideoMOVRoutesToVideo() async throws {
        let videoOnlyData = buildSyntheticMOV(audioTracksCount: 0, videoTracksCount: 1)
        let fileURL = tempDir.appendingPathComponent("silent_animation.mov")
        try videoOnlyData.write(to: fileURL, options: .atomic)

        let diskResult = TTMediaDetector.detectType(url: fileURL)
        guard case .video = diskResult else {
            XCTFail("Expected .video for silent video MOV, got: \(diskResult)")
            return
        }

        let memResult = TTMediaDetector.detectTypeFromMemory(
            data: videoOnlyData,
            suggestedName: "silent_animation.mov"
        )
        defer { memResult.releaseEphemeralMediaLease() }
        guard case .video = memResult else {
            XCTFail("Expected .video for silent video in memory, got: \(memResult)")
            return
        }
    }

    // MARK: - 7. Truncated & Abnormal Box Sizes

    func testTruncatedQuickTimeFileFallsBackToVideoDescriptor() {
        var truncated = Data()
        truncated.append(contentsOf: [0x00, 0x00, 0x00, 0x14])
        truncated.append(Data("ftypqt  ".utf8))
        truncated.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        truncated.append(Data("qt  ".utf8))
        truncated.append(Data(repeating: 0x00, count: 64))

        let kind = TTMediaDetector.probeMagicBytes(data: truncated)
        XCTAssertEqual(kind, .video(mime: "video/quicktime"))

        let memResult = TTMediaDetector.detectTypeFromMemory(data: truncated, suggestedName: "truncated.mov")
        defer { memResult.releaseEphemeralMediaLease() }
        guard case .video = memResult else {
            XCTFail("Expected brand fallback .video for truncated qt brand, got \(memResult)")
            return
        }
    }

    func testMalformedBoxHeaderHandledSafelyWithoutCrash() {
        // Box with size 1 (64-bit size) declaring huge size exceeding total length
        var malformed = Data()
        malformed.append(contentsOf: [0x00, 0x00, 0x00, 0x14])
        malformed.append(Data("ftypqt  ".utf8))
        malformed.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        malformed.append(Data("qt  ".utf8))
        // moov box header: size 1 followed by huge 64-bit size
        malformed.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        malformed.append(Data("moov".utf8))
        malformed.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00])

        let kind = TTMediaDetector.probeMagicBytes(data: malformed)
        XCTAssertEqual(kind, .video(mime: "video/quicktime"))
    }

    private func buildBox(type: String, payload: Data) -> Data {
        var box = Data()
        let size = UInt32(payload.count + 8).bigEndian
        withUnsafeBytes(of: size) { box.append(contentsOf: $0) }
        box.append(Data(type.utf8))
        box.append(payload)
        return box
    }

    private func buildMdiaBox(handlerType: String, stblPadding: Int) -> Data {
        var mdiaPayload = Data()

        // mdhd (20 bytes zero payload)
        mdiaPayload.append(buildBox(type: "mdhd", payload: Data(repeating: 0x00, count: 20)))

        // hdlr box (24 bytes payload)
        var hdlr = Data([0x00, 0x00, 0x00, 0x00])
        hdlr.append(Data("mhlr".utf8))
        hdlr.append(Data(handlerType.utf8))
        hdlr.append(Data(repeating: 0x00, count: 12))
        mdiaPayload.append(buildBox(type: "hdlr", payload: hdlr))

        // minf container
        var minfPayload = Data()
        if handlerType == "vide" {
            var vmhd = Data([0x00, 0x00, 0x00, 0x01])
            vmhd.append(Data(repeating: 0x00, count: 8))
            minfPayload.append(buildBox(type: "vmhd", payload: vmhd))
        } else {
            var smhd = Data([0x00, 0x00, 0x00, 0x00])
            smhd.append(Data(repeating: 0x00, count: 4))
            minfPayload.append(buildBox(type: "smhd", payload: smhd))
        }
        let stblData = stblPadding > 0 ? Data(repeating: 0x00, count: stblPadding) : Data()
        minfPayload.append(buildBox(type: "stbl", payload: stblData))
        mdiaPayload.append(buildBox(type: "minf", payload: minfPayload))

        return buildBox(type: "mdia", payload: mdiaPayload)
    }

    private func buildTrackBox(
        handlerType: String,
        stblPadding: Int = 0,
        edtsPadding: Int = 0
    ) -> Data {
        var trakPayload = Data()
        trakPayload.append(buildBox(type: "tkhd", payload: Data(repeating: 0x00, count: 24)))
        if edtsPadding > 0 {
            trakPayload.append(buildBox(type: "edts", payload: Data(repeating: 0x00, count: edtsPadding)))
        }
        trakPayload.append(buildMdiaBox(handlerType: handlerType, stblPadding: stblPadding))
        return buildBox(type: "trak", payload: trakPayload)
    }

    private func buildSyntheticMOV(
        audioTracksCount: Int = 0,
        videoTracksCount: Int = 0,
        audioStblPadding: Int = 0,
        edtsPadding: Int = 0,
        majorBrand: String = "qt  "
    ) -> Data {
        var fileData = Data()

        // 1. ftyp box (12 bytes payload)
        var ftyp = Data(majorBrand.utf8)
        ftyp.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        ftyp.append(Data(majorBrand.utf8))
        fileData.append(buildBox(type: "ftyp", payload: ftyp))

        // 2. moov container
        var moovPayload = buildBox(type: "mvhd", payload: Data(repeating: 0x00, count: 100))

        if audioTracksCount > 0 {
            for _ in 0..<audioTracksCount {
                moovPayload.append(buildTrackBox(
                    handlerType: "soun",
                    stblPadding: audioStblPadding,
                    edtsPadding: edtsPadding
                ))
            }
        }
        if videoTracksCount > 0 {
            for _ in 0..<videoTracksCount {
                moovPayload.append(buildTrackBox(
                    handlerType: "vide",
                    stblPadding: 0,
                    edtsPadding: edtsPadding
                ))
            }
        }
        fileData.append(buildBox(type: "moov", payload: moovPayload))
        return fileData
    }
}
