// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import Foundation
import SwiftUI
import TTI18nCore
import TTKitDesign

/// Report describing the outcome of loading and migrating `SubtitleStyleConfiguration` from `UserDefaults`.
public struct SubtitleStyleMigrationReport: Equatable, Sendable {
    public let didMigrateFromLegacy: Bool
    public let previousSchemaVersion: Int?
    public let configuration: SubtitleStyleConfiguration

    public init(
        didMigrateFromLegacy: Bool,
        previousSchemaVersion: Int?,
        configuration: SubtitleStyleConfiguration
    ) {
        self.didMigrateFromLegacy = didMigrateFromLegacy
        self.previousSchemaVersion = previousSchemaVersion
        self.configuration = configuration
    }
}

extension SubtitleStyleConfiguration {
    private struct RawLegacyProbe: Decodable {
        let sizingSchemaVersion: Int?
        let relativeFontRatio: Double?
        let fontSize: Double?
    }

    /// Resolves font sizes and margins for a specific video content geometry.
    public func resolvedMetrics(for geometry: SubtitleVideoContentGeometry) -> SubtitleResolvedLayoutMetrics {
        SubtitleRelativeSizingResolver.resolveMetrics(style: self, geometry: geometry)
    }

    public static func clampRelativeFontRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return defaultRelativeFontRatio }
        return min(maxRelativeFontRatio, max(minRelativeFontRatio, ratio))
    }

    public static func migrateLegacyFontSizeToRelativeRatio(_ legacyFontSize: Double) -> Double {
        guard legacyFontSize.isFinite else { return defaultRelativeFontRatio }
        let clampedPt = min(maxBaseFontSize, max(minBaseFontSize, legacyFontSize))
        return clampRelativeFontRatio(clampedPt / Double(referenceVideoHeight))
    }

    /// Loads `SubtitleStyleConfiguration` from `UserDefaults` and performs a one-time idempotent migration
    /// if a legacy v1 payload (lacking `sizingSchemaVersion >= 2` or `relativeFontRatio`) is found.
    public static func loadAndMigrateIfNeeded(
        from defaults: UserDefaults = .standard
    ) -> SubtitleStyleMigrationReport {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return SubtitleStyleMigrationReport(
                didMigrateFromLegacy: false,
                previousSchemaVersion: nil,
                configuration: Self()
            )
        }

        let probe = try? JSONDecoder().decode(RawLegacyProbe.self, from: data)
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return SubtitleStyleMigrationReport(
                didMigrateFromLegacy: false,
                previousSchemaVersion: probe?.sizingSchemaVersion,
                configuration: Self()
            )
        }

        let previousSchema = probe?.sizingSchemaVersion
        let wasLegacyPayload = (previousSchema == nil)
            || (previousSchema ?? 0) < currentSizingSchemaVersion
            || (probe?.relativeFontRatio == nil)

        if wasLegacyPayload {
            decoded.saveToDefaults(defaults)
            defaults.set(currentSizingSchemaVersion, forKey: migrationVersionDefaultsKey)
        }

        return SubtitleStyleMigrationReport(
            didMigrateFromLegacy: wasLegacyPayload,
            previousSchemaVersion: previousSchema,
            configuration: decoded
        )
    }

    public static func loadFromDefaults(_ defaults: UserDefaults = .standard) -> Self {
        loadAndMigrateIfNeeded(from: defaults).configuration
    }

    public func saveToDefaults(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
            defaults.set(Self.currentSizingSchemaVersion, forKey: Self.migrationVersionDefaultsKey)
        }
    }
}

/// Origin of the resolved video content rectangle used for subtitle layout and relative font sizing.
public enum SubtitleVideoGeometrySource: String, Codable, Equatable, Sendable {
    /// Caller supplied an explicit rendered video rectangle (e.g. `displayLayer.videoRect` or `AVMakeRect`).
    case explicitRect
    /// Derived from video track dimensions, pixel aspect ratio (PAR), and rotation metadata (`0/90/180/270`).
    case trackMetadata
    /// Reused the aspect ratio of the last known valid video content rectangle during a transition or seek.
    case lastKnownFallback
    /// Pre-first-frame or missing-metadata fallback using the canonical `16:9` reference aspect ratio.
    case canonicalAspectFallback
}

/// Subtitle track rendering capability classification defining the boundary of relative font sizing and font overrides.
public enum SubtitleRenderCapabilityKind: String, Codable, Equatable, Sendable {
    /// Pure text subtitle cues (SRT, WebVTT, UTF-8 text tracks) rendered by `SubtitleOverlayView`.
    /// Relative font sizing and local font family selection apply in full.
    case textOverlay
    /// ASS/SSA subtitle tracks whose dialogue text is extracted and rendered by `SubtitleOverlayView`.
    /// Relative font sizing and font selection apply to extracted text; full `libass` vector positioning is not executed.
    case assPlainTextExtracts
    /// Pre-rasterized bitmap subtitles (PGS, VobSub, DVBSub).
    /// Font family selection and text relative font sizing do not alter pre-rendered bitmap glyphs.
    case bitmapUntouched
}

/// Input geometry describing the player viewport and the active video track's presentation characteristics.
public struct SubtitleVideoContentGeometry: Equatable, Sendable {
    public static let canonicalViewportSize = CGSize(
        width: SubtitleStyleConfiguration.referenceVideoWidth,
        height: SubtitleStyleConfiguration.referenceVideoHeight
    )

    public let viewportSize: CGSize
    public let videoNaturalSize: CGSize?
    public let pixelAspectRatio: CGSize
    public let rotationDegrees: Int
    public let explicitVideoRect: CGRect?
    public let lastKnownVideoRect: CGRect?

    public init(
        viewportSize: CGSize,
        videoNaturalSize: CGSize? = nil,
        pixelAspectRatio: CGSize = CGSize(width: 1.0, height: 1.0),
        rotationDegrees: Int = 0,
        explicitVideoRect: CGRect? = nil,
        lastKnownVideoRect: CGRect? = nil
    ) {
        self.viewportSize = viewportSize
        self.videoNaturalSize = videoNaturalSize
        self.pixelAspectRatio = pixelAspectRatio
        self.rotationDegrees = Self.normalizeRotationDegrees(rotationDegrees)
        self.explicitVideoRect = explicitVideoRect
        self.lastKnownVideoRect = lastKnownVideoRect
    }

    /// Normalizes arbitrary rotation angles into `{0, 90, 180, 270}`.
    public static func normalizeRotationDegrees(_ degrees: Int) -> Int {
        let mod = ((degrees % 360) + 360) % 360
        switch mod {
        case 45..<135: return 90
        case 135..<225: return 180
        case 225..<315: return 270
        default: return 0
        }
    }

    /// Extracts `{0, 90, 180, 270}` rotation degrees from an `AVAssetTrack.preferredTransform`.
    public static func rotationDegrees(fromPreferredTransform transform: CGAffineTransform) -> Int {
        let radians = atan2(transform.b, transform.a)
        let degrees = Int((radians * 180.0 / .pi).rounded())
        return normalizeRotationDegrees(degrees)
    }
}

/// Resolved subtitle typography and box layout metrics anchored to the actual video content rectangle.
public struct SubtitleResolvedLayoutMetrics: Equatable, Sendable {
    public let viewportSize: CGSize
    public let videoContentRect: CGRect
    public let effectiveReferenceHeight: CGFloat
    public let relativeScaleFactor: CGFloat
    public let primaryFontSize: CGFloat
    public let secondaryFontSize: CGFloat
    public let effectiveBorderWidth: CGFloat
    public let interTrackSpacing: CGFloat
    public let intraTrackLineSpacing: CGFloat
    public let horizontalPadding: CGFloat
    public let maxTextWidth: CGFloat
    public let contentBottomOffset: CGFloat
    public let viewportBottomPadding: CGFloat
    public let resolutionSource: SubtitleVideoGeometrySource
}

/// Stateless, deterministic resolver for video-content-relative subtitle sizing, margins, and capability boundaries.
public enum SubtitleRelativeSizingResolver {
    public static let canonicalAspectRatio: CGFloat = 16.0 / 9.0
    public static let portraitWidthFactor: CGFloat = 1.25
    public static let minPrimaryFontSize: CGFloat = 11.0
    public static let maxPrimaryFontSize: CGFloat = 96.0
    public static let minSecondaryFontSize: CGFloat = 9.5
    public static let maxSecondaryFontSize: CGFloat = 78.72
    public static let secondaryFontSizeRatio: CGFloat = 0.82

    /// Resolves the active video content rectangle inside `geometry.viewportSize` and reports the resolution source.
    public static func resolveVideoContentRect(
        for geometry: SubtitleVideoContentGeometry
    ) -> (rect: CGRect, source: SubtitleVideoGeometrySource) {
        let safeViewport = sanitizeViewportSize(geometry.viewportSize)
        let viewportBounds = CGRect(origin: .zero, size: safeViewport)

        // Priority 1: Explicit valid video rect from display layer or AVMakeRect.
        if let explicit = geometry.explicitVideoRect, isValidSize(explicit.size) {
            let clamped = clampRect(explicit, inside: viewportBounds)
            if isValidSize(clamped.size) {
                return (clamped, .explicitRect)
            }
            return (aspectFitRect(aspectSize: explicit.size, inside: viewportBounds), .explicitRect)
        }

        // Priority 2: Video track dimensions + PAR + rotation metadata.
        if let rawSize = geometry.videoNaturalSize, isValidSize(rawSize) {
            let parW = sanitizePositive(geometry.pixelAspectRatio.width, fallback: 1.0)
            let parH = sanitizePositive(geometry.pixelAspectRatio.height, fallback: 1.0)
            let parScale = min(4.0, max(0.25, parW / parH))
            let displayWidth = rawSize.width * parScale
            let displayHeight = rawSize.height

            let isQuarterTurn = (geometry.rotationDegrees == 90 || geometry.rotationDegrees == 270)
            let orientedSize = isQuarterTurn
                ? CGSize(width: displayHeight, height: displayWidth)
                : CGSize(width: displayWidth, height: displayHeight)

            return (aspectFitRect(aspectSize: orientedSize, inside: viewportBounds), .trackMetadata)
        }

        // Priority 3a: Last known valid video content rect aspect ratio fallback (during seek / rebind).
        if let lastKnown = geometry.lastKnownVideoRect, isValidSize(lastKnown.size) {
            return (aspectFitRect(aspectSize: lastKnown.size, inside: viewportBounds), .lastKnownFallback)
        }

        // Priority 3b: Pre-first-frame canonical 16:9 aspect-fit fallback.
        let canonicalSize = SubtitleVideoContentGeometry.canonicalViewportSize
        return (aspectFitRect(aspectSize: canonicalSize, inside: viewportBounds), .canonicalAspectFallback)
    }

    /// Computes the $C^0$-continuous, degree-1 homogeneous effective reference height $H_{\text{ref}}$
    /// from the resolved video content rectangle size $(W_c, H_c)$.
    public static func effectiveReferenceHeight(forContentSize contentSize: CGSize) -> CGFloat {
        let width = max(1.0, contentSize.width)
        let height = max(1.0, contentSize.height)
        let aspect = width / height

        if aspect < 1.0 {
            // Portrait / vertical video (e.g. 9:16): bound reference height by narrow horizontal line width.
            return min(height, width * portraitWidthFactor)
        } else if aspect <= canonicalAspectRatio + 0.0001 {
            // Square (1:1), classic (4:3), and standard widescreen (16:9): use actual content height.
            return height
        } else {
            // Ultra-wide cinema (e.g. 2.35:1 / 2.39:1): geometric mean of content height and 16:9-equivalent height.
            let equivalent16By9Height = width / canonicalAspectRatio
            return sqrt(height * equivalent16By9Height)
        }
    }

    /// Resolves complete subtitle font sizes, spacing, horizontal wrapping width, and bottom offsets
    /// anchored to the actual video content rectangle.
    public static func resolveMetrics(
        style: SubtitleStyleConfiguration,
        geometry: SubtitleVideoContentGeometry
    ) -> SubtitleResolvedLayoutMetrics {
        let safeViewport = sanitizeViewportSize(geometry.viewportSize)
        let (contentRect, source) = resolveVideoContentRect(for: geometry)
        let refHeight = effectiveReferenceHeight(forContentSize: contentRect.size)
        let scaleFactor = refHeight / SubtitleStyleConfiguration.referenceVideoHeight

        let rawPrimary = refHeight * CGFloat(style.effectiveRelativeFontRatio)
        let primarySize = min(maxPrimaryFontSize, max(minPrimaryFontSize, rawPrimary))
        let secondarySize = min(
            maxSecondaryFontSize,
            max(minSecondaryFontSize, primarySize * secondaryFontSizeRatio)
        )

        let clampedScaleForStroke = min(1.6, max(0.65, scaleFactor))
        let effectiveBorder = CGFloat(style.borderWidth) * clampedScaleForStroke

        let interTrackSpacing = min(14.0, max(3.0, primarySize * 0.22))
        let intraTrackLineSpacing = min(8.0, max(1.5, primarySize * 0.12))

        let horizontalInset = min(48.0, max(10.0, contentRect.width * 0.05))
        let maxTextWidth = max(120.0, contentRect.width - horizontalInset * 2.0)

        // Base bottom margin is 28pt at 540pt content height (~5.185% of content height).
        let baseBottomInContent = min(56.0, max(12.0, contentRect.height * (28.0 / 540.0)))
        let liftFraction = CGFloat(100.0 - style.verticalPosition) / 100.0
        let maxExtraLift = max(0.0, contentRect.height * 0.55)
        let contentBottomOffset = baseBottomInContent + liftFraction * maxExtraLift

        let bottomLetterboxInset = max(0.0, safeViewport.height - contentRect.maxY)
        let viewportBottomPadding = bottomLetterboxInset + contentBottomOffset

        return SubtitleResolvedLayoutMetrics(
            viewportSize: safeViewport,
            videoContentRect: contentRect,
            effectiveReferenceHeight: refHeight,
            relativeScaleFactor: scaleFactor,
            primaryFontSize: primarySize,
            secondaryFontSize: secondarySize,
            effectiveBorderWidth: effectiveBorder,
            interTrackSpacing: interTrackSpacing,
            intraTrackLineSpacing: intraTrackLineSpacing,
            horizontalPadding: horizontalInset,
            maxTextWidth: maxTextWidth,
            contentBottomOffset: contentBottomOffset,
            viewportBottomPadding: viewportBottomPadding,
            resolutionSource: source
        )
    }

    /// Classifies subtitle format or codec identifier to communicate accurate styling capability boundaries.
    public static func capability(forCodecOrFormat rawIdentifier: String?) -> SubtitleRenderCapabilityKind {
        guard let normalized = rawIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return .textOverlay
        }
        let bitmapTokens = ["pgs", "hdmv", "vobsub", "dvb", "dvd_subtitle"]
        if bitmapTokens.contains(where: normalized.contains)
            || [".sup", ".sub"].contains(where: normalized.hasSuffix) {
            return .bitmapUntouched
        }
        if ["s_text/ass", "s_text/ssa"].contains(where: normalized.contains)
            || ["ass", "ssa"].contains(normalized)
            || [".ass", ".ssa"].contains(where: normalized.hasSuffix) {
            return .assPlainTextExtracts
        }
        return .textOverlay
    }

    private static func isValidSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 1.0 && size.height > 1.0
    }

    private static func sanitizePositive(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        (value.isFinite && value > 0.001) ? value : fallback
    }

    private static func sanitizeViewportSize(_ size: CGSize) -> CGSize {
        guard isValidSize(size) else {
            return SubtitleVideoContentGeometry.canonicalViewportSize
        }
        return size
    }

    private static func clampRect(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull, !intersection.isEmpty else { return .zero }
        return intersection
    }

    private static func aspectFitRect(aspectSize: CGSize, inside bounds: CGRect) -> CGRect {
        let safeW = sanitizePositive(aspectSize.width, fallback: 16.0)
        let safeH = sanitizePositive(aspectSize.height, fallback: 9.0)
        let scale = min(bounds.width / safeW, bounds.height / safeH)
        let fittedW = safeW * scale
        let fittedH = safeH * scale
        let originX = bounds.minX + (bounds.width - fittedW) * 0.5
        let originY = bounds.minY + (bounds.height - fittedH) * 0.5
        return CGRect(x: originX, y: originY, width: fittedW, height: fittedH)
    }
}

/// Standalone reusable SwiftUI control for relative subtitle sizing (`scale` + `relativeFontRatio`),
/// preset selection, and explicit text/ASS/bitmap capability boundary disclosure.
@MainActor
public struct SubtitleRelativeScaleSettingsView: View {
    public let style: SubtitleStyleConfiguration
    public let geometry: SubtitleVideoContentGeometry?
    public let activeSubtitleCodec: String?
    public let onUpdateStyle: (SubtitleStyleConfiguration) -> Void
    public let onUserInteraction: () -> Void

    public static let scaleRange: ClosedRange<Double> = 0.5...2.0
    public static let scalePresets: [Double] = [0.75, 1.0, 1.25, 1.5]

    public init(
        style: SubtitleStyleConfiguration,
        geometry: SubtitleVideoContentGeometry? = nil,
        activeSubtitleCodec: String? = nil,
        onUpdateStyle: @escaping (SubtitleStyleConfiguration) -> Void,
        onUserInteraction: @escaping () -> Void = {}
    ) {
        self.style = style
        self.geometry = geometry
        self.activeSubtitleCodec = activeSubtitleCodec
        self.onUpdateStyle = onUpdateStyle
        self.onUserInteraction = onUserInteraction
    }

    public static func clampScale(_ rawScale: Double) -> Double {
        guard rawScale.isFinite else { return 1.0 }
        return min(scaleRange.upperBound, max(scaleRange.lowerBound, rawScale))
    }

    /// Continuous slider binding (`0.50...2.00`) without `0.05` step quantization.
    public var continuousScaleBinding: Binding<Double> {
        Binding(
            get: { Self.clampScale(style.scale) },
            set: { newScale in
                var updated = style
                updated.scale = Self.clampScale(newScale)
                onUpdateStyle(updated)
                onUserInteraction()
            }
        )
    }

    /// Applies a discrete preset multiplier (`0.75x`, `1.0x`, `1.25x`, `1.5x`) and triggers interaction callbacks.
    public func applyScalePreset(_ preset: Double) {
        var updated = style
        updated.scale = Self.clampScale(preset)
        onUpdateStyle(updated)
        onUserInteraction()
    }

    public func isPresetSelected(_ preset: Double) -> Bool {
        abs(style.scale - preset) < 0.005
    }

    public var capabilityKind: SubtitleRenderCapabilityKind {
        SubtitleRelativeSizingResolver.capability(forCodecOrFormat: activeSubtitleCodec)
    }

    public var badgeText: String {
        let scaleString = String(format: "%.2fx", style.scale)
        let percentString = String(format: "%.1f%%", style.effectiveRelativeFontRatio * 100.0)
        return MediaLocalization.formattedRelativeHeightBadge(
            scaleText: scaleString,
            percentText: percentString
        )
    }

    public var capabilityNoticeText: String {
        switch capabilityKind {
        case .textOverlay:
            return MediaLocalization.text(.capabilityTextActive)
        case .assPlainTextExtracts:
            return MediaLocalization.text(.capabilityAssExtractedText)
        case .bitmapUntouched:
            return MediaLocalization.text(.capabilityBitmapNotice)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(MediaLocalization.text(.subtitleFontSize))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(badgeText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }

            Slider(
                value: continuousScaleBinding,
                in: Self.scaleRange
            )
            .disabled(capabilityKind == .bitmapUntouched)

            HStack(spacing: 6) {
                ForEach(Self.scalePresets, id: \.self) { preset in
                    let isSelected = isPresetSelected(preset)
                    Button(String(format: preset.truncatingRemainder(dividingBy: 0.25) == 0 && preset * 10 == (preset * 10).rounded() ? "%.1fx" : "%.2fx", preset)) {
                        applyScalePreset(preset)
                    }
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .monospaced))
                    .buttonStyle(.bordered)
                    .tint(isSelected ? .accentColor : nil)
                    .controlSize(.small)
                    .disabled(capabilityKind == .bitmapUntouched)
                }
            }

            Text(capabilityNoticeText)
                .font(.system(size: 10))
                .foregroundStyle(capabilityKind == .bitmapUntouched ? TTKitTheme.archivalAmber : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
