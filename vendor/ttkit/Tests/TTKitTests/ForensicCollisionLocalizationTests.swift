// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
@testable import TTKitCore
@testable import TTKitDesign
@testable import TTKitFluid
@testable import TTKitUI
@testable import TTKit

final class ForensicCollisionLocalizationTests: XCTestCase {

    // MARK: - 1. Complete Vocabulary in zh-Hans, zh-Hant, and en

    func testCompleteLocalizationInSimplifiedTraditionalAndEnglish() {
        let zhHans = ForensicCollisionLocalization.resolved(forLanguageIdentifier: "zh-Hans")
        let zhHant = ForensicCollisionLocalization.resolved(forLanguageIdentifier: "zh-Hant")
        let en = ForensicCollisionLocalization.resolved(forLanguageIdentifier: "en")

        // Verify left/right card titles clearly distinguish incoming vs. existing items
        XCTAssertEqual(zhHans.incomingCardTitle, "待解压项目（来自归档）")
        XCTAssertEqual(zhHans.existingCardTitle, "目标已有项目（当前位置）")
        XCTAssertEqual(zhHant.incomingCardTitle, "待解壓項目（來自歸檔）")
        XCTAssertEqual(zhHant.existingCardTitle, "目標已有項目（目前位置）")
        XCTAssertEqual(en.incomingCardTitle, "Incoming Item (From Archive)")
        XCTAssertEqual(en.existingCardTitle, "Existing Item (At Destination)")

        // Verify panel titles and badges
        XCTAssertEqual(zhHans.panelTitle, "发现同名项目冲突")
        XCTAssertEqual(zhHant.panelTitle, "發現同名項目衝突")
        XCTAssertEqual(en.panelTitle, "File Collision Resolution")

        XCTAssertEqual(zhHans.newerBadge, "时间较新")
        XCTAssertEqual(zhHans.largerBadge, "体积较大")
        XCTAssertEqual(zhHant.newerBadge, "時間較新")
        XCTAssertEqual(zhHant.largerBadge, "體積較大")
        XCTAssertEqual(en.newerBadge, "Newer")
        XCTAssertEqual(en.largerBadge, "Larger")
        XCTAssertNotEqual(en.newerBadge, "Latest", "Comparison badge must remain objective and not imply recommendation")

        // Verify Stop action accurately describes stopping remaining processing without claiming post-commit rollback
        XCTAssertEqual(zhHans.stopAction.title, "停止")
        XCTAssertEqual(zhHans.stopAction.subtitle, "停止后续解压处理")
        XCTAssertFalse(zhHans.stopAction.subtitle.contains("回滚"))
        XCTAssertEqual(zhHant.stopAction.title, "停止")
        XCTAssertEqual(zhHant.stopAction.subtitle, "停止後續解壓處理")
        XCTAssertEqual(en.stopAction.title, "Stop")
        XCTAssertEqual(en.stopAction.subtitle, "Stop remaining extraction")

        // Verify Skip, Replace, Keep Both
        XCTAssertEqual(zhHans.skipAction.title, "跳过")
        XCTAssertEqual(zhHans.replaceAction.title, "替换")
        XCTAssertEqual(zhHans.keepBothAction.title, "保留两者")
        XCTAssertEqual(zhHant.skipAction.title, "略過")
        XCTAssertEqual(zhHant.replaceAction.title, "取代")
        XCTAssertEqual(zhHant.keepBothAction.title, "保留兩者")

        // Verify checkbox and VoiceOver strings are non-empty across all three languages
        for loc in [zhHans, zhHant, en] {
            assertNoEmptyOrRawKeys(in: loc)
        }
    }

    // MARK: - 2. Other Supported Languages Fallback & Locale Preservation

    func testOtherSupportedLanguagesFallbackWithoutRawKeysOrEmptyStrings() {
        let supportedIdentifiers = ["ja", "de", "fr", "es", "zh_TW", "zh_HK", "zh_CN", "en_GB"]

        for identifier in supportedIdentifiers {
            let loc = ForensicCollisionLocalization.resolved(forLanguageIdentifier: identifier)
            assertNoEmptyOrRawKeys(in: loc)

            if identifier == "zh_TW" || identifier == "zh_HK" {
                XCTAssertEqual(loc.localeIdentifier, "zh-Hant")
                XCTAssertEqual(loc.panelTitle, "發現同名項目衝突")
            } else if identifier == "zh_CN" {
                XCTAssertEqual(loc.localeIdentifier, "zh-Hans")
                XCTAssertEqual(loc.panelTitle, "发现同名项目冲突")
            } else {
                XCTAssertEqual(loc.panelTitle, "File Collision Resolution")
            }
        }
    }

    // MARK: - 3. Real-Time Language Switch Preserves State Without Triggering Resolver

    @MainActor
    func testLanguageSwitchPreservesConflictAndCheckboxWithoutTriggeringResolver() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = ConflictFileDescriptor(
            fileName: "report.pdf",
            relativePath: "docs/report.pdf",
            filePath: "/archive/docs/report.pdf",
            byteSize: 4096,
            modificationDate: now
        )
        let target = ConflictFileDescriptor(
            fileName: "report.pdf",
            relativePath: "docs/report.pdf",
            filePath: "/dest/docs/report.pdf",
            byteSize: 2048,
            modificationDate: now.addingTimeInterval(-3600)
        )

        var applyAllState = true
        let binding = Binding<Bool>(
            get: { applyAllState },
            set: { applyAllState = $0 }
        )

        var currentLang = "en"
        ForensicCollisionLocalization.fallbackProvider = {
            ForensicCollisionLocalization.resolved(forLanguageIdentifier: currentLang)
        }
        defer {
            ForensicCollisionLocalization.fallbackProvider = nil
        }

        final class ResolveRecorder: @unchecked Sendable {
            var calls: [(ConflictResolutionAction, Bool)] = []
        }
        let recorder = ResolveRecorder()

        let panel = ForensicCollisionPanel(
            sourceFile: source,
            targetFile: target,
            conflictIndex: 3,
            totalConflicts: 12,
            applyToAllRemaining: binding,
            onResolve: { action, applyAll in
                recorder.calls.append((action, applyAll))
            }
        )

        XCTAssertEqual(panel.activeLocalization.panelTitle, "File Collision Resolution")
        XCTAssertTrue(panel.applyToAllRemaining)
        XCTAssertTrue(recorder.calls.isEmpty)

        // Switch language to Simplified Chinese while panel is active
        currentLang = "zh-Hans"
        NotificationCenter.default.post(name: Notification.Name("TTZipLanguageChanged"), object: nil)
        XCTAssertEqual(panel.activeLocalization.panelTitle, "发现同名项目冲突")
        XCTAssertEqual(panel.activeLocalization.incomingCardTitle, "待解压项目（来自归档）")
        XCTAssertEqual(panel.conflictIndex, 3)
        XCTAssertEqual(panel.totalConflicts, 12)
        XCTAssertEqual(panel.sourceFile, source)
        XCTAssertEqual(panel.targetFile, target)
        XCTAssertTrue(panel.applyToAllRemaining, "Checkbox state must be preserved across language switch")
        XCTAssertTrue(recorder.calls.isEmpty, "Resolver must never be called by language switch")

        // Switch language to Traditional Chinese while panel is active
        currentLang = "zh-Hant"
        NotificationCenter.default.post(name: Notification.Name("TTZipLanguageChanged"), object: nil)
        XCTAssertEqual(panel.activeLocalization.panelTitle, "發現同名項目衝突")
        XCTAssertEqual(panel.activeLocalization.replaceAction.title, "取代")
        XCTAssertTrue(panel.applyToAllRemaining)
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    // MARK: - 4. Raw Filenames, Paths, Emoji, and Long Text Accessibility

    @MainActor
    func testRawFileNamesPathsEmojiAndLongTextPreservedVerbatim() {
        let trickyFileName = "📦 2026_财务报表 (Final) [v2.1] — résumé_🧪.xlsx"
        let trickyRelativePath = "归档目录/子目录 A/📦 2026_财务报表 (Final) [v2.1] — résumé_🧪.xlsx"
        let trickyFullPath = "/Users/tester/Downloads/" + trickyRelativePath
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let src = ConflictFileDescriptor(
            fileName: trickyFileName,
            relativePath: trickyRelativePath,
            filePath: trickyFullPath,
            byteSize: 1_048_576,
            modificationDate: date,
            conflictKind: .typeMismatch
        )
        let dst = ConflictFileDescriptor(
            fileName: trickyFileName,
            relativePath: trickyRelativePath,
            filePath: "/Volumes/Target/" + trickyRelativePath,
            byteSize: 0,
            modificationDate: date,
            isDirectory: true,
            conflictKind: .typeMismatch
        )

        for lang in ["zh-Hans", "zh-Hant", "en", "ja", "de"] {
            let loc = ForensicCollisionLocalization.resolved(forLanguageIdentifier: lang)
            let progress = loc.formatConflictProgress(index: 1, total: 10000, fileName: src.fileName)
            XCTAssertTrue(progress.contains(trickyFileName), "Progress must preserve raw fileName in \(lang)")
            XCTAssertEqual(loc.fileRowHelpText(for: src), trickyFileName)
            XCTAssertTrue(loc.pathRowHelpText(for: src).contains(trickyRelativePath))
            XCTAssertTrue(loc.pathRowHelpText(for: src).contains(trickyFullPath))

            var applyAll = false
            let panel = ForensicCollisionPanel(
                sourceFile: src,
                targetFile: dst,
                conflictIndex: 1,
                totalConflicts: 10000,
                applyToAllRemaining: Binding(get: { applyAll }, set: { applyAll = $0 }),
                localization: loc,
                onResolve: { _, _ in }
            )
            XCTAssertTrue(panel.headerVoiceOverSummary.contains(trickyFileName))
            XCTAssertTrue(panel.incomingCardVoiceOverSummary.contains(trickyRelativePath))
            XCTAssertTrue(panel.existingCardVoiceOverSummary.contains(trickyRelativePath))
        }
    }

    // MARK: - 5. Locale-Aware Formatting & Missing/Invalid Metadata Defense

    @MainActor
    func testLocaleAwareFormattingAndMissingMetadataDefense() {
        let validDate = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = TimeZone(secondsFromGMT: 0)!

        let validFile = ConflictFileDescriptor(
            fileName: "data.bin",
            relativePath: "data.bin",
            filePath: "/tmp/data.bin",
            byteSize: 2_500_000,
            modificationDate: validDate
        )

        let zhHansSI = ForensicCollisionLocalization.resolved(forLanguageIdentifier: "zh-Hans", byteCountStyle: .file)
        let zhHantIEC = ForensicCollisionLocalization.resolved(forLanguageIdentifier: "zh-Hant", byteCountStyle: .binary)
        let enSI = ForensicCollisionLocalization.resolved(forLanguageIdentifier: "en", byteCountStyle: .file)
        let deSI = ForensicCollisionLocalization.resolved(forLanguageIdentifier: "de", byteCountStyle: .file)

        XCTAssertTrue(zhHansSI.formatSize(for: validFile).contains("2,500,000 字节"))
        XCTAssertTrue(zhHansSI.formatSize(for: validFile).contains("MB"))
        XCTAssertTrue(zhHantIEC.formatSize(for: validFile).contains("2,500,000 位元組"))
        XCTAssertTrue(zhHantIEC.formatSize(for: validFile).contains("MiB"))
        XCTAssertTrue(enSI.formatSize(for: validFile).contains("2,500,000 B"))
        XCTAssertTrue(deSI.formatNumber(10_000).contains("10.000"))

        let zhDateStr = zhHansSI.formatTimestamp(for: validFile, timeZone: utc)
        let enDateStr = enSI.formatTimestamp(for: validFile, timeZone: utc)
        XCTAssertFalse(zhDateStr.isEmpty)
        XCTAssertFalse(enDateStr.isEmpty)
        XCTAssertNotEqual(zhDateStr, enDateStr, "Timestamp formatting must follow active locale")

        // Missing / invalid metadata defense (epoch 0, negative size, explicit invalid flags)
        let missingMetaFile = ConflictFileDescriptor(
            fileName: "corrupt_meta.bin",
            relativePath: "corrupt_meta.bin",
            filePath: "/tmp/corrupt_meta.bin",
            byteSize: -1,
            modificationDate: Date(timeIntervalSince1970: 0),
            hasValidByteSize: false,
            hasValidModificationDate: false
        )
        XCTAssertEqual(zhHansSI.formatSize(for: missingMetaFile), "未提供")
        XCTAssertEqual(zhHansSI.formatTimestamp(for: missingMetaFile, timeZone: utc), "未提供")
        XCTAssertEqual(enSI.formatSize(for: missingMetaFile), "Unavailable")
        XCTAssertEqual(enSI.formatTimestamp(for: missingMetaFile, timeZone: utc), "Unavailable")

        var applyAll = false
        let panelWithMissing = ForensicCollisionPanel(
            sourceFile: validFile,
            targetFile: missingMetaFile,
            conflictIndex: 1,
            totalConflicts: 2,
            applyToAllRemaining: Binding(get: { applyAll }, set: { applyAll = $0 }),
            localization: zhHansSI,
            onResolve: { _, _ in }
        )
        XCTAssertFalse(panelWithMissing.isSourceItemNewer, "Must not claim newer when one side has missing timestamp")
        XCTAssertFalse(panelWithMissing.isTargetItemNewer)
        XCTAssertFalse(panelWithMissing.isSourceItemLarger, "Must not claim larger when one side has invalid size")
        XCTAssertFalse(panelWithMissing.isTargetItemLarger)
    }

    // MARK: - 6. Action Primitives, Shortcuts, and Checkbox Callback Mapping

    @MainActor
    func testFourActionsAndApplyToAllCallbackSemanticsPreserved() {
        XCTAssertEqual(ConflictResolutionAction.allCases.map(\.rawValue), ["REPLACE", "KEEP_BOTH", "SKIP", "STOP"])

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let src = ConflictFileDescriptor(
            fileName: "a.txt",
            relativePath: "a.txt",
            filePath: "/src/a.txt",
            byteSize: 100,
            modificationDate: now
        )
        let dst = ConflictFileDescriptor(
            fileName: "a.txt",
            relativePath: "a.txt",
            filePath: "/dst/a.txt",
            byteSize: 200,
            modificationDate: now.addingTimeInterval(-60)
        )

        var applyAll = false
        final class ActionLog: @unchecked Sendable {
            var events: [(ConflictResolutionAction, Bool)] = []
        }
        let log = ActionLog()

        let panel = ForensicCollisionPanel(
            sourceFile: src,
            targetFile: dst,
            conflictIndex: 1,
            totalConflicts: 4,
            applyToAllRemaining: Binding(get: { applyAll }, set: { applyAll = $0 }),
            localization: .simplifiedChinese,
            onResolve: { action, all in
                log.events.append((action, all))
            }
        )

        for action in [ConflictResolutionAction.stop, .skip, .replace, .keepBoth] {
            applyAll = false
            panel.triggerAction(action)
            applyAll = true
            panel.triggerAction(action)
        }

        XCTAssertEqual(log.events.count, 8)
        XCTAssertEqual(log.events[0].0, .stop)
        XCTAssertFalse(log.events[0].1)
        XCTAssertEqual(log.events[1].0, .stop)
        XCTAssertTrue(log.events[1].1)
        XCTAssertEqual(log.events[6].0, .keepBoth)
        XCTAssertFalse(log.events[6].1)
        XCTAssertEqual(log.events[7].0, .keepBoth)
        XCTAssertTrue(log.events[7].1)
    }

    // MARK: - 7. Light/Dark Theme & Long Translation Layout Verification

    @MainActor
    func testLightAndDarkThemeAndLongTranslationLayoutPass() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let src = ConflictFileDescriptor(
            fileName: "very_long_archive_entry_filename_with_multiple_segments_2026_10_17.tar.zst",
            relativePath: "deeply/nested/subfolder/structure/very_long_archive_entry_filename_with_multiple_segments_2026_10_17.tar.zst",
            filePath: "/Users/tester/Archives/deeply/nested/subfolder/structure/very_long_archive_entry_filename_with_multiple_segments_2026_10_17.tar.zst",
            byteSize: 128_849_018,
            modificationDate: now,
            conflictKind: .typeMismatch
        )
        let dst = ConflictFileDescriptor(
            fileName: "very_long_archive_entry_filename_with_multiple_segments_2026_10_17.tar.zst",
            relativePath: "deeply/nested/subfolder/structure/very_long_archive_entry_filename_with_multiple_segments_2026_10_17.tar.zst",
            filePath: "/Users/tester/Destination/deeply/nested/subfolder/structure/very_long_archive_entry_filename_with_multiple_segments_2026_10_17.tar.zst",
            byteSize: 0,
            modificationDate: now.addingTimeInterval(-86400),
            isDirectory: true,
            conflictKind: .typeMismatch
        )

        var applyAll = false
        let binding = Binding(get: { applyAll }, set: { applyAll = $0 })

        let longGermanOverride = ForensicCollisionLocalization(
            localeIdentifier: "de",
            byteCountStyle: .file,
            panelTitle: "Dateikonfliktlösung beim Entpacken",
            conflictProgressFormat: "Konflikt %1$@ von %2$@ — „%3$@“",
            sameTypeTitle: "Gleicher Typ",
            typeMismatchBadge: "Typkonflikt",
            typeMismatchHelp: "Das zu entpackende Element und das vorhandene Zielelement haben unterschiedliche Typen",
            incomingCardTitle: "Zu entpackendes Element (Aus Archiv)",
            existingCardTitle: "Vorhandenes Element (Am Zielort)",
            newerBadge: "Neuer",
            largerBadge: "Größer",
            mismatchBadge: "Abweichung",
            directoryBadge: "Ordner",
            fileBadge: "Datei",
            pathLabel: "Pfad",
            sizeLabel: "Größe",
            modifiedLabel: "Geändert",
            typeLabel: "Typ",
            directoryTypeValue: "Ordner",
            fileTypeValue: "Datei",
            unavailableValue: "Nicht verfügbar",
            bytesExactFormat: "%1$@ (%2$@ Byte)",
            bytesOnlyFormat: "%1$@ Byte",
            stopAction: ForensicCollisionActionCopy(
                title: "Stoppen",
                subtitle: "Weitere Konflikt- und Entpackverarbeitung beenden",
                accessibilityHint: "Beendet die weitere Verarbeitung. Taste Escape."
            ),
            skipAction: ForensicCollisionActionCopy(
                title: "Überspringen",
                subtitle: "Vorhandenes Zielelement unverändert behalten",
                accessibilityHint: "Überspringt dieses Element und behält das vorhandene Element."
            ),
            replaceAction: ForensicCollisionActionCopy(
                title: "Ersetzen",
                subtitle: "Vorhandenes Zielelement durch Archivversion überschreiben",
                accessibilityHint: "Überschreibt das vorhandene Element am Zielort."
            ),
            keepBothAction: ForensicCollisionActionCopy(
                title: "Beide behalten",
                subtitle: "Zu entpackendes Element automatisch nummeriert speichern",
                accessibilityHint: "Speichert beide Elemente. Standardaktion, Eingabetaste."
            ),
            applyToAllTitle: "Diese Auswahl auf alle verbleibenden Konflikte anwenden",
            applyToAllAccessibilityHint: "Wendet die gewählte Aktion auf alle übrigen Konflikte an.",
            dialogAccessibilityLabel: "Dialog zur Lösung von Dateikonflikten",
            headerSummaryVoiceOverFormat: "Dateikonflikt %1$@ von %2$@: %3$@%4$@. Archivpfad: %5$@, Größe: %6$@, geändert: %7$@. Zielpfad: %8$@, Größe: %9$@, geändert: %10$@.",
            headerTypeMismatchClause: ", Typkonflikt zwischen Archiv und Ziel",
            typeMismatchAccessibilityLabel: "Typkonflikt zwischen Archiv- und Zielelement",
            cardAccessibilityFormat: "%1$@: %2$@, Typ: %3$@, Pfad: %4$@, Größe: %5$@, geändert: %6$@%7$@"
        )

        for loc in [ForensicCollisionLocalization.simplifiedChinese, .traditionalChinese, .english, longGermanOverride] {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let rawPanel = ForensicCollisionPanel(
                    sourceFile: src,
                    targetFile: dst,
                    conflictIndex: 99,
                    totalConflicts: 10_000,
                    applyToAllRemaining: binding,
                    localization: loc,
                    onResolve: { _, _ in }
                )
                if loc.localeIdentifier == "de" {
                    XCTAssertTrue(rawPanel.prefersTwoByTwoActionGrid, "Long translations must switch to 2x2 action grid to prevent truncation")
                }

                let panel = rawPanel.environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: panel)
                hosting.layoutSubtreeIfNeeded()
                let fitting = hosting.fittingSize
                XCTAssertGreaterThanOrEqual(fitting.width, 600, "Panel width must accommodate cards and buttons")
                XCTAssertGreaterThan(fitting.height, 220, "Panel height must fit multiline subtitles without clipping")
            }
        }
    }

    // MARK: - Helper Assertions

    private func assertNoEmptyOrRawKeys(
        in loc: ForensicCollisionLocalization,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let strings = [
            loc.panelTitle,
            loc.conflictProgressFormat,
            loc.sameTypeTitle,
            loc.typeMismatchBadge,
            loc.typeMismatchHelp,
            loc.incomingCardTitle,
            loc.existingCardTitle,
            loc.newerBadge,
            loc.largerBadge,
            loc.mismatchBadge,
            loc.directoryBadge,
            loc.fileBadge,
            loc.pathLabel,
            loc.sizeLabel,
            loc.modifiedLabel,
            loc.typeLabel,
            loc.directoryTypeValue,
            loc.fileTypeValue,
            loc.unavailableValue,
            loc.bytesExactFormat,
            loc.bytesOnlyFormat,
            loc.stopAction.title,
            loc.stopAction.subtitle,
            loc.stopAction.accessibilityLabel,
            loc.stopAction.accessibilityHint,
            loc.skipAction.title,
            loc.skipAction.subtitle,
            loc.skipAction.accessibilityLabel,
            loc.skipAction.accessibilityHint,
            loc.replaceAction.title,
            loc.replaceAction.subtitle,
            loc.replaceAction.accessibilityLabel,
            loc.replaceAction.accessibilityHint,
            loc.keepBothAction.title,
            loc.keepBothAction.subtitle,
            loc.keepBothAction.accessibilityLabel,
            loc.keepBothAction.accessibilityHint,
            loc.applyToAllTitle,
            loc.applyToAllAccessibilityHint,
            loc.dialogAccessibilityLabel,
            loc.headerSummaryVoiceOverFormat,
            loc.headerTypeMismatchClause,
            loc.typeMismatchAccessibilityLabel,
            loc.cardAccessibilityFormat
        ]

        for str in strings {
            XCTAssertFalse(str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Localized string must not be empty", file: file, line: line)
            XCTAssertFalse(str.hasPrefix("collision."), "Localized string '\(str)' must not expose raw key", file: file, line: line)
        }
    }
}
