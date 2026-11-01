// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import AVFoundation

extension UnifiedAudioPlayerView {
    
    public var displayTitle: String {
        if let audioTitle, !audioTitle.isEmpty {
            return audioTitle
        }
        if let mpvTitle = audioEngine.metadata?.title, !mpvTitle.isEmpty {
            return mpvTitle
        }
        let clean = (fileName as NSString).deletingPathExtension
        return clean.isEmpty ? fileName : clean
    }

    public var displaySubtitle: String? {
        let artist = audioArtist ?? audioEngine.metadata?.artist
        let album = audioAlbum
        if let artist, !artist.isEmpty, let album, !album.isEmpty {
            return "\(artist) · \(album)"
        } else if let artist, !artist.isEmpty {
            return artist
        } else if let album, !album.isEmpty {
            return album
        }
        return nil
    }

    public var displayCodecName: String {
        if !audioEngine.codecFormatted.isEmpty && audioEngine.codecFormatted != "--" {
            return audioEngine.codecFormatted
        }
        return defaultCodecName
    }

    public var displayBitrate: String {
        if !audioEngine.bitrateFormatted.isEmpty && audioEngine.bitrateFormatted != "--" {
            return audioEngine.bitrateFormatted
        }
        return defaultBitrate
    }

    public var displaySampleRate: String {
        if !audioEngine.sampleRateFormatted.isEmpty && audioEngine.sampleRateFormatted != "--" {
            return audioEngine.sampleRateFormatted
        }
        return defaultSampleRate
    }

    public var displayChannels: String {
        if !audioEngine.channelsFormatted.isEmpty && audioEngine.channelsFormatted != "--" {
            return audioEngine.channelsFormatted
        }
        return defaultChannels
    }

    private static let codecDescriptions: [String: String] = [
        "ape": "Monkey's Audio Lossless",
        "flac": "FLAC Lossless Audio",
        "dts": "DTS Digital Surround",
        "opus": "Opus Interactive Audio",
        "ogg": "Ogg Vorbis Stream",
        "oga": "Ogg Audio Stream",
        "mp3": "MPEG-1 Layer III",
        "m4a": "MPEG-4 Audio (AAC / ALAC)",
        "m4b": "MPEG-4 Audiobook",
        "m4r": "MPEG-4 Ringtone",
        "aac": "Advanced Audio Coding",
        "wav": "Linear PCM Audio",
        "aiff": "Audio Interchange Format",
        "aif": "Audio Interchange Format",
        "aifc": "Compressed Audio Interchange",
        "alac": "Apple Lossless (ALAC)",
        "wma": "Windows Media Audio",
        "caf": "CoreAudio Format",
        "dsf": "Direct Stream Digital (DSD)",
        "dff": "DSD Interchange File Format",
        "wv": "WavPack Hybrid Lossless",
        "tta": "True Audio Lossless",
        "voc": "Creative Voice Audio",
        "ra": "RealAudio Stream",
        "rm": "RealMedia Container",
        "mid": "Standard MIDI Sequence",
        "midi": "Standard MIDI Sequence",
        "mka": "Matroska Audio Container",
    ]

    public func setupTrackMetadata() {
        metadataTask?.cancel()
        metadataTask = nil
        audioTitle = nil
        audioArtist = nil
        audioAlbum = nil
        albumArtImage = nil
        fileSizeFormatted = Self.formattedFileSize(atPath: url.path)

        let ext = url.pathExtension.lowercased()
        defaultCodecName = Self.codecDescriptions[ext] ?? "\(ext.uppercased()) Audio Stream"
        defaultSampleRate = "--"
        defaultChannels = "--"
        defaultBitrate = "--"

        let currentURL = self.url
        metadataTask = Task {
            let probed = await Self.probeAssetTags(for: currentURL)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                applyProbedTags(probed, for: currentURL)
            }
        }
    }

    private static func formattedFileSize(atPath path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let byteCount = attrs[.size] as? Int64 else {
            return "--"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    private struct ProbedAudioTags: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var artworkData: Data?
    }

    private static func probeAssetTags(for targetURL: URL) async -> ProbedAudioTags {
        let asset = AVURLAsset(url: targetURL)
        var tags = ProbedAudioTags()
        guard let commonMeta = try? await asset.load(.commonMetadata) else {
            return tags
        }
        for item in commonMeta {
            if Task.isCancelled { return tags }
            await populateTag(from: item, into: &tags)
        }
        return tags
    }

    private static func populateTag(from item: AVMetadataItem, into tags: inout ProbedAudioTags) async {
        guard let key = item.commonKey else { return }
        switch key {
        case .commonKeyTitle:
            tags.title = try? await item.load(.stringValue)
        case .commonKeyArtist:
            tags.artist = try? await item.load(.stringValue)
        case .commonKeyAlbumName:
            tags.album = try? await item.load(.stringValue)
        case .commonKeyArtwork:
            tags.artworkData = try? await item.load(.dataValue)
        default:
            break
        }
    }

    private func applyProbedTags(_ tags: ProbedAudioTags, for targetURL: URL) {
        guard self.url == targetURL else { return }
        if let title = tags.title, !title.isEmpty {
            audioTitle = title
        }
        if let artist = tags.artist, !artist.isEmpty {
            audioArtist = artist
        }
        if let album = tags.album, !album.isEmpty {
            audioAlbum = album
        }
        if let data = tags.artworkData, let image = NSImage(data: data) {
            albumArtImage = image
        }
    }

    public func formatTimePrecise(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00.00" }
        let totalSec = Int(seconds)
        let mins = totalSec / 60
        let secs = totalSec % 60
        let centis = Int((seconds - Double(totalSec)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, centis)
    }
}
