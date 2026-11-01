// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import Foundation
import TTI18nCore
import TTI18nUI
import XCTest
@testable import TTMediaKit

final class SubtitleRelativeSizingAndMigrationTests: XCTestCase {

    // MARK: - 1. Cross-Window Visual Proportionality (Sidebar, Standalone Window, Fullscreen)

    @MainActor
    func testCrossWindowProportionalityAcrossSidebarStandaloneAndFullscreen() {
        let style = SubtitleStyleConfiguration(
            fontFamilyName: nil,
            fontSize: 24.0,
            scale: 1.0
        )
        let natural1080p = CGSize(width: 1920, height: 1080)

        let sidebarGeo = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 480, height: 270),
            videoNaturalSize: natural1080p
        )
        let windowGeo = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 960, height: 540),
            videoNaturalSize: natural1080p
        )
        let hdWindowGeo = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 1280, height: 720),
            videoNaturalSize: natural1080p
        )
        let fullscreenGeo = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 1920, height: 1080),
            videoNaturalSize: natural1080p
        )

        let sidebarMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: sidebarGeo)
        let windowMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: windowGeo)
        let hdMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: hdWindowGeo)
        let fullscreenMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: fullscreenGeo)

        // All four 16:9 windows within the unclamped [11pt, 96pt] range maintain the exact same primary font-to-video-height ratio (~4.44%).
        let expectedRatio = CGFloat(style.effectiveRelativeFontRatio)
        XCTAssertEqual(sidebarMetrics.primaryFontSize / sidebarMetrics.videoContentRect.height, expectedRatio, accuracy: 0.0001)
        XCTAssertEqual(windowMetrics.primaryFontSize / windowMetrics.videoContentRect.height, expectedRatio, accuracy: 0.0001)
        XCTAssertEqual(hdMetrics.primaryFontSize / hdMetrics.videoContentRect.height, expectedRatio, accuracy: 0.0001)
        XCTAssertEqual(fullscreenMetrics.primaryFontSize / fullscreenMetrics.videoContentRect.height, expectedRatio, accuracy: 0.0001)

        // Secondary subtitle maintains the 0.82x ratio across all window sizes.
        for metrics in [sidebarMetrics, windowMetrics, hdMetrics, fullscreenMetrics] {
            XCTAssertEqual(
                metrics.secondaryFontSize,
                metrics.primaryFontSize * SubtitleRelativeSizingResolver.secondaryFontSizeRatio,
                accuracy: 0.01
            )
        }
    }

    // MARK: - 2. Continuous Scale Slider Binding Path & Smooth Viewport Resize Without Step Discontinuities

    @MainActor
    func testContinuousScaleSliderMonotonicityWithoutStepJumps() {
        let geometry = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 1280, height: 720),
            videoNaturalSize: CGSize(width: 1920, height: 1080)
        )

        var currentStyle = SubtitleStyleConfiguration(fontSize: 24.0, scale: 0.50)
        var interactionCount = 0

        let makeControl: () -> SubtitleRelativeScaleSettingsView = {
            SubtitleRelativeScaleSettingsView(
                style: currentStyle,
                geometry: geometry,
                activeSubtitleCodec: "S_TEXT/UTF8",
                onUpdateStyle: { updated in currentStyle = updated },
                onUserInteraction: { interactionCount += 1 }
            )
        }

        // Exercise the real slider binding path with fine, non-0.05-quantized values.
        let fineSliderScales: [Double] = [
            0.50, 0.563, 0.618, 0.712, 0.837, 0.964, 1.013, 1.087, 1.142, 1.279, 1.389, 1.531, 1.672, 1.843, 2.00
        ]
        var previousPrimary: CGFloat = 0
        var previousSecondary: CGFloat = 0

        for (index, targetScale) in fineSliderScales.enumerated() {
            makeControl().continuousScaleBinding.wrappedValue = targetScale

            XCTAssertEqual(interactionCount, index + 1)
            XCTAssertEqual(
                currentStyle.scale,
                targetScale,
                accuracy: 0.000001,
                "Slider binding must preserve continuous scale \(targetScale) without 0.05 rounding"
            )
            XCTAssertEqual(makeControl().continuousScaleBinding.wrappedValue, targetScale, accuracy: 0.000001)

            let metrics = SubtitleRelativeSizingResolver.resolveMetrics(style: currentStyle, geometry: geometry)
            XCTAssertGreaterThan(metrics.primaryFontSize, previousPrimary)
            XCTAssertGreaterThan(metrics.secondaryFontSize, previousSecondary)
            previousPrimary = metrics.primaryFontSize
            previousSecondary = metrics.secondaryFontSize
        }

        // Verify non-grid value 1.013 does not falsely highlight the 1.0x preset button, while preset buttons snap accurately.
        makeControl().continuousScaleBinding.wrappedValue = 1.013
        XCTAssertFalse(makeControl().isPresetSelected(1.0))
        for preset in SubtitleRelativeScaleSettingsView.scalePresets {
            makeControl().applyScalePreset(preset)
            XCTAssertEqual(currentStyle.scale, preset, accuracy: 0.000001)
            XCTAssertTrue(makeControl().isPresetSelected(preset))
        }

        // Verify smooth continuity across the former 380pt compact threshold (360 -> 370 -> 378 -> 380 -> 382 -> 390 -> 400).
        let baseStyle = SubtitleStyleConfiguration(fontSize: 24.0, scale: 1.0)
        let widths: [CGFloat] = [360, 370, 378, 380, 382, 390, 400]
        var prevWidthSize: CGFloat = 0
        for width in widths {
            let height = width * 9.0 / 16.0
            let overlay = SubtitleOverlayView(
                primaryText: "连续缩放测试",
                secondaryText: "Continuous Resize",
                style: baseStyle,
                controlsVisible: true,
                viewportWidth: width,
                viewportHeight: height,
                videoNaturalSize: CGSize(width: 1920, height: 1080)
            )
            if prevWidthSize > 0 {
                XCTAssertGreaterThanOrEqual(overlay.primaryRenderedFontSize, prevWidthSize)
                XCTAssertLessThan(overlay.primaryRenderedFontSize - prevWidthSize, 1.0, "No step jump at 380pt")
            }
            prevWidthSize = overlay.primaryRenderedFontSize
        }
    }

    // MARK: - 3. Letterbox (2.39:1), Pillarbox (9:16), Rotation (90/270) & Anamorphic PAR

    @MainActor
    func testLetterboxUltrawidePillarboxPortraitAndRotation90And270Geometry() {
        let style = SubtitleStyleConfiguration(fontSize: 24.0, scale: 1.0)
        let viewport = CGSize(width: 1280, height: 720)

        // 1. Ultra-wide 2.39:1 (1920x804) letterboxed inside 1280x720 (top/bottom black bars of 92pt each).
        let ultrawideGeo = SubtitleVideoContentGeometry(
            viewportSize: viewport,
            videoNaturalSize: CGSize(width: 1920, height: 804)
        )
        let ultrawideMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: ultrawideGeo)
        XCTAssertEqual(ultrawideMetrics.resolutionSource, .trackMetadata)
        XCTAssertEqual(ultrawideMetrics.videoContentRect.width, 1280.0, accuracy: 0.01)
        XCTAssertEqual(ultrawideMetrics.videoContentRect.height, 536.0, accuracy: 0.01)
        XCTAssertEqual(ultrawideMetrics.videoContentRect.minY, 92.0, accuracy: 0.01)
        // Bottom padding in viewport includes the 92pt bottom letterbox bar + contentBottomOffset.
        XCTAssertEqual(
            ultrawideMetrics.viewportBottomPadding,
            92.0 + ultrawideMetrics.contentBottomOffset,
            accuracy: 0.01
        )

        // 2. Native portrait 9:16 (1080x1920) pillarboxed inside 1280x720 (left/right black bars of 437.5pt each).
        let portraitGeo = SubtitleVideoContentGeometry(
            viewportSize: viewport,
            videoNaturalSize: CGSize(width: 1080, height: 1920)
        )
        let portraitMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: portraitGeo)
        XCTAssertEqual(portraitMetrics.videoContentRect.width, 405.0, accuracy: 0.01)
        XCTAssertEqual(portraitMetrics.videoContentRect.height, 720.0, accuracy: 0.01)
        XCTAssertEqual(portraitMetrics.videoContentRect.minX, 437.5, accuracy: 0.01)
        XCTAssertEqual(portraitMetrics.effectiveReferenceHeight, 405.0 * 1.25, accuracy: 0.01)
        XCTAssertLessThanOrEqual(portraitMetrics.maxTextWidth, portraitMetrics.videoContentRect.width - 20.0)

        // 3. Rotated 90° and 270° landscape track (1920x1080 rotated to portrait) matches native 1080x1920.
        let transform90 = CGAffineTransform(rotationAngle: .pi / 2.0)
        let deg90 = SubtitleVideoContentGeometry.rotationDegrees(fromPreferredTransform: transform90)
        XCTAssertEqual(deg90, 90)

        for rot in [90, 270, -90] {
            let rotatedGeo = SubtitleVideoContentGeometry(
                viewportSize: viewport,
                videoNaturalSize: CGSize(width: 1920, height: 1080),
                rotationDegrees: rot
            )
            let rotatedMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: rotatedGeo)
            XCTAssertEqual(rotatedMetrics.videoContentRect, portraitMetrics.videoContentRect)
            XCTAssertEqual(rotatedMetrics.primaryFontSize, portraitMetrics.primaryFontSize, accuracy: 0.001)
            XCTAssertEqual(rotatedMetrics.maxTextWidth, portraitMetrics.maxTextWidth, accuracy: 0.001)
        }

        // 4. Anamorphic 1440x1080 with 4:3 PAR expands to 1920x1080 (full 1280x720 rect).
        let anamorphicGeo = SubtitleVideoContentGeometry(
            viewportSize: viewport,
            videoNaturalSize: CGSize(width: 1440, height: 1080),
            pixelAspectRatio: CGSize(width: 4.0, height: 3.0)
        )
        let anamorphicMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: anamorphicGeo)
        XCTAssertEqual(anamorphicMetrics.videoContentRect, CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    // MARK: - 4. Pre-First-Frame & Missing Metadata Deterministic Fallback

    @MainActor
    func testPreFirstFrameAndMissingMetadataStableFallbackRules() {
        let style = SubtitleStyleConfiguration(fontSize: 24.0, scale: 1.0)

        // When metadata is nil but lastKnownVideoRect exists (e.g., during seek or viewport handoff):
        let lastKnown = CGRect(x: 0, y: 92, width: 1280, height: 536)
        let fallbackLastKnownGeo = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 640, height: 360),
            videoNaturalSize: nil,
            lastKnownVideoRect: lastKnown
        )
        let lastKnownMetrics = SubtitleRelativeSizingResolver.resolveMetrics(
            style: style,
            geometry: fallbackLastKnownGeo
        )
        XCTAssertEqual(lastKnownMetrics.resolutionSource, .lastKnownFallback)
        XCTAssertEqual(lastKnownMetrics.videoContentRect.width, 640.0, accuracy: 0.01)
        XCTAssertEqual(lastKnownMetrics.videoContentRect.height, 268.0, accuracy: 0.01)

        // When opening a video before any metadata or first frame arrives: falls back to canonical 16:9.
        let coldStartGeo = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 800, height: 600),
            videoNaturalSize: nil,
            lastKnownVideoRect: nil
        )
        let coldStartMetrics = SubtitleRelativeSizingResolver.resolveMetrics(
            style: style,
            geometry: coldStartGeo
        )
        XCTAssertEqual(coldStartMetrics.resolutionSource, .canonicalAspectFallback)
        XCTAssertEqual(coldStartMetrics.videoContentRect.width, 800.0, accuracy: 0.01)
        XCTAssertEqual(coldStartMetrics.videoContentRect.height, 450.0, accuracy: 0.01)
        XCTAssertEqual(coldStartMetrics.videoContentRect.minY, 75.0, accuracy: 0.01)

        // Degenerate zero viewport size never produces NaN or zero font size.
        let zeroGeo = SubtitleVideoContentGeometry(viewportSize: .zero)
        let zeroMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: zeroGeo)
        XCTAssertTrue(zeroMetrics.primaryFontSize.isFinite)
        XCTAssertEqual(zeroMetrics.primaryFontSize, 24.0, accuracy: 0.01)
    }

    // MARK: - 5. One-Time Idempotent Legacy Absolute Font Size Migration

    func testOneTimeIdempotentLegacyAbsoluteFontSizeMigration() throws {
        let suiteName = "com.metastudyline.ttmedia.tests.s1.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Simulate a legacy v1 JSON payload saved before `sizingSchemaVersion` and `relativeFontRatio` existed.
        let legacyV1JSON = """
        {
            "fontFamilyName": "Helvetica Neue",
            "fontSize": 30.0,
            "scale": 1.25,
            "isBold": true,
            "isItalic": false,
            "textColor": "yellow",
            "borderWidth": 3.0,
            "backgroundOpacity": 0.35,
            "verticalPosition": 84.0,
            "delay": -0.6
        }
        """.data(using: .utf8)!
        defaults.set(legacyV1JSON, forKey: SubtitleStyleConfiguration.defaultsKey)

        // First load performs one-time migration from v1 -> v2 and writes v2 back to UserDefaults.
        let firstReport = SubtitleStyleConfiguration.loadAndMigrateIfNeeded(from: defaults)
        XCTAssertTrue(firstReport.didMigrateFromLegacy, "First load of v1 payload must trigger migration")
        XCTAssertNil(firstReport.previousSchemaVersion)
        XCTAssertEqual(firstReport.configuration.sizingSchemaVersion, SubtitleStyleConfiguration.currentSizingSchemaVersion)
        XCTAssertEqual(firstReport.configuration.fontFamilyName, "Helvetica Neue")
        XCTAssertEqual(firstReport.configuration.fontSize, 30.0, accuracy: 0.001)
        XCTAssertEqual(firstReport.configuration.relativeFontRatio, 30.0 / 540.0, accuracy: 0.0001)
        XCTAssertEqual(firstReport.configuration.scale, 1.25, accuracy: 0.001)
        XCTAssertEqual(firstReport.configuration.textColor, .yellow)
        XCTAssertEqual(firstReport.configuration.verticalPosition, 84.0, accuracy: 0.001)
        XCTAssertEqual(firstReport.configuration.delay, -0.6, accuracy: 0.001)
        XCTAssertEqual(
            defaults.integer(forKey: SubtitleStyleConfiguration.migrationVersionDefaultsKey),
            SubtitleStyleConfiguration.currentSizingSchemaVersion
        )

        // Second load sees v2 schema already persisted in UserDefaults and MUST NOT re-migrate.
        let secondReport = SubtitleStyleConfiguration.loadAndMigrateIfNeeded(from: defaults)
        XCTAssertFalse(secondReport.didMigrateFromLegacy, "Subsequent startups must not repeat migration")
        XCTAssertEqual(secondReport.previousSchemaVersion, SubtitleStyleConfiguration.currentSizingSchemaVersion)
        XCTAssertEqual(secondReport.configuration, firstReport.configuration)
    }

    // MARK: - 6. Dual-Track Non-Overlap, Long Mixed Text Wrapping & Control Bar Visibility Invariance

    @MainActor
    func testDualTrackNonOverlapControlsVisibilityInvarianceAndLongMixedLineWrapping() {
        let style = SubtitleStyleConfiguration(
            fontFamilyName: "Menlo",
            fontSize: 26.0,
            scale: 1.15,
            isBold: true,
            verticalPosition: 88.0
        )
        let longPrimary = "这是一段用于验证在侧栏小窗、独立窗口、竖屏及宽银幕黑边场景下自动换行与主副字幕不重叠的超长中英混排字幕 · The quick brown fox jumps over the lazy dog 0123456789"
        let longSecondary = "Secondary bilingual track verifying 0.82x proportional scaling and non-overlapping vertical stack layout across multi-line wraps"

        let scenarios: [(CGSize, CGSize?)] = [
            (CGSize(width: 340, height: 210), CGSize(width: 1920, height: 1080)), // Sidebar compact
            (CGSize(width: 960, height: 540), CGSize(width: 1920, height: 1080)), // Standard 16:9
            (CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 804)), // 2.39:1 Letterbox
            (CGSize(width: 1280, height: 720), CGSize(width: 1080, height: 1920)) // 9:16 Pillarbox
        ]

        for (viewport, naturalSize) in scenarios {
            let visible = SubtitleOverlayView(
                primaryText: longPrimary,
                secondaryText: longSecondary,
                style: style,
                controlsVisible: true,
                viewportWidth: viewport.width,
                viewportHeight: viewport.height,
                videoNaturalSize: naturalSize
            )
            let hidden = SubtitleOverlayView(
                primaryText: longPrimary,
                secondaryText: longSecondary,
                style: style,
                controlsVisible: false,
                viewportWidth: viewport.width,
                viewportHeight: viewport.height,
                videoNaturalSize: naturalSize
            )

            // Controls visibility invariance: showing/hiding controls never moves subtitle position or changes font size.
            XCTAssertEqual(visible.bottomPadding, hidden.bottomPadding, accuracy: 0.0001)
            XCTAssertEqual(visible.primaryRenderedFontSize, hidden.primaryRenderedFontSize, accuracy: 0.0001)
            XCTAssertEqual(visible.secondaryRenderedFontSize, hidden.secondaryRenderedFontSize, accuracy: 0.0001)

            // Non-overlapping stack spacing and bounded horizontal wrapping width inside videoContentRect.
            let metrics = visible.layoutMetrics
            XCTAssertGreaterThanOrEqual(metrics.interTrackSpacing, 3.0)
            XCTAssertGreaterThanOrEqual(metrics.intraTrackLineSpacing, 1.5)
            XCTAssertLessThanOrEqual(metrics.maxTextWidth, metrics.videoContentRect.width - 20.0 + 0.01)

            // Verify zero missing glyphs on long mixed CJK + English line.
            let primaryFont = visible.resolvedPrimaryFont()
            XCTAssertTrue(
                SubtitleFontResolver.rendersWithoutMissingGlyphs(text: longPrimary, font: primaryFont.nsFont)
            )
        }
    }

    // MARK: - 7. Capability Boundary Classification & Independent TTI18n Vocabulary

    @MainActor
    func testCapabilityBoundaryClassificationAndLocalization() {
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: nil), .textOverlay)
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "S_TEXT/UTF8"), .textOverlay)
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "movie.zh.srt"), .textOverlay)
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "captions.vtt"), .textOverlay)

        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "S_TEXT/ASS"), .assPlainTextExtracts)
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "S_TEXT/SSA"), .assPlainTextExtracts)
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "anime.ass"), .assPlainTextExtracts)

        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "S_HDMV/PGS"), .bitmapUntouched)
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "S_VOBSUB"), .bitmapUntouched)
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "S_DVBSUB"), .bitmapUntouched)
        XCTAssertEqual(SubtitleRelativeSizingResolver.capability(forCodecOrFormat: "bluray.sup"), .bitmapUntouched)

        let originalLanguage = LocalizationState.shared.currentLanguage
        defer { LocalizationState.shared.setLanguage(originalLanguage) }

        for language in [AppLanguage.en, .zhHans, .zhHant, .ja] {
            LocalizationState.shared.setLanguage(language)
            for key in SubtitleRelativeSizingLocaleKey.allCases {
                let text = MediaLocalization.text(key)
                XCTAssertFalse(text.isEmpty, "Empty translation for \(key) in \(language)")
                XCTAssertNotEqual(text, key.rawValue, "Unresolved raw key \(key.rawValue) in \(language)")
            }
            let badge = MediaLocalization.formattedRelativeHeightBadge(scaleText: "1.25x", percentText: "5.6%")
            XCTAssertTrue(badge.contains("1.25x"))
            XCTAssertTrue(badge.contains("5.6%"))
        }
    }

    // MARK: - 8. Isolated Defaults Persistence of Continuous Slider Binding & [11pt, 96pt] Clamp Exceptions

    @MainActor
    func testScaleSettingsBindingIsolatedPersistenceAndReadabilityClampBounds() throws {
        let suiteName = "com.metastudyline.ttmedia.tests.s1.continuous.\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        var persistedStyle = SubtitleStyleConfiguration.loadFromDefaults(isolatedDefaults)
        let settingsControl = SubtitleRelativeScaleSettingsView(
            style: persistedStyle,
            onUpdateStyle: { updated in
                persistedStyle = updated
                updated.saveToDefaults(isolatedDefaults)
            }
        )

        // Write a non-0.05-multiple value through the actual slider binding and verify isolated persistence round-trip.
        settingsControl.continuousScaleBinding.wrappedValue = 1.137
        let reloadedReport = SubtitleStyleConfiguration.loadAndMigrateIfNeeded(from: isolatedDefaults)
        XCTAssertFalse(reloadedReport.didMigrateFromLegacy)
        XCTAssertEqual(reloadedReport.configuration.scale, 1.137, accuracy: 0.000001)
        XCTAssertEqual(
            reloadedReport.configuration.effectiveRelativeFontRatio,
            SubtitleStyleConfiguration.defaultRelativeFontRatio * 1.137,
            accuracy: 0.000001
        )

        // Verify lower clamp exception: tiny sidebar (240x135) with minimum base (14pt) and 0.5x scale clamps at 11.0pt / 9.5pt.
        let tinyStyle = SubtitleStyleConfiguration(fontSize: 14.0, scale: 0.5)
        let tinyGeo = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 240, height: 135),
            videoNaturalSize: CGSize(width: 1920, height: 1080)
        )
        let tinyMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: tinyStyle, geometry: tinyGeo)
        XCTAssertEqual(tinyMetrics.primaryFontSize, SubtitleRelativeSizingResolver.minPrimaryFontSize, accuracy: 0.001)
        XCTAssertEqual(tinyMetrics.secondaryFontSize, SubtitleRelativeSizingResolver.minSecondaryFontSize, accuracy: 0.001)

        // Verify upper clamp exception: 4K canvas (3840x2160) with max base (48pt) and 2.0x scale clamps at 96.0pt / 78.72pt.
        let hugeStyle = SubtitleStyleConfiguration(fontSize: 48.0, scale: 2.0)
        let hugeGeo = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 3840, height: 2160),
            videoNaturalSize: CGSize(width: 3840, height: 2160)
        )
        let hugeMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: hugeStyle, geometry: hugeGeo)
        XCTAssertEqual(hugeMetrics.primaryFontSize, SubtitleRelativeSizingResolver.maxPrimaryFontSize, accuracy: 0.001)
        XCTAssertEqual(hugeMetrics.secondaryFontSize, SubtitleRelativeSizingResolver.maxSecondaryFontSize, accuracy: 0.001)
    }
}
