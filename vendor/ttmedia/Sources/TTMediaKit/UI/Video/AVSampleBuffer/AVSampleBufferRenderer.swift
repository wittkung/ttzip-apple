// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import os

/// Supported video codec formats for the hardware-accelerated presentation pipeline.
public enum VideoCodecType: String, Sendable, CaseIterable {
    case h264 = "avc1"
    case hevc = "hvc1"
    case prores422 = "apcn"
    case prores4444 = "ap4h"
    case av1 = "av01"
    case vp9 = "vp09"

    public var fourCharCode: FourCharCode {
        switch self {
        case .h264:
            return kCMVideoCodecType_H264
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .prores422:
            return kCMVideoCodecType_AppleProRes422
        case .prores4444:
            return kCMVideoCodecType_AppleProRes4444
        case .av1:
            return 0x61763031 // 'av01'
        case .vp9:
            return 0x76703039 // 'vp09'
        }
    }
}

/// Errors occurring during NAL stream ingestion, format description synthesis, or sample buffer construction.
public enum AVSampleBufferRendererError: LocalizedError, Sendable {
    case emptyPayload
    case blockBufferCreationFailed(OSStatus)
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case missingFormatDescription
    case invalidParameterSets
    case layerRenderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "Demuxed packet contains zero payload bytes."
        case .blockBufferCreationFailed(let status):
            return "Failed to create CMBlockBuffer from memory chunk (OSStatus: \(status))."
        case .formatDescriptionCreationFailed(let status):
            return "Failed to construct CMVideoFormatDescription from parameter sets (OSStatus: \(status))."
        case .sampleBufferCreationFailed(let status):
            return "Failed to create CMSampleBuffer from block buffer and timing info (OSStatus: \(status))."
        case .missingFormatDescription:
            return "No valid CMFormatDescription cached or provided for non-parameter-set packet."
        case .invalidParameterSets:
            return "Parameter sets (SPS/PPS/VPS) are missing or malformed."
        case .layerRenderFailed(let reason):
            return "AVSampleBufferDisplayLayer entered failed rendering status: \(reason)"
        }
    }
}

/// Demuxed video NAL packet received from the Rust media worker or XPC daemon.
public struct DemuxedNALPacket: Sendable {
    /// Compressed NAL unit payload in AVCC 4-byte length-prefixed or Annex-B format.
    public let data: Data
    /// Accurate presentation timestamp (PTS).
    public let pts: CMTime
    /// Accurate decode timestamp (DTS).
    public let dts: CMTime
    /// Frame presentation duration.
    public let duration: CMTime
    /// Whether this frame is an IDR/keyframe.
    public let isKeyframe: Bool
    /// Pre-roll frame flag; if true, decoded for reference but suppressed from screen display.
    public let isPreRoll: Bool
    /// If true, display immediately bypassing display link synchronization.
    public let displayImmediately: Bool
    /// Sequence Parameter Sets (SPS) extracted from extradata or in-band NALUs.
    public let sps: [Data]?
    /// Picture Parameter Sets (PPS) extracted from extradata or in-band NALUs.
    public let pps: [Data]?
    /// Video Parameter Sets (VPS) for HEVC streams.
    public let vps: [Data]?
    /// Video codec identifier.
    public let codec: VideoCodecType

    public init(
        data: Data,
        pts: CMTime,
        dts: CMTime = .invalid,
        duration: CMTime = .invalid,
        isKeyframe: Bool = false,
        isPreRoll: Bool = false,
        displayImmediately: Bool = false,
        sps: [Data]? = nil,
        pps: [Data]? = nil,
        vps: [Data]? = nil,
        codec: VideoCodecType = .h264
    ) {
        self.data = data
        self.pts = pts
        self.dts = dts.isValid ? dts : pts
        self.duration = duration
        self.isKeyframe = isKeyframe
        self.isPreRoll = isPreRoll
        self.displayImmediately = displayImmediately
        self.sps = sps
        self.pps = pps
        self.vps = vps
        self.codec = codec
    }

    public init(
        data: Data,
        ptsNanoseconds: Int64,
        dtsNanoseconds: Int64 = -1,
        durationNanoseconds: Int64 = 0,
        timescale: CMTimeScale = 1_000_000_000,
        isKeyframe: Bool = false,
        isPreRoll: Bool = false,
        displayImmediately: Bool = false,
        sps: [Data]? = nil,
        pps: [Data]? = nil,
        vps: [Data]? = nil,
        codec: VideoCodecType = .h264
    ) {
        let ptsTime = CMTime(value: ptsNanoseconds, timescale: timescale)
        let dtsTime = dtsNanoseconds >= 0 ? CMTime(value: dtsNanoseconds, timescale: timescale) : ptsTime
        let durTime = durationNanoseconds > 0 ? CMTime(value: durationNanoseconds, timescale: timescale) : .invalid
        self.init(
            data: data,
            pts: ptsTime,
            dts: dtsTime,
            duration: durTime,
            isKeyframe: isKeyframe,
            isPreRoll: isPreRoll,
            displayImmediately: displayImmediately,
            sps: sps,
            pps: pps,
            vps: vps,
            codec: codec
        )
    }
}

/// Hardware-accelerated sample buffer presentation coordinator.
///
/// Converts incoming demuxed NAL packets into native `CMSampleBuffer` instances with
/// sample timing, parameter sets, and display suppression flags, feeding them directly
/// into `AVSampleBufferDisplayLayer`.
@MainActor
public final class AVSampleBufferRenderer: Sendable {
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "AVSampleBufferRenderer")

    public let displayLayer: AVSampleBufferDisplayLayer
    public private(set) var currentFormatDescription: CMFormatDescription?

    public private(set) var totalFramesIngested: Int = 0
    public private(set) var totalFramesRendered: Int = 0
    public private(set) var totalFramesDropped: Int = 0

    @MainActor
    public init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        self.displayLayer.videoGravity = .resizeAspect
    }

    @MainActor
    public convenience init() {
        self.init(displayLayer: AVSampleBufferDisplayLayer())
    }

    /// Whether the underlying display layer is ready to receive additional sample buffers.
    public var isReadyForMoreMediaData: Bool {
        displayLayer.isReadyForMoreMediaData
    }

    /// Current rendering status of the display layer.
    public var status: AVQueuedSampleBufferRenderingStatus {
        displayLayer.status
    }

    /// Ingests a demuxed NAL packet, parses/updates parameter sets if present,
    /// synthesizes a `CMSampleBuffer`, and feeds it into the display layer.
    public func ingest(packet: DemuxedNALPacket) throws {
        // 1. Resolve or construct format description
        let formatDescription = try resolveFormatDescription(for: packet)
        self.currentFormatDescription = formatDescription

        // 2. Synthesize CMSampleBuffer
        let sampleBuffer = try Self.makeSampleBuffer(packet: packet, formatDescription: formatDescription)

        // 3. Enqueue to display layer
        enqueue(sampleBuffer)
    }

    /// Enqueues a pre-constructed `CMSampleBuffer` directly to the display layer with status monitoring.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            let errorMsg = displayLayer.error?.localizedDescription ?? "unknown error"
            logger.error("Display layer failed status detected: \(errorMsg), recovering with flush")
            displayLayer.flush()
        }

        displayLayer.enqueue(sampleBuffer)
        totalFramesIngested += 1
    }

    /// Flushes all queued sample buffers and resets the format description cache.
    public func flush(resetFormatDescription: Bool = false) {
        displayLayer.flush()
        if resetFormatDescription {
            currentFormatDescription = nil
        }
    }

    /// Stops requesting media data and flushes outstanding buffers.
    public func stop() {
        displayLayer.stopRequestingMediaData()
        displayLayer.flush()
    }

    /// Coordinates asynchronous backpressure handling with the feeder queue.
    public func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        displayLayer.requestMediaDataWhenReady(on: queue, using: block)
    }

    // MARK: - Format Description Resolution

    private func resolveFormatDescription(for packet: DemuxedNALPacket) throws -> CMFormatDescription {
        // Check if packet carries explicit SPS/PPS parameter sets
        if let sps = packet.sps, let pps = packet.pps, !sps.isEmpty, !pps.isEmpty {
            return try Self.makeFormatDescription(
                codec: packet.codec,
                sps: sps,
                pps: pps,
                vps: packet.vps
            )
        }

        // Try extracting in-band parameter sets from packet payload (e.g. IDR with leading SPS/PPS)
        let extracted = Self.extractParameterSets(from: packet.data, codec: packet.codec)
        if !extracted.sps.isEmpty && !extracted.pps.isEmpty {
            return try Self.makeFormatDescription(
                codec: packet.codec,
                sps: extracted.sps,
                pps: extracted.pps,
                vps: extracted.vps.isEmpty ? nil : extracted.vps
            )
        }

        // Fall back to cached format description
        if let cached = currentFormatDescription {
            return cached
        }

        throw AVSampleBufferRendererError.missingFormatDescription
    }

    // MARK: - CoreMedia Factory Utilities (Sendable & Nonisolated)

    /// Converts Annex-B byte stream (`00 00 00 01` or `00 00 01`) into AVCC 4-byte big-endian length prefix format.
    nonisolated public static func convertAnnexBToAVCCIfNeeded(_ data: Data) -> Data {
        guard data.count >= 4 else { return data }

        // Probe whether stream starts with an Annex-B start code
        let isFourByteStart = data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1
        let isThreeByteStart = data[0] == 0 && data[1] == 0 && data[2] == 1

        guard isFourByteStart || isThreeByteStart else {
            // Already AVCC formatted or container-encapsulated
            return data
        }

        var result = Data()
        result.reserveCapacity(data.count + 64)

        var nalStartIndices: [Int] = []
        var prefixLengths: [Int] = []

        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            let count = data.count
            var i = 0

            while i < count - 2 {
                if ptr[i] == 0 && ptr[i + 1] == 0 {
                    if ptr[i + 2] == 1 {
                        // 3-byte prefix (00 00 01)
                        if i > 0 && ptr[i - 1] == 0 {
                            // 4-byte prefix (00 00 00 01)
                            nalStartIndices.append(i + 3)
                            prefixLengths.append(4)
                        } else {
                            nalStartIndices.append(i + 3)
                            prefixLengths.append(3)
                        }
                        i += 3
                        continue
                    } else if i + 3 < count && ptr[i + 2] == 0 && ptr[i + 3] == 1 {
                        // 4-byte prefix (00 00 00 01)
                        nalStartIndices.append(i + 4)
                        prefixLengths.append(4)
                        i += 4
                        continue
                    }
                }
                i += 1
            }
        }

        guard !nalStartIndices.isEmpty else { return data }

        for index in 0..<nalStartIndices.count {
            let start = nalStartIndices[index]
            let end: Int
            if index + 1 < nalStartIndices.count {
                end = nalStartIndices[index + 1] - prefixLengths[index + 1]
            } else {
                end = data.count
            }

            let nalLength = end - start
            guard nalLength > 0 else { continue }

            var lengthBE = UInt32(nalLength).bigEndian
            withUnsafeBytes(of: &lengthBE) { lengthBytes in
                result.append(contentsOf: lengthBytes)
            }
            result.append(data.subdata(in: start..<end))
        }

        return result
    }

    /// Extracts parameter sets (SPS, PPS, VPS) from in-band NAL payloads.
    nonisolated public static func extractParameterSets(
        from data: Data,
        codec: VideoCodecType
    ) -> (vps: [Data], sps: [Data], pps: [Data]) {
        var vpsList: [Data] = []
        var spsList: [Data] = []
        var ppsList: [Data] = []

        let avccData = convertAnnexBToAVCCIfNeeded(data)
        var offset = 0
        let total = avccData.count

        while offset + 4 <= total {
            let length = avccData.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            offset += 4

            guard length > 0, offset + Int(length) <= total else { break }
            let nalData = avccData.subdata(in: offset..<(offset + Int(length)))
            offset += Int(length)

            guard let firstByte = nalData.first else { continue }

            switch codec {
            case .h264:
                let nalType = firstByte & 0x1F
                if nalType == 7 {
                    spsList.append(nalData)
                } else if nalType == 8 {
                    ppsList.append(nalData)
                }
            case .hevc:
                let nalType = (firstByte >> 1) & 0x3F
                if nalType == 32 {
                    vpsList.append(nalData)
                } else if nalType == 33 {
                    spsList.append(nalData)
                } else if nalType == 34 {
                    ppsList.append(nalData)
                }
            default:
                break
            }
        }

        return (vpsList, spsList, ppsList)
    }

    /// Constructs a `CMVideoFormatDescription` from SPS and PPS parameter sets.
    nonisolated public static func makeFormatDescription(
        codec: VideoCodecType,
        sps: [Data],
        pps: [Data],
        vps: [Data]? = nil
    ) throws -> CMFormatDescription {
        guard !sps.isEmpty && !pps.isEmpty else {
            throw AVSampleBufferRendererError.invalidParameterSets
        }

        switch codec {
        case .h264:
            var allSets: [Data] = []
            allSets.append(contentsOf: sps)
            allSets.append(contentsOf: pps)

            var desc: CMFormatDescription?
            let status = withParameterSetPointers(allSets) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
            guard status == noErr, let formatDesc = desc else {
                throw AVSampleBufferRendererError.formatDescriptionCreationFailed(status)
            }
            return formatDesc

        case .hevc:
            var allSets: [Data] = []
            if let vps = vps {
                allSets.append(contentsOf: vps)
            }
            allSets.append(contentsOf: sps)
            allSets.append(contentsOf: pps)

            var desc: CMFormatDescription?
            let status = withParameterSetPointers(allSets) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &desc
                )
            }
            guard status == noErr, let formatDesc = desc else {
                throw AVSampleBufferRendererError.formatDescriptionCreationFailed(status)
            }
            return formatDesc

        default:
            throw AVSampleBufferRendererError.formatDescriptionCreationFailed(-12710)
        }
    }

    /// Builds a `CMBlockBuffer` containing the given payload data.
    nonisolated public static func makeBlockBuffer(from data: Data) throws -> CMBlockBuffer {
        guard !data.isEmpty else {
            throw AVSampleBufferRendererError.emptyPayload
        }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            throw AVSampleBufferRendererError.blockBufferCreationFailed(status)
        }

        let copyStatus = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferNoErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }

        guard copyStatus == kCMBlockBufferNoErr else {
            throw AVSampleBufferRendererError.blockBufferCreationFailed(copyStatus)
        }

        return buffer
    }

    /// Synthesizes a ready `CMSampleBuffer` from a demuxed NAL packet and format description.
    nonisolated public static func makeSampleBuffer(
        packet: DemuxedNALPacket,
        formatDescription: CMFormatDescription
    ) throws -> CMSampleBuffer {
        let avccData = convertAnnexBToAVCCIfNeeded(packet.data)
        let blockBuffer = try makeBlockBuffer(from: avccData)

        var timingInfo = CMSampleTimingInfo(
            duration: packet.duration,
            presentationTimeStamp: packet.pts,
            decodeTimeStamp: packet.dts
        )

        var sampleSize = avccData.count
        var sampleBuffer: CMSampleBuffer?

        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let buffer = sampleBuffer else {
            throw AVSampleBufferRendererError.sampleBufferCreationFailed(status)
        }

        // Attach pre-roll suppression or display immediately attributes
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            let count = CFArrayGetCount(attachments)
            if count > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)

                if packet.isPreRoll {
                    CFDictionarySetValue(
                        dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                    )
                }

                if packet.displayImmediately {
                    CFDictionarySetValue(
                        dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                    )
                }

                if !packet.isKeyframe {
                    CFDictionarySetValue(
                        dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                    )
                    CFDictionarySetValue(
                        dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                    )
                }
            }
        }

        // Also attach propagate-level keys for layer compatibility
        if packet.isPreRoll {
            CMSetAttachment(
                buffer,
                key: kCMSampleAttachmentKey_DoNotDisplay,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }

        if packet.displayImmediately {
            CMSetAttachment(
                buffer,
                key: kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }

        return buffer
    }

    // MARK: - Private Recursive Pointer Pinning Helper

    nonisolated private static func withParameterSetPointers<R>(
        _ parameterSets: [Data],
        _ body: ([UnsafePointer<UInt8>], [Int]) throws -> R
    ) rethrows -> R {
        func recurse(
            index: Int,
            accumulatedPointers: inout [UnsafePointer<UInt8>],
            accumulatedSizes: inout [Int]
        ) throws -> R {
            if index == parameterSets.count {
                return try body(accumulatedPointers, accumulatedSizes)
            }
            return try parameterSets[index].withUnsafeBytes { raw in
                guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return try recurse(
                        index: index + 1,
                        accumulatedPointers: &accumulatedPointers,
                        accumulatedSizes: &accumulatedSizes
                    )
                }
                accumulatedPointers.append(ptr)
                accumulatedSizes.append(parameterSets[index].count)
                defer {
                    accumulatedPointers.removeLast()
                    accumulatedSizes.removeLast()
                }
                return try recurse(
                    index: index + 1,
                    accumulatedPointers: &accumulatedPointers,
                    accumulatedSizes: &accumulatedSizes
                )
            }
        }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        return try recurse(index: 0, accumulatedPointers: &pointers, accumulatedSizes: &sizes)
    }
}
