// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import CMPVBridge
import TTZipCore
import TTZipUI

extension MPVMetalPlayerStore {
    
    // MARK: - Media Parameter Snapshot & Codec Formatting
    
    nonisolated public static func extractMediaParamsSnapshot(handle: OpaquePointer) -> MPVMediaParamsSnapshot {
        var w: Int64 = 0, h: Int64 = 0
        mpv_get_property(handle, "video-params/w", MPV_FORMAT_INT64, &w)
        mpv_get_property(handle, "video-params/h", MPV_FORMAT_INT64, &h)
        
        let gamma = getMpvString(handle, "video-params/gamma")?.lowercased() ?? ""
        let primaries = getMpvString(handle, "video-params/primaries")?.lowercased() ?? ""
        var detectedHDR: MPVHDRFormat = .sdr
        if gamma.contains("pq") || primaries.contains("bt.2020") {
            detectedHDR = .hdr10
        } else if gamma.contains("dovi") || primaries.contains("dovi") {
            detectedHDR = .dolbyVision
        } else if gamma.contains("hlg") {
            detectedHDR = .hlg
        }
        
        var sampleRateStr = "--"
        var sr: Int64 = 0
        if mpv_get_property(handle, "audio-params/samplerate", MPV_FORMAT_INT64, &sr) >= 0, sr > 0 {
            sampleRateStr = sr >= 1_000_000 ? String(format: "%.4f MHz", Double(sr) / 1_000_000.0) : String(format: "%.1f kHz", Double(sr) / 1000.0)
        }
        
        var channelsStr = "--"
        if let chStr = getMpvString(handle, "audio-params/channels"), !chStr.isEmpty {
            switch chStr.lowercased() {
            case "mono", "1": channelsStr = "Mono"
            case "stereo", "2": channelsStr = "Stereo"
            case "5.1", "5.1(side)": channelsStr = "5.1 Surround"
            case "7.1": channelsStr = "7.1 Surround"
            default: channelsStr = chStr.capitalized
            }
        } else {
            var chCount: Int64 = 0
            if mpv_get_property(handle, "audio-params/channel-count", MPV_FORMAT_INT64, &chCount) >= 0, chCount > 0 {
                channelsStr = chCount == 1 ? "Mono" : (chCount == 2 ? "Stereo" : "\(chCount) Channels")
            }
        }
        
        let codecStr = formatAudioCodecName(getMpvString(handle, "audio-codec-name") ?? "")
        var bitrateStr = ""
        var br: Double = 0
        if mpv_get_property(handle, "audio-bitrate", MPV_FORMAT_DOUBLE, &br) >= 0, br > 0 {
            bitrateStr = String(format: "%.0f kbps", br / 1000.0)
        }
        
        var audios: [MPVTrackItem] = []
        var subs: [MPVSubtitleItem] = []
        var selAudioId: String? = nil
        var selSubId: String? = nil
        
        var count: Int64 = 0
        if mpv_get_property(handle, "track-list/count", MPV_FORMAT_INT64, &count) >= 0, count > 0 {
            for i in 0..<count {
                let type = getMpvString(handle, "track-list/\(i)/type") ?? ""
                var trackId: Int64 = 0
                mpv_get_property(handle, "track-list/\(i)/id", MPV_FORMAT_INT64, &trackId)
                let title = getMpvString(handle, "track-list/\(i)/title") ?? ""
                let lang = getMpvString(handle, "track-list/\(i)/lang") ?? ""
                let codec = getMpvString(handle, "track-list/\(i)/codec") ?? ""
                let extFile = getMpvString(handle, "track-list/\(i)/external-filename")
                var isDefaultFlag: Int32 = 0
                mpv_get_property(handle, "track-list/\(i)/default", MPV_FORMAT_FLAG, &isDefaultFlag)
                var isSelectedFlag: Int32 = 0
                mpv_get_property(handle, "track-list/\(i)/selected", MPV_FORMAT_FLAG, &isSelectedFlag)
                var isExternalFlag: Int32 = 0
                mpv_get_property(handle, "track-list/\(i)/external", MPV_FORMAT_FLAG, &isExternalFlag)
                
                if type == "audio" {
                    let item = MPVTrackItem(
                        id: "mpv_audio_\(trackId)",
                        trackId: UInt32(trackId),
                        title: title.isEmpty ? "Audio Track \(trackId)" : title,
                        language: lang.isEmpty ? "und" : lang,
                        codec: formatAudioCodecName(codec),
                        isDefault: isDefaultFlag != 0,
                        isSelected: isSelectedFlag != 0
                    )
                    audios.append(item)
                    if isSelectedFlag != 0 { selAudioId = item.id }
                } else if type == "sub" {
                    let item = MPVSubtitleItem(
                        id: "mpv_sub_\(trackId)",
                        subtitleId: Int32(trackId),
                        title: title.isEmpty ? (extFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Subtitle \(trackId)") : title,
                        language: lang.isEmpty ? "und" : lang,
                        format: codec.isEmpty ? "SRT" : codec.uppercased(),
                        isExternal: isExternalFlag != 0,
                        fileURL: extFile.map { URL(fileURLWithPath: $0) },
                        isDefault: isDefaultFlag != 0,
                        isSelected: isSelectedFlag != 0,
                        isSecondary: false
                    )
                    subs.append(item)
                    if isSelectedFlag != 0 { selSubId = item.id }
                }
            }
        }
        
        let videoCodecStr = getMpvString(handle, "video-codec") ?? ""
        let hwdecCurrentStr = getMpvString(handle, "hwdec-current") ?? ""

        return MPVMediaParamsSnapshot(
            width: Int(w), height: Int(h), hdrFormat: detectedHDR,
            sampleRate: sampleRateStr, channels: channelsStr, audioCodec: codecStr,
            videoCodec: videoCodecStr, hwdecCurrent: hwdecCurrentStr,
            bitrate: bitrateStr,
            audioTracks: audios, subtitleTracks: subs,
            selectedAudioTrackId: selAudioId, selectedSubtitleTrackId: selSubId
        )
    }
    
    nonisolated public static func getMpvString(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let ptr = mpv_get_property_string(handle, name) else { return nil }
        let str = String(cString: ptr)
        mpv_free(ptr)
        return str
    }
    
    nonisolated public static func formatAudioCodecName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("flac") { return "FLAC Lossless" }
        if lower.contains("ape") { return "Monkey's Audio (APE)" }
        if lower.contains("dts") { return "DTS Digital Surround" }
        if lower.contains("opus") { return "Opus Audio" }
        if lower.contains("vorbis") { return "Ogg Vorbis" }
        if lower.contains("mp3") { return "MPEG-1 Layer III (MP3)" }
        if lower.contains("aac") { return "AAC Audio" }
        if lower.contains("alac") { return "Apple Lossless (ALAC)" }
        if lower.contains("pcm") { return "Linear PCM Audio" }
        if lower.contains("wma") { return "Windows Media Audio" }
        if lower.contains("wavpack") || lower.contains("wv") { return "WavPack Lossless" }
        if lower.contains("dsd") { return "Direct Stream Digital (DSD)" }
        return raw.uppercased()
    }
    
    // MARK: - EDR & Companion Discovery
    
    public func updateEDRMetrics(detectedHDR: MPVHDRFormat = .sdr) {
        let maxHeadroom = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let currentHeadroom = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let peakNits = max(500.0, min(1600.0, Double(maxHeadroom) * 400.0))
        self.edrMetrics = MPVEDRMetrics(
            maxEDRHeadroom: maxHeadroom,
            currentEDRHeadroom: currentHeadroom,
            peakNits: peakNits,
            isHDRActive: maxHeadroom > 1.0 || detectedHDR.isHDR,
            hdrFormat: detectedHDR,
            toneMappingMode: "auto"
        )
    }
    
    public func discoverCompanionSubtitles(for videoURL: URL) {
        Task.detached(priority: .utility) { [weak self] in
            let parentDir = videoURL.deletingLastPathComponent()
            let baseName = videoURL.deletingPathExtension().lastPathComponent
            guard let files = try? FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil) else { return }
            
            var extSubs: [MPVSubtitleItem] = []
            let supportedExts = ["srt", "ass", "ssa", "vtt", "sub", "lrc"]
            let lowerBase = baseName.lowercased()
            
            for file in files {
                let ext = file.pathExtension.lowercased()
                guard supportedExts.contains(ext) else { continue }
                
                let fname = file.deletingPathExtension().lastPathComponent
                let lowerFName = fname.lowercased()
                
                let isMatch = lowerFName == lowerBase ||
                    lowerFName.hasPrefix(lowerBase) ||
                    lowerFName.localizedCaseInsensitiveContains(lowerBase) ||
                    (lowerFName.contains("chs") || lowerFName.contains("cht") || lowerFName.contains("eng") || lowerFName.contains("sub") || lowerFName.contains("zh-cn") || lowerFName.contains("zh-tw"))
                
                if isMatch {
                    let sub = MPVSubtitleItem(
                        id: "ext_sub_\(file.lastPathComponent)",
                        subtitleId: Int32(extSubs.count + 1),
                        title: file.lastPathComponent,
                        language: Self.extractLanguageHint(from: fname),
                        format: ext.uppercased(),
                        isExternal: true,
                        fileURL: file
                    )
                    extSubs.append(sub)
                }
            }
            
            await MainActor.run { [weak self] in
                guard let self = self, self.currentURL == videoURL else { return }
                self.discoveredCompanionSubtitles = extSubs
                for companion in extSubs {
                    if !self.subtitleTracks.contains(where: { $0.fileURL?.path == companion.fileURL?.path || $0.title == companion.title }) {
                        self.subtitleTracks.append(companion)
                    }
                    if let fileURL = companion.fileURL {
                        self.loadSubtitle(url: fileURL, select: false)
                    }
                }
            }
        }
    }
    
    nonisolated private static func extractLanguageHint(from filename: String) -> String {
        let lower = filename.lowercased()
        if lower.contains("chs") || lower.contains("zh-cn") || lower.contains("sc") || lower.contains("simplified") {
            return "CHS"
        }
        if lower.contains("cht") || lower.contains("zh-tw") || lower.contains("tc") || lower.contains("traditional") {
            return "CHT"
        }
        if lower.contains("eng") || lower.contains("en") {
            return "ENG"
        }
        if lower.contains("jpn") || lower.contains("ja") {
            return "JPN"
        }
        return "Ext"
    }
}
