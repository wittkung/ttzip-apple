// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

@preconcurrency import AVFoundation
import CoreAudioTypes
import CoreMedia
import Foundation
import TTMediaDemux

extension MediaAudioExtractPipeline {
    internal static let aacSampleRates: [Int] = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000,
        22050, 16000, 12000, 11025, 8000, 7350
    ]

    // MARK: - Rust Bitstream & Elementary Stream Extraction

    internal func executeRustBitstreamExtract(
        sourceURL: URL,
        stagingURL: URL,
        destinationURL: URL,
        options: MediaAudioExtractOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> MediaAudioExtractResult {
        guard options.trackIndex >= 0 else {
            throw MediaAudioExtractError.trackIndexOutOfRange(
                index: options.trackIndex,
                availableCount: 0
            )
        }
        let ext = sourceURL.pathExtension.lowercased()
        if Self.avFoundationISOBMFFExtensions.contains(ext) && options.mode == .elementaryStream {
            return try await executeISOBMFFElementaryStream(
                sourceURL: sourceURL,
                stagingURL: stagingURL,
                destinationURL: destinationURL,
                options: options,
                progressHandler: progressHandler
            )
        }
        progressHandler?(0.15)
        try await applySimulatedExtractDelayIfNeeded()

        let ffiStats = try invokeRustBitstreamExtractFFI(
            sourceURL: sourceURL,
            stagingURL: stagingURL,
            options: options
        )
        if Task.isCancelled {
            throw MediaAudioExtractError.cancelled
        }
        progressHandler?(0.85)

        let codec = MediaAudioExtractCodec(rawValue: ffiStats.codecRaw) ?? .unknown
        if options.mode == .encapsulatedM4a {
            let verified = try await verifyStagedM4AOutput(
                stagingURL: stagingURL,
                expectedChannels: Int(ffiStats.channelsRaw),
                expectedSampleRate: Double(ffiStats.sampleRateRaw)
            )
            return MediaAudioExtractResult(
                destinationURL: destinationURL,
                mode: .encapsulatedM4a,
                executionPath: .rustBitstreamExtract,
                codec: codec,
                trackIndex: options.trackIndex,
                channels: verified.channels,
                sampleRate: verified.sampleRate,
                packetCount: ffiStats.packetCount,
                durationSeconds: verified.durationSeconds,
                outputBytes: verified.outputBytes
            )
        }
        let verifiedBytes = try verifyStagedElementaryOutput(stagingURL: stagingURL, codec: codec)
        return MediaAudioExtractResult(
            destinationURL: destinationURL,
            mode: .elementaryStream,
            executionPath: .rustBitstreamExtract,
            codec: codec,
            trackIndex: options.trackIndex,
            channels: max(1, Int(ffiStats.channelsRaw)),
            sampleRate: Double(ffiStats.sampleRateRaw),
            packetCount: ffiStats.packetCount,
            durationSeconds: Double(ffiStats.durationMs) / 1000.0,
            outputBytes: verifiedBytes
        )
    }

    private func invokeRustBitstreamExtractFFI(
        sourceURL: URL,
        stagingURL: URL,
        options: MediaAudioExtractOptions
    ) throws -> (codecRaw: UInt32, channelsRaw: UInt32, sampleRateRaw: UInt32, packetCount: UInt64, durationMs: UInt64) {
        var codecRaw: UInt32 = 0
        var channelsRaw: UInt32 = 0
        var sampleRateRaw: UInt32 = 0
        var packetCount: UInt64 = 0
        var durationMs: UInt64 = 0
        var bytesWritten: UInt64 = 0
        let limitBytes = maxInMemoryInputBytes > 0 ? maxInMemoryInputBytes : (256 * 1024 * 1024)
        let status: Int32 = sourceURL.path.withCString { srcPtr in
            stagingURL.path.withCString { dstPtr in
                ttmedia_extract_audio_track_file(
                    srcPtr,
                    dstPtr,
                    options.mode.rawValue,
                    UInt32(options.trackIndex),
                    limitBytes,
                    &codecRaw,
                    &channelsRaw,
                    &sampleRateRaw,
                    &packetCount,
                    &durationMs,
                    &bytesWritten
                )
            }
        }
        try mapRustExtractStatus(status, sourceURL: sourceURL, options: options, limitBytes: limitBytes)
        return (codecRaw, channelsRaw, sampleRateRaw, packetCount, durationMs)
    }

    private func executeISOBMFFElementaryStream(
        sourceURL: URL,
        stagingURL: URL,
        destinationURL: URL,
        options: MediaAudioExtractOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> MediaAudioExtractResult {
        progressHandler?(0.15)
        try await applySimulatedExtractDelayIfNeeded()

        let sourceAsset = AVURLAsset(url: sourceURL)
        let (selectedTrack, descriptor, adtsProfileBits) = try await loadSelectedISOBMFFAudioTrack(
            from: sourceAsset,
            sourceURL: sourceURL,
            trackIndex: options.trackIndex
        )
        let packetCount = try readAndWriteISOBMFFElementaryPackets(
            from: selectedTrack,
            in: sourceAsset,
            descriptor: descriptor,
            adtsProfileBits: adtsProfileBits,
            sourceURL: sourceURL,
            stagingURL: stagingURL
        )
        progressHandler?(0.85)

        let verifiedBytes = try verifyStagedElementaryOutput(
            stagingURL: stagingURL,
            codec: descriptor.codec
        )
        let timeRange = (try? await selectedTrack.load(.timeRange)) ?? .zero
        let durationSec = max(0, CMTimeGetSeconds(timeRange.duration))
        return MediaAudioExtractResult(
            destinationURL: destinationURL,
            mode: .elementaryStream,
            executionPath: .rustBitstreamExtract,
            codec: descriptor.codec,
            trackIndex: options.trackIndex,
            channels: descriptor.channels,
            sampleRate: descriptor.sampleRate,
            packetCount: packetCount,
            durationSeconds: durationSec.isFinite ? durationSec : 0,
            outputBytes: verifiedBytes
        )
    }

    private func loadSelectedISOBMFFAudioTrack(
        from sourceAsset: AVAsset,
        sourceURL: URL,
        trackIndex: Int
    ) async throws -> (AVAssetTrack, MediaAudioTrackDescriptor, UInt8) {
        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw MediaAudioExtractError.noAudioTracksFound(sourceURL)
        }
        guard trackIndex >= 0, trackIndex < audioTracks.count else {
            throw MediaAudioExtractError.trackIndexOutOfRange(
                index: trackIndex,
                availableCount: audioTracks.count
            )
        }
        let selectedTrack = audioTracks[trackIndex]
        guard let descriptor = await buildDescriptor(for: selectedTrack, index: trackIndex),
              descriptor.codec != .unknown else {
            throw MediaAudioExtractError.unsupportedAudioCodec(
                "Source audio track \(trackIndex + 1) codec is not supported for elementary stream extraction."
            )
        }
        var adtsProfileBits: UInt8 = 1
        if descriptor.codec == .aac {
            let formatDescriptions = (try? await selectedTrack.load(.formatDescriptions)) ?? []
            guard let firstDesc = formatDescriptions.first else {
                throw MediaAudioExtractError.unsupportedAudioCodec(
                    "Missing AAC format description on track \(trackIndex + 1)."
                )
            }
            let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
            let asc = Self.extractAudioSpecificConfig(from: firstDesc)
            guard let resolvedProfile = Self.resolveADTSProfileBits(
                subType: subType,
                audioSpecificConfig: asc
            ) else {
                throw MediaAudioExtractError.unsupportedAudioCodec(
                    "Source AAC profile ('\(Self.fourCCString(subType))') on track \(trackIndex + 1) cannot be represented in an ADTS elementary stream."
                )
            }
            adtsProfileBits = resolvedProfile
        }
        return (selectedTrack, descriptor, adtsProfileBits)
    }

    private func readAndWriteISOBMFFElementaryPackets(
        from selectedTrack: AVAssetTrack,
        in sourceAsset: AVAsset,
        descriptor: MediaAudioTrackDescriptor,
        adtsProfileBits: UInt8,
        sourceURL: URL,
        stagingURL: URL
    ) throws -> UInt64 {
        let reader = try AVAssetReader(asset: sourceAsset)
        let output = AVAssetReaderTrackOutput(track: selectedTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaAudioExtractError.extractionFailed(
                "Unable to attach audio track output to AVAssetReader."
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            let reason = reader.error?.localizedDescription ?? "Failed to start reading audio track."
            throw MediaAudioExtractError.extractionFailed(reason)
        }

        var outData = Data()
        var packetCount: UInt64 = 0
        let sampleRateInt = Int(descriptor.sampleRate.rounded())
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw MediaAudioExtractError.cancelled
            }
            for packet in Self.extractCompressedPackets(from: sampleBuffer) where !packet.isEmpty {
                if descriptor.codec == .aac && !Self.hasADTSSyncWord(packet) {
                    let adtsHeader = Self.makeADTSHeader(
                        payloadLength: packet.count,
                        sampleRate: sampleRateInt,
                        channels: descriptor.channels,
                        profileBits: adtsProfileBits
                    )
                    outData.append(contentsOf: adtsHeader)
                }
                outData.append(packet)
                packetCount += 1
            }
        }
        if reader.status == .failed {
            let reason = reader.error?.localizedDescription ?? "Failed reading audio samples."
            throw MediaAudioExtractError.extractionFailed(reason)
        }
        guard packetCount > 0, !outData.isEmpty else {
            throw MediaAudioExtractError.noAudioTracksFound(sourceURL)
        }
        try outData.write(to: stagingURL, options: .atomic)
        return packetCount
    }

    private func mapRustExtractStatus(
        _ status: Int32,
        sourceURL: URL,
        options: MediaAudioExtractOptions,
        limitBytes: UInt64
    ) throws {
        switch status {
        case 0:
            return
        case -5:
            let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let fileBytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? (limitBytes + 1)
            throw MediaAudioExtractError.inputTooLargeForInMemoryExtract(
                sourceURL,
                fileBytes: fileBytes,
                limitBytes: limitBytes
            )
        case -6:
            throw MediaAudioExtractError.trackIndexOutOfRange(
                index: options.trackIndex,
                availableCount: 1
            )
        case -4:
            throw MediaAudioExtractError.unsupportedAudioCodec(
                "Source codec in \(sourceURL.lastPathComponent) is not supported for \(options.mode.displayName)."
            )
        case -2:
            throw MediaAudioExtractError.sourceFileNotFound(sourceURL)
        case -1:
            throw MediaAudioExtractError.extractionFailed("Invalid audio extract C-ABI arguments.")
        default:
            throw MediaAudioExtractError.noAudioTracksFound(sourceURL)
        }
    }

    // MARK: - Elementary Bitstream Framing & ADTS Synthesis

    internal static func hasADTSSyncWord(_ packet: Data) -> Bool {
        guard packet.count >= 7 else {
            return false
        }
        let firstByte = packet[packet.startIndex]
        let secondByte = packet[packet.startIndex + 1]
        return firstByte == 0xFF && (secondByte & 0xF6) == 0xF0
    }

    internal static func extractCompressedPackets(from sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return []
        }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else {
            return []
        }
        var rawBytes = [UInt8](repeating: 0, count: totalLength)
        let copyStatus = CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: totalLength,
            destination: &rawBytes
        )
        guard copyStatus == kCMBlockBufferNoErr else {
            return []
        }
        let fullData = Data(rawBytes)

        var descSizeNeeded: Int = 0
        CMSampleBufferGetAudioStreamPacketDescriptions(
            sampleBuffer,
            allocatedSize: 0,
            packetDescriptionsOut: nil,
            packetDescriptionsSizeNeededOut: &descSizeNeeded
        )
        let count = descSizeNeeded / MemoryLayout<AudioStreamPacketDescription>.stride
        guard count > 0 else {
            return [fullData]
        }

        var descriptions = [AudioStreamPacketDescription](
            repeating: AudioStreamPacketDescription(),
            count: count
        )
        let descStatus = descriptions.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetAudioStreamPacketDescriptions(
                sampleBuffer,
                allocatedSize: descSizeNeeded,
                packetDescriptionsOut: buffer.baseAddress,
                packetDescriptionsSizeNeededOut: nil
            )
        }
        guard descStatus == noErr else {
            return [fullData]
        }

        let packets = descriptions.compactMap { description -> Data? in
            let start = Int(description.mStartOffset)
            let size = Int(description.mDataByteSize)
            guard start >= 0 && size > 0 && start + size <= fullData.count else {
                return nil
            }
            return fullData.subdata(in: start..<(start + size))
        }
        return packets.isEmpty ? [fullData] : packets
    }

    internal static func makeADTSHeader(
        payloadLength: Int,
        sampleRate: Int,
        channels: Int,
        profileBits: UInt8 = 1
    ) -> [UInt8] {
        let freqIdx = UInt8(aacSampleRates.firstIndex(of: sampleRate) ?? 4)
        let chanCfg = UInt8(min(max(channels, 1), 7))
        let frameLen = min(payloadLength + 7, 0x1FFF)
        let byte2 = UInt8(((profileBits & 0x03) << 6) | ((freqIdx & 0x0F) << 2) | ((chanCfg >> 2) & 0x01))
        let byte3 = UInt8(((chanCfg & 0x03) << 6) | UInt8((frameLen >> 11) & 0x03))
        let byte4 = UInt8((frameLen >> 3) & 0xFF)
        let byte5 = UInt8(((frameLen & 0x07) << 5) | 0x1F)
        return [0xFF, 0xF1, byte2, byte3, byte4, byte5, 0xFC]
    }

    internal static func resolveADTSProfileBits(
        subType: FourCharCode,
        audioSpecificConfig: Data?
    ) -> UInt8? {
        guard subType == kAudioFormatMPEG4AAC else {
            return nil
        }
        guard let config = audioSpecificConfig, !config.isEmpty else {
            return 1
        }
        let aot = (config[config.startIndex] >> 3) & 0x1F
        guard (1...4).contains(aot) else {
            return nil
        }
        return UInt8(aot - 1)
    }

    private static func extractAudioSpecificConfig(
        from formatDescription: CMFormatDescription
    ) -> Data? {
        var cookieSize: Int = 0
        guard let cookiePtr = CMAudioFormatDescriptionGetMagicCookie(
            formatDescription,
            sizeOut: &cookieSize
        ), cookieSize > 0 else {
            return nil
        }
        let bytes = [UInt8](UnsafeBufferPointer(start: cookiePtr.assumingMemoryBound(to: UInt8.self), count: cookieSize))
        if bytes.count <= 4 {
            return Data(bytes)
        }
        for idx in 0..<(bytes.count - 2) where bytes[idx] == 0x05 {
            var lenIdx = idx + 1
            var length = 0
            while lenIdx < bytes.count && (bytes[lenIdx] & 0x80) != 0 {
                length = (length << 7) | Int(bytes[lenIdx] & 0x7F)
                lenIdx += 1
            }
            if lenIdx < bytes.count {
                length = (length << 7) | Int(bytes[lenIdx] & 0x7F)
                let start = lenIdx + 1
                if length >= 2, start + length <= bytes.count {
                    return Data(bytes[start..<(start + length)])
                }
            }
        }
        return nil
    }

    // MARK: - Container Header Audio Track Discovery

    internal static func discoverRustBitstreamAudioTracks(
        at sourceURL: URL,
        ext: String
    ) -> [MediaAudioTrackDescriptor] {
        guard let handle = try? FileHandle(forReadingFrom: sourceURL),
              let data = try? handle.read(upToCount: 262_144),
              !data.isEmpty else {
            return []
        }
        try? handle.close()

        let bytes = [UInt8](data)
        if isEBMLHeader(bytes) {
            return parseMKVAudioTracks(bytes)
        }
        if let flacDescriptor = parseFLACHeaderDescriptor(bytes) {
            return [flacDescriptor]
        }
        if let adtsDescriptor = parseADTSHeaderDescriptor(bytes) {
            return [adtsDescriptor]
        }

        let inferred = inferredCodec(forExtension: ext)
        return [
            MediaAudioTrackDescriptor(
                index: 0,
                trackID: 1,
                codec: inferred,
                codecFourCC: inferred.fileExtension,
                channels: 2,
                sampleRate: inferred == .opus ? 48000 : 44100
            )
        ]
    }

    private static func isEBMLHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else {
            return false
        }
        return bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3
    }

    private static func parseFLACHeaderDescriptor(_ bytes: [UInt8]) -> MediaAudioTrackDescriptor? {
        guard bytes.count >= 21,
              String(bytes: bytes[0..<4], encoding: .ascii) == "fLaC" else {
            return nil
        }
        let sampleRate = (Int(bytes[18]) << 12) | (Int(bytes[19]) << 4) | (Int(bytes[20]) >> 4)
        let channels = ((Int(bytes[20]) >> 1) & 0x07) + 1
        return MediaAudioTrackDescriptor(
            index: 0,
            trackID: 1,
            codec: .flac,
            codecFourCC: "flac",
            channels: max(1, channels),
            sampleRate: Double(sampleRate > 0 ? sampleRate : 44100)
        )
    }

    private static func parseADTSHeaderDescriptor(_ bytes: [UInt8]) -> MediaAudioTrackDescriptor? {
        guard bytes.count >= 7,
              bytes[0] == 0xFF,
              (bytes[1] & 0xF6) == 0xF0 else {
            return nil
        }
        let frequencyIndex = Int((bytes[2] >> 2) & 0x0F)
        let sampleRate = frequencyIndex < aacSampleRates.count ? aacSampleRates[frequencyIndex] : 44100
        let channels = Int(((bytes[2] & 0x01) << 2) | (bytes[3] >> 6))
        return MediaAudioTrackDescriptor(
            index: 0,
            trackID: 1,
            codec: .aac,
            codecFourCC: "aac",
            channels: max(1, channels),
            sampleRate: Double(sampleRate)
        )
    }

    private static func parseMKVAudioTracks(_ bytes: [UInt8]) -> [MediaAudioTrackDescriptor] {
        var offset = 0
        var descriptors: [MediaAudioTrackDescriptor] = []
        while let (elementID, contentStart, elementEnd) = nextEBML(bytes, offset: offset, limit: bytes.count) {
            if elementID == 0x1853_8067 {
                offset = contentStart
                continue
            }
            if elementID == 0x1654_AE6B {
                var trackOffset = contentStart
                while let (trackElementID, trackStart, trackEnd) = nextEBML(bytes, offset: trackOffset, limit: elementEnd) {
                    if trackElementID == 0xAE,
                       let descriptor = parseMKVTrackEntry(bytes, start: trackStart, end: trackEnd, index: descriptors.count) {
                        descriptors.append(descriptor)
                    }
                    trackOffset = trackEnd
                }
            }
            offset = elementEnd
        }
        return descriptors
    }

    private static func parseMKVTrackEntry(
        _ bytes: [UInt8],
        start: Int,
        end: Int,
        index: Int
    ) -> MediaAudioTrackDescriptor? {
        var offset = start
        var isAudio = false
        var trackID = Int32(index + 1)
        var codecID = ""
        var channels = 2
        var sampleRate = 0.0
        var codecPrivate: [UInt8] = []

        while let (subID, contentStart, contentEnd) = nextEBML(bytes, offset: offset, limit: end) {
            let slice = Array(bytes[contentStart..<contentEnd])
            switch subID {
            case 0xD7:
                guard let checkedTrackID = decodeBoundedInt32TrackID(slice) else {
                    return nil
                }
                trackID = checkedTrackID
            case 0x83:
                isAudio = (slice.first == 2)
            case 0x86:
                codecID = String(decoding: slice, as: UTF8.self)
            case 0x63A2:
                codecPrivate = slice
            case 0xE1:
                (channels, sampleRate) = parseMKVAudioSubElement(
                    bytes,
                    start: contentStart,
                    end: contentEnd,
                    defaultChannels: channels,
                    defaultRate: sampleRate
                )
            default:
                break
            }
            offset = contentEnd
        }

        guard isAudio else {
            return nil
        }
        let codec = classifyMKVCodecID(codecID)
        guard codec != .unknown else {
            return nil
        }
        let (resolvedChannels, resolvedRate) = resolveMKVAudioParameters(
            codec: codec,
            codecPrivate: codecPrivate,
            channels: channels,
            sampleRate: sampleRate
        )
        return MediaAudioTrackDescriptor(
            index: index,
            trackID: trackID,
            codec: codec,
            codecFourCC: codec.fileExtension,
            channels: resolvedChannels,
            sampleRate: resolvedRate
        )
    }

    private static func parseMKVAudioSubElement(
        _ bytes: [UInt8],
        start: Int,
        end: Int,
        defaultChannels: Int,
        defaultRate: Double
    ) -> (Int, Double) {
        var audioOffset = start
        var channels = defaultChannels
        var sampleRate = defaultRate

        while let (audioID, audioStart, audioEnd) = nextEBML(bytes, offset: audioOffset, limit: end) {
            let audioSlice = Array(bytes[audioStart..<audioEnd])
            if audioID == 0x9F {
                if let rawChannels = decodeBoundedUInt64(audioSlice),
                   let checkedChannels = Int(exactly: min(rawChannels, 64)) {
                    channels = max(1, checkedChannels)
                }
            } else if audioID == 0xB5 && audioSlice.count == 4 {
                let bits = audioSlice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                sampleRate = Double(Float(bitPattern: bits))
            } else if audioID == 0xB5 && audioSlice.count == 8 {
                let bits = audioSlice.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                sampleRate = Double(bitPattern: bits)
            }
            audioOffset = audioEnd
        }
        return (channels, sampleRate)
    }

    internal static func decodeBoundedUInt64(_ slice: [UInt8]) -> UInt64? {
        guard !slice.isEmpty, slice.count <= 8 else {
            return nil
        }
        return slice.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    internal static func decodeBoundedInt32TrackID(_ slice: [UInt8]) -> Int32? {
        guard let rawValue = decodeBoundedUInt64(slice),
              rawValue > 0,
              let trackID = Int32(exactly: rawValue) else {
            return nil
        }
        return trackID
    }

    private static func classifyMKVCodecID(_ codecID: String) -> MediaAudioExtractCodec {
        if codecID.contains("AAC") {
            return .aac
        }
        if codecID.contains("FLAC") {
            return .flac
        }
        if codecID.contains("OPUS") {
            return .opus
        }
        if codecID.contains("MPEG/L3") || codecID.contains("MP3") {
            return .mp3
        }
        return .unknown
    }

    internal static func sanitizeSampleRate(_ rawRate: Double) -> Double? {
        guard rawRate.isFinite, rawRate >= 800.0, rawRate <= 384_000.0 else {
            return nil
        }
        return rawRate
    }

    private static func resolveMKVAudioParameters(
        codec: MediaAudioExtractCodec,
        codecPrivate: [UInt8],
        channels: Int,
        sampleRate: Double
    ) -> (Int, Double) {
        var resolvedChannels = max(1, channels)
        var resolvedSampleRate = sanitizeSampleRate(sampleRate) ?? 0.0
        if resolvedSampleRate <= 0, codec == .aac, codecPrivate.count >= 2 {
            let frequencyIndex = Int(((codecPrivate[0] & 0x07) << 1) | (codecPrivate[1] >> 7))
            if frequencyIndex < aacSampleRates.count {
                resolvedSampleRate = Double(aacSampleRates[frequencyIndex])
            }
            let parsedChannels = Int((codecPrivate[1] >> 3) & 0x0F)
            if parsedChannels > 0 {
                resolvedChannels = parsedChannels
            }
        }
        if resolvedSampleRate <= 0 {
            resolvedSampleRate = (codec == .opus ? 48000 : 44100)
        }
        return (resolvedChannels, resolvedSampleRate)
    }

    private static func nextEBML(
        _ data: [UInt8],
        offset: Int,
        limit: Int
    ) -> (UInt32, Int, Int)? {
        let bound = min(limit, data.count)
        guard offset < bound else {
            return nil
        }
        let firstIDByte = data[offset]
        let idLength = firstIDByte.leadingZeroBitCount + 1
        guard (1...4).contains(idLength), offset + idLength < bound else {
            return nil
        }
        let elementID = data[offset..<(offset + idLength)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        let sizeOffset = offset + idLength
        let firstSizeByte = data[sizeOffset]
        let sizeLength = firstSizeByte.leadingZeroBitCount + 1
        guard (1...8).contains(sizeLength), sizeOffset + sizeLength <= bound else {
            return nil
        }
        let firstMasked = UInt64(firstSizeByte & (sizeLength == 8 ? 0 : (0xFF >> sizeLength)))
        let payloadSize = data[(sizeOffset + 1)..<(sizeOffset + sizeLength)].reduce(firstMasked) {
            ($0 << 8) | UInt64($1)
        }
        let contentStart = sizeOffset + sizeLength
        let contentEnd = min(bound, contentStart + Int(clamping: payloadSize))
        return (elementID, contentStart, contentEnd)
    }

    // MARK: - Codec Mapping Helpers

    internal static func mapAudioSubType(_ subType: FourCharCode) -> MediaAudioExtractCodec {
        switch subType {
        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:
            return .aac
        case kAudioFormatFLAC:
            return .flac
        case kAudioFormatOpus:
            return .opus
        case kAudioFormatMPEGLayer3:
            return .mp3
        default:
            return .unknown
        }
    }

    internal static func inferredCodec(forExtension ext: String) -> MediaAudioExtractCodec {
        switch ext.lowercased() {
        case "flac":
            return .flac
        case "opus", "ogg":
            return .opus
        case "mp3":
            return .mp3
        default:
            return .aac
        }
    }

    internal static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let trimmed = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unkn" : trimmed
    }
}
