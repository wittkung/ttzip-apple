// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Foundation
import XCTest
@testable import TTMediaKit

// MARK: - Group E (Feedback ⑤): Video/Audio/Subtitle Metadata DTO & Cross-Process Transport Contract Tests

final class VideoMetadataTransportContractTests: XCTestCase {

    // MARK: - Synthetic Multi-Track Matroska (EBML) Fixture Builder

    private static func ebmlVint(_ length: Int) -> [UInt8] {
        if length < 0x7F {
            return [UInt8(0x80 | length)]
        }
        return [
            UInt8(0x40 | ((length >> 8) & 0x3F)),
            UInt8(length & 0xFF)
        ]
    }

    private static func ebmlElement(id: [UInt8], payload: [UInt8]) -> [UInt8] {
        var out = id
        out.append(contentsOf: ebmlVint(payload.count))
        out.append(contentsOf: payload)
        return out
    }

    private static func ebmlUIntElement(id: [UInt8], value: UInt64, byteCount: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
        return ebmlElement(id: id, payload: bytes)
    }

    private static func ebmlFloat64Element(id: [UInt8], value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return ebmlUIntElement(id: id, value: bits, byteCount: 8)
    }

    /// Builds a valid multi-track Matroska file containing:
    /// - Track 1 (Video): H.264 (`V_MPEG4/ISO/AVC`), 1920x1080, Display 1920x800, 24fps (`41_666_666 ns`), lang `eng`, name `Director Cut Video`, `avcC` CodecPrivate
    /// - Track 2 (Audio): AAC (`A_AAC`), 48000Hz (output 96000Hz), 2ch, 16-bit, lang `jpn`, name `Original Stereo`, `AudioSpecificConfig` `[0x11, 0x90]`
    /// - Track 3 (Subtitle): UTF-8 SRT (`S_TEXT/UTF8`), lang `zho`, name `Simplified Chinese`, default + forced
    static func createMultiTrackMKVFixture(at url: URL) throws {
        let avcC: [UInt8] = [
            0x01, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0x00, 0x04,
            0x67, 0x64, 0x00, 0x28, 0x01, 0x00, 0x04, 0x68,
            0xEE, 0x3C, 0x80
        ]

        // Video sub-element (0xE0): PixelWidth=1920, PixelHeight=1080, DisplayWidth=1920, DisplayHeight=800
        var videoSub: [UInt8] = []
        videoSub.append(contentsOf: ebmlUIntElement(id: [0xB0], value: 1920, byteCount: 2))
        videoSub.append(contentsOf: ebmlUIntElement(id: [0xBA], value: 1080, byteCount: 2))
        videoSub.append(contentsOf: ebmlUIntElement(id: [0x54, 0xB0], value: 1920, byteCount: 2))
        videoSub.append(contentsOf: ebmlUIntElement(id: [0x54, 0xBA], value: 800, byteCount: 2))

        // Track 1: Video
        var t1: [UInt8] = []
        t1.append(contentsOf: ebmlUIntElement(id: [0xD7], value: 1, byteCount: 1)) // TrackNumber = 1
        t1.append(contentsOf: ebmlUIntElement(id: [0x73, 0xC5], value: 1001, byteCount: 2)) // TrackUID = 1001
        t1.append(contentsOf: ebmlUIntElement(id: [0x83], value: 1, byteCount: 1)) // TrackType = 1 (video)
        t1.append(contentsOf: ebmlUIntElement(id: [0xB9], value: 1, byteCount: 1)) // FlagEnabled = 1
        t1.append(contentsOf: ebmlUIntElement(id: [0x88], value: 1, byteCount: 1)) // FlagDefault = 1
        t1.append(contentsOf: ebmlUIntElement(id: [0x55, 0xAA], value: 0, byteCount: 1)) // FlagForced = 0
        t1.append(contentsOf: ebmlUIntElement(id: [0x23, 0xE3, 0x83], value: 41_666_666, byteCount: 4)) // DefaultDuration (~24fps)
        t1.append(contentsOf: ebmlElement(id: [0x53, 0x6E], payload: Array("Director Cut Video".utf8))) // Name
        t1.append(contentsOf: ebmlElement(id: [0x22, 0xB5, 0x9C], payload: Array("eng".utf8))) // Language
        t1.append(contentsOf: ebmlElement(id: [0x86], payload: Array("V_MPEG4/ISO/AVC".utf8))) // CodecID
        t1.append(contentsOf: ebmlElement(id: [0x63, 0xA2], payload: avcC)) // CodecPrivate
        t1.append(contentsOf: ebmlElement(id: [0xE0], payload: videoSub))
        let trackEntry1 = ebmlElement(id: [0xAE], payload: t1)

        // Audio sub-element (0xE1): SamplingFrequency=48000.0, OutputSamplingFrequency=96000.0, Channels=2, BitDepth=16
        var audioSub: [UInt8] = []
        audioSub.append(contentsOf: ebmlFloat64Element(id: [0xB5], value: 48_000.0))
        audioSub.append(contentsOf: ebmlFloat64Element(id: [0x78, 0xB5], value: 96_000.0))
        audioSub.append(contentsOf: ebmlUIntElement(id: [0x9F], value: 2, byteCount: 1))
        audioSub.append(contentsOf: ebmlUIntElement(id: [0x62, 0x64], value: 16, byteCount: 1))

        // Track 2: Audio
        var t2: [UInt8] = []
        t2.append(contentsOf: ebmlUIntElement(id: [0xD7], value: 2, byteCount: 1)) // TrackNumber = 2
        t2.append(contentsOf: ebmlUIntElement(id: [0x73, 0xC5], value: 2002, byteCount: 2)) // TrackUID = 2002
        t2.append(contentsOf: ebmlUIntElement(id: [0x83], value: 2, byteCount: 1)) // TrackType = 2 (audio)
        t2.append(contentsOf: ebmlUIntElement(id: [0xB9], value: 1, byteCount: 1)) // FlagEnabled = 1
        t2.append(contentsOf: ebmlUIntElement(id: [0x88], value: 1, byteCount: 1)) // FlagDefault = 1
        t2.append(contentsOf: ebmlElement(id: [0x53, 0x6E], payload: Array("Original Stereo".utf8))) // Name
        t2.append(contentsOf: ebmlElement(id: [0x22, 0xB5, 0x9C], payload: Array("jpn".utf8))) // Language
        t2.append(contentsOf: ebmlElement(id: [0x86], payload: Array("A_AAC".utf8))) // CodecID
        t2.append(contentsOf: ebmlElement(id: [0x63, 0xA2], payload: [0x11, 0x90])) // CodecPrivate
        t2.append(contentsOf: ebmlElement(id: [0xE1], payload: audioSub))
        let trackEntry2 = ebmlElement(id: [0xAE], payload: t2)

        // Track 3: Subtitle
        var t3: [UInt8] = []
        t3.append(contentsOf: ebmlUIntElement(id: [0xD7], value: 3, byteCount: 1)) // TrackNumber = 3
        t3.append(contentsOf: ebmlUIntElement(id: [0x73, 0xC5], value: 3003, byteCount: 2)) // TrackUID = 3003
        t3.append(contentsOf: ebmlUIntElement(id: [0x83], value: 0x11, byteCount: 1)) // TrackType = 0x11 (subtitle)
        t3.append(contentsOf: ebmlUIntElement(id: [0xB9], value: 1, byteCount: 1)) // FlagEnabled = 1
        t3.append(contentsOf: ebmlUIntElement(id: [0x88], value: 1, byteCount: 1)) // FlagDefault = 1
        t3.append(contentsOf: ebmlUIntElement(id: [0x55, 0xAA], value: 1, byteCount: 1)) // FlagForced = 1
        t3.append(contentsOf: ebmlElement(id: [0x53, 0x6E], payload: Array("Simplified Chinese".utf8))) // Name
        t3.append(contentsOf: ebmlElement(id: [0x22, 0xB5, 0x9C], payload: Array("zho".utf8))) // Language
        t3.append(contentsOf: ebmlElement(id: [0x86], payload: Array("S_TEXT/UTF8".utf8))) // CodecID
        let trackEntry3 = ebmlElement(id: [0xAE], payload: t3)

        let tracksElement = ebmlElement(
            id: [0x16, 0x54, 0xAE, 0x6B],
            payload: trackEntry1 + trackEntry2 + trackEntry3
        )

        // Segment Info (0x15, 0x49, 0xA9, 0x66): TimecodeScale=1_000_000, Duration=12500.0 (12.5s)
        var infoPayload: [UInt8] = []
        infoPayload.append(contentsOf: ebmlUIntElement(id: [0x2A, 0xD7, 0xB1], value: 1_000_000, byteCount: 3))
        infoPayload.append(contentsOf: ebmlFloat64Element(id: [0x44, 0x89], value: 12_500.0))
        let infoElement = ebmlElement(id: [0x15, 0x49, 0xA9, 0x66], payload: infoPayload)

        // Minimal Cluster (0x1F, 0x43, 0xB6, 0x75)
        let simpleBlock: [UInt8] = [0xA3, 0x89, 0x81, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x01, 0x65]
        let clusterPayload = [0xE7, 0x81, 0x00] + simpleBlock
        let clusterElement = ebmlElement(id: [0x1F, 0x43, 0xB6, 0x75], payload: clusterPayload)

        let segmentPayload = infoElement + tracksElement + clusterElement
        let segmentElement = ebmlElement(id: [0x18, 0x53, 0x80, 0x67], payload: segmentPayload)

        var fileBytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x8B, 0x42, 0x82, 0x88]
        fileBytes.append(contentsOf: "matroska".utf8)
        fileBytes.append(contentsOf: segmentElement)

        try Data(fileBytes).write(to: url, options: .atomic)
    }

    // MARK: - 1. Full Contract v1 Serialization Round-Trip (JSON & PropertyList/XPC)

    func testFullContractV1MetadataRoundTripAcrossTransportDictionaryAndPropertyList() throws {
        let richJSON = """
        {
          "schema_version": 1,
          "container_format": "matroska",
          "duration_seconds": 142.5,
          "has_cues_index": true,
          "bit_rate": 24500000,
          "file_size_bytes": 436207616,
          "title": "Sample 4K Dolby Vision Demo",
          "muxing_app": "libebml v1.4.5 + libmatroska v1.7.1",
          "writing_app": "mkvmerge v82.0",
          "selected_video_track_number": 1,
          "selected_audio_track_number": 2,
          "primary_audio_track_number": 2,
          "tracks_catalog": [
            {
              "catalog_index": 0,
              "container_track_number": 1,
              "playback_track_id": 1,
              "packet_stream_index": 1,
              "track_uid": 987654321,
              "media_type": "video",
              "codec_id": "V_MPEGH/ISO/HEVC",
              "codec_name": "hevc",
              "language": "eng",
              "name": "Dolby Vision Profile 8.1 Master",
              "default_duration_nanos": 41708333,
              "flag_enabled": true,
              "flag_default": true,
              "flag_forced": false,
              "demux_selectable": true,
              "selection_status": "selected",
              "selection_reason": "selected_default",
              "codec_private_present": true,
              "codec_private_len": 4,
              "codec_private_format": "dvcC",
              "codec_private_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
              "codec_private_hex": "01020304",
              "video": {
                "width": 3840,
                "height": 2160,
                "pixel_width": 3840,
                "pixel_height": 2160,
                "display_width": 3840,
                "display_height": 1600,
                "dimensions_source": "track_header",
                "bit_depth": 10,
                "hdr_format": "dolby_vision",
                "dolby_vision_profile": 8,
                "dolby_vision_level": 6,
                "color_primaries": "bt2020",
                "transfer_characteristics": "smpte2084",
                "matrix_coefficients": "bt2020nc",
                "color_range": "tv",
                "chroma_subsampling": "4:2:0",
                "bit_rate_bps": 22000000
              }
            },
            {
              "catalog_index": 1,
              "container_track_number": 2,
              "playback_track_id": 2,
              "packet_stream_index": 2,
              "track_uid": 123456789,
              "media_type": "audio",
              "codec_id": "A_EAC3",
              "codec_name": "eac3",
              "language": "eng",
              "name": "English Dolby Atmos 5.1.2",
              "default_duration_nanos": 32000000,
              "flag_enabled": true,
              "flag_default": true,
              "flag_forced": false,
              "demux_selectable": true,
              "selection_status": "selected",
              "selection_reason": "selected_default",
              "codec_private_present": true,
              "codec_private_len": 2,
              "codec_private_format": "dec3",
              "codec_private_sha256": "abcd",
              "codec_private_hex": "0c10",
              "audio": {
                "sample_rate_hz": 48000.0,
                "output_sample_rate_hz": 48000.0,
                "sample_rate_source": "track_header",
                "channels": 6,
                "channels_source": "track_header",
                "bit_depth": 24,
                "bit_depth_source": "track_header",
                "channel_layout": "5.1",
                "channel_layout_source": "codec_private",
                "audio_profile": "Dolby Digital Plus + Atmos (JOC)",
                "is_atmos": true,
                "bit_rate_bps": 768000
              }
            },
            {
              "catalog_index": 2,
              "container_track_number": 3,
              "playback_track_id": 3,
              "packet_stream_index": -1,
              "track_uid": 555666777,
              "media_type": "subtitle",
              "codec_id": "S_TEXT/ASS",
              "codec_name": "ass",
              "language": "zho",
              "name": "特效双语字幕",
              "flag_enabled": true,
              "flag_default": true,
              "flag_forced": false,
              "demux_selectable": false,
              "selection_status": "not_selected",
              "selection_reason": "catalog_only",
              "codec_private_present": true,
              "codec_private_len": 3,
              "codec_private_format": "ass_header",
              "codec_private_sha256": "112233",
              "codec_private_hex": "5b535d"
            }
          ],
          "selected_tracks": [
            {
              "catalog_index": 0,
              "container_track_number": 1,
              "playback_track_id": 1,
              "packet_stream_index": 1,
              "track_uid": 987654321,
              "media_type": "video",
              "codec_id": "V_MPEGH/ISO/HEVC",
              "codec_name": "hevc",
              "language": "eng",
              "name": "Dolby Vision Profile 8.1 Master",
              "default_duration_nanos": 41708333,
              "flag_enabled": true,
              "flag_default": true,
              "flag_forced": false,
              "demux_selectable": true,
              "selection_status": "selected",
              "selection_reason": "selected_default",
              "codec_private_present": true,
              "codec_private_len": 4,
              "codec_private_format": "dvcC",
              "codec_private_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
              "codec_private_hex": "01020304",
              "video": {
                "width": 3840,
                "height": 2160,
                "pixel_width": 3840,
                "pixel_height": 2160,
                "display_width": 3840,
                "display_height": 1600,
                "dimensions_source": "track_header",
                "bit_depth": 10,
                "hdr_format": "dolby_vision",
                "dolby_vision_profile": 8,
                "dolby_vision_level": 6,
                "color_primaries": "bt2020",
                "transfer_characteristics": "smpte2084",
                "matrix_coefficients": "bt2020nc",
                "color_range": "tv",
                "chroma_subsampling": "4:2:0",
                "bit_rate_bps": 22000000
              }
            },
            {
              "catalog_index": 1,
              "container_track_number": 2,
              "playback_track_id": 2,
              "packet_stream_index": 2,
              "track_uid": 123456789,
              "media_type": "audio",
              "codec_id": "A_EAC3",
              "codec_name": "eac3",
              "language": "eng",
              "name": "English Dolby Atmos 5.1.2",
              "default_duration_nanos": 32000000,
              "flag_enabled": true,
              "flag_default": true,
              "flag_forced": false,
              "demux_selectable": true,
              "selection_status": "selected",
              "selection_reason": "selected_default",
              "codec_private_present": true,
              "codec_private_len": 2,
              "codec_private_format": "dec3",
              "codec_private_sha256": "abcd",
              "codec_private_hex": "0c10",
              "audio": {
                "sample_rate_hz": 48000.0,
                "output_sample_rate_hz": 48000.0,
                "sample_rate_source": "track_header",
                "channels": 6,
                "channels_source": "track_header",
                "bit_depth": 24,
                "bit_depth_source": "track_header",
                "channel_layout": "5.1",
                "channel_layout_source": "codec_private",
                "audio_profile": "Dolby Digital Plus + Atmos (JOC)",
                "is_atmos": true,
                "bit_rate_bps": 768000
              }
            }
          ]
        }
        """

        let transportDict = try MediaWorkerDirectTransport.buildStreamMetadata(
            fromV1ContractJSON: Data(richJSON.utf8),
            cInfo: nil
        )
        // Verify dictionary is 100% PropertyList / NSXPCConnection safe
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: transportDict,
            format: .binary,
            options: 0
        )
        let roundTrippedDict = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )

        let infoA = MediaWorkerDirectTransport.parseStreamMetadata(sessionId: "sess-1", dictionary: transportDict)
        let infoB = MediaWorkerDirectTransport.parseStreamMetadata(sessionId: "sess-1", dictionary: roundTrippedDict)
        XCTAssertEqual(infoA, infoB, "PropertyList / XPC dictionary round-trip must preserve 100% of Contract v1 fields")

        XCTAssertEqual(infoA.metadataContractVersion, "v1")
        XCTAssertEqual(infoA.metadataSchemaVersion, 1)
        XCTAssertEqual(infoA.format, "matroska")
        XCTAssertEqual(infoA.durationSeconds, 142.5, accuracy: 0.001)
        XCTAssertEqual(infoA.bitRateBps, 24_500_000)
        XCTAssertEqual(infoA.fileSizeBytes, 436_207_616)
        XCTAssertEqual(infoA.title, "Sample 4K Dolby Vision Demo")
        XCTAssertEqual(infoA.muxingApp, "libebml v1.4.5 + libmatroska v1.7.1")
        XCTAssertEqual(infoA.writingApp, "mkvmerge v82.0")

        let video = try XCTUnwrap(infoA.primaryVideoTrack)
        XCTAssertEqual(video.trackIndex, 1)
        XCTAssertEqual(video.catalogIndex, 0)
        XCTAssertEqual(video.containerTrackNumber, 1)
        XCTAssertEqual(video.playbackTrackId, 1)
        XCTAssertEqual(video.packetStreamIndex, 1)
        XCTAssertEqual(video.trackUid, 987_654_321)
        XCTAssertEqual(video.codec, .hevc)
        XCTAssertEqual(video.codecDescriptor, .hevc)
        XCTAssertEqual(video.rawCodecId, "V_MPEGH/ISO/HEVC")
        XCTAssertEqual(video.width, 3840)
        XCTAssertEqual(video.height, 2160)
        XCTAssertEqual(video.displayWidth, 3840)
        XCTAssertEqual(video.displayHeight, 1600)
        XCTAssertEqual(video.naturalDisplaySize, CGSize(width: 3840, height: 1600))
        XCTAssertEqual(video.bitDepth, 10)
        XCTAssertEqual(video.dynamicRange, .dolbyVision)
        XCTAssertTrue(video.isHDR)
        XCTAssertTrue(video.isDolbyVision)
        XCTAssertFalse(video.activeHDROutputVerifiedByDemuxer, "Source HDR/DoVi evidence must never claim active display HDR output")
        XCTAssertFalse(infoA.activeHDROutputVerifiedByDemuxer)
        XCTAssertEqual(video.dolbyVisionProfile, 8)
        XCTAssertEqual(video.dolbyVisionLevel, 6)
        XCTAssertEqual(video.colorMetadata.colorPrimaries, "bt2020")
        XCTAssertEqual(video.colorMetadata.transferCharacteristics, "smpte2084")
        XCTAssertEqual(video.colorMetadata.matrixCoefficients, "bt2020nc")
        XCTAssertEqual(video.colorMetadata.colorRange, "tv")
        XCTAssertEqual(video.colorMetadata.chromaSubsampling, "4:2:0")
        XCTAssertEqual(video.frameRateFps ?? 0, 23.976, accuracy: 0.01)
        XCTAssertEqual(video.language, "eng")
        XCTAssertEqual(video.title, "Dolby Vision Profile 8.1 Master")
        XCTAssertEqual(video.extradata, Data([0x01, 0x02, 0x03, 0x04]))

        let audio = try XCTUnwrap(infoA.primaryAudioTrack)
        XCTAssertEqual(audio.trackIndex, 2)
        XCTAssertEqual(audio.catalogIndex, 1)
        XCTAssertEqual(audio.containerTrackNumber, 2)
        XCTAssertEqual(audio.playbackTrackId, 2)
        XCTAssertEqual(audio.packetStreamIndex, 2)
        XCTAssertEqual(audio.trackUid, 123_456_789)
        XCTAssertEqual(audio.codec, .eac3)
        XCTAssertEqual(audio.codecDescriptor, .eac3)
        XCTAssertEqual(audio.sampleRate, 48_000.0)
        XCTAssertEqual(audio.outputSampleRateHz, 48_000.0)
        XCTAssertEqual(audio.channels, 6)
        XCTAssertEqual(audio.bitDepth, 24)
        XCTAssertEqual(audio.bitDepthSource, "track_header")
        XCTAssertEqual(audio.channelLayout, "5.1")
        XCTAssertEqual(audio.channelLayoutSource, "codec_private")
        XCTAssertEqual(audio.audioProfile, "Dolby Digital Plus + Atmos (JOC)")
        XCTAssertTrue(audio.isAtmos)
        XCTAssertEqual(audio.isAtmosVerified, true)
        XCTAssertEqual(audio.language, "eng")
        XCTAssertEqual(audio.title, "English Dolby Atmos 5.1.2")

        XCTAssertEqual(infoA.catalogSubtitleTracks.count, 1)
        let sub = infoA.catalogSubtitleTracks[0]
        XCTAssertEqual(sub.trackIndex, 3)
        XCTAssertEqual(sub.catalogIndex, 2)
        XCTAssertEqual(sub.containerTrackNumber, 3)
        XCTAssertEqual(sub.playbackTrackId, 3)
        XCTAssertEqual(sub.packetStreamIndex, -1)
        XCTAssertEqual(sub.codec, .ass)
        XCTAssertTrue(sub.isTextBased)
        XCTAssertFalse(sub.isImageBased)
        XCTAssertEqual(sub.language, "zho")
        XCTAssertEqual(sub.title, "特效双语字幕")
        XCTAssertTrue(sub.isDefault)
        XCTAssertFalse(sub.isForced)
        XCTAssertEqual(sub.extradata, Data([0x5B, 0x53, 0x5D]))
    }

    // MARK: - 2. Missing Fields & Honest Provenance (Never Fabricate HDR / Dolby Tags)

    func testMissingOptionalMetadataDegradesGracefullyWithoutFabricatingHDROrDolbyTags() throws {
        // 4K 10-bit HEVC + 6-channel E-AC-3 (unknown Atmos / missing bit_depth / unknown channel_layout)
        // + 8-channel E-AC-3 (verified non-Atmos is_atmos=false):
        // Must NOT fabricate HDR10, Dolby Vision, Dolby Atmos, 24-bit depth, or 5.1/7.1 layout!
        let minimalJSON = """
        {
          "schema_version": 1,
          "container_format": "matroska",
          "duration_seconds": 60.0,
          "has_cues_index": false,
          "selected_video_track_number": 1,
          "selected_audio_track_number": 2,
          "primary_audio_track_number": 2,
          "tracks_catalog": [
            {
              "catalog_index": 0, "container_track_number": 1, "playback_track_id": 1, "packet_stream_index": 1,
              "media_type": "video", "codec_id": "V_MPEGH/ISO/HEVC", "codec_name": "hevc",
              "demux_selectable": true, "selection_status": "selected", "selection_reason": "selected_default",
              "video": { "width": 3840, "height": 2160, "bit_depth": 10, "hdr_source": "unavailable", "colour_source": "unavailable" }
            },
            {
              "catalog_index": 1, "container_track_number": 2, "playback_track_id": 2, "packet_stream_index": 2,
              "media_type": "audio", "codec_id": "A_EAC3", "codec_name": "eac3",
              "demux_selectable": true, "selection_status": "selected", "selection_reason": "selected_default",
              "audio": {
                "sample_rate_hz": 48000.0, "channels": 6, "bit_depth": null, "bit_depth_source": "unavailable",
                "channel_layout": null, "channel_layout_source": "unavailable",
                "is_atmos": null, "atmos_source": "unavailable", "audio_profile_source": "unavailable"
              }
            },
            {
              "catalog_index": 2, "container_track_number": 3, "playback_track_id": 3, "packet_stream_index": -1,
              "media_type": "audio", "codec_id": "A_EAC3", "codec_name": "eac3",
              "demux_selectable": true, "selection_status": "not_selected", "selection_reason": "secondary_audio",
              "audio": {
                "sample_rate_hz": 48000.0, "channels": 8, "bit_depth": null, "bit_depth_source": "unavailable",
                "channel_layout": "unknown", "channel_layout_source": "unavailable",
                "is_atmos": false, "atmos_source": "verified_dec3_no_joc", "audio_profile_source": "codec_private"
              }
            }
          ],
          "selected_tracks": [
            {
              "catalog_index": 0, "container_track_number": 1, "playback_track_id": 1, "packet_stream_index": 1,
              "media_type": "video", "codec_id": "V_MPEGH/ISO/HEVC", "codec_name": "hevc",
              "demux_selectable": true, "selection_status": "selected", "selection_reason": "selected_default",
              "video": { "width": 3840, "height": 2160, "bit_depth": 10, "hdr_source": "unavailable", "colour_source": "unavailable" }
            },
            {
              "catalog_index": 1, "container_track_number": 2, "playback_track_id": 2, "packet_stream_index": 2,
              "media_type": "audio", "codec_id": "A_EAC3", "codec_name": "eac3",
              "demux_selectable": true, "selection_status": "selected", "selection_reason": "selected_default",
              "audio": {
                "sample_rate_hz": 48000.0, "channels": 6, "bit_depth": null, "bit_depth_source": "unavailable",
                "channel_layout": null, "channel_layout_source": "unavailable",
                "is_atmos": null, "atmos_source": "unavailable", "audio_profile_source": "unavailable"
              }
            }
          ]
        }
        """

        let info = try TTMediaStreamInfo(sessionId: "minimal", v1ContractJSON: Data(minimalJSON.utf8))
        let video = try XCTUnwrap(info.primaryVideoTrack)
        XCTAssertEqual(video.dynamicRange, .unknown, "Must not fabricate HDR10 or SDR when transfer/HDR evidence is absent")
        XCTAssertFalse(video.isHDR)
        XCTAssertFalse(video.isDolbyVision)
        XCTAssertFalse(video.activeHDROutputVerifiedByDemuxer)
        XCTAssertEqual(video.hdrSource, "unavailable")
        XCTAssertEqual(video.colourSource, "unavailable")
        XCTAssertNil(video.dolbyVisionProfile)
        XCTAssertTrue(video.colorMetadata.isEmpty)
        XCTAssertNil(video.frameRateFps)
        XCTAssertNil(video.language)
        XCTAssertNil(video.title)

        let audio = try XCTUnwrap(info.primaryAudioTrack)
        XCTAssertNil(audio.bitDepth, "Must not fabricate 24-bit default when bit_depth is null")
        XCTAssertEqual(audio.bitsPerChannel, 0)
        XCTAssertEqual(audio.bitDepthSource, "unavailable")
        XCTAssertNil(audio.channelLayout, "Must not infer 5.1 layout solely from channels == 6")
        XCTAssertEqual(audio.channelLayoutSource, "unavailable")
        XCTAssertNil(audio.isAtmosVerified, "Unknown Atmos (null) must remain nil and never turn into verified false")
        XCTAssertFalse(audio.isAtmos, "Must not fabricate Dolby Atmos from 6-channel E-AC-3 without Atmos/JOC evidence")
        XCTAssertEqual(audio.atmosSource, "unavailable")
        XCTAssertEqual(audio.audioProfileSource, "unavailable")
        XCTAssertNil(audio.audioProfile)
        XCTAssertNil(audio.language)
        XCTAssertNil(audio.title)

        let verifiedNonAtmosAudio = info.catalogAudioTracks[1]
        XCTAssertNil(verifiedNonAtmosAudio.bitDepth)
        XCTAssertNil(verifiedNonAtmosAudio.channelLayout, "Must not infer 7.1 layout from channels == 8 or placeholder 'unknown'")
        XCTAssertEqual(verifiedNonAtmosAudio.isAtmosVerified, false, "Explicit false Atmos must remain false")
        XCTAssertFalse(verifiedNonAtmosAudio.isAtmos)
        XCTAssertEqual(verifiedNonAtmosAudio.atmosSource, "verified_dec3_no_joc")
        XCTAssertEqual(verifiedNonAtmosAudio.audioProfileSource, "codec_private")
        XCTAssertNil(info.bitRateBps)
        XCTAssertTrue(info.catalogSubtitleTracks.isEmpty)
    }

    // MARK: - 3. Unknown Enum Values & Forward-Compatible Schema Handling

    func testUnknownCodecAndDynamicRangeEnumValuesDegradeToUnknownWithoutThrowing() throws {
        let forwardJSON = """
        {
          "schema_version": 2,
          "future_unknown_root_field": { "nested": [1, 2, 3] },
          "container_format": "future_container",
          "duration_seconds": 30.0,
          "tracks_catalog": [
            {
              "catalog_index": 0,
              "container_track_number": 10,
              "playback_track_id": 10,
              "packet_stream_index": 0,
              "media_type": "video",
              "codec_id": "V_AVS3",
              "codec_name": "avs3",
              "demux_selectable": false,
              "selection_status": "not_selected",
              "selection_reason": "unsupported_codec",
              "video": {
                "width": 7680,
                "height": 4320,
                "hdr_format": "future_quantum_hdr_2030"
              }
            },
            {
              "catalog_index": 1,
              "container_track_number": 20,
              "playback_track_id": 20,
              "packet_stream_index": 1,
              "media_type": "audio",
              "codec_id": "A_EXPERIMENTAL_SPATIAL",
              "codec_name": "exp_spatial",
              "demux_selectable": false,
              "selection_status": "not_selected",
              "selection_reason": "unsupported_codec",
              "audio": {
                "sample_rate_hz": 192000.0,
                "channels": 12
              }
            },
            {
              "catalog_index": 2,
              "container_track_number": 30,
              "playback_track_id": 30,
              "packet_stream_index": -1,
              "media_type": "subtitle",
              "codec_id": "S_FUTURE/HOLOGRAM",
              "codec_name": "hologram_sub"
            }
          ],
          "selected_tracks": []
        }
        """

        let info = try TTMediaStreamInfo(sessionId: "forward-v2", v1ContractJSON: Data(forwardJSON.utf8))
        XCTAssertEqual(info.metadataSchemaVersion, 2)
        XCTAssertEqual(info.catalogVideoTracks.count, 1)
        XCTAssertNil(info.catalogVideoTracks[0].codec)
        XCTAssertEqual(info.catalogVideoTracks[0].codecDescriptor, .unknown)
        XCTAssertEqual(info.catalogVideoTracks[0].codecName, "avs3")
        XCTAssertEqual(info.catalogVideoTracks[0].rawCodecId, "V_AVS3")
        XCTAssertEqual(info.catalogVideoTracks[0].dynamicRange, .unknown)
        XCTAssertEqual(info.catalogVideoTracks[0].rawDynamicRange, "future_quantum_hdr_2030")

        XCTAssertEqual(info.catalogAudioTracks.count, 1)
        XCTAssertNil(info.catalogAudioTracks[0].codec)
        XCTAssertEqual(info.catalogAudioTracks[0].codecDescriptor, .unknown)
        XCTAssertEqual(info.catalogAudioTracks[0].rawCodecId, "A_EXPERIMENTAL_SPATIAL")

        XCTAssertEqual(info.catalogSubtitleTracks.count, 1)
        XCTAssertEqual(info.catalogSubtitleTracks[0].codec, .unknown)
        XCTAssertFalse(info.catalogSubtitleTracks[0].isTextBased)
        XCTAssertFalse(info.catalogSubtitleTracks[0].isImageBased)
        XCTAssertEqual(info.catalogSubtitleTracks[0].rawCodecId, "S_FUTURE/HOLOGRAM")
    }

    // MARK: - 4. Real Direct Transport vs Real XPC Service vs Process Transport End-to-End Parity

    func testRealDirectTransportRealXPCServiceAndProcessTransportDeliverIdenticalMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-e-contract-v1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mkvURL = tempDir.appendingPathComponent("multitrack_contract_v1.mkv")
        try Self.createMultiTrackMKVFixture(at: mkvURL)

        // 1. Real Direct Transport -> MediaWorkerXPCClient
        let directTransport = MediaWorkerDirectTransport()
        let directClient = MediaWorkerXPCClient(transport: directTransport)
        let directInfo = try await directClient.open(url: mkvURL)
        try await directClient.close(sessionId: directInfo.sessionId)

        // 2. Real XPC Service (MediaWorkerService + NSXPCListener.anonymous + MediaWorkerXPCTransport) -> MediaWorkerXPCClient
        final class RealServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
            func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                let service = MediaWorkerService()
                connection.exportedInterface = .makeMediaWorkerInterface()
                connection.exportedObject = service
                connection.invalidationHandler = { service.invalidate() }
                connection.resume()
                return true
            }
        }
        let listener = NSXPCListener.anonymous()
        let serviceDelegate = RealServiceListenerDelegate()
        listener.delegate = serviceDelegate
        listener.resume()
        defer { listener.invalidate() }

        let xpcTransport = MediaWorkerXPCTransport(endpoint: listener.endpoint, useFileHandleCapability: true)
        let xpcClient = MediaWorkerXPCClient(transport: xpcTransport)
        let xpcInfo = try await xpcClient.open(url: mkvURL)
        try await xpcClient.close(sessionId: xpcInfo.sessionId)
        xpcTransport.invalidate()

        // 3. Real Subprocess IPC (MediaWorkerProcessTransport) -> MediaWorkerXPCClient
        // The subprocess returns the raw V1 contract JSON queried from the same file to verify Process normalization parity.
        let rawDirectOpen = try await directTransport.openMedia(path: mkvURL.path, targetTracks: nil)
        try await directTransport.closeMedia(sessionId: rawDirectOpen.sessionId)
        let jsonSafeMeta = TTMediaTransportMetadataSanitizer.sanitizeDictionary(rawDirectOpen.metadata, encodeDataAsBase64: true)
        let metadataJSONData = try JSONSerialization.data(withJSONObject: jsonSafeMeta)
        let metadataJSONFile = tempDir.appendingPathComponent("worker_meta.json")
        try metadataJSONData.write(to: metadataJSONFile)

        let workerScript = tempDir.appendingPathComponent("process_worker_contract_v1.py")
        let scriptContent = """
        import json, struct, sys
        meta_path = sys.argv[1]
        with open(meta_path, 'rb') as f:
            meta_obj = json.loads(f.read().decode('utf-8'))
        while True:
            hdr = sys.stdin.buffer.read(4)
            if not hdr or len(hdr) < 4:
                break
            length = struct.unpack('>I', hdr)[0]
            body = sys.stdin.buffer.read(length)
            req = json.loads(body.decode('utf-8'))
            cmd = req.get('command')
            sid = req.get('sessionId', 'proc-sid')
            if cmd == 'open':
                resp = json.dumps({'sessionId': sid, 'metadata': meta_obj}).encode('utf-8')
            else:
                resp = json.dumps({'status': 'ok'}).encode('utf-8')
            sys.stdout.buffer.write(struct.pack('>I', len(resp)) + resp)
            sys.stdout.buffer.flush()
        """
        try scriptContent.write(to: workerScript, atomically: true, encoding: .utf8)

        let processTransport = MediaWorkerProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [workerScript.path, metadataJSONFile.path]
        )
        let processClient = MediaWorkerXPCClient(transport: processTransport)
        let processInfo = try await processClient.open(url: mkvURL)
        try await processClient.close(sessionId: processInfo.sessionId)
        processTransport.invalidate()

        // Verify Direct, Real XPC, and Process transports yield 100% identical metadata & track identities!
        XCTAssertEqual(directInfo.format, "matroska")
        XCTAssertEqual(directInfo.format, xpcInfo.format)
        XCTAssertEqual(directInfo.format, processInfo.format)
        XCTAssertEqual(directInfo.durationSeconds, 12.5, accuracy: 0.01)
        XCTAssertEqual(directInfo.durationSeconds, xpcInfo.durationSeconds, accuracy: 0.001)
        XCTAssertEqual(directInfo.durationSeconds, processInfo.durationSeconds, accuracy: 0.001)
        XCTAssertEqual(directInfo.metadataCapability, TTMediaMetadataContract.structuredCapabilityToken)
        XCTAssertEqual(directInfo.metadataCapability, xpcInfo.metadataCapability)
        XCTAssertEqual(directInfo.metadataCapability, processInfo.metadataCapability)
        XCTAssertEqual(directInfo.videoTracks, xpcInfo.videoTracks)
        XCTAssertEqual(directInfo.videoTracks, processInfo.videoTracks)
        XCTAssertEqual(directInfo.audioTracks, xpcInfo.audioTracks)
        XCTAssertEqual(directInfo.audioTracks, processInfo.audioTracks)
        XCTAssertEqual(directInfo.subtitleTracks, xpcInfo.subtitleTracks)
        XCTAssertEqual(directInfo.subtitleTracks, processInfo.subtitleTracks)
        XCTAssertEqual(directInfo.catalogVideoTracks, xpcInfo.catalogVideoTracks)
        XCTAssertEqual(directInfo.catalogAudioTracks, xpcInfo.catalogAudioTracks)
        XCTAssertEqual(directInfo.catalogSubtitleTracks, xpcInfo.catalogSubtitleTracks)

        // Verify real Rust demuxer extracted rich fields on all 3 paths
        let vTrack = try XCTUnwrap(xpcInfo.primaryVideoTrack)
        XCTAssertEqual(vTrack.trackIndex, 1)
        XCTAssertEqual(vTrack.catalogIndex, 0)
        XCTAssertEqual(vTrack.containerTrackNumber, 1)
        XCTAssertEqual(vTrack.playbackTrackId, 1)
        XCTAssertEqual(vTrack.packetStreamIndex, 1)
        XCTAssertEqual(vTrack.trackUid, 1001)
        XCTAssertEqual(vTrack.codec, .h264)
        XCTAssertEqual(vTrack.width, 1920)
        XCTAssertEqual(vTrack.height, 1080)
        XCTAssertEqual(vTrack.displayWidth, 1920)
        XCTAssertEqual(vTrack.displayHeight, 800)
        XCTAssertEqual(vTrack.frameRateFps ?? 0, 24.0, accuracy: 0.05)
        XCTAssertEqual(vTrack.language, "eng")
        XCTAssertEqual(vTrack.title, "Director Cut Video")
        XCTAssertTrue(vTrack.isDefault)
        XCTAssertFalse(vTrack.isForced)
        XCTAssertEqual(vTrack.codecPrivateFormat, "avcc")
        XCTAssertNotNil(vTrack.extradata)

        let aTrack = try XCTUnwrap(xpcInfo.primaryAudioTrack)
        XCTAssertEqual(aTrack.trackIndex, 2)
        XCTAssertEqual(aTrack.catalogIndex, 1)
        XCTAssertEqual(aTrack.containerTrackNumber, 2)
        XCTAssertEqual(aTrack.playbackTrackId, 2)
        XCTAssertEqual(aTrack.packetStreamIndex, 2)
        XCTAssertEqual(aTrack.trackUid, 2002)
        XCTAssertEqual(aTrack.codec, .aac)
        XCTAssertEqual(aTrack.sampleRate, 48_000.0)
        XCTAssertEqual(aTrack.outputSampleRateHz, 96_000.0)
        XCTAssertEqual(aTrack.channels, 2)
        XCTAssertEqual(aTrack.bitDepth, 16)
        XCTAssertEqual(aTrack.language, "jpn")
        XCTAssertEqual(aTrack.title, "Original Stereo")
        XCTAssertEqual(aTrack.extradata, Data([0x11, 0x90]))

        XCTAssertEqual(xpcInfo.catalogSubtitleTracks.count, 1)
        let sTrack = xpcInfo.catalogSubtitleTracks[0]
        XCTAssertEqual(sTrack.trackIndex, 3)
        XCTAssertEqual(sTrack.catalogIndex, 2)
        XCTAssertEqual(sTrack.containerTrackNumber, 3)
        XCTAssertEqual(sTrack.playbackTrackId, 3)
        XCTAssertEqual(sTrack.packetStreamIndex, 3)
        XCTAssertEqual(sTrack.trackUid, 3003)
        XCTAssertEqual(sTrack.codec, .srt)
        XCTAssertTrue(sTrack.isTextBased)
        XCTAssertEqual(sTrack.language, "zho")
        XCTAssertEqual(sTrack.title, "Simplified Chinese")
        XCTAssertTrue(sTrack.isDefault)
        XCTAssertTrue(sTrack.isForced)
    }
}
