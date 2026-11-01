// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension TTMediaCapabilityMatrix {

    internal static func probeISOBMFFContainerTracks(
        sample: Data,
        moovSample: Data?,
        isCompleteScan: Bool
    ) -> TTMediaMagicKind {
        guard sample.count >= 12 else { return .unknown }
        let boxType = String(bytes: sample.subdata(in: 4..<8), encoding: .isoLatin1) ?? ""
        let majorBrand = boxType == "ftyp" ? (String(bytes: sample.subdata(in: 8..<12), encoding: .isoLatin1) ?? "") : ""
        let imageBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis", "crx "]
        if boxType == "ftyp" && imageBrands.contains(majorBrand) {
            return .image(mime: majorBrand.hasPrefix("avi") ? "image/avif" : "image/heic")
        }

        if let trackWindow = moovSample, !trackWindow.isEmpty,
           let trackKind = resolveISOBMFFTrackKind(
               trackWindow: trackWindow, boxType: boxType, brand: majorBrand, isCompleteScan: isCompleteScan
           ) {
            return trackKind
        }
        let fallback = resolveISOBMFFBrandFallback(boxType: boxType, majorBrand: majorBrand)
        if !isCompleteScan, case .audio = fallback {
            return isQuickTimeBoxOrBrand(boxType: boxType, brand: majorBrand)
                ? .video(mime: "video/quicktime")
                : .video(mime: "video/mp4")
        }
        return fallback
    }

    internal static func resolveISOBMFFTrackKind(
        trackWindow: Data,
        boxType: String,
        brand: String,
        isCompleteScan: Bool
    ) -> TTMediaMagicKind? {
        let tracks = scanISOBMFFTrackHandlers(in: trackWindow)
        if tracks.hasVideo {
            return .video(mime: isQuickTimeBoxOrBrand(boxType: boxType, brand: brand) ? "video/quicktime" : "video/mp4")
        }
        if tracks.hasAudio {
            if isCompleteScan { return .audio(mime: "audio/mp4") }
            // Scan completeness contract: When scan is incomplete, an un-scanned video track may follow.
            // Under no circumstances can a container be classified as pure audio with incomplete moov scan.
            let fallback = resolveISOBMFFBrandFallback(boxType: boxType, majorBrand: brand)
            if case .video = fallback { return fallback }
            return isQuickTimeBoxOrBrand(boxType: boxType, brand: brand)
                ? .video(mime: "video/quicktime")
                : .video(mime: "video/mp4")
        }
        if tracks.hasPicture { return .image(mime: "image/heic") }
        return nil
    }

    internal static func isQuickTimeBoxOrBrand(boxType: String, brand: String) -> Bool {
        brand == "qt  " || boxType == "moov" || boxType == "wide"
    }

    internal static func resolveISOBMFFBrandFallback(boxType: String, majorBrand: String) -> TTMediaMagicKind {
        guard boxType == "ftyp" else { return .unknown }
        let explicitAudioBrands: Set<String> = ["M4A ", "M4B ", "M4R ", "F4A ", "F4B ", "mp4a"]
        if explicitAudioBrands.contains(majorBrand) { return .audio(mime: "audio/mp4") }
        let explicitVideoBrands: Set<String> = [
            "mp42", "M4V ", "m4v ", "F4V ", "f4v ", "qt  ", "3gp4", "3gp5", "3gp6", "3g2a"
        ]
        if explicitVideoBrands.contains(majorBrand) {
            return .video(mime: majorBrand == "qt  " ? "video/quicktime" : "video/mp4")
        }
        return .unknown
    }

    internal static func scanISOBMFFTrackHandlers(
        in data: Data
    ) -> (hasVideo: Bool, hasAudio: Bool, hasPicture: Bool) {
        let hdlrPrefix = Data([0x68, 0x64, 0x6C, 0x72, 0x00, 0x00, 0x00, 0x00])
        let vmhdBox = Data([0x76, 0x6D, 0x68, 0x64, 0x00, 0x00, 0x00, 0x01])
        let smhdBox = Data([0x73, 0x6D, 0x68, 0x64, 0x00, 0x00, 0x00, 0x00])
        var hasVideo = data.range(of: vmhdBox) != nil
        var hasAudio = data.range(of: smhdBox) != nil
        var hasPicture = false

        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let range = data.range(of: hdlrPrefix, in: searchStart..<data.endIndex) {
            if data.endIndex - range.lowerBound >= 16 {
                let handlerStart = range.lowerBound + 12
                let handler = String(bytes: data.subdata(in: handlerStart..<(handlerStart + 4)), encoding: .isoLatin1)
                if handler == "vide" { hasVideo = true }
                if handler == "soun" { hasAudio = true }
                if handler == "pict" || handler == "auxv" { hasPicture = true }
            }
            if data.endIndex - range.lowerBound <= 4 { break }
            searchStart = range.lowerBound + 4
        }
        return (hasVideo, hasAudio, hasPicture)
    }

    internal static func probeMatroskaContainerTracks(sample: Data) -> TTMediaMagicKind {
        let videoSignatures: [Data] = [
            Data([0x83, 0x81, 0x01]),
            Data("V_MPEG".utf8), Data("V_VP8".utf8), Data("V_VP9".utf8),
            Data("V_AV1".utf8), Data("V_MPEGH".utf8), Data("V_THEORA".utf8), Data("V_MS/".utf8)
        ]
        if videoSignatures.contains(where: { sample.range(of: $0) != nil }) {
            return .video(mime: "video/x-matroska")
        }
        let audioSignatures: [Data] = [
            Data([0x83, 0x81, 0x02]),
            Data("A_AAC".utf8), Data("A_VORBIS".utf8), Data("A_OPUS".utf8), Data("A_FLAC".utf8),
            Data("A_PCM".utf8), Data("A_MPEG".utf8), Data("A_AC3".utf8), Data("A_EAC3".utf8), Data("A_ALAC".utf8)
        ]
        if audioSignatures.contains(where: { sample.range(of: $0) != nil }) {
            return .audio(mime: "audio/x-matroska")
        }
        return .unknown
    }

    internal static func probeOggContainerTracks(sample: Data) -> TTMediaMagicKind {
        let videoBOS: [Data] = [
            Data([0x80, 0x74, 0x68, 0x65, 0x6F, 0x72, 0x61]),
            Data("BBCD\0".utf8), Data("\u{01}video\0\0".utf8), Data("OVP80".utf8)
        ]
        if videoBOS.contains(where: { sample.range(of: $0) != nil }) {
            return .video(mime: "video/ogg")
        }
        let audioBOS: [Data] = [
            Data([0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]),
            Data("OpusHead".utf8), Data([0x7F, 0x46, 0x4C, 0x41, 0x43]),
            Data("Speex   ".utf8), Data("\u{01}audio\0\0".utf8)
        ]
        if audioBOS.contains(where: { sample.range(of: $0) != nil }) {
            return .audio(mime: "audio/ogg")
        }
        return .unknown
    }

    internal static func probeASFContainerTracks(sample: Data) -> TTMediaMagicKind {
        let asfVideoMediaGUID = Data([
            0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11,
            0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B
        ])
        if sample.range(of: asfVideoMediaGUID) != nil {
            return .video(mime: "video/x-ms-asf")
        }
        let asfAudioMediaGUID = Data([
            0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11,
            0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B
        ])
        if sample.range(of: asfAudioMediaGUID) != nil {
            return .audio(mime: "audio/x-ms-wma")
        }
        return .unknown
    }

    internal static func probeRealMediaContainerTracks(sample: Data) -> TTMediaMagicKind {
        if sample.range(of: Data("video/x-pn-".utf8)) != nil {
            return .video(mime: "application/vnd.rn-realmedia")
        }
        if sample.range(of: Data("audio/x-pn-".utf8)) != nil ||
            sample.range(of: Data([0x2E, 0x72, 0x61, 0xFD])) != nil {
            return .audio(mime: "audio/x-pn-realaudio")
        }
        return .unknown
    }
}
