// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CoreGraphics
import Combine
import TTZipUI

/// Supported High Dynamic Range formats for Metal tone mapping pipeline.
public enum MPVHDRFormat: String, CaseIterable, Identifiable, Sendable {
    case sdr = "SDR"
    case hdr10 = "HDR10"
    case dolbyVision = "Dolby Vision"
    case hlg = "HLG"
    
    public var id: String { rawValue }
    
    public var isHDR: Bool {
        self != .sdr
    }
}

/// Media audio/video track representation for libmpv engine.
public struct MPVTrackItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let trackId: UInt32
    public let title: String
    public let language: String
    public let codec: String
    public let isDefault: Bool
    public let isSelected: Bool
    
    public init(
        id: String = UUID().uuidString,
        trackId: UInt32 = 1,
        title: String,
        language: String = "",
        codec: String = "",
        isDefault: Bool = false,
        isSelected: Bool = false
    ) {
        self.id = id
        self.trackId = trackId
        self.title = title
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
        self.isSelected = isSelected
    }
}

/// Subtitle track representation supporting ASS/SSA, SRT, VTT, and embedded tracks.
public struct MPVSubtitleItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let subtitleId: Int32
    public let title: String
    public let language: String
    public let format: String
    public let isExternal: Bool
    public let fileURL: URL?
    public let isDefault: Bool
    public let isSelected: Bool
    public let isSecondary: Bool
    
    public init(
        id: String = UUID().uuidString,
        subtitleId: Int32 = 1,
        title: String,
        language: String = "",
        format: String = "SRT",
        isExternal: Bool = false,
        fileURL: URL? = nil,
        isDefault: Bool = false,
        isSelected: Bool = false,
        isSecondary: Bool = false
    ) {
        self.id = id
        self.subtitleId = subtitleId
        self.title = title
        self.language = language
        self.format = format
        self.isExternal = isExternal
        self.fileURL = fileURL
        self.isDefault = isDefault
        self.isSelected = isSelected
        self.isSecondary = isSecondary
    }
}

/// EDR (Extended Dynamic Range) display profile metrics for Metal tone mapping.
public struct MPVEDRMetrics: Equatable, Sendable {
    public var maxEDRHeadroom: CGFloat
    public var currentEDRHeadroom: CGFloat
    public var peakNits: Double
    public var isHDRActive: Bool
    public var hdrFormat: MPVHDRFormat
    public var toneMappingMode: String
    
    public init(
        maxEDRHeadroom: CGFloat = 1.0,
        currentEDRHeadroom: CGFloat = 1.0,
        peakNits: Double = 1600.0,
        isHDRActive: Bool = false,
        hdrFormat: MPVHDRFormat = .sdr,
        toneMappingMode: String = "auto"
    ) {
        self.maxEDRHeadroom = maxEDRHeadroom
        self.currentEDRHeadroom = currentEDRHeadroom
        self.peakNits = peakNits
        self.isHDRActive = isHDRActive
        self.hdrFormat = hdrFormat
        self.toneMappingMode = toneMappingMode
    }
}

/// Sendable snapshot of media parameters introspected asynchronously from libmpv.
public struct MPVMediaParamsSnapshot: Sendable {
    public let width: Int
    public let height: Int
    public let hdrFormat: MPVHDRFormat
    public let sampleRate: String
    public let channels: String
    public let audioCodec: String
    public let bitrate: String
    public let audioTracks: [MPVTrackItem]
    public let subtitleTracks: [MPVSubtitleItem]
    public let selectedAudioTrackId: String?
    public let selectedSubtitleTrackId: String?
    
    public init(
        width: Int = 0,
        height: Int = 0,
        hdrFormat: MPVHDRFormat = .sdr,
        sampleRate: String = "--",
        channels: String = "--",
        audioCodec: String = "",
        bitrate: String = "",
        audioTracks: [MPVTrackItem] = [],
        subtitleTracks: [MPVSubtitleItem] = [],
        selectedAudioTrackId: String? = nil,
        selectedSubtitleTrackId: String? = nil
    ) {
        self.width = width
        self.height = height
        self.hdrFormat = hdrFormat
        self.sampleRate = sampleRate
        self.channels = channels
        self.audioCodec = audioCodec
        self.bitrate = bitrate
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.selectedAudioTrackId = selectedAudioTrackId
        self.selectedSubtitleTrackId = selectedSubtitleTrackId
    }
}

