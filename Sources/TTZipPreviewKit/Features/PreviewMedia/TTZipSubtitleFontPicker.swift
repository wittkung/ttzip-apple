// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitDesign
import TTMediaKit
import TTZipUI

@MainActor
struct TTZipSubtitleFontPicker: View {
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
            Label(TTZipSubtitlePresentationLocalization.text(.subtitleFontPickerTitle), systemImage: "textformat")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(TTZipSubtitlePresentationLocalization.text(.subtitleFontDone)) {
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
                TTZipSubtitlePresentationLocalization.text(.subtitleFontSearchPlaceholder),
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
            VStack(alignment: .leading, spacing: 4) {
                Text(TTZipSubtitlePresentationLocalization.text(.subtitleFontFamilyHeader))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if filteredFamilies.isEmpty {
                                Text(TTZipSubtitlePresentationLocalization.text(.subtitleFontNoMatches))
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

            VStack(alignment: .leading, spacing: 4) {
                Text(TTZipSubtitlePresentationLocalization.text(.subtitleFontTypefaceHeader))
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
                    .foregroundStyle(isSelected ? TTZipTheme.accentColor : Color.secondary.opacity(0.45))
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
                    .fill(isSelected ? TTZipTheme.accentColor.opacity(0.18) : Color.clear)
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
                        .foregroundStyle(TTZipTheme.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? TTZipTheme.accentColor.opacity(0.18) : Color.clear)
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
                Text(TTZipSubtitlePresentationLocalization.text(.subtitleFontPreviewHeader))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if resolvedPrimary.isFallbackToSystem {
                    Text(TTZipSubtitlePresentationLocalization.text(.subtitleFontFallbackNotice))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TTKitTheme.archivalAmber)
                } else {
                    Text(resolvedPrimary.isSystemDefault ? MediaLocalization.text(.subtitleFontSystemDefault) : resolvedPrimary.resolvedPostScriptName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 4) {
                Text(TTZipSubtitlePresentationLocalization.text(.subtitleFontPreviewSecondarySample))
                    .font(resolvedSecondary.swiftUIFont)
                    .foregroundStyle(style.textColor.color.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(TTZipSubtitlePresentationLocalization.text(.subtitleFontPreviewPrimarySample))
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
            Text(TTZipSubtitlePresentationLocalization.text(.subtitleFontCustomNameLabel))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(style.fontFamilyName ?? TTZipSubtitlePresentationLocalization.text(.subtitleFontCustomNamePlaceholder))
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
