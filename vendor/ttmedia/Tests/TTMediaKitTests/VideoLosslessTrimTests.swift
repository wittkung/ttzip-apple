// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import TTMediaKit

@MainActor
final class VideoLosslessTrimTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let baseTemp = FileManager.default.temporaryDirectory
        tempDirectoryURL = baseTemp.appendingPathComponent("VideoLosslessTrimTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        let manager = VideoLosslessTrimManager.shared
        manager.cancelTrim()
        manager.savePanelPresenter = nil
        manager.lastErrorMessage = nil
        manager.lastCompletedDestinationURL = nil
        manager.lastCompletedResult = nil
        manager.customTrimStart = nil
        manager.customTrimEnd = nil
        VideoLosslessTrimPipeline.shared.simulatedExportDelayNanoseconds = 0
    }

    override func tearDown() async throws {
        let manager = VideoLosslessTrimManager.shared
        manager.cancelTrim()
        manager.savePanelPresenter = nil
        VideoLosslessTrimPipeline.shared.simulatedExportDelayNanoseconds = 0
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try await super.tearDown()
    }

    func testTailHeadAndMidLosslessTrimMultiTrackMP4PreservesTracksCodecsAVSyncAndMetadata() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("camera_clip.mp4")
        try await Self.writeMultiTrackMP4Fixture(to: sourceURL, durationSeconds: 2.0, fps: 30)

        let customMTime = Date(timeIntervalSinceNow: -7200)
        try FileManager.default.setAttributes(
            [.modificationDate: customMTime, .posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: sourceURL.path
        )

        let pipeline = VideoLosslessTrimPipeline.shared
        XCTAssertEqual(
            pipeline.defaultOutputURL(for: sourceURL),
            tempDirectoryURL.appendingPathComponent("camera_clip_trimmed.mp4")
        )

        let tailURL = tempDirectoryURL.appendingPathComponent("tail_trimmed.mp4")
        let tailResult = try await pipeline.trimVideo(
            sourceURL: sourceURL,
            timeRange: 0.0...1.0,
            destinationURL: tailURL
        )
        XCTAssertEqual(tailResult.branch, .tailOnlyZeroCopy)
        try await assertValidTrimmedMultiTrackMP4(
            at: tailURL,
            sourceURL: sourceURL,
            expectedDuration: 1.0,
            expectedMTime: customMTime
        )

        let headURL = tempDirectoryURL.appendingPathComponent("head_trimmed.mp4")
        let headResult = try await pipeline.trimVideo(
            sourceURL: sourceURL,
            timeRange: 0.4...1.8,
            destinationURL: headURL
        )
        XCTAssertEqual(headResult.branch, .headOrMidEditList)
        XCTAssertGreaterThan(headResult.editListSync.mediaTime, 0)
        XCTAssertGreaterThan(headResult.editListSync.segmentDuration, 0)
        try await assertValidTrimmedMultiTrackMP4(
            at: headURL,
            sourceURL: sourceURL,
            expectedDuration: 1.4,
            expectedMTime: customMTime
        )

        let midURL = tempDirectoryURL.appendingPathComponent("mid_trimmed.mp4")
        let midResult = try await pipeline.trimVideo(
            sourceURL: sourceURL,
            timeRange: 0.3...1.2,
            destinationURL: midURL
        )
        XCTAssertEqual(midResult.branch, .headOrMidEditList)
        try await assertValidTrimmedMultiTrackMP4(
            at: midURL,
            sourceURL: sourceURL,
            expectedDuration: 0.9,
            expectedMTime: customMTime
        )
    }

    func testInvalidBoundsUnsupportedContainerAndSamePathProtection() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("valid_source.mp4")
        try await Self.writeMultiTrackMP4Fixture(to: sourceURL, durationSeconds: 2.0, fps: 30)
        let originalSourceBytes = try Data(contentsOf: sourceURL)

        let existingDestURL = tempDirectoryURL.appendingPathComponent("protected_dest.mp4")
        let sentinelData = Data("pre-existing-protected-output".utf8)
        try sentinelData.write(to: existingDestURL)

        let pipeline = VideoLosslessTrimPipeline.shared

        await assertTrimFails(
            sourceURL: sourceURL, start: 1.5, end: 0.5, destinationURL: existingDestURL,
            expected: .invalidTimeRange(lower: 1.5, upper: 0.5, duration: nil)
        )
        await assertTrimFails(
            sourceURL: sourceURL, start: -0.5, end: 1.0, destinationURL: existingDestURL,
            expected: .invalidTimeRange(lower: -0.5, upper: 1.0, duration: nil)
        )
        await assertTrimFails(
            sourceURL: sourceURL, start: 2.5, end: 3.0, destinationURL: existingDestURL,
            expected: .invalidTimeRange(lower: 2.5, upper: 3.0, duration: 2.0)
        )
        await assertTrimFails(
            sourceURL: sourceURL, start: 0.5, end: 0.55, destinationURL: existingDestURL,
            expected: .invalidTimeRange(lower: 0.5, upper: 0.55, duration: nil)
        )
        await assertTrimFails(
            sourceURL: sourceURL, start: 0.2, end: 1.2, destinationURL: sourceURL,
            expected: .sameSourceAndDestination(sourceURL)
        )

        let unsupportedURL = tempDirectoryURL.appendingPathComponent("unsupported.mkv")
        try Data("not-an-mp4-container".utf8).write(to: unsupportedURL)
        if case .success = pipeline.validateSourceCompatibility(unsupportedURL) {
            XCTFail("Expected unsupported container to be rejected")
        }
        await assertTrimFails(
            sourceURL: unsupportedURL, start: 0.0, end: 1.0, destinationURL: existingDestURL,
            expected: nil
        )

        let fakeMp4URL = tempDirectoryURL.appendingPathComponent("corrupt_container.mp4")
        try Data("corrupt-non-bmff-payload".utf8).write(to: fakeMp4URL)
        if case .success = pipeline.validateSourceCompatibility(fakeMp4URL) {
            XCTFail("Expected corrupt MP4 container to be rejected")
        }

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalSourceBytes)
        XCTAssertEqual(try Data(contentsOf: existingDestURL), sentinelData)
        XCTAssertTrue(stagingFilesInTempDirectory().isEmpty)
    }

    func testCancellationMidTrimRemovesStagingFileAndPreservesExistingDestination() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("cancel_source.mp4")
        try await Self.writeMultiTrackMP4Fixture(to: sourceURL, durationSeconds: 2.0, fps: 30)

        let destURL = tempDirectoryURL.appendingPathComponent("cancel_target.mp4")
        let sentinel = Data("existing-destination-must-survive".utf8)
        try sentinel.write(to: destURL)

        let manager = VideoLosslessTrimManager.shared
        VideoLosslessTrimPipeline.shared.simulatedExportDelayNanoseconds = 250_000_000
        manager.savePanelPresenter = { _ in destURL }

        manager.trimCurrentRange(
            trimStart: 0.2,
            trimEnd: 1.5,
            currentTime: 0.5,
            duration: 2.0,
            sourceURL: sourceURL
        )
        XCTAssertTrue(manager.isTrimming)

        try await Task.sleep(nanoseconds: 60_000_000)
        manager.cancelTrim()
        await manager.waitForCurrentTrim()

        XCTAssertFalse(manager.isTrimming)
        XCTAssertEqual(manager.trimProgress, 0.0, accuracy: 0.001)
        XCTAssertNil(manager.activeSourceURL)
        XCTAssertEqual(try Data(contentsOf: destURL), sentinel)
        XCTAssertTrue(stagingFilesInTempDirectory().isEmpty)

        manager.trimCurrentRange(
            trimStart: 0.0,
            trimEnd: 1.2,
            currentTime: 0.4,
            duration: 2.0,
            sourceURL: sourceURL
        )
        XCTAssertTrue(manager.isTrimming)
        let unrelatedURL = tempDirectoryURL.appendingPathComponent("other.mp4")
        manager.handlePreviewClosed(for: unrelatedURL)
        XCTAssertTrue(manager.isTrimming)

        try await Task.sleep(nanoseconds: 40_000_000)
        manager.handlePreviewClosed(for: sourceURL)
        await manager.waitForCurrentTrim()

        XCTAssertFalse(manager.isTrimming)
        XCTAssertEqual(try Data(contentsOf: destURL), sentinel)
        XCTAssertTrue(stagingFilesInTempDirectory().isEmpty)
    }

    func testManagerResolvesExplicitRangeForCompatibleFile() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("ui_clip.mp4")
        try await Self.writeMultiTrackMP4Fixture(to: sourceURL, durationSeconds: 2.0, fps: 30)

        let manager = VideoLosslessTrimManager.shared
        XCTAssertNil(manager.compatibilityIssue(for: sourceURL))

        let resolved = manager.resolvedTimeRange(
            trimStart: 0.3,
            trimEnd: 1.4,
            currentTime: 0.5,
            duration: 2.0
        )
        XCTAssertEqual(resolved.lowerBound, 0.3, accuracy: 0.001)
        XCTAssertEqual(resolved.upperBound, 1.4, accuracy: 0.001)
    }

    // MARK: - Verification & Fixture Helpers

    private func assertTrimFails(
        sourceURL: URL,
        start: Double,
        end: Double,
        destinationURL: URL,
        expected: VideoLosslessTrimError?
    ) async {
        do {
            _ = try await VideoLosslessTrimPipeline.shared.trimVideo(
                sourceURL: sourceURL,
                startSeconds: start,
                endSeconds: end,
                destinationURL: destinationURL
            )
            XCTFail("Expected trimVideo to fail for (\(start), \(end)) -> \(destinationURL.lastPathComponent)")
        } catch let trimErr as VideoLosslessTrimError {
            if let expected {
                switch (trimErr, expected) {
                case (.invalidTimeRange, .invalidTimeRange),
                     (.sameSourceAndDestination, .sameSourceAndDestination),
                     (.unsupportedSource, .unsupportedSource),
                     (.sourceFileNotFound, .sourceFileNotFound):
                    break
                default:
                    XCTFail("Expected \(expected), got \(trimErr)")
                }
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    private func stagingFilesInTempDirectory() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: tempDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.contains(".ttmedia-staging-") }
    }

    private func assertValidTrimmedMultiTrackMP4(
        at outputURL: URL,
        sourceURL: URL,
        expectedDuration: Double,
        expectedMTime: Date
    ) async throws {
        let data = try Data(contentsOf: outputURL)
        XCTAssertTrue(Self.containsTopLevelBox(named: "ftyp", in: data))
        XCTAssertTrue(Self.containsTopLevelBox(named: "moov", in: data))
        XCTAssertTrue(Self.containsTopLevelBox(named: "mdat", in: data))

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)

        let videoDescs = try await videoTracks[0].load(.formatDescriptions)
        let audioDescs = try await audioTracks[0].load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType( try XCTUnwrap(videoDescs.first)), kCMVideoCodecType_H264)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(audioDescs.first)), kAudioFormatMPEG4AAC)

        let totalDur = CMTimeGetSeconds(try await asset.load(.duration))
        let videoDur = CMTimeGetSeconds((try await videoTracks[0].load(.timeRange)).duration)
        let audioDur = CMTimeGetSeconds((try await audioTracks[0].load(.timeRange)).duration)
        XCTAssertEqual(totalDur, expectedDuration, accuracy: 0.25)
        XCTAssertLessThanOrEqual(abs(videoDur - audioDur), 0.25)

        let srcAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let dstAttrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let dstMTime = try XCTUnwrap(dstAttrs[.modificationDate] as? Date)
        XCTAssertEqual(dstMTime.timeIntervalSince1970, expectedMTime.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(dstAttrs[.posixPermissions] as? NSNumber, srcAttrs[.posixPermissions] as? NSNumber)
    }

    private static func containsTopLevelBox(named fourCC: String, in data: Data) -> Bool {
        let target = Array(fourCC.utf8)
        var offset = 0
        while offset + 8 <= data.count {
            let size32 = data[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let boxType = Array(data[(offset + 4)..<(offset + 8)])
            if boxType == target { return true }
            let step: UInt64
            if size32 == 1 {
                guard offset + 16 <= data.count else { break }
                step = data[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if size32 == 0 {
                step = UInt64(data.count - offset)
            } else {
                step = size32
            }
            if step < 8 { break }
            offset += Int(step)
        }
        return false
    }

    private static func writeMultiTrackMP4Fixture(
        to outputURL: URL,
        durationSeconds: Double,
        fps: Int32
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let (videoInput, adaptor) = makeVideoWriterInput()
        let audioInput = makeAudioWriterInput()
        writer.add(videoInput)
        writer.add(audioInput)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((durationSeconds * Double(fps)).rounded())
        try await appendInterleavedVideoAndAudioSamples(
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
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
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

    private static func appendInterleavedVideoAndAudioSamples(
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
        var audioSamplesSent = 0

        while videoIdx < frameCount || audioSamplesSent < totalAudioSamples {
            if writer.status != .writing {
                throw writer.error ?? NSError(domain: "VideoLosslessTrimTests", code: -1)
            }
            if stepVideoSample(videoInput: videoInput, adaptor: adaptor, videoIdx: &videoIdx, frameCount: frameCount, fps: fps) {
                continue
            }
            if stepAudioSample(audioInput: audioInput, formatDesc: formatDesc, audioSamplesSent: &audioSamplesSent, totalAudioSamples: totalAudioSamples) {
                continue
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func stepVideoSample(
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        videoIdx: inout Int,
        frameCount: Int,
        fps: Int32
    ) -> Bool {
        guard videoIdx < frameCount, videoInput.isReadyForMoreMediaData else { return false }
        appendVideoFrame(adaptor: adaptor, frameIndex: videoIdx, fps: fps)
        videoIdx += 1
        if videoIdx >= frameCount {
            videoInput.markAsFinished()
        }
        return true
    }

    private static func stepAudioSample(
        audioInput: AVAssetWriterInput,
        formatDesc: CMAudioFormatDescription,
        audioSamplesSent: inout Int,
        totalAudioSamples: Int
    ) -> Bool {
        guard audioSamplesSent < totalAudioSamples, audioInput.isReadyForMoreMediaData else { return false }
        let chunk = min(1024, totalAudioSamples - audioSamplesSent)
        if let sbuf = makePCMSampleBuffer(formatDesc: formatDesc, sampleOffset: audioSamplesSent, frameCount: chunk) {
            _ = audioInput.append(sbuf)
        }
        audioSamplesSent += chunk
        if audioSamplesSent >= totalAudioSamples {
            audioInput.markAsFinished()
        }
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

    private static func appendVideoFrame(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        frameIndex: Int,
        fps: Int32
    ) {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        if let buf = pixelBuffer {
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            _ = adaptor.append(buf, withPresentationTime: pts)
        }
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
        CMBlockBufferReplaceDataBytes(with: zeroes, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        let pts = CMTime(value: Int64(sampleOffset), timescale: 44100)
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }
}
