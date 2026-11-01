// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreText
import Foundation
import SwiftUI
import TTI18nCore
import TTKitDesign

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
/// and SwiftUI `Font` (for `SubtitleOverlayView` and live preview rendering).
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

/// Interactive IINA-style subtitle font picker with search filter, family/typeface columns, and bilingual live preview.
@MainActor
internal struct SubtitleFontPickerView: View {
    let style: SubtitleStyleConfiguration
    let onUpdateStyle: (SubtitleStyleConfiguration) -> Void
    let onUserInteraction: () -> Void
    let onClose: () -> Void

    @State private var families: [SubtitleFontFamily] = []
    @State private var searchQuery: String = ""
    @State private var selectedFamilyID: String = SubtitleFontFamily.systemDefaultID
    @State private var selectedFacePostScript: String = SubtitleFontFamily.systemDefaultID

    private var filteredFamilies: [SubtitleFontFamily] {
        SubtitleFontResolver.filterFamilies(families, query: searchQuery)
    }

    private var activeFamily: SubtitleFontFamily? {
        families.first(where: { $0.id == selectedFamilyID })
    }

    private var activeFaces: [SubtitleFontFace] {
        activeFamily?.faces ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            searchBar
            familyAndFaceColumns
            Divider()
            bilingualPreviewCard
            footerBar
        }
        .padding(14)
        .frame(width: 440, height: 450)
        .onAppear {
            loadCatalogAndSyncSelection()
            onUserInteraction()
        }
    }

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            Label(MediaLocalization.text(.subtitleFontPickerTitle), systemImage: "textformat")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(MediaLocalization.text(.subtitleFontDone)) {
                onUserInteraction()
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                MediaLocalization.text(.subtitleFontSearchPlaceholder),
                text: Binding(
                    get: { searchQuery },
                    set: { newValue in
                        searchQuery = newValue
                        onUserInteraction()
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    onUserInteraction()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    @ViewBuilder
    private var familyAndFaceColumns: some View {
        HStack(spacing: 10) {
            // Left Column: Font Family
            VStack(alignment: .leading, spacing: 4) {
                Text(MediaLocalization.text(.subtitleFontFamilyHeader))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if filteredFamilies.isEmpty {
                                Text(MediaLocalization.text(.subtitleFontNoMatches))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            } else {
                                ForEach(filteredFamilies) { family in
                                    familyRowButton(family)
                                        .id(family.id)
                                }
                            }
                        }
                        .padding(4)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .onAppear {
                        proxy.scrollTo(selectedFamilyID, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // Right Column: Typeface / Member
            VStack(alignment: .leading, spacing: 4) {
                Text(MediaLocalization.text(.subtitleFontTypefaceHeader))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(activeFaces) { face in
                            faceRowButton(face)
                        }
                    }
                    .padding(4)
                }
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
            .frame(width: 156)
        }
        .frame(height: 196)
    }

    @ViewBuilder
    private func familyRowButton(_ family: SubtitleFontFamily) -> some View {
        let isSelected = family.id == selectedFamilyID
        Button {
            selectFamily(family)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                Text(family.localizedName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func faceRowButton(_ face: SubtitleFontFace) -> some View {
        let isSelected = face.postScriptName == selectedFacePostScript
        Button {
            selectFace(face)
        } label: {
            HStack(spacing: 6) {
                Text(face.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bilingualPreviewCard: some View {
        let previewGeometry = SubtitleVideoContentGeometry(viewportSize: CGSize(width: 412, height: 232))
        let previewMetrics = SubtitleRelativeSizingResolver.resolveMetrics(style: style, geometry: previewGeometry)
        let previewPrimarySize = min(23.0, max(14.0, previewMetrics.primaryFontSize * 1.45))
        let previewSecondarySize = previewPrimarySize * SubtitleRelativeSizingResolver.secondaryFontSizeRatio
        let resolvedPrimary = SubtitleFontResolver.resolve(style: style, size: previewPrimarySize)
        let resolvedSecondary = SubtitleFontResolver.resolve(style: style, size: previewSecondarySize)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(MediaLocalization.text(.subtitleFontPreviewHeader))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if resolvedPrimary.isFallbackToSystem {
                    Text(MediaLocalization.text(.subtitleFontFallbackNotice))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TTKitTheme.archivalAmber)
                } else {
                    Text(resolvedPrimary.isSystemDefault ? MediaLocalization.text(.subtitleFontSystemDefault) : resolvedPrimary.resolvedPostScriptName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 4) {
                Text(MediaLocalization.text(.subtitleFontPreviewSecondarySample))
                    .font(resolvedSecondary.swiftUIFont)
                    .foregroundStyle(style.textColor.color.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(MediaLocalization.text(.subtitleFontPreviewPrimarySample))
                    .font(resolvedPrimary.swiftUIFont)
                    .foregroundStyle(style.textColor.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .shadow(color: .black.opacity(0.85), radius: max(2.0, CGFloat(style.borderWidth) + 1.0), y: 1.0)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(max(0.68, style.backgroundOpacity)))
            )
        }
    }

    @ViewBuilder
    private var footerBar: some View {
        HStack {
            Text(MediaLocalization.text(.subtitleFontCustomNameLabel))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(style.fontFamilyName ?? MediaLocalization.text(.subtitleFontCustomNamePlaceholder))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Button(MediaLocalization.text(.subtitleFontSystemDefault)) {
                if let sys = families.first(where: \.isSystemDefault) {
                    selectFamily(sys)
                } else {
                    var updated = style
                    updated.fontFamilyName = nil
                    onUpdateStyle(updated)
                    onUserInteraction()
                }
            }
            .font(.system(size: 11, weight: .medium))
            .controlSize(.small)
            .disabled(SubtitleFontResolver.normalizeFontIdentifier(style.fontFamilyName) == nil)
        }
    }

    private func loadCatalogAndSyncSelection() {
        let loaded = SubtitleFontResolver.availableFamilies(includeSystemDefault: true)
        families = loaded

        guard let currentID = SubtitleFontResolver.normalizeFontIdentifier(style.fontFamilyName) else {
            selectedFamilyID = SubtitleFontFamily.systemDefaultID
            selectedFacePostScript = SubtitleFontFamily.systemDefaultID
            return
        }

        if let matchedFamily = loaded.first(where: { family in
            !family.isSystemDefault && (
                family.familyName.caseInsensitiveCompare(currentID) == .orderedSame
                || family.localizedName.caseInsensitiveCompare(currentID) == .orderedSame
                || family.faces.contains { $0.postScriptName.caseInsensitiveCompare(currentID) == .orderedSame }
            )
        }) {
            selectedFamilyID = matchedFamily.id
            if let matchedFace = matchedFamily.faces.first(where: {
                $0.postScriptName.caseInsensitiveCompare(currentID) == .orderedSame
            }) {
                selectedFacePostScript = matchedFace.postScriptName
            } else {
                selectedFacePostScript = matchedFamily.faces.first?.postScriptName ?? matchedFamily.familyName
            }
        } else {
            selectedFamilyID = SubtitleFontFamily.systemDefaultID
            selectedFacePostScript = SubtitleFontFamily.systemDefaultID
        }
    }

    private func selectFamily(_ family: SubtitleFontFamily) {
        selectedFamilyID = family.id
        var updated = style
        if family.isSystemDefault {
            selectedFacePostScript = SubtitleFontFamily.systemDefaultID
            updated.fontFamilyName = nil
        } else {
            let firstFace = family.faces.first?.postScriptName ?? family.familyName
            selectedFacePostScript = firstFace
            updated.fontFamilyName = family.familyName
        }
        onUpdateStyle(updated)
        onUserInteraction()
    }

    private func selectFace(_ face: SubtitleFontFace) {
        selectedFacePostScript = face.postScriptName
        var updated = style
        if face.postScriptName == SubtitleFontFamily.systemDefaultID {
            updated.fontFamilyName = nil
        } else {
            updated.fontFamilyName = face.postScriptName
        }
        onUpdateStyle(updated)
        onUserInteraction()
    }
}
