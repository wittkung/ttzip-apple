// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import Foundation

/// Stored subtitle text color choices.
public enum SubtitleColorPreset: String, CaseIterable, Codable, Sendable {
    case white
    case yellow
    case cyan
    case green
}

/// Persistent subtitle appearance, relative sizing, and timing configuration inspired by IINA (`Preference` + `QuickSettingViewController`).
public struct SubtitleStyleConfiguration: Equatable, Codable, Sendable {
    public static let defaultsKey = "com.metastudyline.ttmedia.subtitleStyleConfiguration"
    public static let migrationVersionDefaultsKey = "com.metastudyline.ttmedia.subtitleStyleMigrationVersion"

    /// Schema v2 introduces video-content-relative font sizing (`relativeFontRatio`) with one-time migration from v1 absolute `fontSize`.
    public static let currentSizingSchemaVersion: Int = 2
    public static let referenceVideoWidth: CGFloat = 960.0
    public static let referenceVideoHeight: CGFloat = 540.0
    public static let defaultBaseFontSize: Double = 24.0
    public static let minBaseFontSize: Double = 14.0
    public static let maxBaseFontSize: Double = 48.0
    public static let defaultRelativeFontRatio: Double = defaultBaseFontSize / Double(referenceVideoHeight)
    public static let minRelativeFontRatio: Double = minBaseFontSize / Double(referenceVideoHeight)
    public static let maxRelativeFontRatio: Double = maxBaseFontSize / Double(referenceVideoHeight)

    public var sizingSchemaVersion: Int
    public var fontFamilyName: String?
    internal var storedRelativeFontRatio: Double

    /// Baseline font height ratio relative to the effective video content height $H_{\text{ref}}$ (default `24 / 540 ≈ 4.44%`).
    public var relativeFontRatio: Double {
        get { storedRelativeFontRatio }
        set { storedRelativeFontRatio = Self.clampRelativeFontRatio(newValue) }
    }

    /// Reference point size at the canonical `960×540` (`16:9`) video content height, kept synchronized with `relativeFontRatio`.
    public var fontSize: Double {
        get {
            let raw = storedRelativeFontRatio * Double(Self.referenceVideoHeight)
            return (raw * 1000.0).rounded() / 1000.0
        }
        set {
            let clampedPt = min(Self.maxBaseFontSize, max(Self.minBaseFontSize, newValue))
            storedRelativeFontRatio = Self.clampRelativeFontRatio(clampedPt / Double(Self.referenceVideoHeight))
        }
    }

    public var scale: Double {
        didSet { scale = min(2.0, max(0.5, scale)) }
    }
    public var isBold: Bool
    public var isItalic: Bool
    public var textColor: SubtitleColorPreset
    public var borderWidth: Double {
        didSet { borderWidth = min(4.0, max(0.0, borderWidth)) }
    }
    public var backgroundOpacity: Double {
        didSet { backgroundOpacity = min(0.85, max(0.0, backgroundOpacity)) }
    }
    public var verticalPosition: Double {
        didSet { verticalPosition = min(100.0, max(10.0, verticalPosition)) }
    }
    public var delay: Double {
        didSet { delay = min(10.0, max(-10.0, (delay * 10.0).rounded() / 10.0)) }
    }

    private enum CodingKeys: String, CodingKey {
        case sizingSchemaVersion
        case fontFamilyName
        case relativeFontRatio
        case fontSize
        case scale
        case isBold
        case isItalic
        case textColor
        case borderWidth
        case backgroundOpacity
        case verticalPosition
        case delay
    }

    public init(
        fontFamilyName: String? = nil,
        fontSize: Double = SubtitleStyleConfiguration.defaultBaseFontSize,
        scale: Double = 1.0,
        isBold: Bool = false,
        isItalic: Bool = false,
        textColor: SubtitleColorPreset = .white,
        borderWidth: Double = 2.0,
        backgroundOpacity: Double = 0.0,
        verticalPosition: Double = 90.0,
        delay: Double = 0.0,
        relativeFontRatio: Double? = nil,
        sizingSchemaVersion: Int = SubtitleStyleConfiguration.currentSizingSchemaVersion
    ) {
        self.sizingSchemaVersion = max(1, sizingSchemaVersion)
        self.fontFamilyName = SubtitleFontResolver.normalizeFontIdentifier(fontFamilyName)
        if let explicitRatio = relativeFontRatio {
            self.storedRelativeFontRatio = Self.clampRelativeFontRatio(explicitRatio)
        } else {
            let clampedSize = min(Self.maxBaseFontSize, max(Self.minBaseFontSize, fontSize))
            self.storedRelativeFontRatio = Self.clampRelativeFontRatio(
                clampedSize / Double(Self.referenceVideoHeight)
            )
        }
        self.scale = min(2.0, max(0.5, scale))
        self.isBold = isBold
        self.isItalic = isItalic
        self.textColor = textColor
        self.borderWidth = min(4.0, max(0.0, borderWidth))
        self.backgroundOpacity = min(0.85, max(0.0, backgroundOpacity))
        self.verticalPosition = min(100.0, max(10.0, verticalPosition))
        self.delay = min(10.0, max(-10.0, (delay * 10.0).rounded() / 10.0))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decodeIfPresent(Int.self, forKey: .sizingSchemaVersion)
        let decodedFont = try container.decodeIfPresent(String.self, forKey: .fontFamilyName)
        let decodedRelativeRatio = try container.decodeIfPresent(Double.self, forKey: .relativeFontRatio)
        let decodedFontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? Self.defaultBaseFontSize
        let decodedScale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        let decodedBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        let decodedItalic = try container.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        let decodedColor = try container.decodeIfPresent(SubtitleColorPreset.self, forKey: .textColor) ?? .white
        let decodedBorder = try container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 2.0
        let decodedBg = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.0
        let decodedPos = try container.decodeIfPresent(Double.self, forKey: .verticalPosition) ?? 90.0
        let decodedDelay = try container.decodeIfPresent(Double.self, forKey: .delay) ?? 0.0

        let resolvedRatio: Double
        if let schema = decodedSchema,
           schema >= Self.currentSizingSchemaVersion,
           let ratio = decodedRelativeRatio {
            resolvedRatio = Self.clampRelativeFontRatio(ratio)
        } else if let ratio = decodedRelativeRatio {
            resolvedRatio = Self.clampRelativeFontRatio(ratio)
        } else {
            resolvedRatio = Self.migrateLegacyFontSizeToRelativeRatio(decodedFontSize)
        }

        self.init(
            fontFamilyName: decodedFont,
            fontSize: resolvedRatio * Double(Self.referenceVideoHeight),
            scale: decodedScale,
            isBold: decodedBold,
            isItalic: decodedItalic,
            textColor: decodedColor,
            borderWidth: decodedBorder,
            backgroundOpacity: decodedBg,
            verticalPosition: decodedPos,
            delay: decodedDelay,
            relativeFontRatio: resolvedRatio,
            sizingSchemaVersion: Self.currentSizingSchemaVersion
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSizingSchemaVersion, forKey: .sizingSchemaVersion)
        try container.encodeIfPresent(fontFamilyName, forKey: .fontFamilyName)
        try container.encode(storedRelativeFontRatio, forKey: .relativeFontRatio)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(scale, forKey: .scale)
        try container.encode(isBold, forKey: .isBold)
        try container.encode(isItalic, forKey: .isItalic)
        try container.encode(textColor, forKey: .textColor)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encode(verticalPosition, forKey: .verticalPosition)
        try container.encode(delay, forKey: .delay)
    }

    /// Combined relative font height ratio ($\rho_{\text{eff}} = \text{relativeFontRatio} \times \text{scale}$).
    public var effectiveRelativeFontRatio: Double {
        storedRelativeFontRatio * scale
    }

    /// Effective primary font size at the canonical `960×540` reference frame.
    public var effectiveFontSize: CGFloat {
        CGFloat(min(96.0, max(11.0, Double(Self.referenceVideoHeight) * effectiveRelativeFontRatio)))
    }

    /// Effective secondary (bilingual) font size at the canonical `960×540` reference frame (`0.82x` of primary).
    public var secondaryFontSize: CGFloat {
        max(9.5, effectiveFontSize * SubtitleRelativeSizingResolver.secondaryFontSizeRatio)
    }
}
