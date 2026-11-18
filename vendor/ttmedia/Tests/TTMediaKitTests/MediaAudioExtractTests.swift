// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreAudioTypes
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import TTMediaKit

@MainActor
final class MediaAudioExtractTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let baseTemp = FileManager.default.temporaryDirectory
        tempDirectoryURL = baseTemp.appendingPathComponent(
            "MediaAudioExtractTests_\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        let manager = MediaAudioExtractManager.shared
        manager.cancelExtraction()
        manager.savePanelPresenter = nil
        manager.errorMessage = nil
        manager.lastExtractedURL = nil
        manager.lastExtractResult = nil
        manager.availableTracks = []
        manager.selectedTrackIndex = 0
        manager.selectedMode = .encapsulatedM4a
        manager.isAudioExtractPopoverPresented = false
        MediaAudioExtractPipeline.shared.simulatedExtractDelayNanoseconds = 0
        MediaAudioExtractPipeline.shared.maxInMemoryInputBytes = 256 * 1024 * 1024
    }

    override func tearDown() async throws {
        let manager = MediaAudioExtractManager.shared
        manager.cancelExtraction()
        manager.savePanelPresenter = nil
        MediaAudioExtractPipeline.shared.simulatedExtractDelayNanoseconds = 0
        MediaAudioExtractPipeline.shared.maxInMemoryInputBytes = 256 * 1024 * 1024
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try await super.tearDown()
    }

    func testSingleAndMultiTrackMP4AndMOVToM4ASelectsRequestedAudioTrackAndPreservesMetadata() async throws {
        let sourceMP4URL = tempDirectoryURL.appendingPathComponent("dual_audio_clip.mp4")
        try await Self.writeDualAudioISOBMFFFixture(to: sourceMP4URL, fileType: .mp4, durationSeconds: 1.2)

        let customMTime = Date(timeIntervalSinceNow: -7200)
        try FileManager.default.setAttributes(
            [.modificationDate: customMTime, .posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: sourceMP4URL.path
        )

        let pipeline = MediaAudioExtractPipeline.shared
        let tracks = await pipeline.discoverAudioTracks(in: sourceMP4URL)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].codec, .aac)
        XCTAssertEqual(tracks[0].channels, 2)
        XCTAssertEqual(tracks[0].sampleRate, 44100.0, accuracy: 1.0)
        XCTAssertEqual(tracks[1].codec, .aac)
        XCTAssertEqual(tracks[1].channels, 1)
        XCTAssertEqual(tracks[1].sampleRate, 48000.0, accuracy: 1.0)

        XCTAssertEqual(
            pipeline.defaultOutputURL(for: sourceMP4URL, mode: .encapsulatedM4a, codec: .aac, trackIndex: 0),
            tempDirectoryURL.appendingPathComponent("dual_audio_clip_audio.m4a")
        )
        XCTAssertEqual(
            pipeline.defaultOutputURL(for: sourceMP4URL, mode: .encapsulatedM4a, codec: .aac, trackIndex: 1),
            tempDirectoryURL.appendingPathComponent("dual_audio_clip_audio_track2.m4a")
        )

        let track0URL = tempDirectoryURL.appendingPathComponent("extracted_track0.m4a")
        let res0 = try await pipeline.extractAudioTrack(
            sourceURL: sourceMP4URL,
            destinationURL: track0URL,
            options: MediaAudioExtractOptions(mode: .encapsulatedM4a, trackIndex: 0)
        )
        XCTAssertEqual(res0.executionPath, .avFoundationM4A)
        XCTAssertEqual(res0.channels, 2)
        XCTAssertEqual(res0.sampleRate, 44100.0, accuracy: 1.0)
        try await assertValidM4AOutput(
            at: track0URL,
            sourceURL: sourceMP4URL,
            expectedChannels: 2,
            expectedSampleRate: 44100.0,
            expectedDuration: 1.2,
            expectedMTime: customMTime
        )

        let track1URL = tempDirectoryURL.appendingPathComponent("extracted_track1.m4a")
        let res1 = try await pipeline.extractAudioTrack(
            sourceURL: sourceMP4URL,
            destinationURL: track1URL,
            options: MediaAudioExtractOptions(mode: .encapsulatedM4a, trackIndex: 1)
        )
        XCTAssertEqual(res1.executionPath, .avFoundationM4A)
        XCTAssertEqual(res1.channels, 1)
        XCTAssertEqual(res1.sampleRate, 48000.0, accuracy: 1.0)
        try await assertValidM4AOutput(
            at: track1URL,
            sourceURL: sourceMP4URL,
            expectedChannels: 1,
            expectedSampleRate: 48000.0,
            expectedDuration: 1.2,
            expectedMTime: customMTime
        )
    }

    func testRustBitstreamExtractionFromMKVMPEGTSADTSAndFLAC() async throws {
        let pipeline = MediaAudioExtractPipeline.shared
        let mkvURL = tempDirectoryURL.appendingPathComponent("multitrack_audio.mkv")
        try Self.makeSyntheticDualAudioMKVData().write(to: mkvURL)

        let mkvM4A0URL = tempDirectoryURL.appendingPathComponent("mkv_track0.m4a")
        let mkvRes0 = try await pipeline.extractAudioTrack(
            sourceURL: mkvURL,
            destinationURL: mkvM4A0URL,
            options: MediaAudioExtractOptions(mode: .encapsulatedM4a, trackIndex: 0)
        )
        XCTAssertEqual(mkvRes0.executionPath, .rustBitstreamExtract)
        XCTAssertEqual(mkvRes0.channels, 2)
        XCTAssertEqual(mkvRes0.sampleRate, 44100.0, accuracy: 1.0)
        XCTAssertEqual(mkvRes0.packetCount, 2)
        try await assertValidM4AOutput(
            at: mkvM4A0URL,
            sourceURL: mkvURL,
            expectedChannels: 2,
            expectedSampleRate: 44100.0,
            expectedDuration: mkvRes0.durationSeconds,
            expectedMTime: nil
        )

        let mkvAAC1URL = tempDirectoryURL.appendingPathComponent("mkv_track1.aac")
        let mkvRes1 = try await pipeline.extractAudioTrack(
            sourceURL: mkvURL,
            destinationURL: mkvAAC1URL,
            options: MediaAudioExtractOptions(mode: .elementaryStream, trackIndex: 1)
        )
        XCTAssertEqual(mkvRes1.executionPath, .rustBitstreamExtract)
        XCTAssertEqual(mkvRes1.channels, 1)
        XCTAssertEqual(mkvRes1.sampleRate, 48000.0, accuracy: 1.0)
        XCTAssertEqual(mkvRes1.packetCount, 1)
        let aacData = try Data(contentsOf: mkvAAC1URL)
        XCTAssertEqual(Array(aacData.prefix(2)), [0xFF, 0xF1])

        let tsURL = tempDirectoryURL.appendingPathComponent("broadcast_audio.ts")
        try Self.makeSyntheticAudioMPEGTSData().write(to: tsURL)
        let tsM4AURL = tempDirectoryURL.appendingPathComponent("ts_extracted.m4a")
        let tsRes = try await pipeline.extractAudioTrack(
            sourceURL: tsURL,
            destinationURL: tsM4AURL,
            options: MediaAudioExtractOptions(mode: .encapsulatedM4a, trackIndex: 0)
        )
        XCTAssertEqual(tsRes.executionPath, .rustBitstreamExtract)
        XCTAssertGreaterThan(tsRes.packetCount, 0)

        let flacURL = tempDirectoryURL.appendingPathComponent("lossless.flac")
        try Self.makeSyntheticFLACData().write(to: flacURL)
        let flacOutURL = tempDirectoryURL.appendingPathComponent("lossless_out.flac")
        let flacRes = try await pipeline.extractAudioTrack(
            sourceURL: flacURL,
            destinationURL: flacOutURL,
            options: MediaAudioExtractOptions(mode: .elementaryStream, trackIndex: 0, preferredCodec: .flac)
        )
        XCTAssertEqual(flacRes.codec, .flac)
        XCTAssertEqual(flacRes.sampleRate, 48000.0, accuracy: 1.0)
        let flacOutData = try Data(contentsOf: flacOutURL)
        XCTAssertEqual(String(data: flacOutData.prefix(4), encoding: .ascii), "fLaC")
    }

    func testRejectionOfVideoOnlyUnsupportedCodecModeOutOfBoundsAndOversizeInput() async throws {
        let pipeline = MediaAudioExtractPipeline.shared
        let videoOnlyMP4URL = tempDirectoryURL.appendingPathComponent("video_only.mp4")
        try await Self.writeVideoOnlyISOBMFFFixture(to: videoOnlyMP4URL, durationSeconds: 0.8)

        let destURL = tempDirectoryURL.appendingPathComponent("protected_dest.m4a")
        let sentinel = Data("sentinel-audio-destination".utf8)
        try sentinel.write(to: destURL)

        await assertExtractFails(
            sourceURL: videoOnlyMP4URL,
            destinationURL: destURL,
            options: MediaAudioExtractOptions(mode: .encapsulatedM4a, trackIndex: 0)
        ) { err in
            guard case .noAudioTracksFound = err else {
                XCTFail("Expected .noAudioTracksFound, got \(err)")
                return
            }
        }

        let dualMP4URL = tempDirectoryURL.appendingPathComponent("bounds_check.mp4")
        try await Self.writeDualAudioISOBMFFFixture(to: dualMP4URL, fileType: .mp4, durationSeconds: 0.8)
        await assertExtractFails(
            sourceURL: dualMP4URL,
            destinationURL: destURL,
            options: MediaAudioExtractOptions(mode: .encapsulatedM4a, trackIndex: 5)
        ) { err in
            guard case .trackIndexOutOfRange(let index, let count) = err else {
                XCTFail("Expected .trackIndexOutOfRange, got \(err)")
                return
            }
            XCTAssertEqual(index, 5)
            XCTAssertEqual(count, 2)
        }

        let flacURL = tempDirectoryURL.appendingPathComponent("reject_m4a.flac")
        let flacBytes = Self.makeSyntheticFLACData()
        try flacBytes.write(to: flacURL)
        await assertExtractFails(
            sourceURL: flacURL,
            destinationURL: destURL,
            options: MediaAudioExtractOptions(mode: .encapsulatedM4a, trackIndex: 0)
        ) { err in
            guard case .unsupportedAudioCodec = err else {
                XCTFail("Expected .unsupportedAudioCodec for FLAC -> M4A, got \(err)")
                return
            }
        }

        pipeline.maxInMemoryInputBytes = 12
        await assertExtractFails(
            sourceURL: flacURL,
            destinationURL: destURL,
            options: MediaAudioExtractOptions(mode: .elementaryStream, trackIndex: 0, preferredCodec: .flac)
        ) { err in
            guard case .inputTooLargeForInMemoryExtract(_, let fileBytes, let limitBytes) = err else {
                XCTFail("Expected .inputTooLargeForInMemoryExtract, got \(err)")
                return
            }
            XCTAssertEqual(fileBytes, UInt64(flacBytes.count))
            XCTAssertEqual(limitBytes, 12)
        }
        pipeline.maxInMemoryInputBytes = 256 * 1024 * 1024

        XCTAssertEqual(try Data(contentsOf: destURL), sentinel)
        XCTAssertTrue(stagingFilesInTempDirectory().isEmpty)
    }

    func testCancellationAndPreviewClosePreserveExistingDestination() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("cancel_audio.mp4")
        try await Self.writeDualAudioISOBMFFFixture(to: sourceURL, fileType: .mp4, durationSeconds: 1.0)

        let destURL = tempDirectoryURL.appendingPathComponent("cancel_dest.m4a")
        let sentinel = Data("existing-audio-destination".utf8)
        try sentinel.write(to: destURL)

        let manager = MediaAudioExtractManager.shared
        await manager.refreshAvailableTracks(for: sourceURL)
        XCTAssertEqual(manager.availableTracks.count, 2)

        MediaAudioExtractPipeline.shared.simulatedExtractDelayNanoseconds = 250_000_000
        manager.savePanelPresenter = { _ in destURL }
        manager.isAudioExtractPopoverPresented = true

        manager.extractCurrentAudio(
            sourceURL: sourceURL,
            options: MediaAudioExtractOptions(mode: .encapsulatedM4a, trackIndex: 0)
        )
        XCTAssertTrue(manager.isExtracting)

        try await Task.sleep(nanoseconds: 50_000_000)
        manager.resetForPreviewClose(for: sourceURL)
        await manager.waitForCurrentExtraction()

        XCTAssertFalse(manager.isExtracting)
        XCTAssertFalse(manager.isAudioExtractPopoverPresented)
        XCTAssertEqual(try Data(contentsOf: destURL), sentinel)
        XCTAssertTrue(stagingFilesInTempDirectory().isEmpty)
    }

    // MARK: - Helpers

    private func assertExtractFails(
        sourceURL: URL,
        destinationURL: URL,
        options: MediaAudioExtractOptions,
        verifyError: (MediaAudioExtractError) -> Void
    ) async {
        do {
            _ = try await MediaAudioExtractPipeline.shared.extractAudioTrack(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                options: options
            )
            XCTFail("Expected extractAudioTrack to fail for \(sourceURL.lastPathComponent)")
        } catch let err as MediaAudioExtractError {
            verifyError(err)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    private func stagingFilesInTempDirectory() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: tempDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.contains(".ttmedia-audio-staging-") }
    }

    private func assertValidM4AOutput(
        at outputURL: URL,
        sourceURL: URL,
        expectedChannels: Int,
        expectedSampleRate: Double,
        expectedDuration: Double,
        expectedMTime: Date?
    ) async throws {
        let offsets = try MediaContainerRemuxPipeline.readTopLevelBoxOffsets(at: outputURL)
        XCTAssertEqual(offsets["ftyp"], 0)
        XCTAssertNotNil(offsets["moov"])
        XCTAssertNotNil(offsets["mdat"])

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 0)
        XCTAssertEqual(audioTracks.count, 1)

        let descs = try await audioTracks[0].load(.formatDescriptions)
        let firstDesc = try XCTUnwrap(descs.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(firstDesc), kAudioFormatMPEG4AAC)
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(firstDesc)?.pointee {
            XCTAssertEqual(Int(asbd.mChannelsPerFrame), expectedChannels)
            XCTAssertEqual(asbd.mSampleRate, expectedSampleRate, accuracy: 1.0)
        }

        let actualDuration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertGreaterThan(actualDuration, 0.0)
        if expectedDuration > 0 {
            XCTAssertEqual(actualDuration, expectedDuration, accuracy: 0.35)
        }

        if let expectedMTime {
            let srcAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let dstAttrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let dstMTime = try XCTUnwrap(dstAttrs[.modificationDate] as? Date)
            XCTAssertEqual(dstMTime.timeIntervalSince1970, expectedMTime.timeIntervalSince1970, accuracy: 1.0)
            XCTAssertEqual(dstAttrs[.posixPermissions] as? NSNumber, srcAttrs[.posixPermissions] as? NSNumber)
        }
    }

    private static func makeSyntheticDualAudioMKVData() -> Data {
        var mkv: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x42, 0x86, 0x81, 0x01]
        var tracks: [UInt8] = []

        let vCid = Array("V_MPEG4/ISO/AVC".utf8)
        let vEntry: [UInt8] = [0xD7, 0x81, 0x01, 0x83, 0x81, 0x01, 0x86, UInt8(0x80 | vCid.count)] + vCid
        tracks.append(contentsOf: [0xAE, UInt8(0x80 | vEntry.count)] + vEntry)

        let aCid = Array("A_AAC".utf8)
        let a1: [UInt8] = [
            0xD7, 0x81, 0x02, 0x83, 0x81, 0x02,
            0x86, UInt8(0x80 | aCid.count)
        ] + aCid + [0x63, 0xA2, 0x82, 0x12, 0x10]
        tracks.append(contentsOf: [0xAE, UInt8(0x80 | a1.count)] + a1)

        let a2: [UInt8] = [
            0xD7, 0x81, 0x03, 0x83, 0x81, 0x02,
            0x86, UInt8(0x80 | aCid.count)
        ] + aCid + [0x63, 0xA2, 0x82, 0x11, 0x88]
        tracks.append(contentsOf: [0xAE, UInt8(0x80 | a2.count)] + a2)

        var cluster: [UInt8] = [0xE7, 0x81, 0x00]
        let blocks: [[UInt8]] = [
            [0x81, 0x00, 0x00, 0x80, 0x65, 0x88, 0x84, 0x00],
            [0x82, 0x00, 0x00, 0x80, 0x21, 0x10, 0x05, 0x60],
            [0x82, 0x00, 0x17, 0x80, 0x21, 0x10, 0x05, 0x61],
            [0x83, 0x00, 0x00, 0x80, 0x01, 0x40, 0x22, 0x80]
        ]
        for blk in blocks {
            cluster.append(contentsOf: [0xA3, UInt8(0x80 | blk.count)] + blk)
        }

        var segment: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, UInt8(0x80 | tracks.count)] + tracks
        segment.append(contentsOf: [0x1F, 0x43, 0xB6, 0x75, UInt8(0x80 | cluster.count)] + cluster)
        mkv.append(contentsOf: [0x18, 0x53, 0x80, 0x67, UInt8(0x80 | segment.count)] + segment)
        return Data(mkv)
    }

    private static func makeSyntheticAudioMPEGTSData() -> Data {
        var packets = [UInt8]()
        var pat = [UInt8](repeating: 0xFF, count: 188)
        let patHdr: [UInt8] = [
            0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D,
            0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE1, 0x00
        ]
        pat.replaceSubrange(0..<patHdr.count, with: patHdr)
        packets.append(contentsOf: pat)

        var pmt = [UInt8](repeating: 0xFF, count: 188)
        let pmtHdr: [UInt8] = [
            0x47, 0x41, 0x00, 0x10, 0x00, 0x02, 0xB0, 0x12,
            0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x02, 0xF0,
            0x00, 0x0F, 0xE1, 0x02, 0xF0, 0x00
        ]
        pmt.replaceSubrange(0..<pmtHdr.count, with: pmtHdr)
        packets.append(contentsOf: pmt)

        let adtsFrame: [UInt8] = [
            0xFF, 0xF1, 0x50, 0x80, 0x01, 0xDF, 0xFC,
            0x21, 0x10, 0x05, 0x60, 0x8C, 0x1E, 0xD0
        ]
        var pes = [UInt8](repeating: 0xFF, count: 188)
        let pesHdr: [UInt8] = [
            0x47, 0x41, 0x02, 0x10,
            0x00, 0x00, 0x01, 0xC0, 0x00, 0x00, 0x80, 0x80, 0x05,
            0x21, 0x00, 0x01, 0x00, 0x01
        ] + adtsFrame + adtsFrame
        pes.replaceSubrange(0..<pesHdr.count, with: pesHdr)
        packets.append(contentsOf: pes)
        return Data(packets)
    }

    private static func makeSyntheticFLACData() -> Data {
        var bytes: [UInt8] = Array("fLaC".utf8)
        bytes.append(contentsOf: [0x80, 0x00, 0x00, 0x22])
        var streamInfo = [UInt8](repeating: 0, count: 34)
        streamInfo[10] = 0x0B
        streamInfo[11] = 0xB8
        streamInfo[12] = 0x02
        streamInfo[13] = 0xF0
        bytes.append(contentsOf: streamInfo)
        bytes.append(contentsOf: [0xFF, 0xF8, 0x69, 0x18, 0x00, 0x11, 0x22, 0x33])
        return Data(bytes)
    }

    private static func writeVideoOnlyISOBMFFFixture(
        to outputURL: URL,
        durationSeconds: Double
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 90
            ]
        )
        writer.add(vInput)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int((durationSeconds * 15.0).rounded())
        for idx in 0..<frames {
            while !vInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32ARGB, nil, &pb)
            if let pb {
                _ = adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(idx), timescale: 15))
            }
        }
        vInput.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private static func writeDualAudioISOBMFFFixture(
        to outputURL: URL,
        fileType: AVFileType,
        durationSeconds: Double
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let audio0 = makeAudioInput(sampleRate: 44100, channels: 2)
        let audio1 = makeAudioInput(sampleRate: 48000, channels: 1)
        writer.add(audio0)
        writer.add(audio1)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        try await feedPCMTrack(input: audio0, sampleRate: 44100, channels: 2, durationSeconds: durationSeconds)
        try await feedPCMTrack(input: audio1, sampleRate: 48000, channels: 1, durationSeconds: durationSeconds)
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private static func makeAudioInput(sampleRate: Int, channels: Int) -> AVAssetWriterInput {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64000,
            AVChannelLayoutKey: layoutData
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private static func feedPCMTrack(
        input: AVAssetWriterInput,
        sampleRate: Int,
        channels: Int,
        durationSeconds: Double
    ) async throws {
        let bytesPerFrame = UInt32(channels * 2)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc
        )
        guard let desc else { return }
        let totalFrames = Int((durationSeconds * Double(sampleRate)).rounded())
        var sent = 0
        while sent < totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let chunk = min(1024, totalFrames - sent)
            if let sbuf = makeZeroPCMSampleBuffer(
                desc: desc,
                sampleRate: Int32(sampleRate),
                bytesPerFrame: Int(bytesPerFrame),
                offset: sent,
                frames: chunk
            ) {
                _ = input.append(sbuf)
            }
            sent += chunk
        }
        input.markAsFinished()
    }

    private static func makeZeroPCMSampleBuffer(
        desc: CMAudioFormatDescription,
        sampleRate: Int32,
        bytesPerFrame: Int,
        offset: Int,
        frames: Int
    ) -> CMSampleBuffer? {
        let byteCount = frames * bytesPerFrame
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &block
        )
        guard let block else { return nil }
        let zeroes = [UInt8](repeating: 0, count: byteCount)
        CMBlockBufferReplaceDataBytes(with: zeroes, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        let pts = CMTime(value: Int64(offset), timescale: sampleRate)
        var sbuf: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: desc,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sbuf
        )
        return sbuf
    }

    func testDiscoverMKVAudioTracksAndISOBMFFElementaryStreamTrackSelection() async throws {
        let pipeline = MediaAudioExtractPipeline.shared
        let mkvURL = tempDirectoryURL.appendingPathComponent("dual.mkv")
        try Self.makeSyntheticDualAudioMKVData().write(to: mkvURL)

        let discoveredMKV = await pipeline.discoverAudioTracks(in: mkvURL)
        XCTAssertEqual(discoveredMKV.count, 2)
        if discoveredMKV.count == 2 {
            XCTAssertEqual(discoveredMKV[0].index, 0)
            XCTAssertEqual(discoveredMKV[0].codec, .aac)
            XCTAssertEqual(discoveredMKV[0].sampleRate, 44100.0, accuracy: 1.0)
            XCTAssertEqual(discoveredMKV[0].channels, 2)
            XCTAssertEqual(discoveredMKV[1].index, 1)
            XCTAssertEqual(discoveredMKV[1].codec, .aac)
            XCTAssertEqual(discoveredMKV[1].sampleRate, 48000.0, accuracy: 1.0)
            XCTAssertEqual(discoveredMKV[1].channels, 1)
        }

        let mp4URL = tempDirectoryURL.appendingPathComponent("dual_iso.mp4")
        try await Self.writeDualAudioISOBMFFFixture(to: mp4URL, fileType: .mp4, durationSeconds: 0.35)
        let aacTrack0URL = tempDirectoryURL.appendingPathComponent("track0.aac")
        let aacTrack1URL = tempDirectoryURL.appendingPathComponent("track1.aac")

        let res0 = try await pipeline.extractAudioTrack(
            sourceURL: mp4URL,
            destinationURL: aacTrack0URL,
            options: MediaAudioExtractOptions(mode: .elementaryStream, trackIndex: 0)
        )
        let res1 = try await pipeline.extractAudioTrack(
            sourceURL: mp4URL,
            destinationURL: aacTrack1URL,
            options: MediaAudioExtractOptions(mode: .elementaryStream, trackIndex: 1)
        )
        XCTAssertEqual(res0.sampleRate, 44100.0, accuracy: 1.0)
        XCTAssertEqual(res0.channels, 2)
        XCTAssertGreaterThan(res0.packetCount, 1)
        XCTAssertEqual(res1.sampleRate, 48000.0, accuracy: 1.0)
        XCTAssertEqual(res1.channels, 1)
        XCTAssertGreaterThan(res1.packetCount, 1)

        // Verify MKV with leading unsupported AC-3 track drops unknown codec so discovered indices match Rust extractor
        let mixedMKVURL = tempDirectoryURL.appendingPathComponent("mixed_ac3_aac.mkv")
        try Self.makeSyntheticMixedUnsupportedAndDualAACMKVData().write(to: mixedMKVURL)
        let discoveredMixed = await pipeline.discoverAudioTracks(in: mixedMKVURL)
        XCTAssertEqual(discoveredMixed.count, 2, "Unsupported AC-3 track must be filtered out to match Rust extractor indexing")
        if discoveredMixed.count == 2 {
            XCTAssertEqual(discoveredMixed[0].index, 0)
            XCTAssertEqual(discoveredMixed[0].codec, .aac)
            XCTAssertEqual(discoveredMixed[0].sampleRate, 44100.0, accuracy: 1.0)
            XCTAssertEqual(discoveredMixed[1].index, 1)
            XCTAssertEqual(discoveredMixed[1].codec, .aac)
            XCTAssertEqual(discoveredMixed[1].sampleRate, 48000.0, accuracy: 1.0)
        }

        // Verify M4A writer readiness check exits immediately when writer enters terminal failed state
        XCTAssertThrowsError(
            try MediaAudioExtractPipeline.validateM4AReadinessStates(
                readerStatus: .reading,
                writerStatus: .failed,
                readerError: nil,
                writerError: NSError(domain: "test", code: 28, userInfo: [NSLocalizedDescriptionKey: "No space left on device"])
            )
        )

        // Verify M4A session start time rebases nonzero track/sample start time instead of starting at .zero
        let nonZeroRange = CMTimeRange(
            start: CMTime(seconds: 2.5, preferredTimescale: 48000),
            duration: CMTime(seconds: 1.0, preferredTimescale: 48000)
        )
        let firstPTS = CMTime(seconds: 2.5, preferredTimescale: 48000)
        let resolvedStart = MediaAudioExtractPipeline.resolvedM4ASessionStartTime(
            trackTimeRange: nonZeroRange,
            firstSamplePTS: firstPTS
        )
        XCTAssertEqual(CMTimeGetSeconds(resolvedStart), 2.5, accuracy: 0.0001)

        // Verify MKV TrackEntry with TrackNumber > Int32.max (0x80000000) is rejected without trapping
        XCTAssertNil(MediaAudioExtractPipeline.decodeBoundedInt32TrackID([0x80, 0x00, 0x00, 0x00]))
        XCTAssertNil(MediaAudioExtractPipeline.decodeBoundedInt32TrackID(Array(repeating: 0xFF, count: 9)))
        XCTAssertEqual(MediaAudioExtractPipeline.decodeBoundedInt32TrackID([0x00, 0x02]), 2)

        // Verify MKV SamplingFrequency with +Inf / NaN / out-of-range float is sanitized without crashing MediaAudioTrackDescriptor
        XCTAssertNil(MediaAudioExtractPipeline.sanitizeSampleRate(.infinity))
        XCTAssertNil(MediaAudioExtractPipeline.sanitizeSampleRate(.nan))
        XCTAssertNil(MediaAudioExtractPipeline.sanitizeSampleRate(1e30))
        XCTAssertEqual(MediaAudioExtractPipeline.sanitizeSampleRate(48000.0), 48000.0)
        let infDesc = MediaAudioTrackDescriptor(
            index: 0,
            trackID: 1,
            codec: .aac,
            codecFourCC: "aac",
            channels: 2,
            sampleRate: .infinity
        )
        XCTAssertEqual(infDesc.sampleRate, 44100.0, accuracy: 1.0)

        // Verify ADTS profile validation rejects AAC-LD / AAC-ELD and preserves valid AOT 1..4 profile bits
        XCTAssertNil(
            MediaAudioExtractPipeline.resolveADTSProfileBits(
                subType: kAudioFormatMPEG4AAC_LD,
                audioSpecificConfig: nil
            )
        )
        XCTAssertNil(
            MediaAudioExtractPipeline.resolveADTSProfileBits(
                subType: kAudioFormatMPEG4AAC_ELD,
                audioSpecificConfig: nil
            )
        )
        // AudioSpecificConfig with AOT = 23 (AAC-LD: 23 << 3 = 0xB8) must be rejected even if subType is kAudioFormatMPEG4AAC
        XCTAssertNil(
            MediaAudioExtractPipeline.resolveADTSProfileBits(
                subType: kAudioFormatMPEG4AAC,
                audioSpecificConfig: Data([0xB8, 0x10])
            )
        )
        // AudioSpecificConfig with AOT = 2 (AAC-LC: 2 << 3 = 0x10) maps to ADTS profile bits 1 (AOT - 1)
        XCTAssertEqual(
            MediaAudioExtractPipeline.resolveADTSProfileBits(
                subType: kAudioFormatMPEG4AAC,
                audioSpecificConfig: Data([0x12, 0x10])
            ),
            1
        )
    }

    private static func makeSyntheticMixedUnsupportedAndDualAACMKVData() -> Data {
        var mkv: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x42, 0x86, 0x81, 0x01]
        var tracks: [UInt8] = []
        let ac3Cid = Array("A_AC3".utf8)
        let a0: [UInt8] = [0xD7, 0x81, 0x01, 0x83, 0x81, 0x02, 0x86, UInt8(0x80 | ac3Cid.count)] + ac3Cid
        tracks.append(contentsOf: [0xAE, UInt8(0x80 | a0.count)] + a0)

        let aacCid = Array("A_AAC".utf8)
        let a1: [UInt8] = [0xD7, 0x81, 0x02, 0x83, 0x81, 0x02, 0x86, UInt8(0x80 | aacCid.count)] + aacCid + [0x63, 0xA2, 0x82, 0x12, 0x10]
        tracks.append(contentsOf: [0xAE, UInt8(0x80 | a1.count)] + a1)

        let a2: [UInt8] = [0xD7, 0x81, 0x03, 0x83, 0x81, 0x02, 0x86, UInt8(0x80 | aacCid.count)] + aacCid + [0x63, 0xA2, 0x82, 0x11, 0x88]
        tracks.append(contentsOf: [0xAE, UInt8(0x80 | a2.count)] + a2)

        let segment: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, UInt8(0x80 | tracks.count)] + tracks
        mkv.append(contentsOf: [0x18, 0x53, 0x80, 0x67, UInt8(0x80 | segment.count)] + segment)
        return Data(mkv)
    }
}
