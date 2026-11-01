// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AVFoundation
import AudioToolbox
import Darwin

/// Evidence-based completeness verdict distinguishing justified codec encoder delay / remainder padding
/// from actual file or stream truncation.
public enum AudioStreamCompletenessProof: Sendable, Equatable {
    /// Container or bitstream carries an authoritative total-length header, packet table, or EOS marker,
    /// and the physical file on disk satisfies all declared bounds.
    case authoritative(
        expectedValidFrames: Int64,
        justifiedPrimingFrames: Int32,
        justifiedRemainderFrames: Int32
    )

    /// Headerless elementary packet stream (e.g., raw ADTS `.aac`, raw ATSC A/52 `.ac3`/`.eac3`, or CBR `.mp3`
    /// without `Xing`/`Info`/`VBRI` header) whose present packets end cleanly on a syncframe boundary,
    /// but which lacks a container total-length header or EOS marker to prove no whole packets were dropped at the tail.
    case unverifiedElementaryStream(
        expectedDecodedFrames: Int64,
        justifiedCodecPrimingFrames: Int32
    )

    /// Container chunk, ISO BMFF atom, Ogg EOS page, FLAC STREAMINFO, Xing header, or packet syncframe is truncated or corrupt.
    case rejectedTruncatedOrCorrupt
}

/// Validates physical container framing, EOS markers, packet tables, and codec priming/remainder metadata.
enum AudioContainerCompletenessValidator {
    /// ATSC A/52 (AC-3 / E-AC-3) fixed decoder priming latency: 256-sample MDCT overlap + 32-sample filterbank delay.
    static let atscA52MDCTPrimingFrames: Int32 = 288

    private static let ac3Words48k: [Int] = [
        64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192, 224, 224,
        256, 256, 320, 320, 384, 384, 448, 448, 512, 512, 640, 640, 768, 768, 896, 896,
        1024, 1024, 1152, 1152, 1280, 1280
    ]
    private static let ac3Words44k: [Int] = [
        69, 70, 87, 88, 104, 105, 121, 122, 139, 140, 174, 175, 208, 209, 243, 244,
        278, 279, 348, 349, 417, 418, 487, 488, 557, 558, 696, 697, 835, 836, 975, 976,
        1114, 1115, 1253, 1254, 1393, 1394
    ]
    private static let ac3Words32k: [Int] = [
        96, 96, 120, 120, 144, 144, 168, 168, 192, 192, 240, 240, 288, 288, 336, 336,
        384, 384, 480, 480, 576, 576, 672, 672, 768, 768, 960, 960, 1152, 1152, 1344, 1344,
        1536, 1536, 1728, 1728, 1920, 1920
    ]

    static func makeSequentialClientBuffer(
        extFile: ExtAudioFileRef,
        fileFormat: AudioStreamBasicDescription,
        bufferCapacity: AVAudioFrameCount
    ) -> (buffer: AVAudioPCMBuffer, channelCount: Int)? {
        let channelCount = AVAudioChannelCount(max(1, fileFormat.mChannelsPerFrame))
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: max(1.0, fileFormat.mSampleRate),
            channels: channelCount,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: bufferCapacity) else {
            return nil
        }

        var clientASBD = clientFormat.streamDescription.pointee
        let setStatus = ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard setStatus == noErr else { return nil }
        return (buffer, Int(channelCount))
    }

    static func evaluate(
        url: URL,
        extFile: ExtAudioFileRef,
        fileFormat: AudioStreamBasicDescription,
        fileLengthFrames: Int64
    ) -> AudioStreamCompletenessProof {
        guard fileLengthFrames > 0,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 12 else {
            return .rejectedTruncatedOrCorrupt
        }

        let packetTable = queryPacketTableInfo(extFile: extFile)
        let magic4 = String(bytes: data.prefix(4), encoding: .ascii) ?? ""

        if magic4 == "RIFF" {
            return validateRIFFWave(data: data, fileLengthFrames: fileLengthFrames)
        }
        if magic4 == "FORM" {
            return validateFORMAiff(data: data, fileLengthFrames: fileLengthFrames)
        }
        if magic4 == "caff" {
            return validateCAF(data: data, fileLengthFrames: fileLengthFrames)
        }
        if magic4 == ".snd" {
            return validateAuSnd(data: data, fileLengthFrames: fileLengthFrames)
        }
        if magic4 == "fLaC" {
            return validateFLAC(data: data, fileLengthFrames: fileLengthFrames, packetTable: packetTable)
        }
        if magic4 == "OggS" {
            return validateOggBitstream(data: data, fileLengthFrames: fileLengthFrames, packetTable: packetTable)
        }
        if data.count >= 8, String(bytes: data[4..<8], encoding: .ascii) == "ftyp" {
            return validateISOBMFF(data: data, fileLengthFrames: fileLengthFrames, packetTable: packetTable)
        }

        return validatePacketStream(
            data: data,
            extFile: extFile,
            formatID: fileFormat.mFormatID,
            fileLengthFrames: fileLengthFrames,
            packetTable: packetTable
        )
    }

    // MARK: - Container Validators

    private static func validateRIFFWave(data: Data, fileLengthFrames: Int64) -> AudioStreamCompletenessProof {
        guard data.count >= 44,
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else {
            return .rejectedTruncatedOrCorrupt
        }
        let riffSize = Int64(readUInt32LE(data, at: 4))
        guard riffSize <= Int64(data.count - 8) else { return .rejectedTruncatedOrCorrupt }

        var offset = 12
        var foundDataChunk = false
        while data.count - offset >= 8 {
            let chunkID = String(bytes: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let chunkSize = Int64(readUInt32LE(data, at: offset + 4))
            let payloadStart = offset + 8
            let remainingBytes = Int64(data.count - payloadStart)
            guard chunkSize <= remainingBytes else { return .rejectedTruncatedOrCorrupt }
            if chunkID == "data" {
                foundDataChunk = chunkSize > 0
                break
            }
            let paddedAdvance = chunkSize + (chunkSize & 1)
            offset = payloadStart + Int(min(paddedAdvance, remainingBytes))
        }
        guard foundDataChunk else { return .rejectedTruncatedOrCorrupt }
        return .authoritative(expectedValidFrames: fileLengthFrames, justifiedPrimingFrames: 0, justifiedRemainderFrames: 0)
    }

    private static func validateFORMAiff(data: Data, fileLengthFrames: Int64) -> AudioStreamCompletenessProof {
        guard data.count >= 12 else { return .rejectedTruncatedOrCorrupt }
        let formType = String(bytes: data[8..<12], encoding: .ascii) ?? ""
        guard formType == "AIFF" || formType == "AIFC" else { return .rejectedTruncatedOrCorrupt }
        let formSize = Int64(readUInt32BE(data, at: 4))
        guard formSize <= Int64(data.count - 8) else { return .rejectedTruncatedOrCorrupt }

        var offset = 12
        var foundSSND = false
        while data.count - offset >= 8 {
            let chunkID = String(bytes: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let chunkSize = Int64(readUInt32BE(data, at: offset + 4))
            let payloadStart = offset + 8
            let remainingBytes = Int64(data.count - payloadStart)
            guard chunkSize <= remainingBytes else { return .rejectedTruncatedOrCorrupt }
            if chunkID == "SSND" {
                foundSSND = chunkSize > 8
                break
            }
            let paddedAdvance = chunkSize + (chunkSize & 1)
            offset = payloadStart + Int(min(paddedAdvance, remainingBytes))
        }
        guard foundSSND else { return .rejectedTruncatedOrCorrupt }
        return .authoritative(expectedValidFrames: fileLengthFrames, justifiedPrimingFrames: 0, justifiedRemainderFrames: 0)
    }

    internal static func validateCAF(data: Data, fileLengthFrames: Int64) -> AudioStreamCompletenessProof {
        guard data.count >= 8,
              String(bytes: data[0..<4], encoding: .ascii) == "caff" else {
            return .rejectedTruncatedOrCorrupt
        }
        var offset = 8
        var hasExplicitDataBounds = false
        while data.count - offset >= 12 {
            let chunkType = String(bytes: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let chunkSize = readInt64BE(data, at: offset + 4)
            let payloadStart = offset + 12
            let remainingBytes = Int64(data.count - payloadStart)
            if chunkType == "data" {
                if chunkSize == -1 {
                    guard remainingBytes >= 4 else { return .rejectedTruncatedOrCorrupt }
                    return .unverifiedElementaryStream(
                        expectedDecodedFrames: fileLengthFrames,
                        justifiedCodecPrimingFrames: 0
                    )
                }
                guard chunkSize >= 4, chunkSize <= remainingBytes else {
                    return .rejectedTruncatedOrCorrupt
                }
                hasExplicitDataBounds = true
            } else {
                guard chunkSize >= 0, chunkSize <= remainingBytes else {
                    return .rejectedTruncatedOrCorrupt
                }
            }
            offset = payloadStart + Int(chunkSize)
        }
        guard hasExplicitDataBounds, offset == data.count else { return .rejectedTruncatedOrCorrupt }
        return .authoritative(expectedValidFrames: fileLengthFrames, justifiedPrimingFrames: 0, justifiedRemainderFrames: 0)
    }

    private static func validateAuSnd(data: Data, fileLengthFrames: Int64) -> AudioStreamCompletenessProof {
        guard data.count >= 24 else { return .rejectedTruncatedOrCorrupt }
        let dataOffset = readUInt32BE(data, at: 4)
        let dataSize = readUInt32BE(data, at: 8)
        guard dataOffset >= 24, Int(dataOffset) < data.count else { return .rejectedTruncatedOrCorrupt }
        if dataSize == 0xFFFF_FFFF {
            return .unverifiedElementaryStream(expectedDecodedFrames: fileLengthFrames, justifiedCodecPrimingFrames: 0)
        }
        guard Int64(dataOffset) + Int64(dataSize) <= Int64(data.count) else {
            return .rejectedTruncatedOrCorrupt
        }
        return .authoritative(expectedValidFrames: fileLengthFrames, justifiedPrimingFrames: 0, justifiedRemainderFrames: 0)
    }

    private static func validateISOBMFF(
        data: Data,
        fileLengthFrames: Int64,
        packetTable: AudioFilePacketTableInfo?
    ) -> AudioStreamCompletenessProof {
        var offset = 0
        var hasMoov = false
        var hasMdat = false
        while offset + 8 <= data.count {
            let size32 = readUInt32BE(data, at: offset)
            let boxType = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii) ?? ""
            let boxSize: Int
            if size32 == 1 {
                guard offset + 16 <= data.count else { return .rejectedTruncatedOrCorrupt }
                let size64 = readInt64BE(data, at: offset + 8)
                guard size64 >= 16, size64 <= Int64(data.count - offset) else { return .rejectedTruncatedOrCorrupt }
                boxSize = Int(size64)
            } else if size32 == 0 {
                return .rejectedTruncatedOrCorrupt
            } else {
                guard size32 >= 8, Int(size32) <= data.count - offset else { return .rejectedTruncatedOrCorrupt }
                boxSize = Int(size32)
            }
            if boxType == "moov" { hasMoov = true }
            if boxType == "mdat" { hasMdat = boxSize > 8 }
            offset += boxSize
        }
        guard offset == data.count, hasMoov, hasMdat,
              let pti = packetTable, pti.mNumberValidFrames > 0,
              pti.mNumberValidFrames == fileLengthFrames else {
            return .rejectedTruncatedOrCorrupt
        }
        return .authoritative(
            expectedValidFrames: pti.mNumberValidFrames,
            justifiedPrimingFrames: pti.mPrimingFrames,
            justifiedRemainderFrames: pti.mRemainderFrames
        )
    }

    private static func validateFLAC(
        data: Data,
        fileLengthFrames: Int64,
        packetTable: AudioFilePacketTableInfo?
    ) -> AudioStreamCompletenessProof {
        var offset = 4
        var totalSamples: UInt64 = 0
        var reachedLastMetadataBlock = false
        while offset + 4 <= data.count {
            let headerByte = data[offset]
            let isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let blockLen = (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            guard blockType != 127, offset + 4 + blockLen <= data.count else { return .rejectedTruncatedOrCorrupt }
            if blockType == 0, blockLen == 34 {
                let sOffset = offset + 4 + 13
                let b0 = UInt64(data[sOffset] & 0x0F) << 32
                let b1 = UInt64(data[sOffset + 1]) << 24
                let b2 = UInt64(data[sOffset + 2]) << 16
                let b3 = UInt64(data[sOffset + 3]) << 8
                let b4 = UInt64(data[sOffset + 4])
                totalSamples = b0 | b1 | b2 | b3 | b4
            }
            offset += 4 + blockLen
            if isLast {
                reachedLastMetadataBlock = true
                break
            }
        }
        guard reachedLastMetadataBlock, offset < data.count else { return .rejectedTruncatedOrCorrupt }
        guard totalSamples > 0 else {
            return .unverifiedElementaryStream(expectedDecodedFrames: fileLengthFrames, justifiedCodecPrimingFrames: 0)
        }
        guard Int64(totalSamples) == fileLengthFrames else { return .rejectedTruncatedOrCorrupt }
        return .authoritative(
            expectedValidFrames: Int64(totalSamples),
            justifiedPrimingFrames: packetTable?.mPrimingFrames ?? 0,
            justifiedRemainderFrames: packetTable?.mRemainderFrames ?? 0
        )
    }

    private static func validateOggBitstream(
        data: Data,
        fileLengthFrames: Int64,
        packetTable: AudioFilePacketTableInfo?
    ) -> AudioStreamCompletenessProof {
        var offset = 0
        var pageCount = 0
        var sawBOS = false
        var lastPageFlags: UInt8 = 0
        while offset + 27 <= data.count {
            guard data[offset] == 0x4F, data[offset + 1] == 0x67,
                  data[offset + 2] == 0x67, data[offset + 3] == 0x53,
                  data[offset + 4] == 0 else {
                return .rejectedTruncatedOrCorrupt
            }
            let flags = data[offset + 5]
            let numSegments = Int(data[offset + 26])
            guard offset + 27 + numSegments <= data.count else { return .rejectedTruncatedOrCorrupt }
            var bodyBytes = 0
            for i in 0..<numSegments {
                bodyBytes += Int(data[offset + 27 + i])
            }
            let pageBytes = 27 + numSegments + bodyBytes
            guard offset + pageBytes <= data.count else { return .rejectedTruncatedOrCorrupt }
            if pageCount == 0 {
                sawBOS = (flags & 0x02) != 0
            }
            lastPageFlags = flags
            offset += pageBytes
            pageCount += 1
        }
        let hasEOS = (lastPageFlags & 0x04) != 0
        guard offset == data.count, pageCount >= 2, sawBOS, hasEOS,
              let pti = packetTable, pti.mNumberValidFrames > 0,
              pti.mNumberValidFrames == fileLengthFrames else {
            return .rejectedTruncatedOrCorrupt
        }
        return .authoritative(
            expectedValidFrames: pti.mNumberValidFrames,
            justifiedPrimingFrames: pti.mPrimingFrames,
            justifiedRemainderFrames: pti.mRemainderFrames
        )
    }

    // MARK: - Packet Stream Validators (MP3, ADTS AAC, AC-3, E-AC-3)

    private static func validatePacketStream(
        data: Data,
        extFile: ExtAudioFileRef,
        formatID: AudioFormatID,
        fileLengthFrames: Int64,
        packetTable: AudioFilePacketTableInfo?
    ) -> AudioStreamCompletenessProof {
        let (_, packetCount) = queryAudioDataBounds(extFile: extFile)
        let payloadStart = skipLeadingID3v2(data: data)
        let payloadEnd = trimTrailingID3v1(data: data, minOffset: payloadStart)
        guard payloadStart < payloadEnd, packetCount > 0 else { return .rejectedTruncatedOrCorrupt }

        if formatID == kAudioFormatMPEGLayer3 {
            return validateMP3Stream(
                data: data,
                payloadStart: payloadStart,
                payloadEnd: payloadEnd,
                fileLengthFrames: fileLengthFrames,
                packetTable: packetTable
            )
        }
        if formatID == kAudioFormatMPEG4AAC {
            let walked = walkADTSFrames(data: data, startOffset: payloadStart, endOffset: payloadEnd)
            guard walked.complete, walked.packets == Int(packetCount) else {
                return .rejectedTruncatedOrCorrupt
            }
            return .unverifiedElementaryStream(expectedDecodedFrames: fileLengthFrames, justifiedCodecPrimingFrames: 0)
        }
        if formatID == kAudioFormatAC3 || formatID == kAudioFormatEnhancedAC3 {
            let walked = walkAC3OrEAC3Syncframes(data: data, startOffset: payloadStart, endOffset: payloadEnd)
            guard walked.complete, walked.packets == Int(packetCount) else {
                return .rejectedTruncatedOrCorrupt
            }
            let expectedDecoded = fileLengthFrames - Int64(atscA52MDCTPrimingFrames)
            guard expectedDecoded > 0 else { return .rejectedTruncatedOrCorrupt }
            return .unverifiedElementaryStream(
                expectedDecodedFrames: expectedDecoded,
                justifiedCodecPrimingFrames: atscA52MDCTPrimingFrames
            )
        }
        return .rejectedTruncatedOrCorrupt
    }

    private static func validateMP3Stream(
        data: Data,
        payloadStart: Int,
        payloadEnd: Int,
        fileLengthFrames: Int64,
        packetTable: AudioFilePacketTableInfo?
    ) -> AudioStreamCompletenessProof {
        guard let firstHeader = parseMPEGFrameHeader(data: data, at: payloadStart),
              payloadStart + firstHeader.frameBytes <= payloadEnd else {
            return .rejectedTruncatedOrCorrupt
        }

        let xingInfo = parseXingOrInfoHeader(data: data, frameOffset: payloadStart, header: firstHeader)
        let audioWalkStart = xingInfo != nil ? (payloadStart + firstHeader.frameBytes) : payloadStart
        let walked = walkMPEGFrames(data: data, startOffset: audioWalkStart, endOffset: payloadEnd)
        guard walked.complete else { return .rejectedTruncatedOrCorrupt }

        if let xing = xingInfo {
            guard payloadStart + Int(xing.declaredBytes) <= payloadEnd,
                  walked.packets == Int(xing.declaredFrames),
                  Int64(xing.declaredFrames) * Int64(firstHeader.samplesPerFrame) == fileLengthFrames else {
                return .rejectedTruncatedOrCorrupt
            }
            return .authoritative(
                expectedValidFrames: fileLengthFrames,
                justifiedPrimingFrames: xing.encoderDelay,
                justifiedRemainderFrames: xing.endPadding
            )
        }

        if let pti = packetTable, pti.mNumberValidFrames > 0, pti.mNumberValidFrames == fileLengthFrames {
            return .authoritative(
                expectedValidFrames: pti.mNumberValidFrames,
                justifiedPrimingFrames: pti.mPrimingFrames,
                justifiedRemainderFrames: pti.mRemainderFrames
            )
        }

        return .unverifiedElementaryStream(expectedDecodedFrames: fileLengthFrames, justifiedCodecPrimingFrames: 0)
    }

    // MARK: - Frame Header Walkers

    private static func walkMPEGFrames(data: Data, startOffset: Int, endOffset: Int) -> (complete: Bool, packets: Int) {
        var offset = startOffset
        var packets = 0
        while offset < endOffset {
            guard let hdr = parseMPEGFrameHeader(data: data, at: offset),
                  hdr.frameBytes >= 24,
                  offset + hdr.frameBytes <= endOffset else {
                return (false, packets)
            }
            offset += hdr.frameBytes
            packets += 1
        }
        return (offset == endOffset && packets > 0, packets)
    }

    private static func parseMPEGFrameHeader(
        data: Data,
        at offset: Int
    ) -> (frameBytes: Int, samplesPerFrame: Int, sideInfoBytes: Int)? {
        guard offset + 4 <= data.count else { return nil }
        let b0 = data[offset], b1 = data[offset + 1], b2 = data[offset + 2], b3 = data[offset + 3]
        guard b0 == 0xFF, (b1 & 0xE0) == 0xE0 else { return nil }
        let versionBits = (b1 >> 3) & 0x03
        let layerBits = (b1 >> 1) & 0x03
        guard versionBits != 1, layerBits == 1 else { return nil }
        let bitrateIdx = Int((b2 >> 4) & 0x0F)
        let srIdx = Int((b2 >> 2) & 0x03)
        let padding = Int((b2 >> 1) & 0x01)
        let channelMode = (b3 >> 6) & 0x03
        guard bitrateIdx > 0, bitrateIdx < 15, srIdx < 3 else { return nil }

        let bitratesMPEG1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        let bitratesMPEG2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
        let srTable = versionBits == 3 ? [44100, 48000, 32000] : (versionBits == 2 ? [22050, 24000, 16000] : [11025, 12000, 8000])
        let isMPEG1 = (versionBits == 3)
        let bitrate = (isMPEG1 ? bitratesMPEG1[bitrateIdx] : bitratesMPEG2[bitrateIdx]) * 1000
        let sampleRate = srTable[srIdx]
        let samplesPerFrame = isMPEG1 ? 1152 : 576
        let frameBytes = ((isMPEG1 ? 144 : 72) * bitrate) / sampleRate + padding
        let isMono = (channelMode == 3)
        let sideInfoBytes = isMPEG1 ? (isMono ? 17 : 32) : (isMono ? 9 : 17)
        return (frameBytes, samplesPerFrame, sideInfoBytes)
    }

    private static func parseXingOrInfoHeader(
        data: Data,
        frameOffset: Int,
        header: (frameBytes: Int, samplesPerFrame: Int, sideInfoBytes: Int)
    ) -> (declaredFrames: UInt32, declaredBytes: UInt32, encoderDelay: Int32, endPadding: Int32)? {
        let xingPos = frameOffset + 4 + header.sideInfoBytes
        guard xingPos + 16 <= frameOffset + header.frameBytes,
              xingPos + 16 <= data.count else {
            return nil
        }
        let tag = String(bytes: data[xingPos..<xingPos + 4], encoding: .ascii) ?? ""
        guard tag == "Xing" || tag == "Info" else { return nil }
        let flags = readUInt32BE(data, at: xingPos + 4)
        guard (flags & 0x03) == 0x03 else { return nil }
        let declaredFrames = readUInt32BE(data, at: xingPos + 8)
        let declaredBytes = readUInt32BE(data, at: xingPos + 12)
        guard declaredFrames > 0, declaredBytes > 0 else { return nil }

        var encoderDelay: Int32 = 0
        var endPadding: Int32 = 0
        let lameOffset = xingPos + 120
        if lameOffset + 24 <= frameOffset + header.frameBytes, lameOffset + 24 <= data.count {
            let d0 = Int32(data[lameOffset + 21])
            let d1 = Int32(data[lameOffset + 22])
            let d2 = Int32(data[lameOffset + 23])
            encoderDelay = (d0 << 4) | (d1 >> 4)
            endPadding = ((d1 & 0x0F) << 8) | d2
        }
        return (declaredFrames, declaredBytes, encoderDelay, endPadding)
    }

    private static func walkADTSFrames(data: Data, startOffset: Int, endOffset: Int) -> (complete: Bool, packets: Int) {
        var offset = startOffset
        var packets = 0
        while offset < endOffset {
            guard offset + 7 <= endOffset,
                  data[offset] == 0xFF,
                  (data[offset + 1] & 0xF6) == 0xF0 else {
                return (false, packets)
            }
            let b3 = Int(data[offset + 3] & 0x03) << 11
            let b4 = Int(data[offset + 4]) << 3
            let b5 = Int(data[offset + 5] >> 5)
            let frameLen = b3 | b4 | b5
            guard frameLen >= 7, offset + frameLen <= endOffset else {
                return (false, packets)
            }
            offset += frameLen
            packets += 1
        }
        return (offset == endOffset && packets > 0, packets)
    }

    private static func walkAC3OrEAC3Syncframes(
        data: Data,
        startOffset: Int,
        endOffset: Int
    ) -> (complete: Bool, packets: Int) {
        var offset = startOffset
        var packets = 0
        while offset < endOffset {
            guard offset + 6 <= endOffset,
                  data[offset] == 0x0B,
                  data[offset + 1] == 0x77 else {
                return (false, packets)
            }
            let bsid = (data[offset + 5] >> 3) & 0x1F
            let frameBytes: Int
            if bsid <= 10 {
                let fscod = (data[offset + 4] >> 6) & 0x03
                let frmsizcod = Int(data[offset + 4] & 0x3F)
                guard frmsizcod < 38 else { return (false, packets) }
                switch fscod {
                case 0: frameBytes = ac3Words48k[frmsizcod] * 2
                case 1: frameBytes = ac3Words44k[frmsizcod] * 2
                case 2: frameBytes = ac3Words32k[frmsizcod] * 2
                default: return (false, packets)
                }
            } else if bsid <= 16 {
                let frmsiz = (Int(data[offset + 2] & 0x07) << 8) | Int(data[offset + 3])
                frameBytes = (frmsiz + 1) * 2
            } else {
                return (false, packets)
            }
            guard frameBytes >= 6, offset + frameBytes <= endOffset else {
                return (false, packets)
            }
            offset += frameBytes
            packets += 1
        }
        return (offset == endOffset && packets > 0, packets)
    }

    // MARK: - Low-Level Helpers

    private static func queryPacketTableInfo(extFile: ExtAudioFileRef) -> AudioFilePacketTableInfo? {
        var audioFile: AudioFileID?
        var afSize = UInt32(MemoryLayout<AudioFileID>.size)
        guard ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_AudioFile, &afSize, &audioFile) == noErr,
              let af = audioFile else {
            return nil
        }
        var pti = AudioFilePacketTableInfo()
        var ptiSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        guard AudioFileGetProperty(af, kAudioFilePropertyPacketTableInfo, &ptiSize, &pti) == noErr else {
            return nil
        }
        return pti
    }

    private static func queryAudioDataBounds(extFile: ExtAudioFileRef) -> (dataOffset: Int64, packetCount: UInt64) {
        var audioFile: AudioFileID?
        var afSize = UInt32(MemoryLayout<AudioFileID>.size)
        guard ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_AudioFile, &afSize, &audioFile) == noErr,
              let af = audioFile else {
            return (0, 0)
        }
        var dataOffset: Int64 = 0
        var s1 = UInt32(MemoryLayout<Int64>.size)
        _ = AudioFileGetProperty(af, kAudioFilePropertyDataOffset, &s1, &dataOffset)
        var packetCount: UInt64 = 0
        var s2 = UInt32(MemoryLayout<UInt64>.size)
        _ = AudioFileGetProperty(af, kAudioFilePropertyAudioDataPacketCount, &s2, &packetCount)
        return (dataOffset, packetCount)
    }

    private static func skipLeadingID3v2(data: Data) -> Int {
        guard data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return 0 }
        let s0 = Int(data[6] & 0x7F) << 21
        let s1 = Int(data[7] & 0x7F) << 14
        let s2 = Int(data[8] & 0x7F) << 7
        let s3 = Int(data[9] & 0x7F)
        let tagEnd = 10 + (s0 | s1 | s2 | s3)
        return min(tagEnd, data.count)
    }

    private static func trimTrailingID3v1(data: Data, minOffset: Int) -> Int {
        guard data.count - minOffset >= 128 else { return data.count }
        let tagStart = data.count - 128
        if data[tagStart] == 0x54, data[tagStart + 1] == 0x41, data[tagStart + 2] == 0x47 {
            return tagStart
        }
        return data.count
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readInt64BE(_ data: Data, at offset: Int) -> Int64 {
        let hi = Int64(readUInt32BE(data, at: offset))
        let lo = Int64(readUInt32BE(data, at: offset + 4))
        return (hi << 32) | (lo & 0xFFFF_FFFF)
    }

    // MARK: - Resource Version Signature & Multi-Window Content Digest

    static func computeResourceSignature(forPath path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_size > 0 else { return nil }
        let digest = sampleContentDigest(forPath: path, fileSize: st.st_size)
        return "\(st.st_dev)_\(st.st_ino)_\(st.st_size)_\(st.st_mtimespec.tv_sec)_\(st.st_mtimespec.tv_nsec)_\(st.st_ctimespec.tv_sec)_\(st.st_ctimespec.tv_nsec)_\(digest)"
    }

    private static func sampleContentDigest(forPath path: String, fileSize: off_t) -> UInt64 {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }

        var hash: UInt64 = 14695981039346656037
        let chunkSize = 4096
        let windowCount = 16
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        if fileSize <= off_t(chunkSize * windowCount) {
            var offset: off_t = 0
            while offset < fileSize {
                let bytesRead = pread(fd, &buffer, chunkSize, offset)
                guard bytesRead > 0 else { break }
                for i in 0..<bytesRead {
                    hash ^= UInt64(buffer[i])
                    hash &*= 1099511628211
                }
                offset += off_t(bytesRead)
            }
            return hash
        }

        let maxStart = max(0, fileSize - off_t(chunkSize))
        for w in 0..<windowCount {
            let offset = (maxStart * off_t(w)) / off_t(windowCount - 1)
            let bytesRead = pread(fd, &buffer, chunkSize, offset)
            if bytesRead > 0 {
                for i in 0..<bytesRead {
                    hash ^= UInt64(buffer[i])
                    hash &*= 1099511628211
                }
            }
        }
        return hash
    }
}
