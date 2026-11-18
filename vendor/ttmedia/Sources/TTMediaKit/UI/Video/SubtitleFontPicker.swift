// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreText
import Foundation
import SwiftUI

/// Typeface member belonging to a font family (modeled after IINA's `FontPickerWindowController` face table).
public struct SubtitleFontFace: Identifiable, Equatable, Sendable {
    public let postScriptName: String
    public let displayName: String
    public let weight: Int
    public let traits: UInt

    public var id: String { postScriptName }

    public init(postScriptName: String, displayName: String, weight: Int = 5, traits: UInt = 0) {
        self.postScriptName = postScriptName
        self.displayName = displayName
        self.weight = weight
        self.traits = traits
    }
}

/// Installed font family entry or synthetic System Default entry.
public struct SubtitleFontFamily: Identifiable, Equatable, Sendable {
    public static let systemDefaultID = "__system_default__"

    public let familyName: String
    public let localizedName: String
    public let faces: [SubtitleFontFace]
    public let isSystemDefault: Bool

    public var id: String { isSystemDefault ? Self.systemDefaultID : familyName }

    public init(
        familyName: String,
        localizedName: String,
        faces: [SubtitleFontFace],
        isSystemDefault: Bool = false
    ) {
        self.familyName = familyName
        self.localizedName = localizedName
        self.faces = faces
        self.isSystemDefault = isSystemDefault
    }
}

/// Resolved font bundle carrying both AppKit `NSFont` (for metrics and CoreText glyph inspection)
/// and SwiftUI `Font` (for host subtitle and preview rendering).
public struct SubtitleResolvedFont {
    public let requestedIdentifier: String?
    public let resolvedPostScriptName: String
    public let resolvedFamilyName: String
    public let isSystemDefault: Bool
    public let isFallbackToSystem: Bool
    public let nsFont: NSFont
    public let swiftUIFont: Font
}

/// Discovers installed macOS font families and resolves `SubtitleStyleConfiguration` into CJK-safe fonts.
public enum SubtitleFontResolver {
    private static let cjkCascadeLanguages: [String] = ["zh-Hans", "zh-Hant", "ja", "en"]

    /// Normalizes a raw font identifier (`nil`, empty, `"system"`, `"default"`, or `"__system_default__"` -> `nil`).
    public static func normalizeFontIdentifier(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lowered = trimmed.lowercased()
        if lowered == "system" || lowered == "default" || lowered == SubtitleFontFamily.systemDefaultID {
            return nil
        }
        return trimmed
    }

    /// Enumerates available macOS font families (excluding hidden `.` system families), sorted by localized name.
    @MainActor
    public static func availableFamilies(includeSystemDefault: Bool = true) -> [SubtitleFontFamily] {
        let manager = NSFontManager.shared
        var result: [SubtitleFontFamily] = []
        if includeSystemDefault {
            let sysTitle = MediaLocalization.text(.subtitleFontSystemDefault)
            let sysFaceTitle = MediaLocalization.text(.subtitleFontSystemDefaultFace)
            result.append(
                SubtitleFontFamily(
                    familyName: SubtitleFontFamily.systemDefaultID,
                    localizedName: sysTitle,
                    faces: [
                        SubtitleFontFace(
                            postScriptName: SubtitleFontFamily.systemDefaultID,
                            displayName: sysFaceTitle
                        )
                    ],
                    isSystemDefault: true
                )
            )
        }

        let installed = manager.availableFontFamilies
            .filter { !$0.hasPrefix(".") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap { family -> SubtitleFontFamily? in
                let rawMembers = manager.availableMembers(ofFontFamily: family) ?? []
                let faces: [SubtitleFontFace] = rawMembers.compactMap { entry in
                    guard entry.count >= 2,
                          let psName = entry[0] as? String,
                          let faceName = entry[1] as? String else {
                        return nil
                    }
                    let weight = (entry.count >= 3 ? entry[2] as? Int : nil) ?? 5
                    let traits = (entry.count >= 4 ? entry[3] as? UInt : nil) ?? 0
                    let localizedFace = manager.localizedName(forFamily: family, face: faceName)
                    return SubtitleFontFace(
                        postScriptName: psName,
                        displayName: localizedFace.isEmpty ? faceName : localizedFace,
                        weight: weight,
                        traits: traits
                    )
                }
                guard !faces.isEmpty else { return nil }
                let localizedFamily = manager.localizedName(forFamily: family, face: nil)
                return SubtitleFontFamily(
                    familyName: family,
                    localizedName: localizedFamily.isEmpty ? family : localizedFamily,
                    faces: faces,
                    isSystemDefault: false
                )
            }
            .sorted {
                $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
            }

        result.append(contentsOf: installed)
        return result
    }

    /// Filters a font family catalog using a case-insensitive query against family, localized, or face names.
    public static func filterFamilies(_ families: [SubtitleFontFamily], query: String) -> [SubtitleFontFamily] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return families }
        return families.filter { family in
            if family.localizedName.localizedCaseInsensitiveContains(trimmed)
                || family.familyName.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            return family.faces.contains {
                $0.displayName.localizedCaseInsensitiveContains(trimmed)
                    || $0.postScriptName.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    /// Resolves the localized display name for the currently configured font, or System Default if unset/unavailable.
    @MainActor
    public static func displayName(for style: SubtitleStyleConfiguration) -> String {
        let resolved = resolve(style: style, size: style.effectiveFontSize)
        if resolved.isSystemDefault || resolved.isFallbackToSystem {
            return MediaLocalization.text(.subtitleFontSystemDefault)
        }
        let manager = NSFontManager.shared
        let localized = manager.localizedName(forFamily: resolved.resolvedFamilyName, face: nil)
        return localized.isEmpty ? resolved.resolvedFamilyName : localized
    }

    /// Resolves a `SubtitleStyleConfiguration` and point size into an `NSFont` and SwiftUI `Font`
    /// with safe fallback to the system rounded font and CJK cascade protection.
    public static func resolve(style: SubtitleStyleConfiguration, size: CGFloat) -> SubtitleResolvedFont {
        let clampedSize = max(10.0, size)
        guard let requested = normalizeFontIdentifier(style.fontFamilyName) else {
            return makeSystemDefaultFont(size: clampedSize, isBold: style.isBold, isItalic: style.isItalic, requested: nil, isFallback: false)
        }

        let manager = NSFontManager.shared
        let baseCandidate = findBaseFont(
            requested: requested, size: clampedSize, isBold: style.isBold, isItalic: style.isItalic
        )

        guard let baseCandidate else {
            return makeSystemDefaultFont(
                size: clampedSize,
                isBold: style.isBold,
                isItalic: style.isItalic,
                requested: requested,
                isFallback: true
            )
        }

        var traitConverted = baseCandidate
        if style.isBold {
            traitConverted = manager.convert(traitConverted, toHaveTrait: .boldFontMask)
        }
        if style.isItalic {
            traitConverted = manager.convert(traitConverted, toHaveTrait: .italicFontMask)
        }

        let cascadedFont = applyingCJKCascadeList(to: traitConverted, size: clampedSize, isBold: style.isBold)
        let symbolic = cascadedFont.fontDescriptor.symbolicTraits
        var swiftFont = Font(cascadedFont as CTFont)
        if style.isBold && !symbolic.contains(.bold) {
            swiftFont = swiftFont.bold()
        }
        if style.isItalic && !symbolic.contains(.italic) {
            swiftFont = swiftFont.italic()
        }

        let resolvedFamily = cascadedFont.familyName ?? requested
        return SubtitleResolvedFont(
            requestedIdentifier: requested,
            resolvedPostScriptName: cascadedFont.fontName,
            resolvedFamilyName: resolvedFamily,
            isSystemDefault: false,
            isFallbackToSystem: false,
            nsFont: cascadedFont,
            swiftUIFont: swiftFont
        )
    }

    private static func findBaseFont(
        requested: String, size: CGFloat, isBold: Bool, isItalic: Bool
    ) -> NSFont? {
        let manager = NSFontManager.shared
        if let direct = NSFont(name: requested, size: size) {
            return direct
        }
        if let members = manager.availableMembers(ofFontFamily: requested),
           let firstPS = preferredMemberPostScriptName(from: members, isBold: isBold, isItalic: isItalic),
           let memberFont = NSFont(name: firstPS, size: size) {
            return memberFont
        }
        // Case-insensitive family or localized name lookup fallback
        let matchedFamily = manager.availableFontFamilies.first { family in
            guard !family.hasPrefix(".") else { return false }
            if family.caseInsensitiveCompare(requested) == .orderedSame { return true }
            let loc = manager.localizedName(forFamily: family, face: nil)
            return loc.caseInsensitiveCompare(requested) == .orderedSame
        }
        if let matchedFamily,
           let members = manager.availableMembers(ofFontFamily: matchedFamily),
           let firstPS = preferredMemberPostScriptName(from: members, isBold: isBold, isItalic: isItalic),
           let memberFont = NSFont(name: firstPS, size: size) {
            return memberFont
        }
        return nil
    }

    /// Checks whether a string renders without any missing glyphs (`CGGlyph == 0`) using CoreText line shaping.
    public static func rendersWithoutMissingGlyphs(text: String, font: NSFont) -> Bool {
        guard !text.isEmpty else { return true }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
            if glyphs.contains(0) {
                return false
            }
        }
        return true
    }

    private static func preferredMemberPostScriptName(
        from members: [[Any]],
        isBold: Bool,
        isItalic: Bool
    ) -> String? {
        guard !members.isEmpty else { return nil }
        for member in members {
            guard let psName = member.first as? String else { continue }
            let traits = (member.count >= 4 ? member[3] as? UInt : nil) ?? 0
            let hasBold = (traits & NSFontTraitMask.boldFontMask.rawValue) != 0
            let hasItalic = (traits & NSFontTraitMask.italicFontMask.rawValue) != 0
            if hasBold == isBold && hasItalic == isItalic {
                return psName
            }
        }
        return members.first?.first as? String
    }

    private static func applyingCJKCascadeList(to font: NSFont, size: CGFloat, isBold: Bool) -> NSFont {
        let weight: NSFont.Weight = isBold ? .bold : .medium
        let systemRef = NSFont.systemFont(ofSize: size, weight: weight)
        let defaultCascade = CTFontCopyDefaultCascadeListForLanguages(
            systemRef as CTFont,
            cjkCascadeLanguages as CFArray
        ) as? [NSFontDescriptor] ?? []
        guard !defaultCascade.isEmpty else { return font }

        let existing = (font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]) ?? []
        let merged = existing + defaultCascade
        let updatedDescriptor = font.fontDescriptor.addingAttributes([.cascadeList: merged])
        return NSFont(descriptor: updatedDescriptor, size: size) ?? font
    }

    private static func makeSystemDefaultFont(
        size: CGFloat,
        isBold: Bool,
        isItalic: Bool,
        requested: String?,
        isFallback: Bool
    ) -> SubtitleResolvedFont {
        let nsWeight: NSFont.Weight = isBold ? .bold : .medium
        let baseSys = NSFont.systemFont(ofSize: size, weight: nsWeight)
        let roundedSys: NSFont = {
            if let desc = baseSys.fontDescriptor.withDesign(.rounded),
               let font = NSFont(descriptor: desc, size: size) {
                return font
            }
            return baseSys
        }()
        let finalNSFont = isItalic
            ? NSFontManager.shared.convert(roundedSys, toHaveTrait: .italicFontMask)
            : roundedSys

        let swiftWeight: Font.Weight = isBold ? .bold : .medium
        let baseSwift = Font.system(size: size, weight: swiftWeight, design: .rounded)
        let finalSwift = isItalic ? baseSwift.italic() : baseSwift

        return SubtitleResolvedFont(
            requestedIdentifier: requested,
            resolvedPostScriptName: finalNSFont.fontName,
            resolvedFamilyName: finalNSFont.familyName ?? ".AppleSystemUIFontRounded",
            isSystemDefault: !isFallback,
            isFallbackToSystem: isFallback,
            nsFont: finalNSFont,
            swiftUIFont: finalSwift
        )
    }
}
