// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import CoreMedia
import Foundation

/// Primary media stream type discriminator.
public enum MediaType: UInt8, Sendable, Codable, Equatable, Hashable {
    case video = 1
    case audio = 2
    case subtitle = 3

    /// Canonical lowercase string representation matching JSON schema contract.
    public var stringValue: String {
        switch self {
        case .video:
            return "video"
        case .audio:
            return "audio"
        case .subtitle:
            return "subtitle"
        }
    }

    /// Initializes a MediaType from a string token.
    public init?(stringValue: String) {
        switch stringValue.lowercased() {
        case "video":
            self = .video
        case "audio":
            self = .audio
        case "subtitle":
            self = .subtitle
        default:
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawInt = try? container.decode(UInt8.self), let resolved = MediaType(rawValue: rawInt) {
            self = resolved
            return
        }
        if let rawString = try? container.decode(String.self), let resolved = MediaType(stringValue: rawString) {
            self = resolved
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported MediaType encoding (expected UInt8 or string token)"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Supported video compression codecs for hardware/software sample buffer decoding.
public enum VideoCodec: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case h264 = "h264"
    case hevc = "hevc"
    case prores = "prores"
    case av1 = "av1"
    case vp9 = "vp9"
}

/// Supported audio compression codecs for CoreAudio sample buffer decoding.
public enum AudioCodec: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case aac = "aac"
    case alac = "alac"
    case flac = "flac"
    case opus = "opus"
    case vorbis = "vorbis"
    case pcm = "pcm"
    case ac3 = "ac3"
    case eac3 = "eac3"
}

/// Metadata-level video codec descriptor with explicit `.unknown` forward-compatible fallback.
public enum TTMediaVideoCodecDescriptor: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case h264 = "h264"
    case hevc = "hevc"
    case vp9 = "vp9"
    case vp8 = "vp8"
    case av1 = "av1"
    case prores = "prores"
    case mpeg4 = "mpeg4"
    case mpeg2 = "mpeg2"
    case theora = "theora"
    case unknown = "unknown"
}

/// Metadata-level audio codec descriptor with explicit `.unknown` forward-compatible fallback.
public enum TTMediaAudioCodecDescriptor: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case aac = "aac"
    case alac = "alac"
    case mp3 = "mp3"
    case opus = "opus"
    case flac = "flac"
    case vorbis = "vorbis"
    case pcm = "pcm"
    case ac3 = "ac3"
    case eac3 = "eac3"
    case dts = "dts"
    case truehd = "truehd"
    case unknown = "unknown"
}

/// Subtitle track codec identifier with explicit `.unknown` fallback.
public enum SubtitleCodec: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case srt = "srt"
    case ass = "ass"
    case ssa = "ssa"
    case webvtt = "webvtt"
    case tx3g = "tx3g"
    case pgs = "pgs"
    case vobsub = "vobsub"
    case dvb = "dvb"
    case unknown = "unknown"

    public var isTextBased: Bool {
        switch self {
        case .srt, .ass, .ssa, .webvtt, .tx3g:
            return true
        case .pgs, .vobsub, .dvb, .unknown:
            return false
        }
    }

    public var isImageBased: Bool {
        switch self {
        case .pgs, .vobsub, .dvb:
            return true
        case .srt, .ass, .ssa, .webvtt, .tx3g, .unknown:
            return false
        }
    }
}

/// Evidence-backed video dynamic range classification (`Contract v1`).
/// Never fabricated from resolution or codec alone when container/bitstream transfer evidence is absent.
public enum TTMediaDynamicRange: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case sdr = "SDR"
    case hdr10 = "HDR10"
    case hdr10Plus = "HDR10+"
    case hlg = "HLG"
    case dolbyVision = "DoVi"
    case unknown = "Unknown"

    public var isHDR: Bool {
        switch self {
        case .hdr10, .hdr10Plus, .hlg, .dolbyVision:
            return true
        case .sdr, .unknown:
            return false
        }
    }
}

/// Version constants for the cross-language and cross-process track metadata contract (`v1`).
public enum TTMediaMetadataContract: Sendable {
    public static let schemaVersion: Int = 1
    public static let versionString: String = "v1"
    public static let structuredCapabilityToken: String = "v1_structured_contract_v1"
    public static let legacyFallbackCapabilityToken: String = "legacy_c_abi_missing_track_identity"
}

/// Optional colorimetry, chroma, codec profile, and HDR static/dynamic metadata reported by container or bitstream configuration.
public struct TTMediaColorMetadata: Sendable, Codable, Equatable, Hashable {
    public static let empty = TTMediaColorMetadata()

    public let colorPrimaries: String?
    public let transferCharacteristics: String?
    public let matrixCoefficients: String?
    public let colorRange: String?
    public let chromaSubsampling: String?
    public let codecProfile: String?
    public let codecLevel: String?
    public let maxCLL: Int?
    public let maxFALL: Int?
    public let masteringDisplayMaxLuminance: Double?
    public let masteringDisplayMinLuminance: Double?
    public let dolbyVisionBLSignalCompatibilityId: Int?
    public let dolbyVisionRPUPresent: Bool?
    public let dolbyVisionELPresent: Bool?
    public let dolbyVisionBLPresent: Bool?
    public let hasHEVCEnhancementLayerConfig: Bool?

    public init(
        colorPrimaries: String? = nil,
        transferCharacteristics: String? = nil,
        matrixCoefficients: String? = nil,
        colorRange: String? = nil,
        chromaSubsampling: String? = nil,
        codecProfile: String? = nil,
        codecLevel: String? = nil,
        maxCLL: Int? = nil,
        maxFALL: Int? = nil,
        masteringDisplayMaxLuminance: Double? = nil,
        masteringDisplayMinLuminance: Double? = nil,
        dolbyVisionBLSignalCompatibilityId: Int? = nil,
        dolbyVisionRPUPresent: Bool? = nil,
        dolbyVisionELPresent: Bool? = nil,
        dolbyVisionBLPresent: Bool? = nil,
        hasHEVCEnhancementLayerConfig: Bool? = nil
    ) {
        self.colorPrimaries = colorPrimaries
        self.transferCharacteristics = transferCharacteristics
        self.matrixCoefficients = matrixCoefficients
        self.colorRange = colorRange
        self.chromaSubsampling = chromaSubsampling
        self.codecProfile = codecProfile
        self.codecLevel = codecLevel
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
        self.masteringDisplayMaxLuminance = masteringDisplayMaxLuminance
        self.masteringDisplayMinLuminance = masteringDisplayMinLuminance
        self.dolbyVisionBLSignalCompatibilityId = dolbyVisionBLSignalCompatibilityId
        self.dolbyVisionRPUPresent = dolbyVisionRPUPresent
        self.dolbyVisionELPresent = dolbyVisionELPresent
        self.dolbyVisionBLPresent = dolbyVisionBLPresent
        self.hasHEVCEnhancementLayerConfig = hasHEVCEnhancementLayerConfig
    }

    public var isEmpty: Bool {
        colorPrimaries == nil
            && transferCharacteristics == nil
            && matrixCoefficients == nil
            && colorRange == nil
            && chromaSubsampling == nil
            && maxCLL == nil
            && maxFALL == nil
            && masteringDisplayMaxLuminance == nil
            && masteringDisplayMinLuminance == nil
    }
}

/// Container-level descriptive and technical metadata (`Contract v1`).
public struct TTMediaContainerMetadata: Sendable, Codable, Equatable, Hashable {
    public let formatName: String
    public let durationSeconds: Double
    public let bitRateBps: Int64?
    public let fileSizeBytes: UInt64?
    public let title: String?
    public let muxingApp: String?
    public let writingApp: String?

    public init(
        formatName: String,
        durationSeconds: Double,
        bitRateBps: Int64? = nil,
        fileSizeBytes: UInt64? = nil,
        title: String? = nil,
        muxingApp: String? = nil,
        writingApp: String? = nil
    ) {
        self.formatName = formatName
        self.durationSeconds = durationSeconds
        self.bitRateBps = bitRateBps
        self.fileSizeBytes = fileSizeBytes
        self.title = title
        self.muxingApp = muxingApp
        self.writingApp = writingApp
    }
}

/// Validation errors raised during media packet operations.
public enum MediaPacketValidationError: Error, LocalizedError, Sendable, Equatable {
    case payloadExceedsMaximumSize(actualSize: Int, maximumSize: Int)
    case invalidTimescale(Int32)

    public var errorDescription: String? {
        switch self {
        case let .payloadExceedsMaximumSize(actualSize, maximumSize):
            return "Payload size of \(actualSize) bytes exceeds limit of \(maximumSize) bytes"
        case let .invalidTimescale(timescale):
            return "Timescale must be strictly positive (got \(timescale))"
        }
    }
}

/// Immutable data transfer object representing a demuxed media packet.
public struct MediaPacketDTO: Sendable, Codable, Equatable {
    /// Upper bound on single packet payload size (16 MB).
    public static let maxPayloadSizeBytes: Int = 16_777_216

    public let streamIndex: UInt32
    public let mediaType: MediaType
    public let ptsValue: Int64
    public let ptsTimescale: Int32
    public let dtsValue: Int64
    public let dtsTimescale: Int32
    public let durationValue: Int64
    public let durationTimescale: Int32
    public let payloadData: Data
    public let isKeyframe: Bool
    public let doNotDisplay: Bool
    public let ioSurfaceId: UInt32?
    public let sampleColorPrimaries: String?
    public let sampleTransferCharacteristics: String?
    public let sampleMatrixCoefficients: String?

    /// Initializes a media packet DTO with payload boundary enforcement.
    public init(
        streamIndex: UInt32,
        mediaType: MediaType,
        ptsValue: Int64,
        ptsTimescale: Int32,
        dtsValue: Int64,
        dtsTimescale: Int32,
        durationValue: Int64,
        durationTimescale: Int32,
        payloadData: Data,
        isKeyframe: Bool,
        doNotDisplay: Bool,
        ioSurfaceId: UInt32? = nil,
        sampleColorPrimaries: String? = nil,
        sampleTransferCharacteristics: String? = nil,
        sampleMatrixCoefficients: String? = nil
    ) throws {
        guard payloadData.count <= Self.maxPayloadSizeBytes else {
            throw MediaPacketValidationError.payloadExceedsMaximumSize(
                actualSize: payloadData.count,
                maximumSize: Self.maxPayloadSizeBytes
            )
        }
        self.streamIndex = streamIndex
        self.mediaType = mediaType
        self.ptsValue = ptsValue
        self.ptsTimescale = ptsTimescale
        self.dtsValue = dtsValue
        self.dtsTimescale = dtsTimescale
        self.durationValue = durationValue
        self.durationTimescale = durationTimescale
        self.payloadData = payloadData
        self.isKeyframe = isKeyframe
        self.doNotDisplay = doNotDisplay
        self.ioSurfaceId = ioSurfaceId
        self.sampleColorPrimaries = sampleColorPrimaries
        self.sampleTransferCharacteristics = sampleTransferCharacteristics
        self.sampleMatrixCoefficients = sampleMatrixCoefficients
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.streamIndex = try container.decode(UInt32.self, forKey: .streamIndex)
        self.mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        self.ptsValue = try container.decode(Int64.self, forKey: .ptsValue)
        self.ptsTimescale = try container.decode(Int32.self, forKey: .ptsTimescale)
        self.dtsValue = try container.decode(Int64.self, forKey: .dtsValue)
        self.dtsTimescale = try container.decode(Int32.self, forKey: .dtsTimescale)
        self.durationValue = try container.decode(Int64.self, forKey: .durationValue)
        self.durationTimescale = try container.decode(Int32.self, forKey: .durationTimescale)
        let payload = try container.decode(Data.self, forKey: .payloadData)
        guard payload.count <= Self.maxPayloadSizeBytes else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadData,
                in: container,
                debugDescription: "Payload size (\(payload.count) bytes) exceeds maximum of \(Self.maxPayloadSizeBytes) bytes"
            )
        }
        self.payloadData = payload
        self.isKeyframe = try container.decode(Bool.self, forKey: .isKeyframe)
        self.doNotDisplay = try container.decode(Bool.self, forKey: .doNotDisplay)
        self.ioSurfaceId = try container.decodeIfPresent(UInt32.self, forKey: .ioSurfaceId)
        self.sampleColorPrimaries = try container.decodeIfPresent(String.self, forKey: .sampleColorPrimaries)
        self.sampleTransferCharacteristics = try container.decodeIfPresent(String.self, forKey: .sampleTransferCharacteristics)
        self.sampleMatrixCoefficients = try container.decodeIfPresent(String.self, forKey: .sampleMatrixCoefficients)
    }

    /// Calculated CoreMedia presentation timestamp.
    public var presentationTimeStamp: CMTime {
        guard ptsTimescale > 0 else { return .invalid }
        return CMTime(value: ptsValue, timescale: ptsTimescale)
    }

    /// Calculated CoreMedia decode timestamp.
    public var decodeTimeStamp: CMTime {
        guard dtsTimescale > 0 else { return .invalid }
        return CMTime(value: dtsValue, timescale: dtsTimescale)
    }

    /// Calculated CoreMedia duration.
    public var duration: CMTime {
        guard durationTimescale > 0 else { return .invalid }
        return CMTime(value: durationValue, timescale: durationTimescale)
    }
}

/// Immutable container for video decoder configuration parameters and colorimetry.
public struct VideoFormatParameters: Sendable, Codable, Equatable {
    public let codec: VideoCodec
    public let width: Int32
    public let height: Int32
    public let pixelFormat: UInt32
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    public let extradata: Data

    public init(
        codec: VideoCodec,
        width: Int32,
        height: Int32,
        pixelFormat: UInt32,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        yCbCrMatrix: String? = nil,
        extradata: Data = Data()
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.extradata = extradata
    }
}

/// Immutable container for audio decoder configuration parameters and layout.
public struct AudioFormatParameters: Sendable, Codable, Equatable {
    public let codec: AudioCodec
    public let sampleRate: Double
    public let channelCount: UInt32
    public let bitsPerChannel: UInt32
    public let channelLayoutTag: UInt32
    public let extradata: Data

    public init(
        codec: AudioCodec,
        sampleRate: Double,
        channelCount: UInt32,
        bitsPerChannel: UInt32,
        channelLayoutTag: UInt32,
        extradata: Data = Data()
    ) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
        self.channelLayoutTag = channelLayoutTag
        self.extradata = extradata
    }
}

// MARK: - Rich Track Metadata DTOs (Contract v1)

/// Metadata descriptor for a video stream track (`Contract v1`).
public struct TTMediaVideoTrackInfo: Sendable, Codable, Equatable {
    public let trackIndex: Int
    public let catalogIndex: Int
    public let containerTrackNumber: Int64
    public let playbackTrackId: Int64
    public let packetStreamIndex: Int
    public let trackUid: UInt64?
    public let codec: VideoCodec?
    public let codecDescriptor: TTMediaVideoCodecDescriptor
    public let codecName: String
    public let rawCodecId: String
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let displayWidth: Int?
    public let displayHeight: Int?
    public let dimensionsSource: String?
    public let frameRateFps: Double?
    public let frameRateSource: String?
    public let defaultDurationNanos: UInt64?
    public let bitDepth: Int?
    public let bitDepthSource: String?
    public let bitrate: Int64?
    public let dynamicRange: TTMediaDynamicRange
    public let rawDynamicRange: String?
    public let hdrSource: String?
    public let colourSource: String?
    public let dolbyVisionProfile: Int?
    public let dolbyVisionLevel: Int?
    public let colorMetadata: TTMediaColorMetadata
    public let activeHDROutputVerifiedByDemuxer: Bool
    public let language: String?
    public let title: String?
    public let isEnabled: Bool
    public let isDefault: Bool
    public let isForced: Bool
    public let extradata: Data?
    public let demuxSelectable: Bool
    public let isSelectedForPackets: Bool
    public let selectionStatus: String
    public let selectionReason: String
    public let codecPrivateFormat: String?
    public let codecPrivateSha256: String?

    public var codecId: String? { rawCodecId.isEmpty ? nil : rawCodecId }
    public var bitRateBps: Int64? { bitrate }
    public var isHDR: Bool { dynamicRange.isHDR }
    public var isDolbyVision: Bool { dynamicRange == .dolbyVision || dolbyVisionProfile != nil }
    public var codecProfile: String? { colorMetadata.codecProfile }
    public var codecLevel: String? { colorMetadata.codecLevel }
    public var maxCLL: Int? { colorMetadata.maxCLL }
    public var maxFALL: Int? { colorMetadata.maxFALL }
    public var masteringDisplayMaxLuminance: Double? { colorMetadata.masteringDisplayMaxLuminance }
    public var masteringDisplayMinLuminance: Double? { colorMetadata.masteringDisplayMinLuminance }
    public var dolbyVisionBLSignalCompatibilityId: Int? { colorMetadata.dolbyVisionBLSignalCompatibilityId }
    public var dolbyVisionRPUPresent: Bool? { colorMetadata.dolbyVisionRPUPresent }
    public var dolbyVisionELPresent: Bool? { colorMetadata.dolbyVisionELPresent }
    public var dolbyVisionBLPresent: Bool? { colorMetadata.dolbyVisionBLPresent }
    public var hasHEVCEnhancementLayerConfig: Bool? { colorMetadata.hasHEVCEnhancementLayerConfig }
    public var naturalDisplaySize: CGSize {
        let resolvedW = (displayWidth ?? width) > 0 ? (displayWidth ?? width) : width
        let resolvedH = (displayHeight ?? height) > 0 ? (displayHeight ?? height) : height
        return CGSize(width: resolvedW, height: resolvedH)
    }

    public init(
        trackIndex: Int, codec: VideoCodec?, codecName: String, width: Int, height: Int,
        bitrate: Int64? = nil, extradata: Data? = nil, rawCodecId: String? = nil,
        demuxSelectable: Bool = true, isSelectedForPackets: Bool = true,
        codecPrivateFormat: String? = nil, codecPrivateSha256: String? = nil,
        catalogIndex: Int? = nil, containerTrackNumber: Int64? = nil,
        playbackTrackId: Int64? = nil, packetStreamIndex: Int? = nil, trackUid: UInt64? = nil,
        codecDescriptor: TTMediaVideoCodecDescriptor? = nil,
        selectionStatus: String = "selected", selectionReason: String = "selected_default",
        pixelWidth: Int? = nil, pixelHeight: Int? = nil,
        displayWidth: Int? = nil, displayHeight: Int? = nil, dimensionsSource: String? = nil,
        frameRateFps: Double? = nil, defaultDurationNanos: UInt64? = nil, bitDepth: Int? = nil,
        dynamicRange: TTMediaDynamicRange = .unknown, rawDynamicRange: String? = nil,
        dolbyVisionProfile: Int? = nil, dolbyVisionLevel: Int? = nil,
        colorMetadata: TTMediaColorMetadata = .empty,
        language: String? = nil, title: String? = nil,
        isEnabled: Bool = true, isDefault: Bool = false, isForced: Bool = false,
        frameRateSource: String? = nil, bitDepthSource: String? = nil,
        hdrSource: String? = nil, colourSource: String? = nil,
        activeHDROutputVerifiedByDemuxer: Bool = false
    ) {
        self.trackIndex = trackIndex
        self.catalogIndex = catalogIndex ?? max(0, trackIndex)
        self.containerTrackNumber = containerTrackNumber ?? Int64(trackIndex)
        self.playbackTrackId = playbackTrackId ?? Int64(trackIndex)
        self.packetStreamIndex = packetStreamIndex ?? trackIndex
        self.trackUid = trackUid
        self.codec = codec
        self.codecDescriptor = codecDescriptor ?? (codec.flatMap { TTMediaVideoCodecDescriptor(rawValue: $0.rawValue) } ?? .unknown)
        self.codecName = codecName
        self.rawCodecId = rawCodecId ?? codecName
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth ?? width
        self.pixelHeight = pixelHeight ?? height
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.dimensionsSource = dimensionsSource
        self.frameRateFps = frameRateFps
        self.frameRateSource = frameRateSource
        self.defaultDurationNanos = defaultDurationNanos
        self.bitDepth = bitDepth
        self.bitDepthSource = bitDepthSource
        self.bitrate = bitrate
        self.dynamicRange = dynamicRange
        self.rawDynamicRange = rawDynamicRange
        self.hdrSource = hdrSource
        self.colourSource = colourSource
        self.dolbyVisionProfile = dolbyVisionProfile
        self.dolbyVisionLevel = dolbyVisionLevel
        self.colorMetadata = colorMetadata
        self.activeHDROutputVerifiedByDemuxer = activeHDROutputVerifiedByDemuxer
        self.language = language
        self.title = title
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.isForced = isForced
        self.extradata = extradata
        self.demuxSelectable = demuxSelectable
        self.isSelectedForPackets = isSelectedForPackets
        self.selectionStatus = selectionStatus
        self.selectionReason = selectionReason
        self.codecPrivateFormat = codecPrivateFormat
        self.codecPrivateSha256 = codecPrivateSha256
    }
}

/// Metadata descriptor for an audio stream track (`Contract v1`).
public struct TTMediaAudioTrackInfo: Sendable, Codable, Equatable {
    public let trackIndex: Int
    public let catalogIndex: Int
    public let containerTrackNumber: Int64
    public let playbackTrackId: Int64
    public let packetStreamIndex: Int
    public let trackUid: UInt64?
    public let codec: AudioCodec?
    public let codecDescriptor: TTMediaAudioCodecDescriptor
    public let codecName: String
    public let rawCodecId: String
    public let sampleRate: Double
    public let outputSampleRateHz: Double?
    public let channels: Int
    public let bitrate: Int64?
    public let extradata: Data?
    public let demuxSelectable: Bool
    public let isSelectedForPackets: Bool
    public let selectionStatus: String
    public let selectionReason: String
    public let sampleRateSource: String?
    public let channelsSource: String?
    public let bitDepth: Int?
    public let bitDepthSource: String?
    public let channelLayout: String?
    public let channelLayoutSource: String?
    public let audioProfile: String?
    public let audioProfileSource: String?
    public let isAtmos: Bool
    public let isAtmosVerified: Bool?
    public let atmosSource: String?
    public let defaultDurationNanos: UInt64?
    public let language: String?
    public let title: String?
    public let isEnabled: Bool
    public let isDefault: Bool
    public let isForced: Bool
    public let codecPrivateFormat: String?
    public let codecPrivateSha256: String?

    public var channelCount: Int { channels }
    public var bitsPerChannel: Int { bitDepth ?? 0 }
    public var codecId: String? { rawCodecId.isEmpty ? nil : rawCodecId }
    public var bitRateBps: Int64? { bitrate }

    public init(
        trackIndex: Int, codec: AudioCodec?, codecName: String, sampleRate: Double, channels: Int,
        bitrate: Int64? = nil, extradata: Data? = nil, rawCodecId: String? = nil,
        demuxSelectable: Bool = true, isSelectedForPackets: Bool = true,
        sampleRateSource: String? = nil, channelsSource: String? = nil, bitDepth: Int? = nil,
        codecPrivateFormat: String? = nil, codecPrivateSha256: String? = nil,
        catalogIndex: Int? = nil, containerTrackNumber: Int64? = nil,
        playbackTrackId: Int64? = nil, packetStreamIndex: Int? = nil, trackUid: UInt64? = nil,
        codecDescriptor: TTMediaAudioCodecDescriptor? = nil,
        selectionStatus: String = "selected", selectionReason: String = "selected_default",
        outputSampleRateHz: Double? = nil, bitDepthSource: String? = nil,
        channelLayout: String? = nil, channelLayoutSource: String? = nil,
        audioProfile: String? = nil, isAtmos: Bool = false,
        defaultDurationNanos: UInt64? = nil, language: String? = nil, title: String? = nil,
        isEnabled: Bool = true, isDefault: Bool = false, isForced: Bool = false,
        audioProfileSource: String? = nil, isAtmosVerified: Bool? = nil, atmosSource: String? = nil
    ) {
        self.trackIndex = trackIndex
        self.catalogIndex = catalogIndex ?? max(0, trackIndex)
        self.containerTrackNumber = containerTrackNumber ?? Int64(trackIndex)
        self.playbackTrackId = playbackTrackId ?? Int64(trackIndex)
        self.packetStreamIndex = packetStreamIndex ?? trackIndex
        self.trackUid = trackUid
        self.codec = codec
        self.codecDescriptor = codecDescriptor ?? (codec.flatMap { TTMediaAudioCodecDescriptor(rawValue: $0.rawValue) } ?? .unknown)
        self.codecName = codecName
        self.rawCodecId = rawCodecId ?? codecName
        self.sampleRate = sampleRate
        self.outputSampleRateHz = outputSampleRateHz
        self.channels = channels
        self.bitrate = bitrate
        self.extradata = extradata
        self.demuxSelectable = demuxSelectable
        self.isSelectedForPackets = isSelectedForPackets
        self.selectionStatus = selectionStatus
        self.selectionReason = selectionReason
        self.sampleRateSource = sampleRateSource
        self.channelsSource = channelsSource
        self.bitDepth = bitDepth
        self.bitDepthSource = bitDepthSource
        self.channelLayout = channelLayout
        self.channelLayoutSource = channelLayoutSource
        self.audioProfile = audioProfile
        self.audioProfileSource = audioProfileSource
        let resolvedVerified = isAtmosVerified ?? (isAtmos ? true : nil)
        self.isAtmosVerified = resolvedVerified
        self.isAtmos = resolvedVerified ?? isAtmos
        self.atmosSource = atmosSource
        self.defaultDurationNanos = defaultDurationNanos
        self.language = language
        self.title = title
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.isForced = isForced
        self.codecPrivateFormat = codecPrivateFormat
        self.codecPrivateSha256 = codecPrivateSha256
    }
}

/// Metadata descriptor for an embedded subtitle track (`Contract v1`).
public struct TTMediaSubtitleTrackInfo: Sendable, Codable, Equatable {
    public let trackIndex: Int
    public let catalogIndex: Int
    public let containerTrackNumber: Int64
    public let playbackTrackId: Int64
    public let packetStreamIndex: Int
    public let trackUid: UInt64?
    public let codec: SubtitleCodec
    public let codecName: String
    public let rawCodecId: String
    public let language: String?
    public let title: String?
    public let isEnabled: Bool
    public let isDefault: Bool
    public let isForced: Bool
    public let demuxSelectable: Bool
    public let isSelectedForPackets: Bool
    public let selectionStatus: String
    public let selectionReason: String
    public let codecPrivateFormat: String?
    public let codecPrivateSha256: String?
    public let extradata: Data?

    public var isTextBased: Bool { codec.isTextBased }
    public var isImageBased: Bool { codec.isImageBased }

    public init(
        trackIndex: Int,
        codec: SubtitleCodec,
        codecName: String,
        rawCodecId: String? = nil,
        catalogIndex: Int? = nil,
        containerTrackNumber: Int64? = nil,
        playbackTrackId: Int64? = nil,
        packetStreamIndex: Int = -1,
        trackUid: UInt64? = nil,
        language: String? = nil,
        title: String? = nil,
        isEnabled: Bool = true,
        isDefault: Bool = false,
        isForced: Bool = false,
        demuxSelectable: Bool = false,
        isSelectedForPackets: Bool = false,
        selectionStatus: String = "not_selected",
        selectionReason: String = "catalog_only",
        codecPrivateFormat: String? = nil,
        codecPrivateSha256: String? = nil,
        extradata: Data? = nil
    ) {
        self.trackIndex = trackIndex
        self.catalogIndex = catalogIndex ?? max(0, trackIndex)
        self.containerTrackNumber = containerTrackNumber ?? Int64(trackIndex)
        self.playbackTrackId = playbackTrackId ?? Int64(trackIndex)
        self.packetStreamIndex = packetStreamIndex
        self.trackUid = trackUid
        self.codec = codec
        self.codecName = codecName
        self.rawCodecId = rawCodecId ?? codecName
        self.language = language
        self.title = title
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.isForced = isForced
        self.demuxSelectable = demuxSelectable
        self.isSelectedForPackets = isSelectedForPackets
        self.selectionStatus = selectionStatus
        self.selectionReason = selectionReason
        self.codecPrivateFormat = codecPrivateFormat
        self.codecPrivateSha256 = codecPrivateSha256
        self.extradata = extradata
    }
}
