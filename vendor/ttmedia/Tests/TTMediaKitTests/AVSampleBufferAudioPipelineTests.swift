// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import CoreMedia
@preconcurrency import AVFoundation
import AudioToolbox
@testable import TTMediaKit

final class AVSampleBufferAudioPipelineTests: XCTestCase {

    func testAC3FormatDescriptionCreation() throws {
        let pipeline = AVSampleBufferAudioPipeline()
        let params = AudioFormatParameters(
            codec: .ac3,
            sampleRate: 48000.0,
            channelCount: 6,
            bitsPerChannel: 16,
            channelLayoutTag: kAudioChannelLayoutTag_AudioUnit_5_1,
            extradata: Data()
        )

        let desc = try pipeline.createAudioFormatDescription(from: params)
        let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        XCTAssertNotNil(asbdPtr)
        
        let asbd = asbdPtr!.pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatAC3)
        XCTAssertEqual(asbd.mFramesPerPacket, 1536)
        XCTAssertEqual(asbd.mChannelsPerFrame, 6)
        XCTAssertEqual(asbd.mSampleRate, 48000.0)
    }

    func testEAC3FormatDescriptionCreation() throws {
        let pipeline = AVSampleBufferAudioPipeline()
        let params = AudioFormatParameters(
            codec: .eac3,
            sampleRate: 48000.0,
            channelCount: 6,
            bitsPerChannel: 16,
            channelLayoutTag: kAudioChannelLayoutTag_AudioUnit_5_1,
            extradata: Data()
        )

        let desc = try pipeline.createAudioFormatDescription(from: params)
        let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        XCTAssertNotNil(asbdPtr)

        let asbd = asbdPtr!.pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatEnhancedAC3)
        XCTAssertEqual(asbd.mFramesPerPacket, 1536)
        XCTAssertEqual(asbd.mChannelsPerFrame, 6)
    }

    func testAACFormatDescriptionCreation() throws {
        let pipeline = AVSampleBufferAudioPipeline()
        let params = AudioFormatParameters(
            codec: .aac,
            sampleRate: 44100.0,
            channelCount: 2,
            bitsPerChannel: 16,
            channelLayoutTag: kAudioChannelLayoutTag_Stereo,
            extradata: Data()
        )

        let desc = try pipeline.createAudioFormatDescription(from: params)
        let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        XCTAssertNotNil(asbdPtr)

        let asbd = asbdPtr!.pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mFramesPerPacket, 1024)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    }

    func testReconstructAndEnqueueAC3Packet() throws {
        let renderer = AVSampleBufferAudioRenderer()
        let pipeline = AVSampleBufferAudioPipeline(audioRenderer: renderer)

        let params = AudioFormatParameters(
            codec: .ac3,
            sampleRate: 48000.0,
            channelCount: 6,
            bitsPerChannel: 16,
            channelLayoutTag: kAudioChannelLayoutTag_AudioUnit_5_1,
            extradata: Data()
        )
        let desc = try pipeline.createAudioFormatDescription(from: params)

        // Mock 1536-byte AC3 sync frame starting with 0x0B77
        var rawAC3 = Data(count: 1536)
        rawAC3[0] = 0x0B
        rawAC3[1] = 0x77

        let packet = try MediaPacketDTO(
            streamIndex: 2,
            mediaType: .audio,
            ptsValue: 0,
            ptsTimescale: 1000,
            dtsValue: 0,
            dtsTimescale: 1000,
            durationValue: 32,
            durationTimescale: 1000,
            payloadData: rawAC3,
            isKeyframe: true,
            doNotDisplay: false,
            ioSurfaceId: nil
        )

        XCTAssertNoThrow(try pipeline.reconstructAndEnqueue(packet: packet, formatDescription: desc))
    }
}
