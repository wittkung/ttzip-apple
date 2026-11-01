// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Formal Mach / XPC interface contract between TTZip host and ttmedia-worker daemon.
@objc(TTMediaWorkerProtocol)
public protocol TTMediaWorkerProtocol {
    /// Opens media container, probes container metadata, and configures demuxer tracks.
    func openMedia(
        at path: String,
        targetTracks: [NSNumber]?,
        reply: @escaping @Sendable (Bool, String?, [String: Any]?) -> Void
    )

    /// Receives a read-only file capability from the host through NSXPCConnection.
    @objc optional func openFileMedia(
        _ file: FileHandle,
        targetTracks: [NSNumber]?,
        reply: @escaping @Sendable (Bool, String?, [String: Any]?) -> Void
    )

    /// Lists embedded tracks (track=-1) or returns a bounded plain-text timeline.
    @objc optional func subtitles(
        forSession sessionId: String, track: Int64,
        reply: @escaping @Sendable (Data?, String?) -> Void
    )

    /// Request-scoped embedded subtitle access (`requestID > 0` isolates cancellation to that request).
    @objc optional func subtitles(
        forSession sessionId: String,
        track: Int64,
        requestID: UInt64,
        reply: @escaping @Sendable (Data?, String?) -> Void
    )

    /// Cooperatively cancels a specific subtitle request (`requestID > 0`) on the worker.
    @objc optional func cancelSubtitle(
        forSession sessionId: String,
        requestID: UInt64,
        reply: @escaping @Sendable (Bool) -> Void
    )

    /// Configures per-cluster cooperative delay (ms) for a specific subtitle request on the worker.
    @objc optional func configureSubtitleRequestDelay(
        forRequestID requestID: UInt64,
        delayMs: UInt32,
        reply: @escaping @Sendable (Bool) -> Void
    )

    /// Queries worker process ID, clusters scanned, and cancellation state for a subtitle request.
    @objc optional func subtitleRequestStatus(
        forSession sessionId: String,
        requestID: UInt64,
        reply: @escaping @Sendable (Int32, UInt64, Bool) -> Void
    )

    /// Demuxes and retrieves the next compressed or uncompressed media packet for an active session.
    func readNextPacket(
        forSession sessionId: String,
        reply: @escaping @Sendable (Data?, String?) -> Void
    )

    /// Seeks the active demuxer session to the specified presentation timestamp.
    func seek(
        to timestamp: Double,
        sessionId: String,
        accurate: Bool,
        reply: @escaping @Sendable (Bool, Double, String?) -> Void
    )

    /// Closes an active demuxing session and frees associated codec contexts.
    func closeMedia(
        forSession sessionId: String,
        reply: @escaping @Sendable (Bool, String?) -> Void
    )

    /// Transitions worker between active playback, warm standby, and cold hibernation states.
    func setSleepState(
        state: Int,
        reply: @escaping @Sendable (Bool) -> Void
    )
}

/// Commands enumerated in `ttmedia-worker.schema.json`.
public enum TTMediaWorkerCommand: String, Sendable, Codable, Equatable, CaseIterable {
    case open = "open"
    case readPacket = "read_packet"
    case seek = "seek"
    case close = "close"
    case sleepState = "sleep_state"
}

/// Worker lifecycle power states.
public enum TTMediaSleepState: Int, Sendable, Codable, Equatable {
    case activePlayback = 0
    case warmStandby = 1
    case coldHibernation = 2
}

/// Parameter payload for the `open` command.
public struct TTMediaWorkerOpenParams: Sendable, Codable, Equatable {
    public let filePath: String
    public let targetTracks: [Int]?

    public init(filePath: String, targetTracks: [Int]? = nil) {
        self.filePath = filePath
        self.targetTracks = targetTracks
    }
}

/// Parameter payload for the `seek` command.
public struct TTMediaWorkerSeekParams: Sendable, Codable, Equatable {
    public let targetTimestamp: Double
    public let accurate: Bool?

    public init(targetTimestamp: Double, accurate: Bool? = nil) {
        self.targetTimestamp = targetTimestamp
        self.accurate = accurate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decode(Double.self, forKey: .targetTimestamp)
        guard timestamp >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .targetTimestamp,
                in: container,
                debugDescription: "Target timestamp must be non-negative"
            )
        }
        self.targetTimestamp = timestamp
        self.accurate = try container.decodeIfPresent(Bool.self, forKey: .accurate)
    }
}

/// Packet metadata representation matching `packetResponse` in `ttmedia-worker.schema.json`.
public struct TTMediaWorkerPacketResponse: Sendable, Codable, Equatable {
    public let streamIndex: Int
    public let mediaType: String
    public let pts: Int64
    public let dts: Int64
    public let duration: Int64
    public let timescale: Int32
    public let isKeyframe: Bool
    public let doNotDisplay: Bool
    public let payloadSizeBytes: Int

    public init(
        streamIndex: Int,
        mediaType: String,
        pts: Int64,
        dts: Int64,
        duration: Int64,
        timescale: Int32,
        isKeyframe: Bool,
        doNotDisplay: Bool,
        payloadSizeBytes: Int
    ) throws {
        guard streamIndex >= 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "streamIndex must be >= 0 (got \(streamIndex))"
                )
            )
        }
        guard ["video", "audio", "subtitle"].contains(mediaType) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "mediaType must be video, audio, or subtitle (got \(mediaType))"
                )
            )
        }
        guard duration >= 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "duration must be >= 0 (got \(duration))"
                )
            )
        }
        guard timescale >= 1 else {
            throw MediaPacketValidationError.invalidTimescale(timescale)
        }
        guard payloadSizeBytes >= 0 && payloadSizeBytes <= MediaPacketDTO.maxPayloadSizeBytes else {
            throw MediaPacketValidationError.payloadExceedsMaximumSize(
                actualSize: payloadSizeBytes,
                maximumSize: MediaPacketDTO.maxPayloadSizeBytes
            )
        }
        self.streamIndex = streamIndex
        self.mediaType = mediaType
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.timescale = timescale
        self.isKeyframe = isKeyframe
        self.doNotDisplay = doNotDisplay
        self.payloadSizeBytes = payloadSizeBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let streamIndex = try container.decode(Int.self, forKey: .streamIndex)
        guard streamIndex >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .streamIndex,
                in: container,
                debugDescription: "streamIndex must be non-negative"
            )
        }
        let mediaType = try container.decode(String.self, forKey: .mediaType)
        guard ["video", "audio", "subtitle"].contains(mediaType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .mediaType,
                in: container,
                debugDescription: "mediaType must be one of [video, audio, subtitle]"
            )
        }
        let pts = try container.decode(Int64.self, forKey: .pts)
        let dts = try container.decode(Int64.self, forKey: .dts)
        let duration = try container.decode(Int64.self, forKey: .duration)
        guard duration >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .duration,
                in: container,
                debugDescription: "duration must be non-negative"
            )
        }
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        guard timescale >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .timescale,
                in: container,
                debugDescription: "timescale must be at least 1"
            )
        }
        let isKeyframe = try container.decode(Bool.self, forKey: .isKeyframe)
        let doNotDisplay = try container.decode(Bool.self, forKey: .doNotDisplay)
        let payloadSizeBytes = try container.decode(Int.self, forKey: .payloadSizeBytes)
        guard payloadSizeBytes >= 0 && payloadSizeBytes <= MediaPacketDTO.maxPayloadSizeBytes else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadSizeBytes,
                in: container,
                debugDescription: "payloadSizeBytes must be between 0 and \(MediaPacketDTO.maxPayloadSizeBytes)"
            )
        }

        self.streamIndex = streamIndex
        self.mediaType = mediaType
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.timescale = timescale
        self.isKeyframe = isKeyframe
        self.doNotDisplay = doNotDisplay
        self.payloadSizeBytes = payloadSizeBytes
    }
}

/// Strong-typed IPC message envelope conforming to `ttmedia-worker.schema.json`.
public struct TTMediaWorkerContract: Sendable, Codable, Equatable {
    public let command: TTMediaWorkerCommand
    public let sessionId: String
    public let openParams: TTMediaWorkerOpenParams?
    public let seekParams: TTMediaWorkerSeekParams?
    public let packetResponse: TTMediaWorkerPacketResponse?

    public init(
        command: TTMediaWorkerCommand,
        sessionId: String,
        openParams: TTMediaWorkerOpenParams? = nil,
        seekParams: TTMediaWorkerSeekParams? = nil,
        packetResponse: TTMediaWorkerPacketResponse? = nil
    ) {
        self.command = command
        self.sessionId = sessionId
        self.openParams = openParams
        self.seekParams = seekParams
        self.packetResponse = packetResponse
    }

    /// Constructs an `open` command contract message.
    public static func open(
        sessionId: String,
        filePath: String,
        targetTracks: [Int]? = nil
    ) -> TTMediaWorkerContract {
        TTMediaWorkerContract(
            command: .open,
            sessionId: sessionId,
            openParams: TTMediaWorkerOpenParams(filePath: filePath, targetTracks: targetTracks)
        )
    }

    /// Constructs a `read_packet` command contract message.
    public static func readPacket(sessionId: String) -> TTMediaWorkerContract {
        TTMediaWorkerContract(command: .readPacket, sessionId: sessionId)
    }

    /// Constructs a `seek` command contract message.
    public static func seek(
        sessionId: String,
        targetTimestamp: Double,
        accurate: Bool = true
    ) -> TTMediaWorkerContract {
        TTMediaWorkerContract(
            command: .seek,
            sessionId: sessionId,
            seekParams: TTMediaWorkerSeekParams(targetTimestamp: targetTimestamp, accurate: accurate)
        )
    }

    /// Constructs a `close` command contract message.
    public static func close(sessionId: String) -> TTMediaWorkerContract {
        TTMediaWorkerContract(command: .close, sessionId: sessionId)
    }

    /// Constructs a `sleep_state` command contract message.
    public static func sleepState(sessionId: String) -> TTMediaWorkerContract {
        TTMediaWorkerContract(command: .sleepState, sessionId: sessionId)
    }

    /// Constructs a response contract message carrying demuxed packet metadata.
    public static func response(
        sessionId: String,
        packet: TTMediaWorkerPacketResponse
    ) -> TTMediaWorkerContract {
        TTMediaWorkerContract(
            command: .readPacket,
            sessionId: sessionId,
            packetResponse: packet
        )
    }
}

extension NSXPCInterface {
    /// Configures canonical NSXPCInterface instance for TTMediaWorkerProtocol.
    public static func makeMediaWorkerInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: TTMediaWorkerProtocol.self)
        let allowedClasses = NSSet(array: [
            NSDictionary.self,
            NSString.self,
            NSNumber.self,
            NSArray.self,
            NSData.self,
            NSNull.self
        ]) as! Set<AnyHashable>
        interface.setClasses(
            allowedClasses,
            for: #selector(TTMediaWorkerProtocol.openMedia(at:targetTracks:reply:)),
            argumentIndex: 2,
            ofReply: true
        )
        interface.setClasses(
            allowedClasses,
            for: #selector(TTMediaWorkerProtocol.openFileMedia(_:targetTracks:reply:)),
            argumentIndex: 2,
            ofReply: true
        )
        return interface
    }
}

/// Sanitizes metadata dictionaries so all nested values conform strictly to XPC and PropertyList safe types (`NSDictionary`, `NSArray`, `NSString`, `NSNumber`, `NSData`) without `NSNull`.
public enum TTMediaTransportMetadataSanitizer {
    public static func sanitizeDictionary(_ dict: [String: Any], encodeDataAsBase64: Bool = false) -> [String: Any] {
        var cleaned: [String: Any] = [:]
        cleaned.reserveCapacity(dict.count)
        for (key, rawValue) in dict {
            if let safeValue = sanitizeValue(rawValue, encodeDataAsBase64: encodeDataAsBase64) {
                cleaned[key] = safeValue
            }
        }
        return cleaned
    }

    public static func sanitizeValue(_ rawValue: Any, encodeDataAsBase64: Bool = false) -> Any? {
        if rawValue is NSNull { return nil }
        if let str = rawValue as? String { return str }
        if let data = rawValue as? Data { return encodeDataAsBase64 ? data.base64EncodedString() : data }
        if let num = rawValue as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return num.boolValue }
            return num.doubleValue.isFinite ? num : nil
        }
        if let subDict = rawValue as? [String: Any] { return sanitizeDictionary(subDict, encodeDataAsBase64: encodeDataAsBase64) }
        if let arr = rawValue as? [Any] { return arr.compactMap { sanitizeValue($0, encodeDataAsBase64: encodeDataAsBase64) } }
        return nil
    }

    public static func mergeOptionalEntries(_ entries: [(String, Any?)], into dict: inout [String: Any]) {
        for (key, rawValue) in entries {
            if let rawValue, let safeValue = sanitizeValue(rawValue) {
                dict[key] = safeValue
            }
        }
    }
}

extension MediaPacketDTO {
    /// Transforms the DTO into its schema-compliant IPC packet response representation.
    public func toWorkerPacketResponse() -> TTMediaWorkerPacketResponse {
        do {
            return try TTMediaWorkerPacketResponse(
                streamIndex: Int(streamIndex),
                mediaType: mediaType.stringValue,
                pts: ptsValue,
                dts: dtsValue,
                duration: durationValue,
                timescale: ptsTimescale,
                isKeyframe: isKeyframe,
                doNotDisplay: doNotDisplay,
                payloadSizeBytes: payloadData.count
            )
        } catch {
            // Internal fallback: guaranteed to succeed given valid MediaPacketDTO invariants
            return try! TTMediaWorkerPacketResponse(
                streamIndex: Int(streamIndex),
                mediaType: mediaType.stringValue,
                pts: ptsValue,
                dts: dtsValue,
                duration: max(0, durationValue),
                timescale: max(1, ptsTimescale),
                isKeyframe: isKeyframe,
                doNotDisplay: doNotDisplay,
                payloadSizeBytes: min(payloadData.count, MediaPacketDTO.maxPayloadSizeBytes)
            )
        }
    }

    /// Reconstructs a MediaPacketDTO from an IPC packet response and raw payload data.
    public init(
        packetResponse: TTMediaWorkerPacketResponse,
        payloadData: Data,
        durationTimescale: Int32? = nil,
        ioSurfaceId: UInt32? = nil
    ) throws {
        guard let resolvedType = MediaType(stringValue: packetResponse.mediaType) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Unsupported mediaType: \(packetResponse.mediaType)"
                )
            )
        }
        try self.init(
            streamIndex: UInt32(packetResponse.streamIndex),
            mediaType: resolvedType,
            ptsValue: packetResponse.pts,
            ptsTimescale: packetResponse.timescale,
            dtsValue: packetResponse.dts,
            dtsTimescale: packetResponse.timescale,
            durationValue: packetResponse.duration,
            durationTimescale: durationTimescale ?? packetResponse.timescale,
            payloadData: payloadData,
            isKeyframe: packetResponse.isKeyframe,
            doNotDisplay: packetResponse.doNotDisplay,
            ioSurfaceId: ioSurfaceId
        )
    }
}

// MARK: - Contract v1 Transport Dictionary Serialization & StreamInfo

extension TTMediaContainerMetadata {
    internal func toTransportDictionary() -> [String: Any] {
        var dict: [String: Any] = ["formatName": formatName, "durationSeconds": durationSeconds]
        TTMediaTransportMetadataSanitizer.mergeOptionalEntries([
            ("bitRateBps", bitRateBps), ("fileSizeBytes", fileSizeBytes),
            ("title", title), ("muxingApp", muxingApp), ("writingApp", writingApp)
        ], into: &dict)
        return dict
    }
}

extension TTMediaVideoTrackInfo {
    internal func toTransportDictionary(fallbackExtradata: Data? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "trackIndex": trackIndex, "catalogIndex": catalogIndex,
            "containerTrackNumber": containerTrackNumber, "playbackTrackId": playbackTrackId,
            "packetStreamIndex": packetStreamIndex, "codecDescriptor": codecDescriptor.rawValue,
            "rawCodecId": rawCodecId, "codecName": codecName,
            "width": width, "height": height, "pixelWidth": pixelWidth, "pixelHeight": pixelHeight,
            "dynamicRange": dynamicRange.rawValue,
            "activeHDROutputVerifiedByDemuxer": activeHDROutputVerifiedByDemuxer,
            "isEnabled": isEnabled, "isDefault": isDefault, "isForced": isForced,
            "demuxSelectable": demuxSelectable, "isSelectedForPackets": isSelectedForPackets,
            "selectionStatus": selectionStatus, "selectionReason": selectionReason
        ]
        let resolvedExtradata = extradata ?? (isSelectedForPackets ? fallbackExtradata : nil)
        TTMediaTransportMetadataSanitizer.mergeOptionalEntries([
            ("codec", codec?.rawValue), ("trackUid", trackUid),
            ("displayWidth", displayWidth), ("displayHeight", displayHeight),
            ("dimensionsSource", dimensionsSource), ("frameRateFps", frameRateFps),
            ("frameRateSource", frameRateSource), ("defaultDurationNanos", defaultDurationNanos),
            ("bitDepth", bitDepth), ("bitDepthSource", bitDepthSource),
            ("bitrate", bitrate), ("rawDynamicRange", rawDynamicRange),
            ("hdrSource", hdrSource), ("colourSource", colourSource),
            ("dolbyVisionProfile", dolbyVisionProfile), ("dolbyVisionLevel", dolbyVisionLevel),
            ("colorPrimaries", colorMetadata.colorPrimaries),
            ("transferCharacteristics", colorMetadata.transferCharacteristics),
            ("matrixCoefficients", colorMetadata.matrixCoefficients),
            ("colorRange", colorMetadata.colorRange),
            ("chromaSubsampling", colorMetadata.chromaSubsampling),
            ("language", language), ("title", title),
            ("codecPrivateFormat", codecPrivateFormat), ("codecPrivateSha256", codecPrivateSha256),
            ("extradata", resolvedExtradata)
        ], into: &dict)
        return dict
    }
}

extension TTMediaAudioTrackInfo {
    internal func toTransportDictionary(fallbackExtradata: Data? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "trackIndex": trackIndex, "catalogIndex": catalogIndex,
            "containerTrackNumber": containerTrackNumber, "playbackTrackId": playbackTrackId,
            "packetStreamIndex": packetStreamIndex, "codecDescriptor": codecDescriptor.rawValue,
            "rawCodecId": rawCodecId, "codecName": codecName,
            "sampleRate": sampleRate, "channels": channels,
            "isEnabled": isEnabled, "isDefault": isDefault, "isForced": isForced,
            "demuxSelectable": demuxSelectable, "isSelectedForPackets": isSelectedForPackets,
            "selectionStatus": selectionStatus, "selectionReason": selectionReason
        ]
        let resolvedExtradata = extradata ?? (isSelectedForPackets ? fallbackExtradata : nil)
        TTMediaTransportMetadataSanitizer.mergeOptionalEntries([
            ("codec", codec?.rawValue), ("trackUid", trackUid),
            ("outputSampleRateHz", outputSampleRateHz), ("bitrate", bitrate),
            ("sampleRateSource", sampleRateSource), ("channelsSource", channelsSource),
            ("bitDepth", bitDepth), ("bitDepthSource", bitDepthSource),
            ("channelLayout", channelLayout), ("channelLayoutSource", channelLayoutSource),
            ("audioProfile", audioProfile), ("audioProfileSource", audioProfileSource),
            ("isAtmos", isAtmosVerified), ("isAtmosVerified", isAtmosVerified),
            ("atmosSource", atmosSource), ("defaultDurationNanos", defaultDurationNanos),
            ("language", language), ("title", title),
            ("codecPrivateFormat", codecPrivateFormat), ("codecPrivateSha256", codecPrivateSha256),
            ("extradata", resolvedExtradata)
        ], into: &dict)
        return dict
    }
}

extension TTMediaSubtitleTrackInfo {
    internal func toTransportDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "trackIndex": trackIndex, "catalogIndex": catalogIndex,
            "containerTrackNumber": containerTrackNumber, "playbackTrackId": playbackTrackId,
            "packetStreamIndex": packetStreamIndex, "codec": codec.rawValue,
            "codecName": codecName, "rawCodecId": rawCodecId,
            "isEnabled": isEnabled, "isDefault": isDefault, "isForced": isForced,
            "isTextBased": isTextBased, "isImageBased": isImageBased,
            "demuxSelectable": demuxSelectable, "isSelectedForPackets": isSelectedForPackets,
            "selectionStatus": selectionStatus, "selectionReason": selectionReason
        ]
        TTMediaTransportMetadataSanitizer.mergeOptionalEntries([
            ("trackUid", trackUid), ("language", language), ("title", title),
            ("codecPrivateFormat", codecPrivateFormat), ("codecPrivateSha256", codecPrivateSha256),
            ("extradata", extradata)
        ], into: &dict)
        return dict
    }
}

/// High-level container and stream metadata returned upon opening a media resource (`Contract v1`).
public struct TTMediaStreamInfo: Sendable, Codable, Equatable {
    public let sessionId: String
    public let format: String
    public let durationSeconds: Double
    public let videoTracks: [TTMediaVideoTrackInfo]
    public let audioTracks: [TTMediaAudioTrackInfo]
    public let subtitleTracks: [TTMediaSubtitleTrackInfo]
    public let catalogVideoTracks: [TTMediaVideoTrackInfo]
    public let catalogAudioTracks: [TTMediaAudioTrackInfo]
    public let catalogSubtitleTracks: [TTMediaSubtitleTrackInfo]
    public let selectedVideoTrackNumber: Int?
    public let selectedAudioTrackNumber: Int?
    public let primaryAudioTrackNumber: Int?
    public let hasCuesIndex: Bool
    public let containerMetadata: TTMediaContainerMetadata
    public let metadataSchemaVersion: Int
    public let metadataContractVersion: String
    public let activeHDROutputVerifiedByDemuxer: Bool
    public let metadata: [String: String]

    public var metadataCapability: String? { metadata["metadataCapability"] }
    public var hasVideo: Bool { !videoTracks.isEmpty || !catalogVideoTracks.isEmpty }
    public var hasAudio: Bool { !audioTracks.isEmpty || !catalogAudioTracks.isEmpty }
    public var hasSubtitles: Bool { !subtitleTracks.isEmpty || !catalogSubtitleTracks.isEmpty }
    public var primaryVideoTrack: TTMediaVideoTrackInfo? {
        videoTracks.first(where: \.isSelectedForPackets) ?? videoTracks.first ?? catalogVideoTracks.first
    }
    public var primaryAudioTrack: TTMediaAudioTrackInfo? {
        audioTracks.first(where: \.isSelectedForPackets) ?? audioTracks.first ?? catalogAudioTracks.first
    }
    public var bitRateBps: Int64? { containerMetadata.bitRateBps }
    public var fileSizeBytes: UInt64? { containerMetadata.fileSizeBytes }
    public var title: String? { containerMetadata.title }
    public var muxingApp: String? { containerMetadata.muxingApp }
    public var writingApp: String? { containerMetadata.writingApp }

    public init(
        sessionId: String, format: String, durationSeconds: Double,
        videoTracks: [TTMediaVideoTrackInfo] = [], audioTracks: [TTMediaAudioTrackInfo] = [],
        metadata: [String: String] = [:],
        catalogVideoTracks: [TTMediaVideoTrackInfo]? = nil,
        catalogAudioTracks: [TTMediaAudioTrackInfo]? = nil,
        selectedVideoTrackNumber: Int? = nil, selectedAudioTrackNumber: Int? = nil,
        primaryAudioTrackNumber: Int? = nil, hasCuesIndex: Bool = false,
        subtitleTracks: [TTMediaSubtitleTrackInfo] = [],
        catalogSubtitleTracks: [TTMediaSubtitleTrackInfo]? = nil,
        containerMetadata: TTMediaContainerMetadata? = nil,
        metadataSchemaVersion: Int = TTMediaMetadataContract.schemaVersion,
        metadataContractVersion: String = TTMediaMetadataContract.versionString,
        activeHDROutputVerifiedByDemuxer: Bool = false
    ) {
        self.sessionId = sessionId
        self.format = format
        self.durationSeconds = durationSeconds
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.catalogVideoTracks = catalogVideoTracks ?? videoTracks
        self.catalogAudioTracks = catalogAudioTracks ?? audioTracks
        self.catalogSubtitleTracks = catalogSubtitleTracks ?? subtitleTracks
        self.selectedVideoTrackNumber = selectedVideoTrackNumber ?? Self.firstValidTrackIndex(in: videoTracks.filter(\.isSelectedForPackets))
        self.selectedAudioTrackNumber = selectedAudioTrackNumber ?? Self.firstValidTrackIndex(in: audioTracks.filter(\.isSelectedForPackets))
        self.primaryAudioTrackNumber = primaryAudioTrackNumber ?? Self.firstValidTrackIndex(in: audioTracks)
        self.hasCuesIndex = hasCuesIndex
        self.containerMetadata = containerMetadata ?? TTMediaContainerMetadata(formatName: format, durationSeconds: durationSeconds)
        self.metadataSchemaVersion = metadataSchemaVersion
        self.metadataContractVersion = metadataContractVersion
        self.activeHDROutputVerifiedByDemuxer = activeHDROutputVerifiedByDemuxer
        self.metadata = metadata
    }

    internal func toTransportDictionary(
        videoExtradataFallback: Data? = nil,
        audioExtradataFallback: Data? = nil,
        capabilityOverride: String? = nil,
        hasExplicitSelectedAudioTrack: Bool = true
    ) -> [String: Any] {
        let capability = capabilityOverride ?? metadataCapability ?? TTMediaMetadataContract.structuredCapabilityToken
        var stringMeta = metadata
        stringMeta["metadataCapability"] = capability
        stringMeta["schemaVersion"] = String(metadataSchemaVersion)
        stringMeta["metadataContractVersion"] = metadataContractVersion

        var dict: [String: Any] = [
            "format": format,
            "durationSeconds": durationSeconds,
            "hasCuesIndex": hasCuesIndex,
            "activeHDROutputVerifiedByDemuxer": activeHDROutputVerifiedByDemuxer,
            "videoTracks": videoTracks.map { $0.toTransportDictionary(fallbackExtradata: videoExtradataFallback) },
            "audioTracks": audioTracks.map { $0.toTransportDictionary(fallbackExtradata: audioExtradataFallback) },
            "subtitleTracks": subtitleTracks.map { $0.toTransportDictionary() },
            "catalogVideoTracks": catalogVideoTracks.map { $0.toTransportDictionary(fallbackExtradata: videoExtradataFallback) },
            "catalogAudioTracks": catalogAudioTracks.map { $0.toTransportDictionary(fallbackExtradata: audioExtradataFallback) },
            "catalogSubtitleTracks": catalogSubtitleTracks.map { $0.toTransportDictionary() },
            "containerMetadata": containerMetadata.toTransportDictionary(),
            "hasExplicitSelectedAudioTrack": hasExplicitSelectedAudioTrack,
            "schemaVersion": metadataSchemaVersion,
            "metadataSchemaVersion": metadataSchemaVersion,
            "metadataContractVersion": metadataContractVersion,
            "metadataCapability": capability,
            "metadata": stringMeta
        ]
        TTMediaTransportMetadataSanitizer.mergeOptionalEntries([
            ("bitRateBps", containerMetadata.bitRateBps), ("fileSizeBytes", containerMetadata.fileSizeBytes),
            ("title", containerMetadata.title), ("muxingApp", containerMetadata.muxingApp),
            ("writingApp", containerMetadata.writingApp), ("selectedVideoTrackNumber", selectedVideoTrackNumber),
            ("selectedAudioTrackNumber", selectedAudioTrackNumber), ("primaryAudioTrackNumber", primaryAudioTrackNumber)
        ], into: &dict)
        return TTMediaTransportMetadataSanitizer.sanitizeDictionary(dict)
    }

    private static let videoCodecMap: [String: VideoCodec] = [
        "h264": .h264, "avc": .h264, "avc1": .h264, "v_mpeg4/iso/avc": .h264,
        "hevc": .hevc, "h265": .hevc, "hvc1": .hevc, "hev1": .hevc, "v_mpegh/iso/hevc": .hevc,
        "vp9": .vp9, "v_vp9": .vp9, "av1": .av1, "av01": .av1, "v_av1": .av1, "prores": .prores, "v_prores": .prores,
    ]
    private static let videoDescriptorMap: [String: TTMediaVideoCodecDescriptor] = [
        "h264": .h264, "avc": .h264, "avc1": .h264, "v_mpeg4/iso/avc": .h264,
        "hevc": .hevc, "h265": .hevc, "hvc1": .hevc, "hev1": .hevc, "dvh1": .hevc, "dvhe": .hevc, "v_mpegh/iso/hevc": .hevc,
        "vp9": .vp9, "v_vp9": .vp9, "vp8": .vp8, "v_vp8": .vp8,
        "av1": .av1, "av01": .av1, "dav1": .av1, "v_av1": .av1, "prores": .prores, "v_prores": .prores,
        "mpeg4": .mpeg4, "v_mpeg4/iso/sp": .mpeg4, "v_mpeg4/iso/asp": .mpeg4,
        "mpeg2": .mpeg2, "v_mpeg2": .mpeg2, "theora": .theora, "v_theora": .theora,
    ]
    private static let exactAudioCodecMap: [String: AudioCodec] = [
        "aac": .aac, "mp4a": .aac, "ac3": .ac3, "a_ac3": .ac3, "eac3": .eac3, "ec-3": .eac3, "a_eac3": .eac3,
        "alac": .alac, "a_alac": .alac, "flac": .flac, "a_flac": .flac,
        "opus": .opus, "a_opus": .opus, "vorbis": .vorbis, "a_vorbis": .vorbis,
        "pcm": .pcm, "a_pcm/int/lit": .pcm, "a_pcm/int/big": .pcm, "a_pcm/float/ieee": .pcm,
    ]
    private static let audioDescriptorMap: [String: TTMediaAudioCodecDescriptor] = [
        "aac": .aac, "mp4a": .aac, "alac": .alac, "a_alac": .alac,
        "mp3": .mp3, "a_mpeg/l3": .mp3, "a_mpeg/l2": .mp3, "opus": .opus, "a_opus": .opus,
        "flac": .flac, "a_flac": .flac, "vorbis": .vorbis, "a_vorbis": .vorbis,
        "pcm": .pcm, "a_pcm/int/lit": .pcm, "a_pcm/int/big": .pcm, "a_pcm/float/ieee": .pcm,
        "ac3": .ac3, "a_ac3": .ac3, "eac3": .eac3, "ec-3": .eac3, "a_eac3": .eac3,
        "dts": .dts, "a_dts": .dts, "truehd": .truehd, "a_truehd": .truehd,
    ]
    private static let subtitleCodecMap: [String: SubtitleCodec] = [
        "srt": .srt, "subrip": .srt, "utf8": .srt, "s_text/utf8": .srt, "s_text/ascii": .srt,
        "ass": .ass, "s_text/ass": .ass, "s_ass": .ass, "ssa": .ssa, "s_text/ssa": .ssa, "s_ssa": .ssa,
        "webvtt": .webvtt, "vtt": .webvtt, "wvtt": .webvtt, "s_text/webvtt": .webvtt,
        "tx3g": .tx3g, "mov_text": .tx3g, "pgs": .pgs, "hdmv_pgs_subtitle": .pgs, "s_hdmv/pgs": .pgs,
        "vobsub": .vobsub, "dvd_subtitle": .vobsub, "s_vobsub": .vobsub, "dvb": .dvb, "dvb_subtitle": .dvb, "s_dvbsub": .dvb,
    ]
    private static let rawDynamicRangeMap: [String: TTMediaDynamicRange] = [
        "dovi": .dolbyVision, "dolby_vision": .dolbyVision, "dolbyvision": .dolbyVision, "dv": .dolbyVision,
        "hdr10+": .hdr10Plus, "hdr10_plus": .hdr10Plus, "hdr10plus": .hdr10Plus, "smpte2094-40": .hdr10Plus,
        "hdr10": .hdr10, "pq": .hdr10, "smpte2084": .hdr10, "hlg": .hlg, "arib-std-b67": .hlg, "sdr": .sdr, "unknown": .unknown,
    ]
    private static let sdrTransferTokens: Set<String> = [
        "bt709", "itu-r-bt709", "itu_r_709_2", "srgb", "iec61966-2-1", "smpte170m", "bt601", "bt470m", "bt470bg", "smpte240m"
    ]

    internal static func mapVideoCodec(canonical: String?, raw: String?) -> VideoCodec? {
        [canonical, raw].compactMap { $0?.lowercased() }.lazy.compactMap { videoCodecMap[$0] }.first
    }

    internal static func mapVideoDescriptor(canonical: String?, raw: String?, explicit: String?) -> TTMediaVideoCodecDescriptor {
        if let explicit, let desc = TTMediaVideoCodecDescriptor(rawValue: explicit.lowercased()), desc != .unknown { return desc }
        return [canonical, raw].compactMap { $0?.lowercased() }.lazy.compactMap { videoDescriptorMap[$0] }.first ?? .unknown
    }

    internal static func mapAudioCodec(canonical: String?, raw: String?) -> AudioCodec? {
        for candidate in [canonical, raw].compactMap({ $0?.lowercased() }) {
            if let exact = exactAudioCodecMap[candidate] { return exact }
            if candidate.hasPrefix("a_aac") { return .aac }
            if candidate.hasPrefix("pcm_") { return .pcm }
        }
        return nil
    }

    internal static func mapAudioDescriptor(canonical: String?, raw: String?, explicit: String?) -> TTMediaAudioCodecDescriptor {
        if let explicit, let desc = TTMediaAudioCodecDescriptor(rawValue: explicit.lowercased()), desc != .unknown { return desc }
        for candidate in [canonical, raw].compactMap({ $0?.lowercased() }) {
            if let exact = audioDescriptorMap[candidate] { return exact }
            if candidate.hasPrefix("a_aac") { return .aac }
            if candidate.hasPrefix("pcm_") { return .pcm }
            if candidate.hasPrefix("a_dts") { return .dts }
        }
        return .unknown
    }

    internal static func mapSubtitleCodec(canonical: String?, raw: String?, explicit: String?) -> SubtitleCodec {
        [explicit, canonical, raw].compactMap { $0?.lowercased() }.lazy.compactMap { subtitleCodecMap[$0] }.first ?? .unknown
    }

    internal static func resolveDynamicRange(
        rawDynamicRange: String?, transferCharacteristics: String?,
        dolbyVisionProfile: Int?, codecPrivateFormat: String?, rawCodecId: String?
    ) -> TTMediaDynamicRange {
        if let raw = rawDynamicRange?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let mapped = rawDynamicRangeMap[raw] { return mapped }
        if dolbyVisionProfile != nil { return .dolbyVision }
        if let cpf = codecPrivateFormat?.lowercased(), ["dvcc", "dvvc", "dvwc"].contains(cpf) { return .dolbyVision }
        if let cid = rawCodecId?.lowercased(), ["dvh1", "dvhe", "dav1", "dva1"].contains(cid) { return .dolbyVision }
        if let tc = transferCharacteristics?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !tc.isEmpty {
            if tc.contains("2084") || tc == "pq" || tc == "itu_r_2100_pq" { return .hdr10 }
            if tc.contains("std-b67") || tc.contains("hlg") || tc == "itu_r_2100_hlg" { return .hlg }
            if sdrTransferTokens.contains(tc) { return .sdr }
        }
        return .unknown
    }

    internal static func resolveAtmosVerified(
        explicitFlag: Bool?, audioProfile: String?, rawCodecId: String?, atmosSource: String? = nil
    ) -> Bool? {
        if let explicitFlag { return explicitFlag }
        if let profile = audioProfile?.lowercased(), profile.contains("atmos") || profile.contains("joc") { return true }
        if let cid = rawCodecId?.lowercased(), cid.contains("atmos") || cid.contains("ec+3") { return true }
        if let src = atmosSource?.lowercased(), src.contains("no_joc") || src.contains("no_atmos") { return false }
        return nil
    }
}

/// Canonical typealias aligning with architecture contracts.
public typealias StreamMetadata = TTMediaStreamInfo
