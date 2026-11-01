// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Darwin
import Foundation
import TTMediaDemux

// MARK: - TTMediaStreamInfo Dictionary & V1 JSON Initializers and Parsing Helpers

extension TTMediaStreamInfo {
    public init(sessionId: String, dictionary: [String: Any]) {
        let fmt = Self.parseContainerFormat(dictionary)
        let dur = Self.parseDurationSeconds(dictionary)
        let resolvedTracks = Self.resolveTrackCollections(from: dictionary)
        let selection = Self.resolveSelectedTrackNumbers(
            dictionary: dictionary,
            videoTracks: resolvedTracks.video,
            audioTracks: resolvedTracks.audio
        )
        self.init(
            sessionId: sessionId,
            format: fmt,
            durationSeconds: dur,
            videoTracks: resolvedTracks.video,
            audioTracks: resolvedTracks.audio,
            metadata: Self.parseStringMetadata(dictionary),
            catalogVideoTracks: resolvedTracks.catalogVideo,
            catalogAudioTracks: resolvedTracks.catalogAudio,
            selectedVideoTrackNumber: selection.video,
            selectedAudioTrackNumber: selection.audio,
            primaryAudioTrackNumber: selection.primaryAudio,
            hasCuesIndex: Self.firstBool(in: dictionary, keys: ["hasCuesIndex", "has_cues_index"]) ?? false,
            subtitleTracks: resolvedTracks.subtitle,
            catalogSubtitleTracks: resolvedTracks.catalogSubtitle,
            containerMetadata: Self.parseContainerMetadata(dictionary, formatName: fmt, durationSeconds: dur),
            metadataSchemaVersion: Self.firstInt(in: dictionary, keys: ["schema_version", "schemaVersion", "metadataSchemaVersion"]) ?? TTMediaMetadataContract.schemaVersion,
            metadataContractVersion: Self.firstString(in: dictionary, keys: ["metadataContractVersion", "contract_version"]) ?? TTMediaMetadataContract.versionString,
            activeHDROutputVerifiedByDemuxer: Self.firstBool(in: dictionary, keys: ["activeHDROutputVerifiedByDemuxer", "active_hdr_output_verified_by_demuxer"]) ?? false
        )
    }

    public init(sessionId: String, v1ContractJSON: Data) throws {
        let dict = try MediaWorkerDirectTransport.buildStreamMetadata(fromV1ContractJSON: v1ContractJSON, cInfo: nil)
        self.init(sessionId: sessionId, dictionary: dict)
    }

    internal static func firstValidTrackIndex(in tracks: [TTMediaVideoTrackInfo]) -> Int? {
        guard let idx = tracks.first?.trackIndex, idx >= 0 else { return nil }
        return idx
    }

    internal static func firstValidTrackIndex(in tracks: [TTMediaAudioTrackInfo]) -> Int? {
        guard let idx = tracks.first?.trackIndex, idx >= 0 else { return nil }
        return idx
    }

    fileprivate static func firstDictArray(in dict: [String: Any], keys: [String]) -> [[String: Any]]? {
        keys.lazy.compactMap { dict[$0] as? [[String: Any]] }.first
    }

    fileprivate static func extractTrackItems<T>(
        from dict: [String: Any],
        directKeys: [String],
        fallbackPools: [[[String: Any]]?],
        mediaType: String,
        parser: ([String: Any]) -> T
    ) -> [T]? {
        if let direct = firstDictArray(in: dict, keys: directKeys) { return direct.map(parser) }
        for pool in fallbackPools {
            if let pool { return pool.filter { isTrackType($0, mediaType) }.map(parser) }
        }
        return nil
    }

    fileprivate static func resolveTrackCollections(from dict: [String: Any]) -> (
        video: [TTMediaVideoTrackInfo], audio: [TTMediaAudioTrackInfo], subtitle: [TTMediaSubtitleTrackInfo],
        catalogVideo: [TTMediaVideoTrackInfo], catalogAudio: [TTMediaAudioTrackInfo], catalogSubtitle: [TTMediaSubtitleTrackInfo]
    ) {
        let generic = firstDictArray(in: dict, keys: ["tracks"])
        let selectedPool = [firstDictArray(in: dict, keys: ["selected_tracks"]), generic]
        let catalogPool = [firstDictArray(in: dict, keys: ["tracks_catalog", "tracksCatalog"]), generic]

        let video = extractTrackItems(from: dict, directKeys: ["videoTracks"], fallbackPools: selectedPool, mediaType: "video", parser: parseSingleVideoTrack) ?? []
        let audio = extractTrackItems(from: dict, directKeys: ["audioTracks"], fallbackPools: selectedPool, mediaType: "audio", parser: parseSingleAudioTrack) ?? []
        let catVideo = extractTrackItems(from: dict, directKeys: ["catalogVideoTracks"], fallbackPools: catalogPool, mediaType: "video", parser: parseSingleVideoTrack) ?? video
        let catAudio = extractTrackItems(from: dict, directKeys: ["catalogAudioTracks"], fallbackPools: catalogPool, mediaType: "audio", parser: parseSingleAudioTrack) ?? audio
        let catSub = extractTrackItems(from: dict, directKeys: ["catalogSubtitleTracks", "subtitleTracks"], fallbackPools: catalogPool + selectedPool, mediaType: "subtitle", parser: parseSingleSubtitleTrack) ?? []
        let sub = extractTrackItems(from: dict, directKeys: ["subtitleTracks"], fallbackPools: selectedPool, mediaType: "subtitle", parser: parseSingleSubtitleTrack) ?? catSub
        return (video, audio, sub, catVideo, catAudio, catSub)
    }

    fileprivate static func resolveSelectedTrackNumbers(
        dictionary: [String: Any],
        videoTracks: [TTMediaVideoTrackInfo],
        audioTracks: [TTMediaAudioTrackInfo]
    ) -> (video: Int?, audio: Int?, primaryAudio: Int?) {
        let explicitV = firstInt(in: dictionary, keys: ["selectedVideoTrackNumber", "selected_video_track_number"])
        let explicitA = firstInt(in: dictionary, keys: ["selectedAudioTrackNumber", "selected_audio_track_number"])
        let explicitPrimA = firstInt(in: dictionary, keys: ["primaryAudioTrackNumber", "primary_audio_track_number"])
        let hasExplicitAudio = (dictionary["hasExplicitSelectedAudioTrack"] as? Bool == true)
            || dictionary.keys.contains("selectedAudioTrackNumber")
            || dictionary.keys.contains("selected_audio_track_number")
        let resolvedV = explicitV ?? firstValidTrackIndex(in: videoTracks.filter(\.isSelectedForPackets))
        let resolvedA = hasExplicitAudio ? explicitA : firstValidTrackIndex(in: audioTracks.filter(\.isSelectedForPackets))
        return (resolvedV, resolvedA, explicitPrimA ?? firstValidTrackIndex(in: audioTracks))
    }

    fileprivate static func isTrackType(_ item: [String: Any], _ expected: String) -> Bool {
        firstString(in: item, keys: ["media_type", "track_type", "mediaType"])?.lowercased() == expected
    }

    fileprivate static func parseContainerFormat(_ dict: [String: Any]) -> String {
        firstString(in: [dict, dict["containerMetadata"] as? [String: Any]], keys: ["format", "container_format", "formatName"]) ?? "unknown"
    }

    fileprivate static func parseDurationSeconds(_ dict: [String: Any]) -> Double {
        let scopes = [dict, dict["containerMetadata"] as? [String: Any]]
        if let sec = firstDouble(in: scopes, keys: ["durationSeconds", "duration_seconds", "duration"]) { return sec }
        if let nanos = firstInt64(in: scopes, keys: ["duration_nanos", "durationNanos"]), nanos > 0 {
            return Double(nanos) / 1_000_000_000.0
        }
        return 0.0
    }

    fileprivate static func parseContainerMetadata(
        _ dict: [String: Any], formatName: String, durationSeconds: Double
    ) -> TTMediaContainerMetadata {
        let scopes = [dict, dict["containerMetadata"] as? [String: Any]]
        let bitRate = firstInt64(in: scopes, keys: ["bitRateBps", "bit_rate_bps", "bit_rate", "bitrate"])
        return TTMediaContainerMetadata(
            formatName: formatName,
            durationSeconds: durationSeconds,
            bitRateBps: (bitRate ?? 0) > 0 ? bitRate : nil,
            fileSizeBytes: firstUInt64(in: scopes, keys: ["fileSizeBytes", "file_size_bytes"]),
            title: firstString(in: scopes, keys: ["title", "container_title"]),
            muxingApp: firstString(in: scopes, keys: ["muxingApp", "muxing_app"]),
            writingApp: firstString(in: scopes, keys: ["writingApp", "writing_app"])
        )
    }

    fileprivate static func parseStringMetadata(_ dict: [String: Any]) -> [String: String] {
        var result = (dict["metadata"] as? [String: String]) ?? [:]
        if let cap = dict["metadataCapability"] as? String { result["metadataCapability"] = cap }
        if let ver = firstInt(in: dict, keys: ["schema_version", "schemaVersion", "metadataSchemaVersion"]) {
            result["schemaVersion"] = String(ver)
        }
        if let contractVer = firstString(in: dict, keys: ["metadataContractVersion", "contract_version"]) {
            result["metadataContractVersion"] = contractVer
        }
        return result
    }

    fileprivate static func firstString(in dicts: [[String: Any]?], keys: [String]) -> String? {
        for dict in dicts {
            guard let dict else { continue }
            for key in keys {
                if let str = dict[key] as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return str }
            }
        }
        return nil
    }
    fileprivate static func firstString(in dict: [String: Any]?, keys: [String]) -> String? { firstString(in: [dict], keys: keys) }

    fileprivate static func firstInt(in dicts: [[String: Any]?], keys: [String]) -> Int? {
        dicts.lazy.compactMap { $0 }.flatMap { d in keys.lazy.compactMap { parseInt(d[$0]) } }.first
    }
    fileprivate static func firstInt(in dict: [String: Any]?, keys: [String]) -> Int? { firstInt(in: [dict], keys: keys) }

    fileprivate static func firstInt64(in dicts: [[String: Any]?], keys: [String]) -> Int64? {
        dicts.lazy.compactMap { $0 }.flatMap { d in keys.lazy.compactMap { parseInt64(d[$0]) } }.first
    }
    fileprivate static func firstInt64(in dict: [String: Any]?, keys: [String]) -> Int64? { firstInt64(in: [dict], keys: keys) }

    fileprivate static func firstUInt64(in dicts: [[String: Any]?], keys: [String]) -> UInt64? {
        dicts.lazy.compactMap { $0 }.flatMap { d in keys.lazy.compactMap { parseUInt64(d[$0]) } }.first
    }
    fileprivate static func firstUInt64(in dict: [String: Any]?, keys: [String]) -> UInt64? { firstUInt64(in: [dict], keys: keys) }

    fileprivate static func firstDouble(in dicts: [[String: Any]?], keys: [String]) -> Double? {
        dicts.lazy.compactMap { $0 }.flatMap { d in keys.lazy.compactMap { parseDouble(d[$0]) } }.first
    }
    fileprivate static func firstDouble(in dict: [String: Any]?, keys: [String]) -> Double? { firstDouble(in: [dict], keys: keys) }

    fileprivate static func firstBool(in dicts: [[String: Any]?], keys: [String]) -> Bool? {
        for dict in dicts {
            guard let dict else { continue }
            for key in keys {
                if let b = dict[key] as? Bool { return b }
                if let num = dict[key] as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() { return num.boolValue }
            }
        }
        return nil
    }
    fileprivate static func firstBool(in dict: [String: Any]?, keys: [String]) -> Bool? { firstBool(in: [dict], keys: keys) }

    fileprivate static func parseInt(_ raw: Any?) -> Int? { parseInt64(raw).flatMap { Int(exactly: $0) } }

    fileprivate static func parseInt64(_ raw: Any?) -> Int64? {
        if let val = raw as? Int64 { return val }
        if let val = raw as? Int { return Int64(val) }
        if let val = raw as? UInt32 { return Int64(val) }
        if let val = raw as? UInt64 { return Int64(exactly: val) }
        if let num = raw as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() { return num.int64Value }
        return nil
    }

    fileprivate static func parseUInt64(_ raw: Any?) -> UInt64? {
        if let val = raw as? UInt64 { return val }
        if let val = parseInt64(raw), val >= 0 { return UInt64(val) }
        return nil
    }

    fileprivate static func parseDouble(_ raw: Any?) -> Double? {
        if let val = raw as? Double, val.isFinite { return val }
        if let val = raw as? Float, val.isFinite { return Double(val) }
        if let num = raw as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite {
            return num.doubleValue
        }
        return nil
    }

    fileprivate static func decodeHex(_ hex: String) -> Data? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let b = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        return Data(bytes)
    }

    fileprivate static func parseExtradata(_ item: [String: Any]) -> Data? {
        if let d = item["extradata"] as? Data { return d }
        if let arr = item["extradata"] as? [UInt8] { return Data(arr) }
        if let nsArr = item["extradata"] as? [NSNumber] { return Data(nsArr.map(\.uint8Value)) }
        if let hex = firstString(in: item, keys: ["codec_private_hex", "codecPrivateHex"]) { return decodeHex(hex) }
        if let b64 = item["extradata"] as? String { return Data(base64Encoded: b64) }
        return nil
    }

    private struct CommonTrackHeader {
        let trackIndex: Int, catalogIndex: Int, containerTrackNumber: Int64, playbackTrackId: Int64, packetStreamIndex: Int
        let trackUid: UInt64?, rawCodec: String?, canonicalCodec: String?, bitrate: Int64?, extradata: Data?
        let selectable: Bool, selected: Bool, selectionStatus: String, selectionReason: String
        let defaultDurationNanos: UInt64?, language: String?, title: String?
        let isEnabled: Bool, isDefault: Bool, isForced: Bool, codecPrivateFormat: String?, codecPrivateSha256: String?
    }

    private static func resolveTrackSelection(in item: [String: Any], selectable: Bool) -> (selected: Bool, status: String, reason: String) {
        let status = firstString(in: item, keys: ["selectionStatus", "selection_status"])
        let explicitSel = firstBool(in: item, keys: ["isSelectedForPackets", "is_selected_for_packets", "selected_for_playback"])
        let selected: Bool
        if let explicitSel {
            selected = explicitSel
        } else if let status {
            selected = (status == "selected")
        } else {
            selected = selectable
        }
        let finalStatus = status ?? (selected ? "selected" : "not_selected")
        let finalReason = firstString(in: item, keys: ["selectionReason", "selection_reason"]) ?? (selected ? "selected_default" : "catalog_only")
        return (selected, finalStatus, finalReason)
    }

    private static func parseCommonTrackHeader(_ item: [String: Any]) -> CommonTrackHeader {
        let selectable = firstBool(in: item, keys: ["demuxSelectable", "demux_selectable"]) ?? true
        let sel = resolveTrackSelection(in: item, selectable: selectable)
        let resolvedIndex = firstInt(in: item, keys: ["trackIndex", "playback_track_id", "packet_stream_index", "container_track_number", "index", "catalog_index"]) ?? -1
        let containerNum = firstInt64(in: item, keys: ["containerTrackNumber", "container_track_number"]) ?? Int64(resolvedIndex)
        return CommonTrackHeader(
            trackIndex: resolvedIndex,
            catalogIndex: firstInt(in: item, keys: ["catalogIndex", "catalog_index", "index"]) ?? max(0, resolvedIndex),
            containerTrackNumber: containerNum,
            playbackTrackId: firstInt64(in: item, keys: ["playbackTrackId", "playback_track_id"]) ?? containerNum,
            packetStreamIndex: firstInt(in: item, keys: ["packetStreamIndex", "packet_stream_index", "index"]) ?? resolvedIndex,
            trackUid: firstUInt64(in: item, keys: ["trackUid", "track_uid"]),
            rawCodec: firstString(in: item, keys: ["rawCodecId", "raw_codec_id", "codec_id_raw", "codec_id", "codecName", "codec"]),
            canonicalCodec: firstString(in: item, keys: ["canonicalCodec", "canonical_codec", "codec_canonical", "codecName", "codec_name", "codec"]),
            bitrate: firstInt64(in: item, keys: ["bitrate", "bit_rate_bps", "bit_rate"]),
            extradata: parseExtradata(item), selectable: selectable, selected: sel.selected,
            selectionStatus: sel.status, selectionReason: sel.reason,
            defaultDurationNanos: firstUInt64(in: item, keys: ["defaultDurationNanos", "default_duration_nanos"]),
            language: firstString(in: item, keys: ["language", "lang"]),
            title: firstString(in: item, keys: ["title", "name"]),
            isEnabled: firstBool(in: item, keys: ["isEnabled", "flag_enabled"]) ?? true,
            isDefault: firstBool(in: item, keys: ["isDefault", "flag_default"]) ?? false,
            isForced: firstBool(in: item, keys: ["isForced", "flag_forced"]) ?? false,
            codecPrivateFormat: firstString(in: item, keys: ["codecPrivateFormat", "codec_private_format"]),
            codecPrivateSha256: firstString(in: item, keys: ["codecPrivateSha256", "codec_private_sha256"])
        )
    }

    private static func parseColorMetadata(scopes: [[String: Any]?]) -> TTMediaColorMetadata {
        TTMediaColorMetadata(
            colorPrimaries: firstString(in: scopes, keys: ["colorPrimaries", "color_primaries"]),
            transferCharacteristics: firstString(in: scopes, keys: ["transferCharacteristics", "transfer_characteristics", "transfer_function"]),
            matrixCoefficients: firstString(in: scopes, keys: ["matrixCoefficients", "matrix_coefficients", "ycbcr_matrix"]),
            colorRange: firstString(in: scopes, keys: ["colorRange", "color_range"]),
            chromaSubsampling: firstString(in: scopes, keys: ["chromaSubsampling", "chroma_subsampling"])
        )
    }

    private static func resolveFrameRate(scopes: [[String: Any]?], durationNanos: UInt64?) -> Double? {
        if let fps = firstDouble(in: scopes, keys: ["frameRateFps", "frame_rate_fps", "fps"]), fps > 0 { return fps }
        if let nanos = durationNanos, nanos > 0 { return 1_000_000_000.0 / Double(nanos) }
        return nil
    }

    fileprivate static func parseSingleVideoTrack(_ item: [String: Any]) -> TTMediaVideoTrackInfo {
        let hdr = parseCommonTrackHeader(item)
        let resolvedCodec = mapVideoCodec(canonical: hdr.canonicalCodec, raw: hdr.rawCodec)
        let descriptor = mapVideoDescriptor(canonical: hdr.canonicalCodec, raw: hdr.rawCodec, explicit: firstString(in: item, keys: ["codecDescriptor", "codec_descriptor"]))
        let displayCodec = [hdr.canonicalCodec, hdr.rawCodec, resolvedCodec?.rawValue].compactMap { $0 }.first ?? "unknown"
        let nested = (item["video"] as? [String: Any]) ?? (item["video_params"] as? [String: Any])
        let scopes: [[String: Any]?] = [item, nested]
        let width = firstInt(in: scopes, keys: ["width", "effective_width", "pixel_width"]) ?? 0
        let height = firstInt(in: scopes, keys: ["height", "effective_height", "pixel_height"]) ?? 0
        let pixelWidth = firstInt(in: scopes, keys: ["pixelWidth", "pixel_width", "width"]) ?? width
        let pixelHeight = firstInt(in: scopes, keys: ["pixelHeight", "pixel_height", "height"]) ?? height
        let durationNanos = firstUInt64(in: scopes, keys: ["defaultDurationNanos", "default_duration_nanos"])
        let colorMeta = parseColorMetadata(scopes: scopes)
        let dvProfile = firstInt(in: scopes, keys: ["dolbyVisionProfile", "dolby_vision_profile"])
        let rawDR = firstString(in: scopes, keys: ["rawDynamicRange", "hdr_format", "hdrFormat", "dynamicRange", "dynamic_range"])
        let resolvedDR = resolveDynamicRange(
            rawDynamicRange: rawDR, transferCharacteristics: colorMeta.transferCharacteristics,
            dolbyVisionProfile: dvProfile, codecPrivateFormat: hdr.codecPrivateFormat, rawCodecId: hdr.rawCodec
        )
        return TTMediaVideoTrackInfo(
            trackIndex: hdr.trackIndex, codec: resolvedCodec, codecName: displayCodec,
            width: max(0, width), height: max(0, height),
            bitrate: firstInt64(in: scopes, keys: ["bitrate", "bit_rate_bps", "bit_rate"]),
            extradata: hdr.extradata, rawCodecId: hdr.rawCodec ?? displayCodec,
            demuxSelectable: hdr.selectable, isSelectedForPackets: hdr.selected,
            codecPrivateFormat: hdr.codecPrivateFormat, codecPrivateSha256: hdr.codecPrivateSha256,
            catalogIndex: hdr.catalogIndex, containerTrackNumber: hdr.containerTrackNumber,
            playbackTrackId: hdr.playbackTrackId, packetStreamIndex: hdr.packetStreamIndex,
            trackUid: hdr.trackUid, codecDescriptor: descriptor,
            selectionStatus: hdr.selectionStatus, selectionReason: hdr.selectionReason,
            pixelWidth: max(0, pixelWidth), pixelHeight: max(0, pixelHeight),
            displayWidth: firstInt(in: scopes, keys: ["displayWidth", "display_width"]),
            displayHeight: firstInt(in: scopes, keys: ["displayHeight", "display_height"]),
            dimensionsSource: firstString(in: scopes, keys: ["dimensionsSource", "dimensions_source"]),
            frameRateFps: resolveFrameRate(scopes: scopes, durationNanos: durationNanos),
            defaultDurationNanos: durationNanos,
            bitDepth: firstInt(in: scopes, keys: ["bitDepth", "bit_depth", "bits_per_component"]),
            dynamicRange: resolvedDR, rawDynamicRange: rawDR,
            dolbyVisionProfile: dvProfile,
            dolbyVisionLevel: firstInt(in: scopes, keys: ["dolbyVisionLevel", "dolby_vision_level"]),
            colorMetadata: colorMeta,
            language: hdr.language, title: hdr.title,
            isEnabled: hdr.isEnabled, isDefault: hdr.isDefault, isForced: hdr.isForced,
            frameRateSource: firstString(in: scopes, keys: ["frameRateSource", "frame_rate_source"]),
            bitDepthSource: firstString(in: scopes, keys: ["bitDepthSource", "bit_depth_source"]),
            hdrSource: firstString(in: scopes, keys: ["hdrSource", "hdr_source"]),
            colourSource: firstString(in: scopes, keys: ["colourSource", "colour_source", "colorSource", "color_source"]),
            activeHDROutputVerifiedByDemuxer: firstBool(in: scopes, keys: ["activeHDROutputVerifiedByDemuxer", "active_hdr_output_verified_by_demuxer"]) ?? false
        )
    }

    fileprivate static func parseSingleAudioTrack(_ item: [String: Any]) -> TTMediaAudioTrackInfo {
        let hdr = parseCommonTrackHeader(item)
        let resolvedCodec = mapAudioCodec(canonical: hdr.canonicalCodec, raw: hdr.rawCodec)
        let descriptor = mapAudioDescriptor(canonical: hdr.canonicalCodec, raw: hdr.rawCodec, explicit: firstString(in: item, keys: ["codecDescriptor", "codec_descriptor"]))
        let displayCodec = [hdr.canonicalCodec, hdr.rawCodec, resolvedCodec?.rawValue].compactMap { $0 }.first ?? "unknown"
        let nested = (item["audio"] as? [String: Any]) ?? (item["audio_params"] as? [String: Any])
        let scopes: [[String: Any]?] = [item, nested]
        let sampleRate = firstDouble(in: scopes, keys: ["sampleRate", "sample_rate_hz", "sample_rate"]) ?? 0.0
        let channels = firstInt(in: scopes, keys: ["channels", "channel_count"]) ?? 0
        let profile = firstString(in: scopes, keys: ["audioProfile", "audio_profile", "profile"])
        let explicitAtmos = firstBool(in: scopes, keys: ["isAtmosVerified", "isAtmos", "is_atmos", "dolby_atmos"])
        let atmosSrc = firstString(in: scopes, keys: ["atmosSource", "atmos_source"])
        let verifiedAtmos = resolveAtmosVerified(explicitFlag: explicitAtmos, audioProfile: profile, rawCodecId: hdr.rawCodec, atmosSource: atmosSrc)
        let rawLayout = firstString(in: scopes, keys: ["channelLayout", "channel_layout"])
        let cleanLayout = (rawLayout?.lowercased() == "unknown") ? nil : rawLayout
        return TTMediaAudioTrackInfo(
            trackIndex: hdr.trackIndex, codec: resolvedCodec, codecName: displayCodec,
            sampleRate: max(0.0, sampleRate), channels: max(0, channels),
            bitrate: firstInt64(in: scopes, keys: ["bitrate", "bit_rate_bps", "bit_rate"]),
            extradata: hdr.extradata, rawCodecId: hdr.rawCodec ?? displayCodec,
            demuxSelectable: hdr.selectable, isSelectedForPackets: hdr.selected,
            sampleRateSource: firstString(in: scopes, keys: ["sampleRateSource", "sample_rate_source"]),
            channelsSource: firstString(in: scopes, keys: ["channelsSource", "channels_source"]),
            bitDepth: firstInt(in: scopes, keys: ["bitDepth", "bit_depth", "bits_per_channel"]),
            codecPrivateFormat: hdr.codecPrivateFormat, codecPrivateSha256: hdr.codecPrivateSha256,
            catalogIndex: hdr.catalogIndex, containerTrackNumber: hdr.containerTrackNumber,
            playbackTrackId: hdr.playbackTrackId, packetStreamIndex: hdr.packetStreamIndex,
            trackUid: hdr.trackUid, codecDescriptor: descriptor,
            selectionStatus: hdr.selectionStatus, selectionReason: hdr.selectionReason,
            outputSampleRateHz: firstDouble(in: scopes, keys: ["outputSampleRateHz", "output_sample_rate_hz"]),
            bitDepthSource: firstString(in: scopes, keys: ["bitDepthSource", "bit_depth_source"]),
            channelLayout: cleanLayout,
            channelLayoutSource: firstString(in: scopes, keys: ["channelLayoutSource", "channel_layout_source"]),
            audioProfile: profile,
            isAtmos: verifiedAtmos ?? false,
            defaultDurationNanos: hdr.defaultDurationNanos, language: hdr.language, title: hdr.title,
            isEnabled: hdr.isEnabled, isDefault: hdr.isDefault, isForced: hdr.isForced,
            audioProfileSource: firstString(in: scopes, keys: ["audioProfileSource", "audio_profile_source", "profile_source"]),
            isAtmosVerified: verifiedAtmos,
            atmosSource: atmosSrc
        )
    }

    fileprivate static func parseSingleSubtitleTrack(_ item: [String: Any]) -> TTMediaSubtitleTrackInfo {
        let hdr = parseCommonTrackHeader(item)
        let resolvedCodec = mapSubtitleCodec(canonical: hdr.canonicalCodec, raw: hdr.rawCodec, explicit: firstString(in: item, keys: ["codec"]))
        let displayCodec = [hdr.canonicalCodec, hdr.rawCodec].compactMap { $0 }.first ?? resolvedCodec.rawValue
        return TTMediaSubtitleTrackInfo(
            trackIndex: hdr.trackIndex, codec: resolvedCodec, codecName: displayCodec,
            rawCodecId: hdr.rawCodec ?? displayCodec, catalogIndex: hdr.catalogIndex,
            containerTrackNumber: hdr.containerTrackNumber, playbackTrackId: hdr.playbackTrackId,
            packetStreamIndex: firstInt(in: item, keys: ["packetStreamIndex", "packet_stream_index"]) ?? -1,
            trackUid: hdr.trackUid, language: hdr.language, title: hdr.title,
            isEnabled: hdr.isEnabled, isDefault: hdr.isDefault, isForced: hdr.isForced,
            demuxSelectable: firstBool(in: item, keys: ["demuxSelectable", "demux_selectable"]) ?? false,
            isSelectedForPackets: firstBool(in: item, keys: ["isSelectedForPackets", "is_selected_for_packets"]) ?? false,
            selectionStatus: hdr.selectionStatus, selectionReason: hdr.selectionReason,
            codecPrivateFormat: hdr.codecPrivateFormat, codecPrivateSha256: hdr.codecPrivateSha256,
            extradata: hdr.extradata
        )
    }
}

// MARK: - MediaWorkerDirectTransport

/// In-process direct C-ABI bridge transport for hermetic native playback without external daemons.
public final class MediaWorkerDirectTransport: MediaWorkerTransport, MediaSubtitleTransport, @unchecked Sendable {
    private static let maxMetadataJSONBytes = 4 * 1024 * 1024

    private let lock = NSLock()
    private var subtitlePath: String?
    private var activeSessionId: String? = nil
    private var demuxerHandle: UnsafeMutableRawPointer? = nil
    internal private(set) var openCloseBalanceCount: Int = 0
    internal var contractJSONProviderOverride: (@Sendable (String) throws -> Data)?
    internal var forceLegacyCAbiFallback: Bool = false

    internal var hasActiveDemuxerHandle: Bool { lock.withLock { demuxerHandle != nil } }
    internal var currentActiveSessionId: String? { lock.withLock { activeSessionId } }

    public init() {}

    @discardableResult
    private func closeActiveHandleLocked() -> String? {
        if let handle = demuxerHandle {
            ttmedia_demux_close(handle)
            openCloseBalanceCount -= 1
            demuxerHandle = nil
        }
        let previous = activeSessionId
        activeSessionId = nil
        subtitlePath = nil
        return previous
    }

    private func requireSessionHandleLocked(_ sessionId: String) throws -> UnsafeMutableRawPointer {
        guard let handle = demuxerHandle else {
            throw MediaWorkerError.serviceUnavailable("Demuxer not open")
        }
        guard activeSessionId == sessionId else {
            throw MediaWorkerError.sessionNotFound(sessionId)
        }
        return handle
    }

    deinit {
        lock.withLock { _ = closeActiveHandleLocked() }
    }

    public func openMedia(path: String, targetTracks: [Int]?) async throws -> (sessionId: String, metadata: [String: Any]) {
        try lock.withLock {
            if let overrideProvider = self.contractJSONProviderOverride {
                let jsonData = try overrideProvider(path)
                let meta = try Self.buildStreamMetadata(fromV1ContractJSON: jsonData, cInfo: nil)
                let sessionId = UUID().uuidString
                self.activeSessionId = sessionId
                self.subtitlePath = path
                return (sessionId: sessionId, metadata: meta)
            }

            _ = closeActiveHandleLocked()
            var handle: UnsafeMutableRawPointer? = nil
            var info = TTMediaDemux.TTMediaStreamInfo()
            let status = path.withCString { ttmedia_demux_open($0, &handle, &info) }
            guard status == 0, let validHandle = handle else {
                throw MediaWorkerError.openFailed("ttmedia_demux_open returned \(status)")
            }
            let sessionId = UUID().uuidString
            self.activeSessionId = sessionId
            self.demuxerHandle = validHandle
            self.openCloseBalanceCount += 1
            self.subtitlePath = path

            if !self.forceLegacyCAbiFallback,
               let jsonData = try Self.queryNativeTracksJSON(handle: validHandle) {
                let meta = try Self.buildStreamMetadata(fromV1ContractJSON: jsonData, cInfo: info, filePath: path)
                return (sessionId: sessionId, metadata: meta)
            }
            return (sessionId: sessionId, metadata: Self.buildLegacyStreamMetadata(from: info))
        }
    }

    private static func queryNativeTracksJSON(handle: UnsafeMutableRawPointer) throws -> Data? {
        var requiredLen: Int = 0
        let probeStatus = ttmedia_demux_query_tracks_json(UnsafeRawPointer(handle), nil, 0, &requiredLen)
        guard probeStatus == 0 else {
            throw MediaWorkerError.openFailed("ttmedia_demux_query_tracks_json length probe returned \(probeStatus)")
        }
        guard requiredLen > 0, requiredLen <= maxMetadataJSONBytes else {
            throw MediaWorkerError.openFailed("ttmedia_demux_query_tracks_json invalid length \(requiredLen)")
        }
        var buffer = [CChar](repeating: 0, count: requiredLen + 1)
        var writtenLen: Int = 0
        let copyStatus = buffer.withUnsafeMutableBufferPointer { ptr in
            ttmedia_demux_query_tracks_json(UnsafeRawPointer(handle), ptr.baseAddress, ptr.count, &writtenLen)
        }
        guard copyStatus == 0, writtenLen == requiredLen else {
            throw MediaWorkerError.openFailed("ttmedia_demux_query_tracks_json copy returned \(copyStatus)")
        }
        return Data(bytes: buffer, count: writtenLen)
    }

    internal static func buildStreamMetadata(
        fromV1ContractJSON jsonData: Data,
        cInfo: TTMediaDemux.TTMediaStreamInfo?,
        filePath: String? = nil
    ) throws -> [String: Any] {
        guard let rawRoot = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MediaWorkerError.invalidResponse("V1 track metadata contract is not a JSON object")
        }
        guard let schemaVer = TTMediaStreamInfo.parseInt(rawRoot["schema_version"]), schemaVer >= 1 else {
            throw MediaWorkerError.invalidResponse("Unsupported or missing V1 track metadata schema_version")
        }
        var root = rawRoot
        if let cInfo, cInfo.bit_rate > 0, root["bit_rate"] == nil, root["bitRateBps"] == nil {
            root["bit_rate"] = cInfo.bit_rate
        }
        if let filePath, root["file_size_bytes"] == nil, root["fileSizeBytes"] == nil,
           let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
           let size = attrs[.size] as? NSNumber, size.uint64Value > 0 {
            root["file_size_bytes"] = size.uint64Value
        }
        let parsed = TTMediaStreamInfo(sessionId: "v1-parse", dictionary: root)
        let vFallback = cInfo.flatMap { copyExtradata(ptr: $0.video_desc.extradata, len: $0.video_desc.extradata_len) }
        let aFallback = cInfo.flatMap { copyExtradata(ptr: $0.audio_desc.extradata, len: $0.audio_desc.extradata_len) }
        return parsed.toTransportDictionary(
            videoExtradataFallback: vFallback,
            audioExtradataFallback: aFallback,
            capabilityOverride: TTMediaMetadataContract.structuredCapabilityToken,
            hasExplicitSelectedAudioTrack: true
        )
    }

    public static func parseStreamMetadata(sessionId: String, dictionary: [String: Any]) -> TTMediaStreamInfo {
        TTMediaStreamInfo(sessionId: sessionId, dictionary: dictionary)
    }

    public static func normalizeTransportMetadataDictionary(
        _ rawDict: [String: Any],
        cInfo: TTMediaDemux.TTMediaStreamInfo? = nil
    ) -> [String: Any] {
        let sanitizedInput = TTMediaTransportMetadataSanitizer.sanitizeDictionary(rawDict)
        let isRawV1Contract = sanitizedInput["tracks_catalog"] != nil || sanitizedInput["selected_tracks"] != nil
        let hasExplicitAudio = isRawV1Contract
            || (sanitizedInput["hasExplicitSelectedAudioTrack"] as? Bool == true)
            || sanitizedInput.keys.contains("selectedAudioTrackNumber")
            || sanitizedInput.keys.contains("selected_audio_track_number")
        let parsed = TTMediaStreamInfo(sessionId: "normalize", dictionary: sanitizedInput)
        let vFallback = cInfo.flatMap { copyExtradata(ptr: $0.video_desc.extradata, len: $0.video_desc.extradata_len) }
        let aFallback = cInfo.flatMap { copyExtradata(ptr: $0.audio_desc.extradata, len: $0.audio_desc.extradata_len) }
        let capability = (sanitizedInput["metadataCapability"] as? String)
            ?? (isRawV1Contract ? TTMediaMetadataContract.structuredCapabilityToken : parsed.metadataCapability)
        var normalized = parsed.toTransportDictionary(
            videoExtradataFallback: vFallback,
            audioExtradataFallback: aFallback,
            capabilityOverride: capability,
            hasExplicitSelectedAudioTrack: hasExplicitAudio
        )
        if !hasExplicitAudio && !sanitizedInput.keys.contains("selectedAudioTrackNumber") {
            normalized.removeValue(forKey: "selectedAudioTrackNumber")
        }
        return normalized
    }

    private static func copyExtradata(ptr: UnsafePointer<UInt8>?, len: Int) -> Data? {
        guard let ptr, len > 0 else { return nil }
        return Data(bytes: ptr, count: len)
    }

    internal static func buildLegacyStreamMetadata(from info: TTMediaDemux.TTMediaStreamInfo) -> [String: Any] {
        var videoTracks: [[String: Any]] = []
        if info.has_video {
            let vName = videoCodecName(for: Int32(info.video_desc.codec.rawValue))
            let track = TTMediaVideoTrackInfo(
                trackIndex: -1, codec: TTMediaStreamInfo.mapVideoCodec(canonical: vName, raw: vName),
                codecName: vName ?? "unknown", width: max(0, Int(info.video_desc.width)),
                height: max(0, Int(info.video_desc.height)),
                extradata: copyExtradata(ptr: info.video_desc.extradata, len: info.video_desc.extradata_len),
                rawCodecId: vName ?? "unknown", demuxSelectable: vName != nil, isSelectedForPackets: vName != nil
            )
            videoTracks.append(track.toTransportDictionary())
        }

        var audioTracks: [[String: Any]] = []
        if info.has_audio {
            let aName = audioCodecName(for: Int32(info.audio_desc.codec.rawValue))
            let track = TTMediaAudioTrackInfo(
                trackIndex: -1, codec: TTMediaStreamInfo.mapAudioCodec(canonical: aName, raw: aName),
                codecName: aName ?? "unknown", sampleRate: max(0.0, info.audio_desc.sample_rate),
                channels: max(0, Int(info.audio_desc.channel_count)),
                extradata: copyExtradata(ptr: info.audio_desc.extradata, len: info.audio_desc.extradata_len),
                rawCodecId: aName ?? "unknown", demuxSelectable: aName != nil, isSelectedForPackets: aName != nil,
                bitDepth: info.audio_desc.bits_per_channel > 0 ? Int(info.audio_desc.bits_per_channel) : nil
            )
            audioTracks.append(track.toTransportDictionary())
        }

        return [
            "format": containerFormatName(for: Int32(info.container_format.rawValue)),
            "durationSeconds": info.duration_seconds,
            "videoTracks": videoTracks,
            "audioTracks": audioTracks,
            "subtitleTracks": [[String: Any]](),
            "catalogVideoTracks": videoTracks,
            "catalogAudioTracks": audioTracks,
            "catalogSubtitleTracks": [[String: Any]](),
            "metadataContractVersion": TTMediaMetadataContract.versionString,
            "metadataCapability": TTMediaMetadataContract.legacyFallbackCapabilityToken,
            "metadata": ["metadataCapability": TTMediaMetadataContract.legacyFallbackCapabilityToken]
        ]
    }

    private static let containerFormatNames: [Int32: String] = [
        1: "mov", 2: "matroska", 3: "webm", 4: "avi", 5: "flv",
        6: "mpegts", 7: "mp3", 8: "aac", 9: "flac", 10: "ogg", 11: "wav"
    ]
    private static let videoCodecNames: [Int32: String] = [
        1: "h264", 2: "hevc", 3: "av1", 4: "vp9", 5: "vp8", 6: "prores"
    ]
    private static let audioCodecNames: [Int32: String] = [
        1: "aac", 2: "alac", 3: "opus", 4: "flac", 5: "vorbis",
        6: "mp3", 7: "pcm", 8: "pcm", 9: "pcm", 10: "ac3", 11: "eac3"
    ]

    internal static func containerFormatName(for raw: Int32) -> String { containerFormatNames[raw] ?? "unknown" }
    internal static func videoCodecName(for codec: Int32) -> String? { videoCodecNames[codec] }
    internal static func audioCodecName(for codec: Int32) -> String? { audioCodecNames[codec] }

    public func readNextPacket(sessionId: String) async throws -> Data? {
        try lock.withLock {
            let handle = try requireSessionHandleLocked(sessionId)
            var cPacket = TTMediaDemux.TTMediaPacket()
            let status = ttmedia_demux_read_packet(handle, &cPacket)
            if status == 1 { return nil }
            guard status == 0 else {
                throw MediaWorkerError.readPacketFailed("ttmedia_demux_read_packet returned \(status)")
            }
            defer { ttmedia_demux_release_packet(&cPacket) }

            let payloadData = Self.copyExtradata(ptr: cPacket.payload_data, len: Int(cPacket.payload_len)) ?? Data()
            let mediaType = MediaType(rawValue: cPacket.media_type) ?? .video
            let durationVal = max(0, cPacket.duration_value)
            let durationTs = cPacket.duration_timescale > 0 ? cPacket.duration_timescale : max(1, cPacket.pts_timescale)
            let dto = try MediaPacketDTO(
                streamIndex: cPacket.stream_index, mediaType: mediaType,
                ptsValue: cPacket.pts_value, ptsTimescale: cPacket.pts_timescale,
                dtsValue: cPacket.dts_value, dtsTimescale: cPacket.dts_timescale,
                durationValue: durationVal, durationTimescale: durationTs,
                payloadData: payloadData, isKeyframe: cPacket.is_keyframe,
                doNotDisplay: cPacket.do_not_display, ioSurfaceId: cPacket.iosurface_id
            )
            return try JSONEncoder().encode(dto)
        }
    }

    public func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        try lock.withLock {
            let handle = try requireSessionHandleLocked(sessionId)
            let status = ttmedia_demux_seek(handle, timestamp, accurate)
            guard status == 0 else {
                throw MediaWorkerError.seekFailed("ttmedia_demux_seek returned \(status)")
            }
            return timestamp
        }
    }

    public func closeMedia(sessionId: String) async throws {
        let didMatch = lock.withLock { () -> Bool in
            guard activeSessionId == sessionId else { return false }
            _ = closeActiveHandleLocked()
            return true
        }
        if didMatch {
            SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: sessionId)
        }
    }

    public func subtitleData(sessionId: String, track: Int64) async throws -> Data {
        let requestID = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sessionId)
        return try await subtitleData(sessionId: sessionId, track: track, requestID: requestID)
    }

    public func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data {
        defer { SubtitleSessionRequestRegistry.shared.finishRequest(sessionId: sessionId, requestID: requestID) }
        try SubtitleSessionRequestRegistry.shared.beginRequest(sessionId: sessionId, requestID: requestID)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let file = try lock.withLock {
                guard activeSessionId == sessionId else { throw MediaWorkerError.sessionNotFound(sessionId) }
                guard let subtitlePath, demuxerHandle != nil else { throw MediaWorkerError.connectionInvalidated }
                return try FileHandle(forReadingFrom: URL(fileURLWithPath: subtitlePath))
            }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { try? file.close() }
                    let path = "/dev/fd/\(file.fileDescriptor)"
                    let value = path.withCString { ttmedia_subtitles_container_request($0, track, requestID) }
                    guard let value else {
                        continuation.resume(throwing: MediaWorkerError.readPacketFailed("Subtitle allocation failed"))
                        return
                    }
                    defer { ttmedia_subtitles_free(value) }
                    continuation.resume(returning: Data(String(cString: value).utf8))
                }
            }
        } onCancel: {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
        }
    }

    public func cancelSubtitleRequest(sessionId: String, requestID: UInt64) async {
        SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
    }

    public func cancelAllSubtitleRequests(sessionId: String) async {
        SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: sessionId)
    }

    public func setSleepState(state: Int) async throws {}
    public func invalidate() {
        if let closingSession = lock.withLock({ closeActiveHandleLocked() }) {
            SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: closingSession)
        }
    }
    public func reconnect() async throws {}
    public func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {}

    public var isConnected: Bool { lock.withLock { demuxerHandle != nil } }
}
