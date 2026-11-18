// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreMedia
import SwiftUI
@testable import TTMediaKit
import TTI18nCore
import TTI18nUI
import XCTest
@testable import TTZipPreviewKit

final class VideoControlPresentationTests: XCTestCase {
    @MainActor
    func testDisabledSubtitleTrackStaysDisabledAfterNativeMenuUpdate() throws {
        let inspector = UIHierarchyInspector(rootView: TTZipSubtitleTrackMenu(
            options: [
                SubtitleMenuOption(id: "sub_0", title: "English", enabled: true, supportsSecondary: true),
                SubtitleMenuOption(id: "sub_1", title: "PGS Forced", enabled: false, supportsSecondary: false),
            ],
            selectedID: "sub_0",
            selectedSecondaryID: "off",
            hasExternalSubtitle: false,
            controlsVisibility: nil,
            onSelect: { _ in },
            onSelectSecondary: { _ in },
            onRemove: {},
            onLoad: {},
            onShowStyle: {},
            onUserInteraction: {}
        ))
        inspector.hostingView.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(inspector.allSubviews().compactMap { $0 as? TTZipSubtitleTrackMenu.MenuButton }.first)
        let menu = try XCTUnwrap(button.trackMenu)
        XCTAssertFalse(menu.autoenablesItems)
        menu.update()

        let availableTrack = try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == "sub_0" })
        let disabledTrack = try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == "sub_1" })
        XCTAssertTrue(availableTrack.isEnabled)
        XCTAssertEqual(availableTrack.state, .on)
        XCTAssertFalse(disabledTrack.isEnabled)
    }

    @MainActor
    func testExportButtonsHaveNonemptyCompactAndWideLayout() throws {
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let duration = CMTime(seconds: 2, preferredTimescale: 600)
        for compact in [true, false] {
            assertButtonFits(TTZipVideoGIFExportButton(
                videoURL: nil, currentTime: time, duration: duration, isCompact: compact,
                isPopoverPresented: .constant(false), onUserInteraction: {}
            ))
            assertButtonFits(TTZipVideoLosslessTrimButton(
                videoURL: nil, currentTime: time, duration: duration, isCompact: compact,
                isPopoverPresented: .constant(false), onUserInteraction: {}
            ))
            assertButtonFits(TTZipMediaContainerRemuxButton(
                videoURL: nil, isCompact: compact,
                isPopoverPresented: .constant(false), onUserInteraction: {}
            ))
            assertButtonFits(TTZipMediaAudioExtractButton(
                videoURL: nil, isCompact: compact,
                isPopoverPresented: .constant(false), onUserInteraction: {}
            ))
        }
    }

    @MainActor
    func testSubtitleFontPickerKeepsControlsVisibleUntilBothPanelsClose() {
        let controls = MediaControlsVisibility()
        defer { controls.tearDown() }
        controls.isPlaying = true
        controls.setHovered(true)

        var quickSettingsHeld = false
        var fontPickerHeld = false
        TTZipSubtitleQuickSettings.syncInteractionDepth(isHeld: &quickSettingsHeld, shouldHold: true, controls: controls)
        controls.setHovered(false)
        controls.hideForInactivity()
        XCTAssertTrue(controls.isVisible)

        TTZipSubtitleQuickSettings.syncInteractionDepth(isHeld: &fontPickerHeld, shouldHold: true, controls: controls)
        TTZipSubtitleQuickSettings.syncInteractionDepth(isHeld: &fontPickerHeld, shouldHold: true, controls: controls)
        controls.hideForInactivity()
        XCTAssertTrue(controls.isVisible)

        TTZipSubtitleQuickSettings.syncInteractionDepth(isHeld: &fontPickerHeld, shouldHold: false, controls: controls)
        TTZipSubtitleQuickSettings.syncInteractionDepth(isHeld: &fontPickerHeld, shouldHold: false, controls: controls)
        controls.hideForInactivity()
        XCTAssertTrue(controls.hasActiveInteractionLock)
        XCTAssertTrue(controls.isVisible)

        TTZipSubtitleQuickSettings.syncInteractionDepth(isHeld: &quickSettingsHeld, shouldHold: false, controls: controls)
        XCTAssertFalse(controls.hasActiveInteractionLock)
        XCTAssertFalse(controls.isVisible)
    }

    @MainActor
    func testSubtitleScaleBindingPreservesFineValuesAndPresetSelection() {
        let geometry = SubtitleVideoContentGeometry(
            viewportSize: CGSize(width: 1280, height: 720),
            videoNaturalSize: CGSize(width: 1920, height: 1080)
        )
        var style = SubtitleStyleConfiguration(scale: 0.5)
        var interactions = 0

        func control() -> TTZipSubtitleRelativeScaleSettings {
            TTZipSubtitleRelativeScaleSettings(
                style: style,
                activeSubtitleCodec: "S_TEXT/UTF8",
                onUpdateStyle: { style = $0 },
                onUserInteraction: { interactions += 1 }
            )
        }

        let scales = [0.5, 0.563, 0.618, 0.712, 0.837, 0.964, 1.013, 1.087, 1.142, 1.279, 1.389, 1.531, 1.672, 1.843, 2.0]
        var previousPrimary: CGFloat = 0
        var previousSecondary: CGFloat = 0
        for (index, scale) in scales.enumerated() {
            control().continuousScaleBinding.wrappedValue = scale
            XCTAssertEqual(interactions, index + 1)
            XCTAssertEqual(style.scale, scale, accuracy: 0.000001)
            XCTAssertEqual(control().continuousScaleBinding.wrappedValue, scale, accuracy: 0.000001)

            let metrics = style.resolvedMetrics(for: geometry)
            XCTAssertGreaterThan(metrics.primaryFontSize, previousPrimary)
            XCTAssertGreaterThan(metrics.secondaryFontSize, previousSecondary)
            previousPrimary = metrics.primaryFontSize
            previousSecondary = metrics.secondaryFontSize
        }

        control().continuousScaleBinding.wrappedValue = 1.013
        XCTAssertFalse(control().isPresetSelected(1.0))
        XCTAssertEqual(TTZipSubtitleRelativeScaleSettings.scalePresets, [0.75, 1.0, 1.25, 1.5])
        for preset in TTZipSubtitleRelativeScaleSettings.scalePresets {
            control().applyScalePreset(preset)
            XCTAssertEqual(style.scale, preset, accuracy: 0.000001)
            XCTAssertTrue(control().isPresetSelected(preset))
        }
    }

    @MainActor
    func testSubtitleScaleBindingWritesFineValueAndReloadsIt() throws {
        let suite = "com.metastudyline.ttzip.tests.subtitle-scale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let control = TTZipSubtitleRelativeScaleSettings(
            style: SubtitleStyleConfiguration.loadFromDefaults(defaults),
            activeSubtitleCodec: "S_TEXT/UTF8",
            onUpdateStyle: { $0.saveToDefaults(defaults) },
            onUserInteraction: {}
        )
        control.continuousScaleBinding.wrappedValue = 1.137

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let result = SubtitleStyleConfiguration.loadAndMigrateIfNeeded(from: reopened)
        XCTAssertFalse(result.didMigrateFromLegacy)
        XCTAssertEqual(result.configuration.scale, 1.137, accuracy: 0.000001)
        XCTAssertEqual(
            result.configuration.effectiveRelativeFontRatio,
            SubtitleStyleConfiguration.defaultRelativeFontRatio * 1.137,
            accuracy: 0.000001
        )
    }

    @MainActor
    func testSubtitlePresentationLocalizationAndRelativeSizingVocabulary() {
        let state = LocalizationState.shared
        let originalLanguage = state.currentLanguage
        defer { state.setLanguage(originalLanguage) }

        XCTAssertEqual(TTZipSubtitleFontLocaleKey.allCases.count, 14)
        XCTAssertEqual(SubtitleRelativeSizingLocaleKey.allCases.count, 9)
        XCTAssertEqual(SubtitleFontLocaleKey.allCases.count, 2)

        let expected: [(AppLanguage, String, String, String)] = [
            (.en, "Font", "Font Size", "1.25x · 5.6% of video height"),
            (.zhHans, "字体", "字号", "1.25x · 画面高度 5.6%"),
            (.zhHant, "字體", "字級", "1.25x · 畫面高度 5.6%"),
            (.ja, "Font", MediaLocaleKey.subtitleFontSize.fallbackTranslation(for: .ja), "1.25x · 5.6% of video height"),
        ]
        for (language, expectedFont, expectedSize, expectedBadge) in expected {
            state.setLanguage(language)
            for key in TTZipSubtitleFontLocaleKey.allCases {
                let resolved = TTZipSubtitlePresentationLocalization.text(key)
                XCTAssertFalse(resolved.isEmpty, "Empty translation for \(key) in \(language)")
                XCTAssertNotEqual(resolved, key.rawKey)
                if language == .ja {
                    XCTAssertEqual(resolved, key.fallbackTranslation(for: .en))
                }
            }
            for key in SubtitleRelativeSizingLocaleKey.allCases {
                let resolved = TTZipSubtitlePresentationLocalization.text(key)
                XCTAssertFalse(resolved.isEmpty, "Empty translation for \(key) in \(language)")
                XCTAssertNotEqual(resolved, key.rawKey)
                if language == .ja {
                    XCTAssertEqual(resolved, key.fallbackTranslation(for: .en))
                }
            }
            XCTAssertEqual(TTZipSubtitlePresentationLocalization.text(.subtitleFont), expectedFont)
            XCTAssertEqual(MediaLocalization.text(.subtitleFontSize), expectedSize)
            XCTAssertNotEqual(expectedFont, expectedSize)
            XCTAssertEqual(
                TTZipSubtitlePresentationLocalization.formattedRelativeHeightBadge(
                    scaleText: "1.25x",
                    percentText: "5.6%"
                ),
                expectedBadge
            )
        }
    }

    @MainActor
    private func assertButtonFits<Control: View>(_ control: Control, file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingView(rootView: control)
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 36)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        XCTAssertGreaterThan(size.width, 0, file: file, line: line)
        XCTAssertGreaterThan(size.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(size.width, host.bounds.width, file: file, line: line)
        XCTAssertLessThanOrEqual(size.height, host.bounds.height, file: file, line: line)
    }
}
