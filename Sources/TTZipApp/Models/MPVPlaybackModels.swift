// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CoreGraphics

/// Media track representation for native video playback.
public struct MPVTrackItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let trackId: UInt32
    public let title: String
    public let language: String
    public let codec: String
    public let isDefault: Bool
    
    public init(
        id: String = UUID().uuidString,
        trackId: UInt32,
        title: String,
        language: String = "",
        codec: String = "",
        isDefault: Bool = false
    ) {
        self.id = id
        self.trackId = trackId
        self.title = title
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
    }
}

/// Subtitle track representation supporting ASS, SRT, VTT and embedded tracks.
public struct MPVSubtitleItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let language: String
    public let format: String
    public let isExternal: Bool
    public let fileURL: URL?
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        language: String = "",
        format: String = "SRT",
        isExternal: Bool = false,
        fileURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.format = format
        self.isExternal = isExternal
        self.fileURL = fileURL
    }
}

/// EDR (Extended Dynamic Range) display profile metrics for Metal tone mapping.
public struct MPVEDRMetrics: Equatable, Sendable {
    public var maxEDRHeadroom: CGFloat
    public var currentEDRHeadroom: CGFloat
    public var peakNits: Double
    public var isHDRActive: Bool
    
    public init(
        maxEDRHeadroom: CGFloat = 1.0,
        currentEDRHeadroom: CGFloat = 1.0,
        peakNits: Double = 1600.0,
        isHDRActive: Bool = false
    ) {
        self.maxEDRHeadroom = maxEDRHeadroom
        self.currentEDRHeadroom = currentEDRHeadroom
        self.peakNits = peakNits
        self.isHDRActive = isHDRActive
    }
}
