// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import Foundation
import SwiftUI
import TTI18nCore
import TTKitDesign

/// Preset text colors modeled after IINA's subtitle quick settings.
public enum SubtitleColorPreset: String, CaseIterable, Codable, Sendable {
    case white
    case yellow
    case cyan
    case green

    public var color: Color {
        switch self {
        case .white:
            return .white
        case .yellow:
            return Color(red: 1.0, green: 0.92, blue: 0.23)
        case .cyan:
            return Color(red: 0.35, green: 0.92, blue: 1.0)
        case .green:
            return Color(red: 0.45, green: 0.95, blue: 0.55)
        }
    }

    internal var localeKey: MediaLocaleKey {
        switch self {
        case .white: return .colorWhite
        case .yellow: return .colorYellow
        case .cyan: return .colorCyan
        case .green: return .colorGreen
        }
    }
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

/// High-contrast subtitle canvas overlay supporting primary and secondary (bilingual) tracks,
/// anchored to the actual video content rectangle with continuous relative font sizing.
@MainActor
public struct SubtitleOverlayView: View {
    public let primaryText: String
    public let secondaryText: String
    public let style: SubtitleStyleConfiguration
    public let controlsVisible: Bool
    public var viewportWidth: CGFloat
    public let viewportHeight: CGFloat
    public var videoContentRect: CGRect?
    public var videoNaturalSize: CGSize?
    public var videoPixelAspectRatio: CGSize
    public var videoRotationDegrees: Int
    public var lastKnownVideoRect: CGRect?

    public init(
        primaryText: String,
        secondaryText: String,
        style: SubtitleStyleConfiguration,
        controlsVisible: Bool,
        viewportWidth: CGFloat = 800,
        viewportHeight: CGFloat,
        videoContentRect: CGRect? = nil,
        videoNaturalSize: CGSize? = nil,
        videoPixelAspectRatio: CGSize = CGSize(width: 1.0, height: 1.0),
        videoRotationDegrees: Int = 0,
        lastKnownVideoRect: CGRect? = nil
    ) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.style = style
        self.controlsVisible = controlsVisible
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.videoContentRect = videoContentRect
        self.videoNaturalSize = videoNaturalSize
        self.videoPixelAspectRatio = videoPixelAspectRatio
        self.videoRotationDegrees = videoRotationDegrees
        self.lastKnownVideoRect = lastKnownVideoRect
    }

    public var geometry: SubtitleVideoContentGeometry {
        SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: viewportWidth, height: viewportHeight),
            videoNaturalSize: videoNaturalSize,
            pixelAspectRatio: videoPixelAspectRatio,
            rotationDegrees: videoRotationDegrees,
            explicitVideoRect: videoContentRect,
            lastKnownVideoRect: lastKnownVideoRect
        )
    }

    public var layoutMetrics: SubtitleResolvedLayoutMetrics {
        SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: geometry)
    }

    public var bottomPadding: CGFloat {
        layoutMetrics.viewportBottomPadding
    }

    public var primaryRenderedFontSize: CGFloat {
        layoutMetrics.primaryFontSize
    }

    public var secondaryRenderedFontSize: CGFloat {
        layoutMetrics.secondaryFontSize
    }

    public func resolvedPrimaryFont() -> SubtitleResolvedFont {
        SubtitleFontResolver.resolve(style: style, size: primaryRenderedFontSize)
    }

    public func resolvedSecondaryFont() -> SubtitleResolvedFont {
        SubtitleFontResolver.resolve(style: style, size: secondaryRenderedFontSize)
    }

    public var body: some View {
        if !primaryText.isEmpty || !secondaryText.isEmpty {
            let metrics = layoutMetrics
            VStack(spacing: metrics.interTrackSpacing) {
                Spacer(minLength: 0)
                if !secondaryText.isEmpty {
                    styledTextBlock(
                        text: secondaryText,
                        size: metrics.secondaryFontSize,
                        metrics: metrics,
                        isSecondary: true
                    )
                }
                if !primaryText.isEmpty {
                    styledTextBlock(
                        text: primaryText,
                        size: metrics.primaryFontSize,
                        metrics: metrics,
                        isSecondary: false
                    )
                }
            }
            .frame(width: metrics.videoContentRect.width, alignment: .bottom)
            .padding(.bottom, metrics.viewportBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func styledTextBlock(
        text: String,
        size: CGFloat,
        metrics: SubtitleResolvedLayoutMetrics,
        isSecondary: Bool
    ) -> some View {
        let resolvedFont = SubtitleFontResolver.resolve(style: style, size: size)
        let configuredFont = resolvedFont.swiftUIFont
        let stroke = metrics.effectiveBorderWidth

        ZStack {
            if stroke > 0.1 {
                ForEach(Self.strokeOffsets(radius: stroke), id: \.id) { offset in
                    Text(text)
                        .font(configuredFont)
                        .lineSpacing(metrics.intraTrackLineSpacing)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.black.opacity(0.92))
                        .offset(x: offset.dx, y: offset.dy)
                }
            }
            Text(text)
                .font(configuredFont)
                .lineSpacing(metrics.intraTrackLineSpacing)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSecondary ? style.textColor.color.opacity(0.92) : style.textColor.color)
                .shadow(color: .black.opacity(0.85), radius: max(2.0, stroke + 1.0), y: 1.0)
        }
        .frame(maxWidth: metrics.maxTextWidth)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, size * (style.backgroundOpacity > 0.01 ? 0.4 : 0.13))
        .padding(.vertical, size * (style.backgroundOpacity > 0.01 ? 0.17 : 0.03))
        .background(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(Color.black.opacity(style.backgroundOpacity))
        )
    }

    private struct StrokeOffset: Identifiable {
        let id: Int
        let dx: CGFloat
        let dy: CGFloat
    }

    private static func strokeOffsets(radius: CGFloat) -> [StrokeOffset] {
        let r = min(4.5, max(0.4, radius))
        let d = r * 0.72
        return [
            StrokeOffset(id: 0, dx: -r, dy: 0),
            StrokeOffset(id: 1, dx: r, dy: 0),
            StrokeOffset(id: 2, dx: 0, dy: -r),
            StrokeOffset(id: 3, dx: 0, dy: r),
            StrokeOffset(id: 4, dx: -d, dy: -d),
            StrokeOffset(id: 5, dx: d, dy: -d),
            StrokeOffset(id: 6, dx: -d, dy: d),
            StrokeOffset(id: 7, dx: d, dy: d),
        ]
    }
}

/// Interactive popover inspector modeled after IINA's `QuickSettingViewController` subtitle tab.
@MainActor
internal struct SubtitleQuickSettingsPopover: View {
    let subtitleOptions: [SubtitleMenuOption]
    let selectedSubtitleID: String?
    let selectedSecondarySubtitleID: String
    let style: SubtitleStyleConfiguration
    var videoGeometry: SubtitleVideoContentGeometry? = nil
    var activeSubtitleCodec: String? = nil
    let onSelectSubtitle: (String) -> Void
    let onSelectSecondarySubtitle: (String) -> Void
    let onLoadSubtitles: () -> Void
    let onUpdateStyle: (SubtitleStyleConfiguration) -> Void
    let onUserInteraction: () -> Void

    @Environment(\.mediaControlsVisibility) private var mediaControlsVisibility
    @State private var showFontPickerPopover = false
    @State private var isHoldingQuickSettingsInteraction = false
    @State private var isHoldingFontPickerInteraction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            trackSelectionSection
            Divider()
            timingSection
            Divider()
            appearanceSection
            Divider()
            footerSection
        }
        .padding(14)
        .frame(width: 296)
        .onAppear {
            setQuickSettingsInteractionHeld(true)
            onUserInteraction()
        }
        .onDisappear {
            setFontPickerInteractionHeld(false)
            setQuickSettingsInteractionHeld(false)
        }
        .onChange(of: showFontPickerPopover) { _, isPresented in
            setFontPickerInteractionHeld(isPresented)
            onUserInteraction()
        }
    }

    private func setQuickSettingsInteractionHeld(_ shouldHold: Bool) {
        Self.syncInteractionDepth(
            isHeld: &isHoldingQuickSettingsInteraction,
            shouldHold: shouldHold,
            controls: mediaControlsVisibility
        )
    }

    private func setFontPickerInteractionHeld(_ shouldHold: Bool) {
        Self.syncInteractionDepth(
            isHeld: &isHoldingFontPickerInteraction,
            shouldHold: shouldHold,
            controls: mediaControlsVisibility
        )
    }

    internal static func syncInteractionDepth(
        isHeld: inout Bool,
        shouldHold: Bool,
        controls: MediaControlsVisibility?
    ) {
        guard shouldHold != isHeld else { return }
        isHeld = shouldHold
        if shouldHold {
            controls?.beginInteraction()
        } else {
            controls?.endInteraction()
        }
    }

    @ViewBuilder
    private var trackSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(MediaLocalization.text(.subtitleTrack))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(MediaLocalization.text(.loadSubtitles)) {
                    onLoadSubtitles()
                    onUserInteraction()
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.link)
            }

            Picker(
                "",
                selection: Binding(
                    get: { selectedSubtitleID ?? "off" },
                    set: { id in
                        onSelectSubtitle(id)
                        onUserInteraction()
                    }
                )
            ) {
                Text(MediaLocalization.text(.off)).tag("off")
                ForEach(subtitleOptions.filter(\.enabled)) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()

            HStack {
                Text(MediaLocalization.text(.secondarySubtitle))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Picker(
                "",
                selection: Binding(
                    get: { selectedSecondarySubtitleID },
                    set: { id in
                        onSelectSecondarySubtitle(id)
                        onUserInteraction()
                    }
                )
            ) {
                Text(MediaLocalization.text(.off)).tag("off")
                ForEach(subtitleOptions.filter { $0.enabled && $0.supportsSecondary }) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(MediaLocalization.text(.subtitleDelay))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1fs", style.delay))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            HStack(spacing: 6) {
                ForEach([-0.5, -0.1, 0.0, 0.1, 0.5], id: \.self) { step in
                    Button(step == 0.0 ? "0.0s" : String(format: "%+.1fs", step)) {
                        var updated = style
                        updated.delay = step == 0.0 ? 0.0 : min(10.0, max(-10.0, style.delay + step))
                        onUpdateStyle(updated)
                        onUserInteraction()
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fontSelectionRow

            SubtitleRelativeScaleSettingsView(
                style: style,
                geometry: videoGeometry,
                activeSubtitleCodec: activeSubtitleCodec,
                onUpdateStyle: onUpdateStyle,
                onUserInteraction: onUserInteraction
            )

            HStack {
                Text(MediaLocalization.text(.subtitlePosition))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(style.verticalPosition))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            Slider(
                value: Binding(
                    get: { style.verticalPosition },
                    set: { newPos in
                        var updated = style
                        updated.verticalPosition = newPos.rounded()
                        onUpdateStyle(updated)
                        onUserInteraction()
                    }
                ),
                in: 10.0...100.0
            )

            styleTogglesAndColorRow
            borderAndBackgroundRow
        }
    }

    @ViewBuilder
    private var fontSelectionRow: some View {
        HStack(spacing: 8) {
            Text(MediaLocalization.text(.subtitleFont))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showFontPickerPopover.toggle()
                onUserInteraction()
            } label: {
                HStack(spacing: 4) {
                    Text(SubtitleFontResolver.displayName(for: style))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .ttButtonHelp(MediaLocalization.text(.subtitleFontChoose))
            .popover(isPresented: $showFontPickerPopover, arrowEdge: .trailing) {
                SubtitleFontPickerView(
                    style: style,
                    onUpdateStyle: onUpdateStyle,
                    onUserInteraction: onUserInteraction,
                    onClose: { showFontPickerPopover = false }
                )
            }
        }
    }

    @ViewBuilder
    private var styleTogglesAndColorRow: some View {
        HStack(spacing: 8) {
            Toggle(
                MediaLocalization.text(.subtitleBold),
                isOn: Binding(
                    get: { style.isBold },
                    set: { val in
                        var updated = style
                        updated.isBold = val
                        onUpdateStyle(updated)
                        onUserInteraction()
                    }
                )
            )
            .toggleStyle(.button)
            .controlSize(.small)

            Toggle(
                MediaLocalization.text(.subtitleItalic),
                isOn: Binding(
                    get: { style.isItalic },
                    set: { val in
                        var updated = style
                        updated.isItalic = val
                        onUpdateStyle(updated)
                        onUserInteraction()
                    }
                )
            )
            .toggleStyle(.button)
            .controlSize(.small)

            Spacer()

            ForEach(SubtitleColorPreset.allCases, id: \.self) { preset in
                Button {
                    var updated = style
                    updated.textColor = preset
                    onUpdateStyle(updated)
                    onUserInteraction()
                } label: {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    style.textColor == preset ? Color.accentColor : Color.gray.opacity(0.45),
                                    lineWidth: style.textColor == preset ? 2.0 : 1.0
                                )
                        )
                }
                .buttonStyle(.plain)
                .ttButtonHelp(MediaLocalization.text(preset.localeKey))
            }
        }
    }

    @ViewBuilder
    private var borderAndBackgroundRow: some View {
        HStack(spacing: 10) {
            Text(MediaLocalization.text(.subtitleBorder))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker(
                "",
                selection: Binding(
                    get: { Int(style.borderWidth.rounded()) },
                    set: { width in
                        var updated = style
                        updated.borderWidth = Double(width)
                        onUpdateStyle(updated)
                        onUserInteraction()
                    }
                )
            ) {
                ForEach([0, 1, 2, 3, 4], id: \.self) { pt in
                    Text("\(pt)pt").tag(pt)
                }
            }
            .labelsHidden()
            .frame(width: 68)

            Spacer()

            Text(MediaLocalization.text(.subtitleBackground))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker(
                "",
                selection: Binding(
                    get: { Int((style.backgroundOpacity * 100.0).rounded()) },
                    set: { pct in
                        var updated = style
                        updated.backgroundOpacity = Double(pct) / 100.0
                        onUpdateStyle(updated)
                        onUserInteraction()
                    }
                )
            ) {
                ForEach([0, 35, 65, 85], id: \.self) { pct in
                    Text("\(pct)%").tag(pct)
                }
            }
            .labelsHidden()
            .frame(width: 68)
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        HStack {
            Spacer()
            Button(MediaLocalization.text(.subtitleReset)) {
                onUpdateStyle(SubtitleStyleConfiguration())
                onUserInteraction()
            }
            .font(.system(size: 11, weight: .medium))
            .controlSize(.small)
        }
    }
}
