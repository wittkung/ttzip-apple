// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Foundation
import XCTest
@testable import TTMediaKit

final class MediaPacketDTOTests: XCTestCase {

    // MARK: - Core MediaPacketDTO & CMTime Tests

    func testMediaPacketDTOInitializationAndProperties() throws {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E])
        let packet = try MediaPacketDTO(
            streamIndex: 0,
            mediaType: .video,
            ptsValue: 3000,
            ptsTimescale: 1000,
            dtsValue: 2000,
            dtsTimescale: 1000,
            durationValue: 1000,
            durationTimescale: 1000,
            payloadData: payload,
            isKeyframe: true,
            doNotDisplay: false,
            ioSurfaceId: 101
        )

        XCTAssertEqual(packet.streamIndex, 0)
        XCTAssertEqual(packet.mediaType, .video)
        XCTAssertEqual(packet.ptsValue, 3000)
        XCTAssertEqual(packet.ptsTimescale, 1000)
        XCTAssertEqual(packet.dtsValue, 2000)
        XCTAssertEqual(packet.dtsTimescale, 1000)
        XCTAssertEqual(packet.durationValue, 1000)
        XCTAssertEqual(packet.durationTimescale, 1000)
        XCTAssertEqual(packet.payloadData, payload)
        XCTAssertTrue(packet.isKeyframe)
        XCTAssertFalse(packet.doNotDisplay)
        XCTAssertEqual(packet.ioSurfaceId, 101)
    }

    func testCMTimeConversionsAndEdgeCases() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let validPacket = try MediaPacketDTO(
            streamIndex: 1,
            mediaType: .audio,
            ptsValue: 48000,
            ptsTimescale: 48000,
            dtsValue: 48000,
            dtsTimescale: 48000,
            durationValue: 1024,
            durationTimescale: 48000,
            payloadData: payload,
            isKeyframe: true,
            doNotDisplay: false
        )

        XCTAssertTrue(validPacket.presentationTimeStamp.isValid)
        XCTAssertEqual(validPacket.presentationTimeStamp.value, 48000)
        XCTAssertEqual(validPacket.presentationTimeStamp.timescale, 48000)
        XCTAssertEqual(CMTimeGetSeconds(validPacket.presentationTimeStamp), 1.0, accuracy: 0.0001)

        XCTAssertTrue(validPacket.decodeTimeStamp.isValid)
        XCTAssertEqual(CMTimeGetSeconds(validPacket.decodeTimeStamp), 1.0, accuracy: 0.0001)

        XCTAssertTrue(validPacket.duration.isValid)
        XCTAssertEqual(CMTimeGetSeconds(validPacket.duration), 1024.0 / 48000.0, accuracy: 0.0001)

        // Invalid timescale edge case (<= 0)
        let invalidPacket = try MediaPacketDTO(
            streamIndex: 0,
            mediaType: .video,
            ptsValue: 100,
            ptsTimescale: 0,
            dtsValue: 100,
            dtsTimescale: -1,
            durationValue: 50,
            durationTimescale: 0,
            payloadData: payload,
            isKeyframe: false,
            doNotDisplay: false
        )

        XCTAssertFalse(invalidPacket.presentationTimeStamp.isValid)
        XCTAssertFalse(invalidPacket.decodeTimeStamp.isValid)
        XCTAssertFalse(invalidPacket.duration.isValid)
    }

    // MARK: - Bounds Enforcement Tests

    func testPayloadBoundsEnforcement() throws {
        // Upper bound boundary: exactly 16 MB is allowed
        let exact16MB = Data(count: MediaPacketDTO.maxPayloadSizeBytes)
        let validMaxPacket = try MediaPacketDTO(
            streamIndex: 0,
            mediaType: .video,
            ptsValue: 0,
            ptsTimescale: 1000,
            dtsValue: 0,
            dtsTimescale: 1000,
            durationValue: 100,
            durationTimescale: 1000,
            payloadData: exact16MB,
            isKeyframe: true,
            doNotDisplay: false
        )
        XCTAssertEqual(validMaxPacket.payloadData.count, 16_777_216)

        // Oversized payload: 16 MB + 1 byte must be rejected
        let oversizedData = Data(count: MediaPacketDTO.maxPayloadSizeBytes + 1)
        XCTAssertThrowsError(
            try MediaPacketDTO(
                streamIndex: 0,
                mediaType: .video,
                ptsValue: 0,
                ptsTimescale: 1000,
                dtsValue: 0,
                dtsTimescale: 1000,
                durationValue: 100,
                durationTimescale: 1000,
                payloadData: oversizedData,
                isKeyframe: true,
                doNotDisplay: false
            )
        ) { error in
            guard let validationError = error as? MediaPacketValidationError else {
                XCTFail("Expected MediaPacketValidationError, got \(error)")
                return
            }
            if case let .payloadExceedsMaximumSize(actual, max) = validationError {
                XCTAssertEqual(actual, 16_777_217)
                XCTAssertEqual(max, 16_777_216)
            } else {
                XCTFail("Unexpected validation error case: \(validationError)")
            }
        }
    }

    func testPacketResponseBoundsValidation() throws {
        // Valid packet response
        let validResponse = try TTMediaWorkerPacketResponse(
            streamIndex: 0,
            mediaType: "video",
            pts: 1000,
            dts: 1000,
            duration: 500,
            timescale: 1000,
            isKeyframe: true,
            doNotDisplay: false,
            payloadSizeBytes: 16_777_216
        )
        XCTAssertEqual(validResponse.payloadSizeBytes, 16_777_216)

        // Oversized packet response
        XCTAssertThrowsError(
            try TTMediaWorkerPacketResponse(
                streamIndex: 0,
                mediaType: "video",
                pts: 1000,
                dts: 1000,
                duration: 500,
                timescale: 1000,
                isKeyframe: true,
                doNotDisplay: false,
                payloadSizeBytes: 16_777_217
            )
        )

        // Invalid timescale (< 1)
        XCTAssertThrowsError(
            try TTMediaWorkerPacketResponse(
                streamIndex: 0,
                mediaType: "video",
                pts: 1000,
                dts: 1000,
                duration: 500,
                timescale: 0,
                isKeyframe: true,
                doNotDisplay: false,
                payloadSizeBytes: 1024
            )
        )
    }

    // MARK: - Equality & Codable Conformance Tests

    func testMediaPacketDTOEqualityAndCodable() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packetA = try MediaPacketDTO(
            streamIndex: 0,
            mediaType: .video,
            ptsValue: 1000,
            ptsTimescale: 600,
            dtsValue: 1000,
            dtsTimescale: 600,
            durationValue: 20,
            durationTimescale: 600,
            payloadData: payload,
            isKeyframe: true,
            doNotDisplay: false,
            ioSurfaceId: 42
        )
        let packetB = try MediaPacketDTO(
            streamIndex: 0,
            mediaType: .video,
            ptsValue: 1000,
            ptsTimescale: 600,
            dtsValue: 1000,
            dtsTimescale: 600,
            durationValue: 20,
            durationTimescale: 600,
            payloadData: payload,
            isKeyframe: true,
            doNotDisplay: false,
            ioSurfaceId: 42
        )
        let packetC = try MediaPacketDTO(
            streamIndex: 1,
            mediaType: .audio,
            ptsValue: 1000,
            ptsTimescale: 600,
            dtsValue: 1000,
            dtsTimescale: 600,
            durationValue: 20,
            durationTimescale: 600,
            payloadData: payload,
            isKeyframe: true,
            doNotDisplay: false
        )

        XCTAssertEqual(packetA, packetB)
        XCTAssertNotEqual(packetA, packetC)

        // JSON Codable round trip
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(packetA)
        let decoded = try decoder.decode(MediaPacketDTO.self, from: data)
        XCTAssertEqual(packetA, decoded)
    }

    func testMediaTypeEnumCodableAndTokens() throws {
        XCTAssertEqual(MediaType.video.rawValue, 1)
        XCTAssertEqual(MediaType.audio.rawValue, 2)
        XCTAssertEqual(MediaType.subtitle.rawValue, 3)

        XCTAssertEqual(MediaType.video.stringValue, "video")
        XCTAssertEqual(MediaType.audio.stringValue, "audio")
        XCTAssertEqual(MediaType.subtitle.stringValue, "subtitle")

        XCTAssertEqual(MediaType(stringValue: "video"), .video)
        XCTAssertEqual(MediaType(stringValue: "AUDIO"), .audio)
        XCTAssertEqual(MediaType(stringValue: "subtitle"), .subtitle)
        XCTAssertNil(MediaType(stringValue: "unknown"))

        // Decode from JSON string token
        let jsonStringToken = "\"video\"".data(using: .utf8)!
        let fromString = try JSONDecoder().decode(MediaType.self, from: jsonStringToken)
        XCTAssertEqual(fromString, .video)

        // Decode from JSON integer
        let jsonInt = "2".data(using: .utf8)!
        let fromInt = try JSONDecoder().decode(MediaType.self, from: jsonInt)
        XCTAssertEqual(fromInt, .audio)
    }

    func testVideoAndAudioFormatParameters() throws {
        let videoExtradata = Data([0x01, 0x64, 0x00, 0x1F])
        let videoParams = VideoFormatParameters(
            codec: .hevc,
            width: 3840,
            height: 2160,
            pixelFormat: 0x34323076, // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            colorPrimaries: "ITU_R_2020",
            transferFunction: "SMPTE_ST_2084_PQ",
            yCbCrMatrix: "ITU_R_2020",
            extradata: videoExtradata
        )

        XCTAssertEqual(videoParams.codec, .hevc)
        XCTAssertEqual(videoParams.width, 3840)
        XCTAssertEqual(videoParams.height, 2160)
        XCTAssertEqual(videoParams.pixelFormat, 0x34323076)
        XCTAssertEqual(videoParams.colorPrimaries, "ITU_R_2020")

        let encodedVideo = try JSONEncoder().encode(videoParams)
        let decodedVideo = try JSONDecoder().decode(VideoFormatParameters.self, from: encodedVideo)
        XCTAssertEqual(videoParams, decodedVideo)

        let audioExtradata = Data([0x12, 0x10])
        let audioParams = AudioFormatParameters(
            codec: .aac,
            sampleRate: 48000.0,
            channelCount: 2,
            bitsPerChannel: 16,
            channelLayoutTag: 0x640002,
            extradata: audioExtradata
        )

        XCTAssertEqual(audioParams.codec, .aac)
        XCTAssertEqual(audioParams.sampleRate, 48000.0)
        XCTAssertEqual(audioParams.channelCount, 2)
        XCTAssertEqual(audioParams.bitsPerChannel, 16)

        let encodedAudio = try JSONEncoder().encode(audioParams)
        let decodedAudio = try JSONDecoder().decode(AudioFormatParameters.self, from: encodedAudio)
        XCTAssertEqual(audioParams, decodedAudio)
    }

    // MARK: - Schema JSON Round-Trip Tests

    func testContractSchemaOpenCommandSerialization() throws {
        let contract = TTMediaWorkerContract.open(
            sessionId: "123e4567-e89b-12d3-a456-426614174000",
            filePath: "/path/to/media.mkv",
            targetTracks: [0, 1]
        )

        let data = try JSONEncoder().encode(contract)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(jsonObject)
        XCTAssertEqual(jsonObject?["command"] as? String, "open")
        XCTAssertEqual(jsonObject?["sessionId"] as? String, "123e4567-e89b-12d3-a456-426614174000")

        let openParams = jsonObject?["openParams"] as? [String: Any]
        XCTAssertEqual(openParams?["filePath"] as? String, "/path/to/media.mkv")
        XCTAssertEqual(openParams?["targetTracks"] as? [Int], [0, 1])

        let decoded = try JSONDecoder().decode(TTMediaWorkerContract.self, from: data)
        XCTAssertEqual(contract, decoded)
    }

    func testContractSchemaSeekCommandSerialization() throws {
        let contract = TTMediaWorkerContract.seek(
            sessionId: "123e4567-e89b-12d3-a456-426614174000",
            targetTimestamp: 12.345,
            accurate: true
        )

        let data = try JSONEncoder().encode(contract)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(jsonObject?["command"] as? String, "seek")

        let seekParams = jsonObject?["seekParams"] as? [String: Any]
        XCTAssertEqual(seekParams?["targetTimestamp"] as? Double, 12.345)
        XCTAssertEqual(seekParams?["accurate"] as? Bool, true)

        let decoded = try JSONDecoder().decode(TTMediaWorkerContract.self, from: data)
        XCTAssertEqual(contract, decoded)
    }

    func testContractSchemaPacketResponseRoundTrip() throws {
        let response = try TTMediaWorkerPacketResponse(
            streamIndex: 0,
            mediaType: "video",
            pts: 12000,
            dts: 12000,
            duration: 1000,
            timescale: 24000,
            isKeyframe: true,
            doNotDisplay: false,
            payloadSizeBytes: 4096
        )
        let contract = TTMediaWorkerContract.response(
            sessionId: "123e4567-e89b-12d3-a456-426614174000",
            packet: response
        )

        let data = try JSONEncoder().encode(contract)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(jsonObject?["command"] as? String, "read_packet")

        let packetJson = jsonObject?["packetResponse"] as? [String: Any]
        XCTAssertEqual(packetJson?["streamIndex"] as? Int, 0)
        XCTAssertEqual(packetJson?["mediaType"] as? String, "video")
        XCTAssertEqual(packetJson?["pts"] as? Int, 12000)
        XCTAssertEqual(packetJson?["dts"] as? Int, 12000)
        XCTAssertEqual(packetJson?["duration"] as? Int, 1000)
        XCTAssertEqual(packetJson?["timescale"] as? Int, 24000)
        XCTAssertEqual(packetJson?["isKeyframe"] as? Bool, true)
        XCTAssertEqual(packetJson?["doNotDisplay"] as? Bool, false)
        XCTAssertEqual(packetJson?["payloadSizeBytes"] as? Int, 4096)

        let decoded = try JSONDecoder().decode(TTMediaWorkerContract.self, from: data)
        XCTAssertEqual(contract, decoded)
    }

    func testDTOToWorkerPacketResponseBridge() throws {
        let payload = Data(repeating: 0xAA, count: 512)
        let dto = try MediaPacketDTO(
            streamIndex: 2,
            mediaType: .subtitle,
            ptsValue: 5000,
            ptsTimescale: 1000,
            dtsValue: 5000,
            dtsTimescale: 1000,
            durationValue: 2000,
            durationTimescale: 1000,
            payloadData: payload,
            isKeyframe: true,
            doNotDisplay: false
        )

        let response = dto.toWorkerPacketResponse()
        XCTAssertEqual(response.streamIndex, 2)
        XCTAssertEqual(response.mediaType, "subtitle")
        XCTAssertEqual(response.pts, 5000)
        XCTAssertEqual(response.dts, 5000)
        XCTAssertEqual(response.duration, 2000)
        XCTAssertEqual(response.timescale, 1000)
        XCTAssertEqual(response.payloadSizeBytes, 512)

        let reconstructed = try MediaPacketDTO(
            packetResponse: response,
            payloadData: payload
        )
        XCTAssertEqual(reconstructed.streamIndex, dto.streamIndex)
        XCTAssertEqual(reconstructed.mediaType, dto.mediaType)
        XCTAssertEqual(reconstructed.ptsValue, dto.ptsValue)
        XCTAssertEqual(reconstructed.dtsValue, dto.dtsValue)
        XCTAssertEqual(reconstructed.durationValue, dto.durationValue)
        XCTAssertEqual(reconstructed.payloadData, dto.payloadData)
    }

    func testNSXPCInterfaceConfiguration() {
        let interface = NSXPCInterface.makeMediaWorkerInterface()
        XCTAssertNotNil(interface)
    }
}
