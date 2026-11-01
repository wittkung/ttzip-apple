// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreMedia

/// Errors related to reconstructing sample buffers and format descriptions.
public enum SampleBufferReconstructorError: LocalizedError, Sendable {
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case formatDescriptionFailed(OSStatus)
    case unsupportedCodec(String)
    case emptyPayload
    case invalidParameterSets

    public var errorDescription: String? {
        switch self {
        case .blockBufferFailed(let status):
            return "Block buffer creation failed with OSStatus: \(status)"
        case .sampleBufferFailed(let status):
            return "Sample buffer creation failed with OSStatus: \(status)"
        case .formatDescriptionFailed(let status):
            return "Format description creation failed with OSStatus: \(status)"
        case .unsupportedCodec(let codec):
            return "Unsupported codec for video format description: \(codec)"
        case .emptyPayload:
            return "Cannot reconstruct sample buffer from empty payload"
        case .invalidParameterSets:
            return "Invalid or missing SPS/PPS/VPS parameter sets in extradata"
        }
    }
}

/// Reconstructs CMSampleBuffers from MediaPacketDTOs and manages format descriptions.
public final class SampleBufferReconstructor: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedFormatDescriptions: [UInt32: CMFormatDescription] = [:]
    private var cachedColorAttachments: [UInt32: (primaries: CFString?, transfer: CFString?, matrix: CFString?)] = [:]

    public init() {}

    /// Clears the cached format descriptions.
    public func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedFormatDescriptions.removeAll()
        cachedColorAttachments.removeAll()
    }

    /// Retrieves or creates and caches a format description for a given stream.
    public func formatDescription(for streamIndex: UInt32, parameters: VideoFormatParameters) throws -> CMFormatDescription {
        let resolvedColor = (
            primaries: CMFormatDescriptionMetadataExtractor.mapColorPrimariesToCoreMedia(parameters.colorPrimaries),
            transfer: CMFormatDescriptionMetadataExtractor.mapTransferFunctionToCoreMedia(parameters.transferFunction),
            matrix: CMFormatDescriptionMetadataExtractor.mapYCbCrMatrixToCoreMedia(parameters.yCbCrMatrix)
        )
        lock.lock()
        cachedColorAttachments[streamIndex] = resolvedColor
        if let cached = cachedFormatDescriptions[streamIndex] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let formatDescription = try createVideoFormatDescription(from: parameters)
        
        lock.lock()
        cachedFormatDescriptions[streamIndex] = formatDescription
        lock.unlock()
        
        return formatDescription
    }

    /// Reconstructs a CoreMedia sample buffer from a demuxed media packet.
    public func reconstruct(
        packet: MediaPacketDTO,
        formatDescription: CMFormatDescription,
        displayImmediately: Bool = false
    ) throws -> CMSampleBuffer {
        guard !packet.payloadData.isEmpty else {
            throw SampleBufferReconstructorError.emptyPayload
        }
        let finalBlockBuffer = try makeBlockBuffer(from: packet.payloadData)
        let duration = (packet.duration.isValid && packet.duration > .zero)
            ? packet.duration
            : CMTime(value: 41708, timescale: 1000000)
        let decodeTS = (packet.decodeTimeStamp.isValid && packet.decodeTimeStamp > .zero && packet.decodeTimeStamp != packet.presentationTimeStamp)
            ? packet.decodeTimeStamp
            : .invalid
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: packet.presentationTimeStamp,
            decodeTimeStamp: decodeTS
        )
        var sampleSize = packet.payloadData.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: finalBlockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let buffer = sampleBuffer else {
            throw SampleBufferReconstructorError.sampleBufferFailed(sampleStatus)
        }
        attachSampleAttachments(buffer: buffer, packet: packet, displayImmediately: displayImmediately)
        attachColorimetryAttachments(buffer: buffer, packet: packet, formatDescription: formatDescription)
        return buffer
    }

    private func makeBlockBuffer(from payloadData: Data) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = payloadData.withUnsafeBytes { bufferPointer -> OSStatus in
            guard let baseAddress = bufferPointer.baseAddress else { return kCMBlockBufferNoErr }
            var newBlockBuffer: CMBlockBuffer?
            let status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: payloadData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: payloadData.count,
                flags: 0,
                blockBufferOut: &newBlockBuffer
            )
            guard status == kCMBlockBufferNoErr, let buffer = newBlockBuffer else { return status }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: payloadData.count
            )
            if copyStatus == kCMBlockBufferNoErr { blockBuffer = buffer }
            return copyStatus
        }
        guard blockStatus == kCMBlockBufferNoErr, let resolved = blockBuffer else {
            throw SampleBufferReconstructorError.blockBufferFailed(blockStatus)
        }
        return resolved
    }

    private func attachColorimetryAttachments(
        buffer: CMSampleBuffer,
        packet: MediaPacketDTO,
        formatDescription: CMFormatDescription
    ) {
        let cached = lock.withLock { cachedColorAttachments[packet.streamIndex] }
        let ext = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any]
        let packetPrimaries = CMFormatDescriptionMetadataExtractor.mapColorPrimariesToCoreMedia(packet.sampleColorPrimaries)
        let packetTransfer = CMFormatDescriptionMetadataExtractor.mapTransferFunctionToCoreMedia(packet.sampleTransferCharacteristics)
        let packetMatrix = CMFormatDescriptionMetadataExtractor.mapYCbCrMatrixToCoreMedia(packet.sampleMatrixCoefficients)
        if let primaries = packetPrimaries ?? cached?.primaries ?? (ext?[kCMFormatDescriptionExtension_ColorPrimaries] as! CFString?) {
            CMSetAttachment(buffer, key: kCVImageBufferColorPrimariesKey, value: primaries, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        if let transfer = packetTransfer ?? cached?.transfer ?? (ext?[kCMFormatDescriptionExtension_TransferFunction] as! CFString?) {
            CMSetAttachment(buffer, key: kCVImageBufferTransferFunctionKey, value: transfer, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        if let matrix = packetMatrix ?? cached?.matrix ?? (ext?[kCMFormatDescriptionExtension_YCbCrMatrix] as! CFString?) {
            CMSetAttachment(buffer, key: kCVImageBufferYCbCrMatrixKey, value: matrix, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
    }

    private func attachSampleAttachments(buffer: CMSampleBuffer, packet: MediaPacketDTO, displayImmediately: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) else {
            return
        }
        
        let count = CFArrayGetCount(attachments)
        guard count > 0 else { return }
        
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        
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
        } else {
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
            )
        }

        if packet.doNotDisplay {
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        
        // DisplayImmediately must ONLY be set when explicitly requested (e.g. paused seek step).
        // During normal synchronized playback, frames are strictly driven by AVSampleBufferRenderSynchronizer CMTimebase.
        if displayImmediately {
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
    }

    /// Creates a CoreMedia video format description from the given parameters.
    public func createVideoFormatDescription(from params: VideoFormatParameters) throws -> CMFormatDescription {
        switch params.codec {
        case .h264:
            let (sps, pps) = extractH264ParameterSets(from: params.extradata)
            guard !sps.isEmpty, !pps.isEmpty else {
                throw SampleBufferReconstructorError.invalidParameterSets
            }
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
                throw SampleBufferReconstructorError.formatDescriptionFailed(status)
            }
            return formatDesc
            
        case .hevc:
            let (vps, sps, pps) = extractHEVCParameterSets(from: params.extradata)
            guard !sps.isEmpty, !pps.isEmpty else {
                throw SampleBufferReconstructorError.invalidParameterSets
            }
            var allSets: [Data] = []
            allSets.append(contentsOf: vps)
            allSets.append(contentsOf: sps)
            allSets.append(contentsOf: pps)
            let extensions = buildColorExtensions(from: params)
            
            var desc: CMFormatDescription?
            let status = withParameterSetPointers(allSets) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: extensions.isEmpty ? nil : (extensions as CFDictionary),
                    formatDescriptionOut: &desc
                )
            }
            guard status == noErr, let formatDesc = desc else {
                throw SampleBufferReconstructorError.formatDescriptionFailed(status)
            }
            return formatDesc
            
        case .prores, .av1, .vp9:
            // For ProRes and generic codecs, we create a standard description
            var formatDesc: CMFormatDescription?
            let extensions = buildColorExtensions(from: params)
            
            let codecType: FourCharCode
            switch params.codec {
            case .prores: codecType = kCMVideoCodecType_AppleProRes422
            case .av1: codecType = 0x61763031 // 'av01'
            case .vp9: codecType = 0x76703039 // 'vp09'
            default: codecType = 0
            }
            
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codecType,
                width: params.width,
                height: params.height,
                extensions: extensions.isEmpty ? nil : (extensions as CFDictionary),
                formatDescriptionOut: &formatDesc
            )
            guard status == noErr, let desc = formatDesc else {
                throw SampleBufferReconstructorError.formatDescriptionFailed(status)
            }
            return desc
        }
    }

    private func buildColorExtensions(from params: VideoFormatParameters) -> [CFString: Any] {
        var extensions: [CFString: Any] = [:]
        if let primaries = CMFormatDescriptionMetadataExtractor.mapColorPrimariesToCoreMedia(params.colorPrimaries) {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
        }
        if let transfer = CMFormatDescriptionMetadataExtractor.mapTransferFunctionToCoreMedia(params.transferFunction) {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
        }
        if let matrix = CMFormatDescriptionMetadataExtractor.mapYCbCrMatrixToCoreMedia(params.yCbCrMatrix) {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
        }
        return extensions
    }

    private func extractH264ParameterSets(from data: Data) -> (sps: [Data], pps: [Data]) {
        guard data.count >= 7, data[0] == 1 else {
            // Fallback to searching NALUs if not an AVCDecoderConfigurationRecord
            let extracted = AVSampleBufferRenderer.extractParameterSets(from: data, codec: .h264)
            return (extracted.sps, extracted.pps)
        }
        
        var sps: [Data] = []
        var pps: [Data] = []
        
        let numOfSPS = data[5] & 0x1F
        var offset = 6
        for _ in 0..<numOfSPS {
            guard offset + 2 <= data.count else { break }
            let length = Int(data[offset]) << 8 | Int(data[offset+1])
            offset += 2
            guard offset + length <= data.count else { break }
            sps.append(data.subdata(in: offset..<(offset+length)))
            offset += length
        }
        
        guard offset < data.count else { return (sps, pps) }
        let numOfPPS = data[offset]
        offset += 1
        for _ in 0..<numOfPPS {
            guard offset + 2 <= data.count else { break }
            let length = Int(data[offset]) << 8 | Int(data[offset+1])
            offset += 2
            guard offset + length <= data.count else { break }
            pps.append(data.subdata(in: offset..<(offset+length)))
            offset += length
        }
        return (sps, pps)
    }

    private func extractHEVCParameterSets(from data: Data) -> (vps: [Data], sps: [Data], pps: [Data]) {
        guard data.count >= 23, data[0] == 1 else {
            let extracted = AVSampleBufferRenderer.extractParameterSets(from: data, codec: .hevc)
            return (extracted.vps, extracted.sps, extracted.pps)
        }
        
        var vps: [Data] = []
        var sps: [Data] = []
        var pps: [Data] = []
        
        let numOfArrays = Int(data[22])
        var offset = 23
        for _ in 0..<numOfArrays {
            guard offset + 3 <= data.count else { break }
            let naluType = data[offset] & 0x3F
            let numNalus = Int(data[offset+1]) << 8 | Int(data[offset+2])
            offset += 3
            
            for _ in 0..<numNalus {
                guard offset + 2 <= data.count else { break }
                let length = Int(data[offset]) << 8 | Int(data[offset+1])
                offset += 2
                guard offset + length <= data.count else { break }
                let nalData = data.subdata(in: offset..<(offset+length))
                offset += length
                
                if naluType == 32 {
                    vps.append(nalData)
                } else if naluType == 33 {
                    sps.append(nalData)
                } else if naluType == 34 {
                    pps.append(nalData)
                }
            }
        }
        return (vps, sps, pps)
    }

    private func withParameterSetPointers<R>(
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
