// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import Foundation

/// Width classification for adaptive audio inspector layout across narrow, regular, and wide sidebars.
public enum AudioInspectorWidthTier: String, Sendable, Equatable {
    case narrow
    case regular
    case wide

    public static func resolve(for width: CGFloat) -> AudioInspectorWidthTier {
        if width < 320.0 {
            return .narrow
        } else if width < 430.0 {
            return .regular
        } else {
            return .wide
        }
    }
}

/// Deterministic layout metrics for the audio inspector across width and height constraints.
public struct AudioInspectorLayoutMetrics: Sendable, Equatable {
    public static let minimumHitTargetSize: CGFloat = 28.0
    public static let compactHeightThreshold: CGFloat = 340.0
    public static let ultraCompactHeightThreshold: CGFloat = 255.0

    public let availableWidth: CGFloat
    public let availableHeight: CGFloat
    public let widthTier: AudioInspectorWidthTier
    public let isCompact: Bool
    public let isUltraCompact: Bool
    public let artworkSize: CGFloat
    public let waveformHeight: CGFloat
    public let playButtonSize: CGFloat
    public let secondaryButtonMinSize: CGFloat
    public let volumeSliderWidth: CGFloat
    public let showsMiniPlayerTitle: Bool
    public let showsExtendedCompactSpecs: Bool
    public let showsFullSpecsGrid: Bool

    public init(availableWidth: CGFloat, availableHeight: CGFloat) {
        let safeWidth = max(220.0, availableWidth)
        let safeHeight = max(180.0, availableHeight)
        self.availableWidth = safeWidth
        self.availableHeight = safeHeight
        self.widthTier = AudioInspectorWidthTier.resolve(for: safeWidth)

        let compact = safeHeight < Self.compactHeightThreshold || safeWidth < 340.0
        let ultraCompact = safeHeight < Self.ultraCompactHeightThreshold || safeWidth < 290.0
        self.isCompact = compact
        self.isUltraCompact = ultraCompact

        if ultraCompact {
            self.artworkSize = 38.0
            self.waveformHeight = 42.0
            self.playButtonSize = 34.0
        } else if compact {
            self.artworkSize = 42.0
            self.waveformHeight = 48.0
            self.playButtonSize = 36.0
        } else {
            self.artworkSize = (safeWidth >= 430.0) ? 54.0 : 48.0
            self.waveformHeight = (safeHeight >= 420.0) ? 62.0 : 54.0
            self.playButtonSize = 40.0
        }

        self.secondaryButtonMinSize = Self.minimumHitTargetSize

        switch self.widthTier {
        case .narrow:
            self.volumeSliderWidth = 72.0
            self.showsMiniPlayerTitle = false
            self.showsExtendedCompactSpecs = false
        case .regular:
            self.volumeSliderWidth = 96.0
            self.showsMiniPlayerTitle = true
            self.showsExtendedCompactSpecs = true
        case .wide:
            self.volumeSliderWidth = 124.0
            self.showsMiniPlayerTitle = true
            self.showsExtendedCompactSpecs = true
        }

        self.showsFullSpecsGrid = !compact && safeHeight >= Self.compactHeightThreshold
    }

    public var horizontalPadding: CGFloat {
        switch widthTier {
        case .narrow: return 10.0
        case .regular: return 12.0
        case .wide: return 16.0
        }
    }

    public var verticalPadding: CGFloat {
        if isUltraCompact { return 8.0 }
        return isCompact ? 10.0 : 14.0
    }

    public var artworkThumbnailSize: CGFloat {
        artworkSize
    }

    public var overviewStripHeight: CGFloat {
        isUltraCompact ? 10.0 : 12.0
    }

    public var primaryPlayButtonSize: CGFloat {
        playButtonSize
    }

    /// Determines whether the compact header should display a primary track title line.
    /// When the host inspector already displays `fileName`, duplicate filename stacking is suppressed
    /// unless the audio file carries a distinct embedded track title.
    public static func shouldDisplayCompactHeaderTitle(
        metadataTitle: String?,
        fileName: String,
        hostDisplaysFileName: Bool
    ) -> Bool {
        guard hostDisplaysFileName else { return true }
        guard let rawTitle = metadataTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty else {
            return false
        }
        let normalizedFile = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = (normalizedFile as NSString).deletingPathExtension
        if rawTitle.caseInsensitiveCompare(normalizedFile) == .orderedSame ||
           rawTitle.caseInsensitiveCompare(baseName) == .orderedSame {
            return false
        }
        return true
    }
}
