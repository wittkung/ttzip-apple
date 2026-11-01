// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreMedia
import Foundation
import TTI18nCore
import TTI18nUI
import XCTest
@testable import TTMediaKit

final class SubtitleFontConfigurationTests: XCTestCase {

    // MARK: - 1. Legacy JSON Migration & Persistence

    func testLegacyJSONWithoutFontFieldPreservesAllCustomStyleFields() throws {
        // Legacy JSON produced before `fontFamilyName` was added to `SubtitleStyleConfiguration`.
        let legacyJSON = Data("""
        {
          "fontSize": 32.0,
          "scale": 1.35,
          "isBold": true,
          "isItalic": true,
          "textColor": "yellow",
          "borderWidth": 3.0,
          "backgroundOpacity": 0.65,
          "verticalPosition": 78.0,
          "delay": -1.4
        }
        """.utf8)

        let suiteName = "com.metastudyline.ttmedia.tests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(legacyJSON, forKey: SubtitleStyleConfiguration.defaultsKey)
        let migrated = SubtitleStyleConfiguration.loadFromDefaults(defaults)

        XCTAssertNil(migrated.fontFamilyName, "Legacy payload without fontFamilyName must default to System Default (nil)")
        XCTAssertEqual(migrated.fontSize, 32.0, accuracy: 0.001)
        XCTAssertEqual(migrated.scale, 1.35, accuracy: 0.001)
        XCTAssertTrue(migrated.isBold)
        XCTAssertTrue(migrated.isItalic)
        XCTAssertEqual(migrated.textColor, .yellow)
        XCTAssertEqual(migrated.borderWidth, 3.0, accuracy: 0.001)
        XCTAssertEqual(migrated.backgroundOpacity, 0.65, accuracy: 0.001)
        XCTAssertEqual(migrated.verticalPosition, 78.0, accuracy: 0.001)
        XCTAssertEqual(migrated.delay, -1.4, accuracy: 0.001)
    }

    func testFontPersistenceRoundTripAndIdentifierNormalization() throws {
        let suiteName = "com.metastudyline.ttmedia.tests.persist.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for sentinel in [nil, "", "   ", "system", "DEFAULT", SubtitleFontFamily.systemDefaultID] {
            let normalized = SubtitleStyleConfiguration(fontFamilyName: sentinel)
            XCTAssertNil(normalized.fontFamilyName, "Sentinel \(String(describing: sentinel)) must normalize to nil")
        }

        let custom = SubtitleStyleConfiguration(
            fontFamilyName: "  Menlo  ",
            fontSize: 28.0,
            scale: 1.2,
            isBold: true,
            isItalic: false,
            textColor: .cyan,
            borderWidth: 2.0,
            backgroundOpacity: 0.35,
            verticalPosition: 85.0,
            delay: 0.5
        )
        XCTAssertEqual(custom.fontFamilyName, "Menlo")

        custom.saveToDefaults(defaults)
        let reloaded = SubtitleStyleConfiguration.loadFromDefaults(defaults)
        XCTAssertEqual(reloaded, custom)
        XCTAssertEqual(reloaded.fontFamilyName, "Menlo")
    }

    // MARK: - 2. System Default, Multiple Local Fonts & Uninstalled Font Fallback

    @MainActor
    func testSwitchingBetweenSystemDefaultAndInstalledLocalFontsChangesResolvedFont() {
        let families = SubtitleFontResolver.availableFamilies(includeSystemDefault: true)
        XCTAssertGreaterThan(families.count, 3, "macOS should expose system default plus installed font families")
        XCTAssertTrue(families[0].isSystemDefault)

        let defaultStyle = SubtitleStyleConfiguration(fontFamilyName: nil, fontSize: 24.0, scale: 1.0)
        let menloStyle = SubtitleStyleConfiguration(fontFamilyName: "Menlo", fontSize: 24.0, scale: 1.0)
        let timesStyle = SubtitleStyleConfiguration(fontFamilyName: "Times New Roman", fontSize: 24.0, scale: 1.0)

        let resolvedDefault = SubtitleFontResolver.resolve(style: defaultStyle, size: defaultStyle.effectiveFontSize)
        let resolvedMenlo = SubtitleFontResolver.resolve(style: menloStyle, size: menloStyle.effectiveFontSize)
        let resolvedTimes = SubtitleFontResolver.resolve(style: timesStyle, size: timesStyle.effectiveFontSize)

        XCTAssertTrue(resolvedDefault.isSystemDefault)
        XCTAssertFalse(resolvedDefault.isFallbackToSystem)

        XCTAssertFalse(resolvedMenlo.isSystemDefault)
        XCTAssertFalse(resolvedMenlo.isFallbackToSystem)
        XCTAssertTrue(resolvedMenlo.resolvedPostScriptName.localizedCaseInsensitiveContains("Menlo"))

        XCTAssertFalse(resolvedTimes.isSystemDefault)
        XCTAssertFalse(resolvedTimes.isFallbackToSystem)
        XCTAssertTrue(resolvedTimes.resolvedPostScriptName.localizedCaseInsensitiveContains("Times"))

        // Switching across System Default, Menlo, and Times New Roman produces distinct PostScript fonts.
        let postScriptSet: Set<String> = [
            resolvedDefault.resolvedPostScriptName,
            resolvedMenlo.resolvedPostScriptName,
            resolvedTimes.resolvedPostScriptName,
        ]
        XCTAssertEqual(postScriptSet.count, 3)
    }

    @MainActor
    func testInvalidOrUninstalledFontFallsBackSafelyAndRendersChineseAndMixedTextWithoutMissingGlyphs() {
        let sampleTexts = [
            "中文字幕测试：哪怕你完全不知道 π 的十进制展开",
            "English Subtitle Sample 0123456789",
            "中英混合 Bilingual 字幕 · AVSampleBuffer 4K 60fps",
        ]

        let invalidStyle = SubtitleStyleConfiguration(
            fontFamilyName: "UninstalledFont-DoesNotExist-9999",
            fontSize: 26.0,
            scale: 1.1,
            isBold: true,
            isItalic: true
        )
        let fallbackResolved = SubtitleFontResolver.resolve(style: invalidStyle, size: invalidStyle.effectiveFontSize)
        XCTAssertFalse(fallbackResolved.isSystemDefault)
        XCTAssertTrue(fallbackResolved.isFallbackToSystem, "Missing font must flag safe fallback to system font")
        XCTAssertEqual(
            SubtitleFontResolver.displayName(for: invalidStyle),
            MediaLocalization.text(.subtitleFontSystemDefault)
        )

        // Verify Chinese, English, and mixed text have zero missing glyphs (`.notdef` / glyph 0)
        // under System Default, uninstalled fallback font, Latin font with CJK cascade (Menlo), and CJK font (PingFang SC).
        let stylesToVerify: [SubtitleStyleConfiguration] = [
            SubtitleStyleConfiguration(fontFamilyName: nil),
            invalidStyle,
            SubtitleStyleConfiguration(fontFamilyName: "Menlo", isBold: true),
            SubtitleStyleConfiguration(fontFamilyName: "PingFang SC", isBold: true),
        ]

        for style in stylesToVerify {
            let resolved = SubtitleFontResolver.resolve(style: style, size: style.effectiveFontSize)
            for sample in sampleTexts {
                XCTAssertTrue(
                    SubtitleFontResolver.rendersWithoutMissingGlyphs(text: sample, font: resolved.nsFont),
                    "Font \(resolved.resolvedPostScriptName) produced missing glyph (.notdef) for text: \(sample)"
                )
            }
        }
    }

    // MARK: - 3. Primary/Secondary Ratio, Compact Viewport Scaling & Invariant Positioning

    @MainActor
    func testOverlayPreservesSecondaryFontSizeRatioCompactScalingAndControlVisibilityInvariance() {
        let style = SubtitleStyleConfiguration(
            fontFamilyName: "Menlo",
            fontSize: 24.0,
            scale: 1.25,
            isBold: true,
            isItalic: true,
            textColor: .cyan,
            borderWidth: 3.0,
            backgroundOpacity: 0.65,
            verticalPosition: 82.0
        )

        let wideVisible = SubtitleOverlayView(
            primaryText: "主字幕：你好世界",
            secondaryText: "Secondary: Hello World",
            style: style,
            controlsVisible: true,
            viewportWidth: 960,
            viewportHeight: 540
        )
        let wideHidden = SubtitleOverlayView(
            primaryText: "主字幕：你好世界",
            secondaryText: "Secondary: Hello World",
            style: style,
            controlsVisible: false,
            viewportWidth: 960,
            viewportHeight: 540
        )

        XCTAssertEqual(wideVisible.primaryRenderedFontSize, 30.0, accuracy: 0.01)
        XCTAssertEqual(wideVisible.secondaryRenderedFontSize, 30.0 * 0.82, accuracy: 0.01)
        XCTAssertEqual(wideVisible.bottomPadding, wideHidden.bottomPadding, accuracy: 0.001)

        let primaryFont = wideVisible.resolvedPrimaryFont()
        let secondaryFont = wideVisible.resolvedSecondaryFont()
        XCTAssertEqual(primaryFont.resolvedPostScriptName, secondaryFont.resolvedPostScriptName)
        XCTAssertTrue(primaryFont.resolvedPostScriptName.localizedCaseInsensitiveContains("Menlo"))
        XCTAssertTrue(primaryFont.nsFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(primaryFont.nsFont.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertEqual(primaryFont.nsFont.pointSize, 30.0, accuracy: 0.01)
        XCTAssertEqual(secondaryFont.nsFont.pointSize, 24.6, accuracy: 0.01)

        // Compact viewport (< 380pt) scales down while keeping controlsVisible invariance.
        let compactVisible = SubtitleOverlayView(
            primaryText: "主字幕",
            secondaryText: "Secondary",
            style: style,
            controlsVisible: true,
            viewportWidth: 300,
            viewportHeight: 220
        )
        let compactHidden = SubtitleOverlayView(
            primaryText: "主字幕",
            secondaryText: "Secondary",
            style: style,
            controlsVisible: false,
            viewportWidth: 300,
            viewportHeight: 220
        )
        XCTAssertLessThan(compactVisible.primaryRenderedFontSize, wideVisible.primaryRenderedFontSize)
        XCTAssertEqual(compactVisible.bottomPadding, compactHidden.bottomPadding, accuracy: 0.001)
    }

    // MARK: - 4. Production Session Integration Tests (Requires Full TTMediaKit Target)

    private func withRestoredStandardSubtitleDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let savedPayload = defaults.data(forKey: SubtitleStyleConfiguration.defaultsKey)
        let savedMigration = defaults.object(forKey: SubtitleStyleConfiguration.migrationVersionDefaultsKey)
        defer {
            if let savedPayload {
                defaults.set(savedPayload, forKey: SubtitleStyleConfiguration.defaultsKey)
            } else {
                defaults.removeObject(forKey: SubtitleStyleConfiguration.defaultsKey)
            }
            if let savedMigration {
                defaults.set(savedMigration, forKey: SubtitleStyleConfiguration.migrationVersionDefaultsKey)
            } else {
                defaults.removeObject(forKey: SubtitleStyleConfiguration.migrationVersionDefaultsKey)
            }
        }
        return try await body()
    }

    @MainActor
    func testUpdatingFontDuringPlaybackDoesNotReloadSubtitlesOrInterruptPlaybackState() async {
        await withRestoredStandardSubtitleDefaults {
            let counter = SubtitleFontTestLoadCounter()
            let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/font-switch-live.mkv"))
            session.externalSubtitleLoader = { _ in
                await counter.recordExternal()
                return ExternalSubtitleTrack(cues: [])
            }
            session.embeddedSubtitleLoader = { _ in
                await counter.recordEmbedded()
                return Data()
            }

            session.subtitleCache["embedded:1"] = ExternalSubtitleTrack(
                cues: [.init(start: 0.0, end: 10.0, text: "第一行中文")]
            )
            session.subtitleCache["embedded:2"] = ExternalSubtitleTrack(
                cues: [.init(start: 0.0, end: 10.0, text: "First line English")]
            )
            session.currentTime = CMTime(seconds: 4.2, preferredTimescale: 600)
            session.isPlaying = true
            session.selectSubtitle("embedded:1", showFeedback: false)
            session.selectSecondarySubtitle("embedded:2")

            let initialPrimaryGen = session.subtitleLoadGeneration
            let initialSecondaryGen = session.secondarySubtitleLoadGeneration
            let initialPrewarmGen = session.subtitlePrewarmGeneration

            var updated = session.subtitleStyle
            updated.fontFamilyName = "Menlo"
            session.updateSubtitleStyle(updated)

            XCTAssertEqual(session.subtitleStyle.fontFamilyName, "Menlo")
            XCTAssertEqual(session.activeSubtitleText, "第一行中文")
            XCTAssertEqual(session.activeSecondarySubtitleText, "First line English")
            XCTAssertTrue(session.isPlaying)
            XCTAssertEqual(CMTimeGetSeconds(session.currentTime), 4.2, accuracy: 0.001)
            XCTAssertEqual(session.subtitleLoadGeneration, initialPrimaryGen, "Font change must not re-select or reload primary subtitle")
            XCTAssertEqual(session.secondarySubtitleLoadGeneration, initialSecondaryGen, "Font change must not reload secondary subtitle")
            XCTAssertEqual(session.subtitlePrewarmGeneration, initialPrewarmGen, "Font change must not restart subtitle prewarm")

            let counts = await counter.snapshot()
            XCTAssertEqual(counts.external, 0)
            XCTAssertEqual(counts.embedded, 0)

            session.stop()
        }
    }

    @MainActor
    func testFontStylePreservedAcrossFullscreenRoundTripAndNewSessionReload() async {
        await withRestoredStandardSubtitleDefaults {
            let sessions = VideoPlaybackSessions()
            let url = URL(fileURLWithPath: "/tmp/font-roundtrip.mkv")
            let inspectorViewport = UUID()
            let fullScreenViewport = UUID()

            let initialSession = sessions.claim(url: url, viewportID: inspectorViewport, isFullScreen: false)
            var configuredStyle = initialSession.subtitleStyle
            configuredStyle.fontFamilyName = "Times New Roman"
            configuredStyle.fontSize = 28.0
            configuredStyle.scale = 1.2
            configuredStyle.isBold = true
            initialSession.updateSubtitleStyle(configuredStyle)

            // Expand to full-window viewport and return to inspector viewport: same session and font style retained.
            let fullScreenSession = sessions.claim(url: url, viewportID: fullScreenViewport, isFullScreen: true)
            XCTAssertTrue(initialSession === fullScreenSession)
            XCTAssertEqual(fullScreenSession.subtitleStyle.fontFamilyName, "Times New Roman")
            XCTAssertEqual(fullScreenSession.subtitleStyle.fontSize, 28.0, accuracy: 0.001)
            XCTAssertEqual(fullScreenSession.subtitleStyle.scale, 1.2, accuracy: 0.001)

            sessions.release(sessionID: fullScreenSession.sessionID, viewportID: fullScreenViewport)
            let restoredInspectorSession = sessions.claim(url: url, viewportID: inspectorViewport, isFullScreen: false)
            XCTAssertTrue(initialSession === restoredInspectorSession)
            XCTAssertEqual(restoredInspectorSession.subtitleStyle.fontFamilyName, "Times New Roman")
            sessions.release(sessionID: restoredInspectorSession.sessionID, viewportID: inspectorViewport)
            initialSession.stop()

            // Simulate closing/reopening or app restart: a freshly initialized VideoPlaybackSession loads persisted font from UserDefaults.
            let freshSessionAfterRestart = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/another-video.mp4"))
            XCTAssertEqual(freshSessionAfterRestart.subtitleStyle.fontFamilyName, "Times New Roman")
            XCTAssertEqual(freshSessionAfterRestart.subtitleStyle.fontSize, 28.0, accuracy: 0.001)
            XCTAssertEqual(freshSessionAfterRestart.subtitleStyle.scale, 1.2, accuracy: 0.001)
            XCTAssertTrue(freshSessionAfterRestart.subtitleStyle.isBold)
            freshSessionAfterRestart.stop()
        }
    }

    // MARK: - 5. Catalog Search & Shared TTI18n Coverage

    @MainActor
    func testFontCatalogFilteringAndSharedTTI18nTranslations() {
        let sampleCatalog = [
            SubtitleFontFamily(
                familyName: SubtitleFontFamily.systemDefaultID,
                localizedName: "System Default",
                faces: [SubtitleFontFace(postScriptName: SubtitleFontFamily.systemDefaultID, displayName: "Rounded")],
                isSystemDefault: true
            ),
            SubtitleFontFamily(
                familyName: "PingFang SC",
                localizedName: "苹方-简",
                faces: [
                    SubtitleFontFace(postScriptName: "PingFangSC-Regular", displayName: "常规体"),
                    SubtitleFontFace(postScriptName: "PingFangSC-Semibold", displayName: "中粗体"),
                ]
            ),
            SubtitleFontFamily(
                familyName: "Menlo",
                localizedName: "Menlo",
                faces: [
                    SubtitleFontFace(postScriptName: "Menlo-Regular", displayName: "Regular"),
                    SubtitleFontFace(postScriptName: "Menlo-Bold", displayName: "Bold"),
                ]
            ),
        ]

        XCTAssertEqual(SubtitleFontResolver.filterFamilies(sampleCatalog, query: "").count, 3)
        XCTAssertEqual(SubtitleFontResolver.filterFamilies(sampleCatalog, query: "苹方").map(\.familyName), ["PingFang SC"])
        XCTAssertEqual(SubtitleFontResolver.filterFamilies(sampleCatalog, query: "PingFangSC-Semibold").map(\.familyName), ["PingFang SC"])
        XCTAssertEqual(SubtitleFontResolver.filterFamilies(sampleCatalog, query: "menlo").map(\.familyName), ["Menlo"])
        XCTAssertTrue(SubtitleFontResolver.filterFamilies(sampleCatalog, query: "nonexistent-xyz").isEmpty)

        let originalLanguage = LocalizationState.shared.currentLanguage
        defer { LocalizationState.shared.setLanguage(originalLanguage) }

        for language in [AppLanguage.en, .zhHans, .zhHant, .ja] {
            LocalizationState.shared.setLanguage(language)
            for key in SubtitleFontLocaleKey.allCases {
                let resolved = MediaLocalization.text(key)
                XCTAssertFalse(resolved.isEmpty, "Empty translation for \(key) in \(language)")
                XCTAssertNotEqual(resolved, key.rawValue, "Unresolved raw key \(key.rawValue) in \(language)")
            }
        }

        LocalizationState.shared.setLanguage(.zhHans)
        XCTAssertEqual(MediaLocalization.text(.subtitleFont), "字体")
        XCTAssertEqual(MediaLocalization.text(.subtitleFontSize), "字号")
        XCTAssertEqual(MediaLocalization.text(.subtitleFontSystemDefaultFace), "常规／圆体")
        XCTAssertNotEqual(MediaLocalization.text(.subtitleFont), MediaLocalization.text(.subtitleFontSize))
        let zhHansSystemFamily = SubtitleFontResolver.availableFamilies(includeSystemDefault: true).first(where: \.isSystemDefault)
        XCTAssertEqual(zhHansSystemFamily?.faces.first?.displayName, "常规／圆体")

        LocalizationState.shared.setLanguage(.zhHant)
        XCTAssertEqual(MediaLocalization.text(.subtitleFont), "字體")
        XCTAssertEqual(MediaLocalization.text(.subtitleFontSize), "字級")
        XCTAssertEqual(MediaLocalization.text(.subtitleFontSystemDefaultFace), "常規／圓體")
        let zhHantSystemFamily = SubtitleFontResolver.availableFamilies(includeSystemDefault: true).first(where: \.isSystemDefault)
        XCTAssertEqual(zhHantSystemFamily?.faces.first?.displayName, "常規／圓體")

        LocalizationState.shared.setLanguage(.en)
        XCTAssertEqual(MediaLocalization.text(.subtitleFont), "Font")
        XCTAssertEqual(MediaLocalization.text(.subtitleFontSize), "Font Size")
        XCTAssertEqual(MediaLocalization.text(.subtitleFontSystemDefaultFace), "Regular / Rounded")
        let enSystemFamily = SubtitleFontResolver.availableFamilies(includeSystemDefault: true).first(where: \.isSystemDefault)
        XCTAssertEqual(enSystemFamily?.faces.first?.displayName, "Regular / Rounded")
    }

    @MainActor
    func testFontPickerInteractionDepthKeepsControlsVisibleWhileOpen() {
        let controls = MediaControlsVisibility()
        controls.isPlaying = true
        controls.setHovered(true)
        XCTAssertTrue(controls.isVisible)

        var quickSettingsHeld = false
        var fontPickerHeld = false

        // 1. Quick settings popover opens -> holds interaction lock even if pointer leaves player canvas.
        SubtitleQuickSettingsPopover.syncInteractionDepth(
            isHeld: &quickSettingsHeld,
            shouldHold: true,
            controls: controls
        )
        controls.setHovered(false)
        controls.hideForInactivity()
        XCTAssertTrue(controls.isVisible, "Quick settings popover must keep controls visible while open")

        // 2. Font picker opens from quick settings -> increments interaction depth.
        SubtitleQuickSettingsPopover.syncInteractionDepth(
            isHeld: &fontPickerHeld,
            shouldHold: true,
            controls: controls
        )
        controls.hideForInactivity()
        XCTAssertTrue(controls.isVisible, "Font picker popover must keep controls visible while open")

        // 3. Font picker closes while quick settings remains open -> controls stay visible.
        SubtitleQuickSettingsPopover.syncInteractionDepth(
            isHeld: &fontPickerHeld,
            shouldHold: false,
            controls: controls
        )
        controls.hideForInactivity()
        XCTAssertTrue(controls.isVisible, "Closing font picker while quick settings is open must retain visibility")

        // 4. Quick settings closes with pointer outside -> interaction depth returns to 0 and controls hide cleanly.
        SubtitleQuickSettingsPopover.syncInteractionDepth(
            isHeld: &quickSettingsHeld,
            shouldHold: false,
            controls: controls
        )
        XCTAssertFalse(controls.isVisible)
    }
}

private actor SubtitleFontTestLoadCounter {
    private var externalCount = 0
    private var embeddedCount = 0

    func recordExternal() { externalCount += 1 }
    func recordEmbedded() { embeddedCount += 1 }
    func snapshot() -> (external: Int, embedded: Int) { (externalCount, embeddedCount) }
}
