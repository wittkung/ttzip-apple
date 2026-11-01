// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0
// Doc twin: products/ttzip/docs/twin/preview/video-timeline-thumbnails.md

import AVFoundation
import CoreImage
import VideoToolbox

struct VideoTimelineFrame: Sendable {
    let image: CGImage
    let seconds: Double
}

protocol VideoTimelineDecoding: Sendable {
    func frame(at seconds: Double) async throws -> VideoTimelineFrame
    func close() async
    func interrupt()
}

/// Carries the image generator across the isolation boundary that Swift 6
/// imposes on the cancellation handler and the asynchronous frame request.
private final class CancellableImageGenerator: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(_ generator: AVAssetImageGenerator) {
        self.generator = generator
    }

    func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        try await generator.image(at: time)
    }

    func cancelAll() {
        generator.cancelAllCGImageGeneration()
    }
}

/// One decoder per generation, never the decoder or transport used by playback.
actor VideoTimelineThumbnailDecoder: VideoTimelineDecoding {
    private let url: URL
    private var generator: AVAssetImageGenerator?
    private var useWorker = false
    private let client: MediaWorkerXPCClient
    private nonisolated let transport: any MediaWorkerTransport
    private var metadata: TTMediaStreamInfo?
    private let reconstructor = SampleBufferReconstructor()
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(url: URL, transport: (any MediaWorkerTransport)? = nil) {
        self.url = url
        let selected: any MediaWorkerTransport
        if let transport { selected = transport }
        else if Bundle.main.bundleURL.pathExtension == "app" {
            let name = (Bundle.main.bundleIdentifier ?? "com.metastudyline.ttzip") + ".media-worker"
            selected = MediaWorkerXPCTransport(serviceName: name)
        } else { selected = MediaWorkerDirectTransport() }
        self.transport = selected
        client = MediaWorkerXPCClient(transport: selected)
    }

    nonisolated func interrupt() { transport.invalidate() }

    func close() async {
        generator?.cancelAllCGImageGeneration()
        generator = nil
        if let metadata { try? await client.close(sessionId: metadata.sessionId) }
        metadata = nil
        transport.invalidate()
    }

    func frame(at seconds: Double) async throws -> VideoTimelineFrame {
        try Task.checkCancellation()
        if !useWorker {
            do { return try await nativeFrame(at: seconds) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                generator?.cancelAllCGImageGeneration()
                generator = nil
                useWorker = true
            }
        }
        return try await workerFrame(at: seconds)
    }

    private func nativeFrame(at seconds: Double) async throws -> VideoTimelineFrame {
        let decoder: AVAssetImageGenerator
        if let generator { decoder = generator }
        else {
            decoder = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            decoder.appliesPreferredTrackTransform = true
            decoder.maximumSize = CGSize(width: 240, height: 160)
            // A timeline overview needs representative frames, not exact-frame seeking.
            decoder.requestedTimeToleranceBefore = .positiveInfinity
            decoder.requestedTimeToleranceAfter = .positiveInfinity
            generator = decoder
        }
        let cancellable = CancellableImageGenerator(decoder)
        return try await withTaskCancellationHandler {
            let result = try await cancellable.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            try Task.checkCancellation()
            return VideoTimelineFrame(image: result.image, seconds: result.actualTime.seconds)
        } onCancel: {
            cancellable.cancelAll()
        }
    }

    private func workerFrame(at seconds: Double) async throws -> VideoTimelineFrame {
        if metadata == nil { metadata = try await client.open(url: url) }
        try Task.checkCancellation()
        guard let metadata,
              let track = metadata.videoTracks.first(where: \.isSelectedForPackets),
              let codec = track.codec else { throw VideoTimelineDecodeError.noVideo }
        let format = try reconstructor.createVideoFormatDescription(from: VideoFormatParameters(
            codec: codec, width: Int32(track.width), height: Int32(track.height),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            colorPrimaries: track.colorMetadata.colorPrimaries,
            transferFunction: track.colorMetadata.transferCharacteristics,
            yCbCrMatrix: track.colorMetadata.matrixCoefficients,
            extradata: track.extradata ?? Data()
        ))
        _ = try await client.seek(to: seconds, sessionId: metadata.sessionId, accurate: false)
        // Fresh state after every seek prevents reference frames leaking across samples.
        let decoder = try VideoTimelineFrameDecompressor(format: format)
        defer { decoder.invalidate() }
        var started = false
        for _ in 0..<240 {
            try Task.checkCancellation()
            guard let packet = try await client.readNextPacket(sessionId: metadata.sessionId) else { break }
            guard packet.mediaType == .video, packet.streamIndex == UInt32(track.packetStreamIndex) else { continue }
            if !started { guard packet.isKeyframe else { continue }; started = true }
            let sample = try reconstructor.reconstruct(packet: packet, formatDescription: format)
            if let decoded = try decoder.decode(sample) {
                let raw = CIImage(cvImageBuffer: decoded.buffer)
                let display = track.naturalDisplaySize
                let ratio = display.width > 0 && display.height > 0 ? display.width / display.height : raw.extent.width / raw.extent.height
                let height = min(160, 240 / ratio)
                let width = height * ratio
                let scaled = raw.transformed(by: CGAffineTransform(
                    scaleX: width / raw.extent.width, y: height / raw.extent.height
                ))
                guard let image = context.createCGImage(scaled, from: scaled.extent) else {
                    throw VideoTimelineDecodeError.noFrame
                }
                return VideoTimelineFrame(image: image, seconds: decoded.seconds)
            }
        }
        throw VideoTimelineDecodeError.noFrame
    }
}

enum VideoTimelineDecodeError: Error { case noVideo, noFrame, codec(OSStatus), timedOut }

/// Synchronous VideoToolbox work stays on the decoder actor, off the main actor.
private final class VideoTimelineFrameDecompressor {
    struct Output { let buffer: CVPixelBuffer; let seconds: Double }
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var output: Output?
        func store(_ buffer: CVPixelBuffer, time: CMTime) {
            lock.lock(); defer { lock.unlock() }
            if output == nil { output = Output(buffer: buffer, seconds: time.seconds) }
        }
        func read() -> Output? { lock.lock(); defer { lock.unlock() }; return output }
    }
    private let session: VTDecompressionSession
    init(format: CMVideoFormatDescription) throws {
        var result: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: nil,
            decompressionSessionOut: &result
        )
        guard status == noErr, let result else { throw VideoTimelineDecodeError.codec(status) }
        session = result
    }
    func invalidate() { VTDecompressionSessionInvalidate(session) }
    func decode(_ sample: CMSampleBuffer) throws -> Output? {
        let box = ResultBox()
        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: &flags
        ) { status, _, buffer, _, time, _ in
            if status == noErr, let buffer { box.store(buffer, time: time) }
        }
        guard status == noErr else { throw VideoTimelineDecodeError.codec(status) }
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return box.read()
    }
}
