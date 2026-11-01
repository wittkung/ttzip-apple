// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreMedia
import AudioToolbox
@preconcurrency import AVFoundation

/// Pipeline for converting DTOs into CMSampleBuffers and enqueuing them to an AVSampleBufferAudioRenderer.
public final class AVSampleBufferAudioPipeline: @unchecked Sendable {
    public let audioRenderer: AVSampleBufferAudioRenderer
    private let lock = NSLock()
    private var cachedFormatDescriptions: [UInt32: CMAudioFormatDescription] = [:]
    private var isolatedFlag: Bool = false
    private var attachedToSynchronizerFlag: Bool = false
    private var recordedFault: AVSampleBufferAudioFault?

    /// Test hook allowing deterministic simulation of temporary backpressure or readiness transitions.
    internal var readinessOverride: (@Sendable () -> Bool)?
    /// Test hook allowing deterministic simulation of asynchronous `AVSampleBufferAudioRenderer` failures.
    internal var rendererFailureOverride: (@Sendable () -> NSError?)?

    public init(audioRenderer: AVSampleBufferAudioRenderer = AVSampleBufferAudioRenderer()) {
        self.audioRenderer = audioRenderer
    }

    /// Whether the audio pipeline has been isolated due to an audio fault.
    public var isIsolated: Bool {
        lock.withLock { isolatedFlag }
    }

    /// Whether the audio renderer is currently attached to an `AVSampleBufferRenderSynchronizer`.
    public var isAttachedToSynchronizer: Bool {
        lock.withLock { attachedToSynchronizerFlag }
    }

    /// Returns whether the audio renderer is ready to accept more media data (respecting test overrides).
    public var isReadyForMoreMediaData: Bool {
        if let override = lock.withLock({ readinessOverride }) {
            return override()
        }
        return audioRenderer.isReadyForMoreMediaData
    }

    /// The last recorded isolatable audio fault, if any.
    public var lastFault: AVSampleBufferAudioFault? {
        lock.withLock { recordedFault }
    }

    /// Resets cached format descriptions and fault isolation state for a new playback session.
    public func resetIsolationState() {
        lock.withLock {
            isolatedFlag = false
            recordedFault = nil
            cachedFormatDescriptions.removeAll()
        }
    }

    /// Attaches the audio renderer to a master synchronizer.
    public func attach(to synchronizer: AVSampleBufferRenderSynchronizer) {
        if !synchronizer.renderers.contains(where: { $0 === audioRenderer }) {
            synchronizer.addRenderer(audioRenderer)
        }
        lock.withLock {
            attachedToSynchronizerFlag = synchronizer.renderers.contains(where: { $0 === audioRenderer })
        }
    }

    /// Detaches the audio renderer from its synchronizer.
    public func detach(from synchronizer: AVSampleBufferRenderSynchronizer) {
        if synchronizer.renderers.contains(where: { $0 === audioRenderer }) {
            synchronizer.removeRenderer(audioRenderer, at: .invalid)
        }
        lock.withLock {
            attachedToSynchronizerFlag = synchronizer.renderers.contains(where: { $0 === audioRenderer })
        }
    }

    /// Isolates a failed audio pipeline and detaches the renderer from the master synchronizer.
    public func isolate(from synchronizer: AVSampleBufferRenderSynchronizer, fault: AVSampleBufferAudioFault) {
        lock.withLock {
            isolatedFlag = true
            recordedFault = fault
        }
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        detach(from: synchronizer)
    }

    /// Flushes all queued sample buffers in the audio renderer.
    public func flush() {
        audioRenderer.flush()
    }

    /// Stops the renderer from requesting more media data.
    public func stopRequestingMediaData() {
        audioRenderer.stopRequestingMediaData()
    }

    /// Audio volume control.
    public var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = newValue }
    }

    /// Audio mute control.
    public var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    /// Inspects the underlying `AVSampleBufferAudioRenderer` for asynchronous AudioQueue/converter failures.
    ///
    /// The reported stage and codec capability distinguish a track the system decoder cannot
    /// decode at all from a decoder that rejected the configuration it was given.
    public func detectRendererFailure(
        codec: AudioCodec?,
        codecName: String?,
        sampleRateHz: Double?,
        channelCount: Int?
    ) -> AVSampleBufferAudioFault? {
        let simulatedError = lock.withLock { rendererFailureOverride }?()
        guard simulatedError != nil || audioRenderer.status == .failed || audioRenderer.error != nil else {
            return nil
        }
        let nsError = simulatedError ?? (audioRenderer.error as NSError?)
        let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
        let status = Int32(underlying?.code ?? nsError?.code ?? -11800)
        let detail = nsError?.localizedDescription ?? "AVSampleBufferAudioRenderer status=.failed"
        let kind: AVSampleBufferAudioFaultKind = codec?.isDecodableBySystemAudioDecoder == false
            ? .unsupportedAudioTrack
            : .audioInitializationFailed
        return AVSampleBufferAudioFault(
            kind: kind,
            stage: .rendererFailure,
            codecName: codecName,
            statusCode: status,
            diagnosticDetail: detail,
            sampleRateHz: sampleRateHz,
            channelCount: channelCount
        )
    }

    private static let dtsSyncWords: Set<UInt32> = [
        0x7FFE_8001, 0xFE7F_0180, 0x1FFF_E800, 0xFF1F_00E8, 0x6458_2025
    ]

    /// Diagnostic safeguard: detects non-CoreAudio bitstream sync signatures on raw unconfigured packets.
    public static func detectUnsupportedBitstreamSignature(
        payload: Data,
        codec: AudioCodec,
        extradata: Data,
        channelCount: UInt32
    ) -> String? {
        let _ = (codec, channelCount)
        guard extradata.isEmpty else { return nil }
        if let leadingWord = readBigEndianUInt32(from: payload, offset: 0) {
            if dtsSyncWords.contains(leadingWord) {
                return "DTS"
            }
            if leadingWord == 0x4F67_6753 {
                return "Ogg"
            }
        }
        if let trueHDWord = readBigEndianUInt32(from: payload, offset: 4),
           trueHDWord == 0xF872_6FBA || trueHDWord == 0xF872_6FBB {
            return "TrueHD"
        }
        return nil
    }

    private static func readBigEndianUInt32(from data: Data, offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    // MARK: - Evidence-Based AAC Configuration & Channel Layout Validation

    /// Validates and resolves a magic cookie strictly from authentic codec configuration evidence.
    /// Never guesses or fabricates an AAC-LC configuration when `extradata` is absent.
    public static func resolvedMagicCookie(for params: AudioFormatParameters) throws -> Data {
        guard params.codec == .aac else { return params.extradata }
        guard !params.extradata.isEmpty else {
            return Data()
        }
        if params.extradata.first == 0x03 {
            guard params.extradata.count >= 10, params.extradata.contains(0x05) else {
                throw AVSampleBufferAudioPipelineError.invalidCodecConfiguration(
                    "Truncated or malformed MPEG-4 esds descriptor (\(params.extradata.count) bytes)"
                )
            }
            return params.extradata
        }
        try validateAACAudioSpecificConfig(params.extradata)
        return wrapAudioSpecificConfigInESDS(params.extradata)
    }

    /// Validates a raw ISO/IEC 14496-3 `AudioSpecificConfig` buffer.
    public static func validateAACAudioSpecificConfig(_ asc: Data) throws {
        guard asc.count >= 2 && asc.count <= 64 else {
            throw AVSampleBufferAudioPipelineError.invalidCodecConfiguration(
                "AAC AudioSpecificConfig length (\(asc.count) bytes) is outside valid range 2...64"
            )
        }
        let b0 = asc[asc.startIndex]
        let b1 = asc[asc.startIndex + 1]
        let audioObjectType = (b0 >> 3) & 0x1F
        guard audioObjectType != 0 else {
            throw AVSampleBufferAudioPipelineError.invalidCodecConfiguration(
                "AAC AudioSpecificConfig has invalid audioObjectType 0"
            )
        }
        if audioObjectType != 31 {
            let srIndex = ((b0 & 0x07) << 1) | ((b1 >> 7) & 0x01)
            if srIndex == 0x0D || srIndex == 0x0E {
                throw AVSampleBufferAudioPipelineError.invalidCodecConfiguration(
                    "AAC AudioSpecificConfig uses reserved samplingFrequencyIndex \(srIndex)"
                )
            }
            if srIndex == 0x0F && asc.count < 5 {
                throw AVSampleBufferAudioPipelineError.invalidCodecConfiguration(
                    "AAC AudioSpecificConfig with explicit samplingFrequencyIndex 0x0F requires >= 5 bytes"
                )
            }
        }
    }

    /// Extracts an `AudioSpecificConfig` and header length if and only if `payload` begins with a valid ADTS frame header.
    public static func extractADTSAudioSpecificConfig(from payload: Data) -> (asc: Data, headerLength: Int)? {
        guard payload.count >= 7 else { return nil }
        let base = payload.startIndex
        guard payload[base] == 0xFF, (payload[base + 1] & 0xF0) == 0xF0 else { return nil }
        let layer = (payload[base + 1] >> 1) & 0x03
        guard layer == 0 else { return nil }
        let protectionAbsent = payload[base + 1] & 0x01
        let headerLen = protectionAbsent == 1 ? 7 : 9
        guard payload.count > headerLen else { return nil }

        let profileObjectType = ((payload[base + 2] >> 6) & 0x03) + 1
        let srIndex = (payload[base + 2] >> 2) & 0x0F
        guard srIndex <= 12 else { return nil }
        let channelConfig = ((payload[base + 2] & 0x01) << 2) | ((payload[base + 3] >> 6) & 0x03)
        let frameLength = (Int(payload[base + 3] & 0x03) << 11)
            | (Int(payload[base + 4]) << 3)
            | Int((payload[base + 5] >> 5) & 0x07)
        guard frameLength == payload.count else { return nil }

        let byte0 = (profileObjectType << 3) | ((srIndex & 0x0E) >> 1)
        let byte1 = ((srIndex & 0x01) << 7) | ((channelConfig & 0x0F) << 3)
        return (Data([byte0, byte1]), headerLen)
    }

    private static func wrapAudioSpecificConfigInESDS(_ asc: Data) -> Data {
        let ascBytes = [UInt8](asc)
        let decSpecInfoLen = UInt8(ascBytes.count)
        let decConfigLen = UInt8(13 + 2 + ascBytes.count)
        let esDescLen = UInt8(3 + 2 + Int(decConfigLen) + 3)
        var esds: [UInt8] = [
            0x03, esDescLen,
            0x00, 0x01, 0x00,
            0x04, decConfigLen,
            0x40, 0x15, 0x00, 0x00, 0x00,
            0x00, 0x01, 0xF4, 0x00,
            0x00, 0x01, 0xF4, 0x00,
            0x05, decSpecInfoLen
        ]
        esds.append(contentsOf: ascBytes)
        esds.append(contentsOf: [0x06, 0x01, 0x02])
        return Data(esds)
    }

    /// Resolves the `AudioChannelLayoutTag` to attach to `CMAudioFormatDescriptionCreate` based on codec and layout evidence.
    /// Never assigns `kAudioChannelLayoutTag_Stereo` to a stream whose channel count is not 2, and never invents
    /// surround speaker permutations for compressed bitstreams (`AC-3`, `E-AC-3`, `AAC`) when no explicit layout tag exists.
    public static func resolveVerifiedChannelLayoutTag(from params: AudioFormatParameters) throws -> UInt32? {
        if params.channelLayoutTag != 0 {
            let layoutChannels = AudioChannelLayoutTag_GetNumberOfChannels(params.channelLayoutTag)
            if layoutChannels != 0 && layoutChannels != params.channelCount {
                throw AVSampleBufferAudioPipelineError.invalidCodecConfiguration(
                    "Channel layout tag \(params.channelLayoutTag) (\(layoutChannels)ch) conflicts with channelCount \(params.channelCount)"
                )
            }
            return params.channelLayoutTag
        }
        switch params.codec {
        case .pcm:
            switch params.channelCount {
            case 1: return kAudioChannelLayoutTag_Mono
            case 2: return kAudioChannelLayoutTag_Stereo
            default: return kAudioChannelLayoutTag_DiscreteInOrder | params.channelCount
            }
        case .ac3, .eac3, .aac, .alac, .flac, .opus, .vorbis:
            return nil
        }
    }

    /// Retrieves or creates and caches an audio format description for a given stream.
    public func formatDescription(for streamIndex: UInt32, parameters: AudioFormatParameters) throws -> CMAudioFormatDescription {
        lock.lock()
        if let cached = cachedFormatDescriptions[streamIndex] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let formatDescription = try createAudioFormatDescription(from: parameters)

        lock.lock()
        cachedFormatDescriptions[streamIndex] = formatDescription
        lock.unlock()

        return formatDescription
    }

    /// Creates a CoreMedia audio format description from the given parameters.
    public func createAudioFormatDescription(from params: AudioFormatParameters) throws -> CMAudioFormatDescription {
        guard params.sampleRate.isFinite, params.sampleRate > 0, params.channelCount > 0 else {
            throw AVSampleBufferAudioPipelineError.formatDescriptionFailed(-50)
        }
        let cookie = try Self.resolvedMagicCookie(for: params)
        let verifiedLayoutTag = try Self.resolveVerifiedChannelLayoutTag(from: params)
        var asbd = makeAudioStreamBasicDescription(from: params)
        var formatDesc: CMAudioFormatDescription?

        let status: OSStatus
        if let layoutTag = verifiedLayoutTag {
            var layout = AudioChannelLayout(
                mChannelLayoutTag: layoutTag,
                mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                mNumberChannelDescriptions: 0,
                mChannelDescriptions: AudioChannelDescription()
            )
            status = withUnsafePointer(to: &layout) { layoutPtr in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: MemoryLayout<AudioChannelLayout>.size,
                    layout: layoutPtr,
                    magicCookieSize: cookie.count,
                    magicCookie: cookie.isEmpty ? nil : cookie.withUnsafeBytes { $0.baseAddress },
                    extensions: nil,
                    formatDescriptionOut: &formatDesc
                )
            }
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookie.count,
                magicCookie: cookie.isEmpty ? nil : cookie.withUnsafeBytes { $0.baseAddress },
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
        }

        guard status == noErr, let desc = formatDesc else {
            throw AVSampleBufferAudioPipelineError.formatDescriptionFailed(status)
        }

        return desc
    }

    private func makeAudioStreamBasicDescription(from params: AudioFormatParameters) -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = params.sampleRate
        asbd.mChannelsPerFrame = params.channelCount
        asbd.mBitsPerChannel = params.bitsPerChannel

        switch params.codec {
        case .aac:
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFormatFlags = 0
            asbd.mFramesPerPacket = 1024
        case .alac:
            asbd.mFormatID = kAudioFormatAppleLossless
            asbd.mFormatFlags = 0
        case .pcm:
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            asbd.mFramesPerPacket = 1
            let bits = params.bitsPerChannel > 0 ? params.bitsPerChannel : 16
            asbd.mBitsPerChannel = bits
            asbd.mBytesPerFrame = (bits / 8) * params.channelCount
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
        case .opus:
            asbd.mFormatID = kAudioFormatOpus
            asbd.mFormatFlags = 0
        case .flac:
            asbd.mFormatID = kAudioFormatFLAC
            asbd.mFormatFlags = 0
        case .vorbis:
            asbd.mFormatID = 0x76726273 // 'vrbs'
            asbd.mFormatFlags = 0
        case .ac3:
            asbd.mFormatID = kAudioFormatAC3
            asbd.mFormatFlags = 0
            asbd.mFramesPerPacket = 1536
        case .eac3:
            asbd.mFormatID = kAudioFormatEnhancedAC3
            asbd.mFormatFlags = 0
            asbd.mFramesPerPacket = 1536
        }
        return asbd
    }

    /// Reconstructs a CoreMedia audio sample buffer and enqueues it to the audio renderer.
    public func reconstructAndEnqueue(packet: MediaPacketDTO, formatDescription: CMAudioFormatDescription) throws {
        guard !packet.payloadData.isEmpty else {
            throw AVSampleBufferAudioPipelineError.emptyPayload
        }

        let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        let asbd = asbdPtr?.pointee
        var effectiveFormatDescription = formatDescription
        var effectivePayload = packet.payloadData

        if asbd?.mFormatID == kAudioFormatMPEG4AAC {
            var cookieSize: Int = 0
            let cookiePtr = CMAudioFormatDescriptionGetMagicCookie(formatDescription, sizeOut: &cookieSize)
            if cookiePtr == nil || cookieSize == 0 {
                guard let adts = Self.extractADTSAudioSpecificConfig(from: packet.payloadData) else {
                    throw AVSampleBufferAudioPipelineError.missingCodecConfiguration(
                        "AAC stream lacks CodecPrivate/AudioSpecificConfig and packet has no valid ADTS header"
                    )
                }
                let adtsParams = AudioFormatParameters(
                    codec: .aac,
                    sampleRate: asbd?.mSampleRate ?? 0,
                    channelCount: asbd?.mChannelsPerFrame ?? 0,
                    bitsPerChannel: asbd?.mBitsPerChannel ?? 16,
                    channelLayoutTag: 0,
                    extradata: adts.asc
                )
                effectiveFormatDescription = try createAudioFormatDescription(from: adtsParams)
                effectivePayload = Data(packet.payloadData.dropFirst(adts.headerLength))
            }
        }

        let finalBlockBuffer = try Self.makeBlockBuffer(from: effectivePayload)
        let isPCM = asbd?.mFormatID == kAudioFormatLinearPCM
        var sampleCount: CMItemCount = 1
        if isPCM, let asbd = asbd, asbd.mBytesPerFrame > 0 {
            sampleCount = CMItemCount(effectivePayload.count / Int(asbd.mBytesPerFrame))
        }

        let frameDuration: CMTime
        if packet.duration.isValid && packet.duration > .zero {
            frameDuration = packet.duration
        } else if let asbd = asbd, asbd.mFramesPerPacket > 0 && asbd.mSampleRate > 0 {
            frameDuration = CMTime(value: Int64(asbd.mFramesPerPacket), timescale: Int32(asbd.mSampleRate))
        } else {
            frameDuration = .invalid
        }

        var timingInfo = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: packet.presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var sampleSize = effectivePayload.count
        var sampleBuffer: CMSampleBuffer?

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: finalBlockBuffer,
            formatDescription: effectiveFormatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let buffer = sampleBuffer else {
            throw AVSampleBufferAudioPipelineError.sampleBufferFailed(sampleStatus)
        }

        audioRenderer.enqueue(buffer)
    }

    private static func makeBlockBuffer(from payload: Data) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = payload.withUnsafeBytes { bufferPointer -> OSStatus in
            guard let baseAddress = bufferPointer.baseAddress else { return kCMBlockBufferNoErr }
            var newBlockBuffer: CMBlockBuffer?
            let status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: payload.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: payload.count,
                flags: 0,
                blockBufferOut: &newBlockBuffer
            )
            guard status == kCMBlockBufferNoErr, let buffer = newBlockBuffer else {
                return status
            }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
            if copyStatus == kCMBlockBufferNoErr {
                blockBuffer = buffer
            }
            return copyStatus
        }
        guard blockStatus == kCMBlockBufferNoErr, let finalBlockBuffer = blockBuffer else {
            throw AVSampleBufferAudioPipelineError.blockBufferFailed(blockStatus)
        }
        return finalBlockBuffer
    }

    /// Validates a candidate audio track before it is handed to the system decoder.
    ///
    /// The returned fault names the stage and the real parameters the system decoder would
    /// have been configured with, so a failure report can distinguish "this track is not
    /// decodable" from "the decoder rejected this configuration".
    internal static func validateCandidateTrack(_ track: TTMediaAudioTrackInfo) -> AVSampleBufferAudioFault? {
        let rawLabel = track.codecName.isEmpty ? (track.codec?.rawValue ?? "unknown") : track.codecName
        let sampleRateHz = track.sampleRate > 0 ? track.sampleRate : nil
        let channelCount = track.channels > 0 ? track.channels : nil
        guard track.demuxSelectable, track.isSelectedForPackets,
              let codec = track.codec, codec.isDecodableBySystemAudioDecoder else {
            return AVSampleBufferAudioFault(
                kind: .unsupportedAudioTrack,
                stage: .trackSelection,
                codecName: rawLabel,
                statusCode: nil,
                diagnosticDetail: "Unsupported audio track (\(rawLabel))",
                sampleRateHz: sampleRateHz,
                channelCount: channelCount
            )
        }
        guard track.trackIndex >= 0 else {
            return AVSampleBufferAudioFault(
                kind: .audioInitializationFailed,
                stage: .trackSelection,
                codecName: rawLabel,
                statusCode: -50,
                diagnosticDetail: "Compatibility limitation: audio track is missing container trackIndex",
                sampleRateHz: sampleRateHz,
                channelCount: channelCount
            )
        }
        guard track.sampleRate > 0, track.channels > 0 else {
            return AVSampleBufferAudioFault(
                kind: .audioInitializationFailed,
                stage: .trackSelection,
                codecName: rawLabel,
                statusCode: -50,
                diagnosticDetail: "Invalid audio parameters (sampleRate=\(track.sampleRate), channels=\(track.channels))",
                sampleRateHz: sampleRateHz,
                channelCount: channelCount
            )
        }
        if codec == .aac, let extra = track.extradata, !extra.isEmpty {
            let probeParams = AudioFormatParameters(
                codec: .aac,
                sampleRate: track.sampleRate,
                channelCount: UInt32(track.channels),
                bitsPerChannel: UInt32(track.bitDepth ?? 16),
                channelLayoutTag: 0,
                extradata: extra
            )
            do {
                _ = try resolvedMagicCookie(for: probeParams)
            } catch {
                return classifyFault(
                    from: error,
                    codecName: rawLabel,
                    sampleRateHz: sampleRateHz,
                    channelCount: channelCount
                )
            }
        }
        return nil
    }
}
