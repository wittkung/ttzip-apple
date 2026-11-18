// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import TTMediaKit

@MainActor
final class MediaContainerRemuxTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let baseTemp = FileManager.default.temporaryDirectory
        tempDirectoryURL = baseTemp.appendingPathComponent(
            "MediaContainerRemuxTests_\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        let manager = MediaContainerRemuxManager.shared
        manager.cancelRemux()
        manager.savePanelPresenter = nil
        manager.lastErrorMessage = nil
        manager.lastCompletedDestinationURL = nil
        manager.lastCompletedResult = nil
        manager.targetContainer = .mp4
        manager.fastStart = true
        manager.stripAudio = false
        MediaContainerRemuxPipeline.shared.simulatedExportDelayNanoseconds = 0
        MediaContainerRemuxPipeline.shared.maxInMemoryInputBytes = 256 * 1024 * 1024
    }

    override func tearDown() async throws {
        let manager = MediaContainerRemuxManager.shared
        manager.cancelRemux()
        manager.savePanelPresenter = nil
        MediaContainerRemuxPipeline.shared.simulatedExportDelayNanoseconds = 0
        MediaContainerRemuxPipeline.shared.maxInMemoryInputBytes = 256 * 1024 * 1024
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try await super.tearDown()
    }

    func testISOBMFFPassthroughMP4ToMOVAndMOVToMP4PreservesCodecsTimingAndMetadata() async throws {
        let sourceMP4URL = tempDirectoryURL.appendingPathComponent("camera_source.mp4")
        try await Self.writeMultiTrackISOBMFFFixture(to: sourceMP4URL, fileType: .mp4, durationSeconds: 1.5, fps: 30)

        let customMTime = Date(timeIntervalSinceNow: -5400)
        try FileManager.default.setAttributes(
            [.modificationDate: customMTime, .posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: sourceMP4URL.path
        )

        let pipeline = MediaContainerRemuxPipeline.shared
        XCTAssertEqual(
            pipeline.defaultOutputURL(for: sourceMP4URL, targetContainer: .mov),
            tempDirectoryURL.appendingPathComponent("camera_source_remuxed.mov")
        )
        XCTAssertEqual(
            pipeline.defaultOutputURL(for: sourceMP4URL, targetContainer: .mp4),
            tempDirectoryURL.appendingPathComponent("camera_source_remuxed.mp4")
        )

        let movURL = tempDirectoryURL.appendingPathComponent("camera_remuxed.mov")
        let movResult = try await pipeline.remuxMedia(
            sourceURL: sourceMP4URL,
            destinationURL: movURL,
            options: MediaContainerRemuxOptions(targetContainer: .mov, fastStart: true, stripAudio: false)
        )
        XCTAssertEqual(movResult.executionPath, .isoBMFFPassthrough)
        XCTAssertEqual(movResult.targetContainer, .mov)
        XCTAssertEqual(movResult.videoTrackCount, 1)
        XCTAssertEqual(movResult.audioTrackCount, 1)
        try await assertValidRemuxedOutput(
            at: movURL,
            sourceURL: sourceMP4URL,
            expectedVideoCount: 1,
            expectedAudioCount: 1,
            expectedDuration: 1.5,
            expectedMTime: customMTime,
            requireFastStart: true
        )

        let strippedMP4URL = tempDirectoryURL.appendingPathComponent("camera_video_only.mp4")
        let strippedResult = try await pipeline.remuxMedia(
            sourceURL: movURL,
            destinationURL: strippedMP4URL,
            options: MediaContainerRemuxOptions(targetContainer: .mp4, fastStart: true, stripAudio: true)
        )
        XCTAssertEqual(strippedResult.executionPath, .isoBMFFPassthrough)
        XCTAssertEqual(strippedResult.videoTrackCount, 1)
        XCTAssertEqual(strippedResult.audioTrackCount, 0)
        try await assertValidRemuxedOutput(
            at: strippedMP4URL,
            sourceURL: movURL,
            expectedVideoCount: 1,
            expectedAudioCount: 0,
            expectedDuration: 1.5,
            expectedMTime: customMTime,
            requireFastStart: true
        )
    }

    func testRustBitstreamRemuxFromMKVMPEGTSAndAnnexBProducesPlayableMP4AndMOV() async throws {
        let pipeline = MediaContainerRemuxPipeline.shared
        let customMTime = Date(timeIntervalSinceNow: -3600)

        let annexbURL = tempDirectoryURL.appendingPathComponent("capture.h264")
        try Self.makeSyntheticH264AnnexBData().write(to: annexbURL)
        try FileManager.default.setAttributes(
            [.modificationDate: customMTime, .posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: annexbURL.path
        )

        let annexbMP4URL = tempDirectoryURL.appendingPathComponent("capture_from_h264.mp4")
        let annexbResult = try await pipeline.remuxMedia(
            sourceURL: annexbURL,
            destinationURL: annexbMP4URL,
            options: MediaContainerRemuxOptions(targetContainer: .mp4, fastStart: true, stripAudio: true)
        )
        XCTAssertEqual(annexbResult.executionPath, .rustBitstreamRemux)
        XCTAssertEqual(annexbResult.sampleCount, 4)
        XCTAssertEqual(annexbResult.syncSampleCount, 2)
        try await assertValidRemuxedOutput(
            at: annexbMP4URL,
            sourceURL: annexbURL,
            expectedVideoCount: 1,
            expectedAudioCount: 0,
            expectedDuration: annexbResult.durationSeconds,
            expectedMTime: customMTime,
            requireFastStart: true
        )

        let tsURL = tempDirectoryURL.appendingPathComponent("broadcast.ts")
        try Self.makeSyntheticMPEGTSData().write(to: tsURL)
        let tsMOVURL = tempDirectoryURL.appendingPathComponent("broadcast_remuxed.mov")
        let tsResult = try await pipeline.remuxMedia(
            sourceURL: tsURL,
            destinationURL: tsMOVURL,
            options: MediaContainerRemuxOptions(targetContainer: .mov, fastStart: true, stripAudio: false)
        )
        XCTAssertEqual(tsResult.executionPath, .rustBitstreamRemux)
        XCTAssertEqual(tsResult.targetContainer, .mov)
        XCTAssertGreaterThan(tsResult.sampleCount, 0)
        try await assertValidRemuxedOutput(
            at: tsMOVURL,
            sourceURL: tsURL,
            expectedVideoCount: 1,
            expectedAudioCount: 0,
            expectedDuration: tsResult.durationSeconds,
            expectedMTime: nil,
            requireFastStart: true
        )

        let mkvURL = tempDirectoryURL.appendingPathComponent("multitrack.mkv")
        try Self.makeSyntheticMultiTrackMKVData().write(to: mkvURL)
        let mkvMP4URL = tempDirectoryURL.appendingPathComponent("multitrack_remuxed.mp4")
        let mkvResult = try await pipeline.remuxMedia(
            sourceURL: mkvURL,
            destinationURL: mkvMP4URL,
            options: MediaContainerRemuxOptions(targetContainer: .mp4, fastStart: true, stripAudio: true)
        )
        XCTAssertEqual(mkvResult.executionPath, .rustBitstreamRemux)
        XCTAssertEqual(mkvResult.videoTrackCount, 1)
        XCTAssertEqual(mkvResult.audioTrackCount, 0)
        try await assertValidRemuxedOutput(
            at: mkvMP4URL,
            sourceURL: mkvURL,
            expectedVideoCount: 1,
            expectedAudioCount: 0,
            expectedDuration: mkvResult.durationSeconds,
            expectedMTime: nil,
            requireFastStart: true
        )
    }

    func testUnsupportedContainersInMemorySizeCapAndSamePathProtection() async throws {
        let pipeline = MediaContainerRemuxPipeline.shared
        let validSourceURL = tempDirectoryURL.appendingPathComponent("valid.h264")
        let validSourceBytes = Self.makeSyntheticH264AnnexBData()
        try validSourceBytes.write(to: validSourceURL)

        let existingDestURL = tempDirectoryURL.appendingPathComponent("existing_output.mp4")
        let sentinel = Data("protected-destination-payload".utf8)
        try sentinel.write(to: existingDestURL)

        await assertRemuxFails(
            sourceURL: validSourceURL,
            destinationURL: validSourceURL,
            expectedSameSource: true
        )

        let aviURL = tempDirectoryURL.appendingPathComponent("legacy.avi")
        try Data("RIFF....AVI LIST".utf8).write(to: aviURL)
        if case .success = pipeline.validateSourceCompatibility(aviURL) {
            XCTFail("Expected .avi container to be rejected")
        }
        await assertRemuxFails(sourceURL: aviURL, destinationURL: existingDestURL)

        let corruptMP4URL = tempDirectoryURL.appendingPathComponent("corrupt.mp4")
        try Data("not-an-isobmff-file".utf8).write(to: corruptMP4URL)
        if case .success = pipeline.validateSourceCompatibility(corruptMP4URL) {
            XCTFail("Expected corrupt .mp4 to be rejected")
        }
        await assertRemuxFails(sourceURL: corruptMP4URL, destinationURL: existingDestURL)

        let emptyMKVURL = tempDirectoryURL.appendingPathComponent("empty.mkv")
        try Data().write(to: emptyMKVURL)
        if case .success = pipeline.validateSourceCompatibility(emptyMKVURL) {
            XCTFail("Expected empty .mkv to be rejected")
        }

        pipeline.maxInMemoryInputBytes = 16
        if case .failure(.inputTooLargeForInMemoryRemux(_, let fileBytes, let limitBytes)) =
            pipeline.validateSourceCompatibility(validSourceURL) {
            XCTAssertEqual(fileBytes, UInt64(validSourceBytes.count))
            XCTAssertEqual(limitBytes, 16)
        } else {
            XCTFail("Expected inputTooLargeForInMemoryRemux when file exceeds maxInMemoryInputBytes")
        }
        await assertRemuxFails(sourceURL: validSourceURL, destinationURL: existingDestURL)
        pipeline.maxInMemoryInputBytes = 256 * 1024 * 1024

        XCTAssertEqual(try Data(contentsOf: validSourceURL), validSourceBytes)
        XCTAssertEqual(try Data(contentsOf: existingDestURL), sentinel)
        XCTAssertTrue(stagingFilesInTempDirectory().isEmpty)
    }

    func testCancellationMidRemuxAndOnPreviewCloseCleansUpStagingAndPreservesDestination() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("cancel_clip.mp4")
        try await Self.writeMultiTrackISOBMFFFixture(to: sourceURL, fileType: .mp4, durationSeconds: 1.5, fps: 30)

        let destURL = tempDirectoryURL.appendingPathComponent("cancel_dest.mov")
        let sentinel = Data("existing-destination-must-remain-intact".utf8)
        try sentinel.write(to: destURL)

        let manager = MediaContainerRemuxManager.shared
        MediaContainerRemuxPipeline.shared.simulatedExportDelayNanoseconds = 250_000_000
        manager.savePanelPresenter = { _ in destURL }

        manager.remuxCurrentMedia(
            sourceURL: sourceURL,
            options: MediaContainerRemuxOptions(targetContainer: .mov, fastStart: true, stripAudio: false)
        )
        XCTAssertTrue(manager.isRemuxing)

        try await Task.sleep(nanoseconds: 60_000_000)
        manager.cancelRemux()
        await manager.waitForCurrentRemux()

        XCTAssertFalse(manager.isRemuxing)
        XCTAssertEqual(manager.remuxProgress, 0.0, accuracy: 0.001)
        XCTAssertNil(manager.activeSourceURL)
        XCTAssertEqual(try Data(contentsOf: destURL), sentinel)
        XCTAssertTrue(stagingFilesInTempDirectory().isEmpty)

        manager.remuxCurrentMedia(
            sourceURL: sourceURL,
            options: MediaContainerRemuxOptions(targetContainer: .mov, fastStart: true, stripAudio: false)
        )
        XCTAssertTrue(manager.isRemuxing)
        let unrelatedURL = tempDirectoryURL.appendingPathComponent("other.mp4")
        manager.handlePreviewClosed(for: unrelatedURL)
        XCTAssertTrue(manager.isRemuxing)

        try await Task.sleep(nanoseconds: 40_000_000)
        manager.handlePreviewClosed(for: sourceURL)
        await manager.waitForCurrentRemux()

        XCTAssertFalse(manager.isRemuxing)
        XCTAssertEqual(try Data(contentsOf: destURL), sentinel)
        XCTAssertTrue(stagingFilesInTempDirectory().isEmpty)
    }

    func testManagerSelectsBitstreamRemuxForCompatibleMKV() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("ui_source.mkv")
        try Self.makeSyntheticMultiTrackMKVData().write(to: sourceURL)

        let manager = MediaContainerRemuxManager.shared
        XCTAssertNil(manager.compatibilityIssue(for: sourceURL))
        XCTAssertEqual(manager.executionPath(for: sourceURL), .rustBitstreamRemux)
    }

    // MARK: - Helpers

    private func assertRemuxFails(
        sourceURL: URL,
        destinationURL: URL,
        expectedSameSource: Bool = false
    ) async {
        do {
            _ = try await MediaContainerRemuxPipeline.shared.remuxMedia(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
            XCTFail("Expected remuxMedia to fail for \(sourceURL.lastPathComponent)")
        } catch let err as MediaContainerRemuxError {
            if expectedSameSource {
                guard case .sameSourceAndDestination = err else {
                    XCTFail("Expected .sameSourceAndDestination, got \(err)")
                    return
                }
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    private func stagingFilesInTempDirectory() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: tempDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.contains(".ttmedia-remux-staging-") }
    }

    private func assertValidRemuxedOutput(
        at outputURL: URL,
        sourceURL: URL,
        expectedVideoCount: Int,
        expectedAudioCount: Int,
        expectedDuration: Double,
        expectedMTime: Date?,
        requireFastStart: Bool
    ) async throws {
        let offsets = try MediaContainerRemuxPipeline.readTopLevelBoxOffsets(at: outputURL)
        let ftypOff = try XCTUnwrap(offsets["ftyp"])
        let moovOff = try XCTUnwrap(offsets["moov"])
        let mdatOff = try XCTUnwrap(offsets["mdat"])
        XCTAssertEqual(ftypOff, 0)
        if requireFastStart {
            XCTAssertLessThan(moovOff, mdatOff)
        }

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, expectedVideoCount)
        XCTAssertEqual(audioTracks.count, expectedAudioCount)

        let videoDescs = try await videoTracks[0].load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(videoDescs.first)), kCMVideoCodecType_H264)
        if expectedAudioCount > 0 {
            let audioDescs = try await audioTracks[0].load(.formatDescriptions)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(audioDescs.first)), kAudioFormatMPEG4AAC)
        }

        let actualDuration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertGreaterThan(actualDuration, 0.0)
        XCTAssertEqual(actualDuration, expectedDuration, accuracy: 0.35)

        if let expectedMTime {
            let srcAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let dstAttrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let dstMTime = try XCTUnwrap(dstAttrs[.modificationDate] as? Date)
            XCTAssertEqual(dstMTime.timeIntervalSince1970, expectedMTime.timeIntervalSince1970, accuracy: 1.0)
            XCTAssertEqual(dstAttrs[.posixPermissions] as? NSNumber, srcAttrs[.posixPermissions] as? NSNumber)
        }
    }

    private static func makeSyntheticH264AnnexBData() -> Data {
        var bytes: [UInt8] = []
        let nalus: [[UInt8]] = [
            [0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9, 0x40, 0x78, 0x02, 0x27, 0xE5, 0x84],
            [0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0],
            [0x65, 0x88, 0x84, 0x00, 0x33, 0xFF, 0xAA, 0x55],
            [0x61, 0x9A, 0x20, 0x11, 0x22, 0x33, 0x44],
            [0x41, 0x9A, 0x20, 0x55, 0x66, 0x77, 0x88],
            [0x65, 0x88, 0x84, 0x11, 0x22, 0x33, 0x44, 0x55]
        ]
        for nalu in nalus {
            bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            bytes.append(contentsOf: nalu)
        }
        return Data(bytes)
    }

    private static func makeSyntheticMPEGTSData() -> Data {
        let annexb = [UInt8](makeSyntheticH264AnnexBData())
        var packets = [UInt8]()

        var pat = [UInt8](repeating: 0xFF, count: 188)
        let patHeader: [UInt8] = [
            0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D,
            0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE1, 0x00
        ]
        pat.replaceSubrange(0..<patHeader.count, with: patHeader)
        packets.append(contentsOf: pat)

        var pmt = [UInt8](repeating: 0xFF, count: 188)
        let pmtHeader: [UInt8] = [
            0x47, 0x41, 0x00, 0x10, 0x00, 0x02, 0xB0, 0x12,
            0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0,
            0x00, 0x1B, 0xE1, 0x01, 0xF0, 0x00
        ]
        pmt.replaceSubrange(0..<pmtHeader.count, with: pmtHeader)
        packets.append(contentsOf: pmt)

        for idx in 0..<3 {
            var pesPkt = [UInt8](repeating: 0xFF, count: 188)
            let pesHeader: [UInt8] = [
                0x47, 0x41, 0x01, 0x10,
                0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05,
                0x21, 0x00, UInt8(0x01 + idx * 2), 0x00, 0x01
            ]
            let start = pesHeader.count
            let end = min(188, start + annexb.count)
            pesPkt.replaceSubrange(0..<start, with: pesHeader)
            pesPkt.replaceSubrange(start..<end, with: annexb[0..<(end - start)])
            packets.append(contentsOf: pesPkt)
        }
        return Data(packets)
    }

    private static func makeSyntheticMultiTrackMKVData() -> Data {
        let avccRecord: [UInt8] = [
            0x01, 0x64, 0x00, 0x28, 0xFF, 0xE1,
            0x00, 0x0C, 0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9, 0x40, 0x78, 0x02, 0x27, 0xE5, 0x84,
            0x01, 0x00, 0x06, 0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0
        ]
        var vEntry: [UInt8] = [0xD7, 0x81, 0x01, 0x83, 0x81, 0x01]
        let vCid = Array("V_MPEG4/ISO/AVC".utf8)
        vEntry.append(contentsOf: [0x86, UInt8(0x80 | vCid.count)] + vCid)
        vEntry.append(contentsOf: [0x63, 0xA2, UInt8(0x80 | avccRecord.count)] + avccRecord)
        vEntry.append(contentsOf: [0xE0, 0x88, 0xB0, 0x82, 0x01, 0x40, 0xBA, 0x82, 0x00, 0xB4])

        let aCid = Array("A_AAC".utf8)
        let aEntry: [UInt8] = [0xD7, 0x81, 0x02, 0x83, 0x81, 0x02, 0x86, UInt8(0x80 | aCid.count)] + aCid

        var tracksPayload: [UInt8] = [0xAE, UInt8(0x80 | vEntry.count)] + vEntry
        tracksPayload.append(contentsOf: [0xAE, UInt8(0x80 | aEntry.count)] + aEntry)

        var cluster: [UInt8] = [0xE7, 0x81, 0x00]
        let idrFrame: [UInt8] = [0x00, 0x00, 0x00, 0x08, 0x65, 0x88, 0x84, 0x00, 0x33, 0xFF, 0xAA, 0x55]
        for ptsMs in [Int16(0), Int16(33), Int16(66)] {
            let hi = UInt8(truncatingIfNeeded: ptsMs >> 8)
            let lo = UInt8(truncatingIfNeeded: ptsMs & 0xFF)
            let block: [UInt8] = [0x81, hi, lo, 0x80] + idrFrame
            cluster.append(contentsOf: [0xA3, UInt8(0x80 | block.count)] + block)
        }
        let audioBlock: [UInt8] = [0x82, 0x00, 0x10, 0x80, 0x21, 0x10, 0x05]
        cluster.append(contentsOf: [0xA3, UInt8(0x80 | audioBlock.count)] + audioBlock)

        var segment: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, UInt8(0x80 | tracksPayload.count)] + tracksPayload
        segment.append(contentsOf: [0x1F, 0x43, 0xB6, 0x75, UInt8(0x80 | cluster.count)] + cluster)

        var mkv: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x42, 0x86, 0x81, 0x01]
        mkv.append(contentsOf: [0x18, 0x53, 0x80, 0x67, UInt8(0x80 | segment.count)] + segment)
        return Data(mkv)
    }

    private static func writeMultiTrackISOBMFFFixture(
        to outputURL: URL,
        fileType: AVFileType,
        durationSeconds: Double,
        fps: Int32
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let (videoInput, adaptor) = makeVideoWriterInput()
        let audioInput = makeAudioWriterInput()
        writer.add(videoInput)
        writer.add(audioInput)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((durationSeconds * Double(fps)).rounded())
        try await appendInterleavedSamples(
            writer: writer,
            videoInput: videoInput,
            adaptor: adaptor,
            audioInput: audioInput,
            frameCount: frameCount,
            fps: fps,
            durationSeconds: durationSeconds
        )
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private static func makeVideoWriterInput() -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 5,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )
        return (input, adaptor)
    }

    private static func makeAudioWriterInput() -> AVAssetWriterInput {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 64000,
            AVChannelLayoutKey: layoutData
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private static func appendInterleavedSamples(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioInput: AVAssetWriterInput,
        frameCount: Int,
        fps: Int32,
        durationSeconds: Double
    ) async throws {
        guard let formatDesc = makePCMFormatDescription() else { return }
        let totalAudioSamples = Int((durationSeconds * 44100.0).rounded())
        var videoIdx = 0
        var audioSent = 0
        while videoIdx < frameCount || audioSent < totalAudioSamples {
            if writer.status != .writing {
                throw writer.error ?? NSError(domain: "MediaContainerRemuxTests", code: -1)
            }
            if stepVideo(videoInput: videoInput, adaptor: adaptor, idx: &videoIdx, total: frameCount, fps: fps) {
                continue
            }
            if stepAudio(audioInput: audioInput, formatDesc: formatDesc, sent: &audioSent, total: totalAudioSamples) {
                continue
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func stepVideo(
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        idx: inout Int,
        total: Int,
        fps: Int32
    ) -> Bool {
        guard idx < total, videoInput.isReadyForMoreMediaData else { return false }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        if let buf = pixelBuffer {
            _ = adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(idx), timescale: fps))
        }
        idx += 1
        if idx >= total { videoInput.markAsFinished() }
        return true
    }

    private static func stepAudio(
        audioInput: AVAssetWriterInput,
        formatDesc: CMAudioFormatDescription,
        sent: inout Int,
        total: Int
    ) -> Bool {
        guard sent < total, audioInput.isReadyForMoreMediaData else { return false }
        let chunk = min(1024, total - sent)
        if let sbuf = makePCMSampleBuffer(formatDesc: formatDesc, sampleOffset: sent, frameCount: chunk) {
            _ = audioInput.append(sbuf)
        }
        sent += chunk
        if sent >= total { audioInput.markAsFinished() }
        return true
    }

    private static func makePCMFormatDescription() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc
        )
        return formatDesc
    }

    private static func makePCMSampleBuffer(
        formatDesc: CMAudioFormatDescription,
        sampleOffset: Int,
        frameCount: Int
    ) -> CMSampleBuffer? {
        let byteCount = frameCount * 4
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &blockBuffer
        )
        guard let blockBuffer else { return nil }
        let zeroes = [UInt8](repeating: 0, count: byteCount)
        CMBlockBufferReplaceDataBytes(
            with: zeroes, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount
        )
        let pts = CMTime(value: Int64(sampleOffset), timescale: 44100)
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDesc,
            sampleCount: frameCount, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    func testCorrupt64BitLargesizeBoxDoesNotTrapAndRejectsContainer() throws {
        let corruptURL = tempDirectoryURL.appendingPathComponent("corrupt_largesize.mp4")
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, // size == 1 (64-bit largesize)
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF // UInt64.max largesize
        ]
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x76])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x08, 0x6D, 0x64, 0x61, 0x74])
        try Data(bytes).write(to: corruptURL)

        XCTAssertFalse(MediaContainerRemuxPipeline.hasRequiredISOBMFFBoxes(at: corruptURL))
        XCTAssertThrowsError(try MediaContainerRemuxPipeline.readTopLevelBoxOffsets(at: corruptURL))
    }
}
