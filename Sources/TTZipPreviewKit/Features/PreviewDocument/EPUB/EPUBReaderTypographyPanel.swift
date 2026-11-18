// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit
import TTZipUI

// MARK: - EPUB Typography & Theme Panel

/// Product-owned typography and theme panel for the EPUB reader workspace.
///
/// The panel drives the reading session that TTMediaKit exposes. Visual language belongs to
/// the product, so every accent comes from `TTZipTheme` rather than the system accent color.
///
/// Every change goes through the session's public setters. Those setters write the value and
/// then flush one preference snapshot to the host, so the host never observes a half-applied
/// set of preferences.
struct EPUBReaderTypographyPanel: View {
    @ObservedObject var session: EPUBReaderSession

    var body: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.md) {
            headerBar
            Divider()
            layoutModeSection
            fontFamilySection
            cjkFontSection
            fontSizeSection
            themeSection
        }
        .padding(TTZipTheme.Spacing.md)
        .frame(width: 268)
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: TTZipTheme.Spacing.xs) {
            Image(systemName: "textformat")
                .font(.callout.weight(.bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(EBookPreviewLocalization.text(.typographyAndThemeTitle))
                .font(.headline)
                .foregroundStyle(TTZipTheme.textPhotonicPrimary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Layout Mode

    @ViewBuilder
    private var layoutModeSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
            sectionLabel(EPUBPaginationLocalization.text(.layoutModeLabel))
            HStack(spacing: TTZipTheme.Spacing.xs) {
                layoutChip(
                    title: EPUBPaginationLocalization.text(.layoutModePaginated),
                    systemImage: "book.pages",
                    key: "paginated"
                )
                layoutChip(
                    title: EPUBPaginationLocalization.text(.layoutModeScrolling),
                    systemImage: "scroll",
                    key: "scrolling"
                )
            }
        }
    }

    private func layoutChip(
        title: String,
        systemImage: String,
        key: String
    ) -> some View {
        let isSelected = session.layoutMode == key
        return Button {
            session.setLayoutMode(key)
        } label: {
            HStack(spacing: TTZipTheme.Spacing.xxs) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : TTZipTheme.textPhotonicPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(chipFill(isSelected: isSelected))
            .overlay(chipStroke(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: Fonts

    private var fontFamilySection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
            sectionLabel(EPUBReaderWorkspaceLocalization.text(.latinFont))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: TTZipTheme.Spacing.xs) {
                fontChip("Charter / Georgia", key: "serif")
                fontChip("Helvetica / Arial", key: "sans")
                fontChip("Menlo / Courier", key: "mono")
            }
        }
    }

    private var cjkFontSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
            sectionLabel(EPUBReaderWorkspaceLocalization.text(.cjkFont))
            Picker(
                EPUBReaderWorkspaceLocalization.text(.cjkFont),
                selection: Binding(
                    get: { session.cjkFontFamily },
                    set: { session.setCJKFontFamily($0) }
                )
            ) {
                Text(EBookPreviewLocalization.text(.fontSerif)).tag("serif")
                Text(EBookPreviewLocalization.text(.fontKaiti)).tag("kaiti")
                Text(EBookPreviewLocalization.text(.fontSansSerif)).tag("sans")
                Text(EBookPreviewLocalization.text(.fontFangsong)).tag("fangsong")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(TTZipTheme.bambooGreen)
        }
    }

    private func fontChip(_ title: String, key: String) -> some View {
        let isSelected = session.fontFamily == key
        return Button {
            session.setFontFamily(key)
        } label: {
            Text(title)
                .font(.caption.weight(isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : TTZipTheme.textPhotonicPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(chipFill(isSelected: isSelected))
                .overlay(chipStroke(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: Font Size

    private var fontSizeSection: some View {
        let decreaseHelp = EBookPreviewLocalization.text(.decreaseFontSizeHelp)
        let increaseHelp = EBookPreviewLocalization.text(.increaseFontSizeHelp)
        return VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
            HStack {
                sectionLabel(EBookPreviewLocalization.text(.fontSizeLabel))
                Spacer(minLength: 0)
                Text("\(session.fontSize) pt")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }

            HStack(spacing: TTZipTheme.Spacing.xs) {
                fontSizeStepButton(label: "A-", help: decreaseHelp) {
                    session.setFontSize(max(session.fontSize - 1, 12))
                }

                Slider(
                    value: Binding(
                        get: { Double(session.fontSize) },
                        set: { session.setFontSize(Int($0)) }
                    ),
                    in: 12...36,
                    step: 1
                )
                .tint(TTZipTheme.bambooGreen)

                fontSizeStepButton(label: "A+", help: increaseHelp) {
                    session.setFontSize(min(session.fontSize + 1, 36))
                }
            }
        }
    }

    private func fontSizeStepButton(label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(TTZipTheme.textPhotonicPrimary)
                .frame(width: 28, height: 28)
                .background(chipFill(isSelected: false))
                .overlay(chipStroke(isSelected: false))
                .contentShape(
                    RoundedRectangle(cornerRadius: TTZipTheme.Radius.xs, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .ttButtonHelp(help)
    }

    // MARK: Theme

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
            sectionLabel(EBookPreviewLocalization.text(.themeLabel))
            HStack(spacing: TTZipTheme.Spacing.md) {
                themeOptionButton(
                    name: EBookPreviewLocalization.text(.themeLight),
                    key: "light",
                    fill: Color.white,
                    stroke: Color.gray.opacity(0.35)
                )
                themeOptionButton(
                    name: EBookPreviewLocalization.text(.themeSepia),
                    key: "sepia",
                    fill: Color(red: 0.97, green: 0.94, blue: 0.85),
                    stroke: Color.gray.opacity(0.35)
                )
                themeOptionButton(
                    name: EBookPreviewLocalization.text(.themeDark),
                    key: "dark",
                    fill: Color(red: 0.12, green: 0.12, blue: 0.13),
                    stroke: Color.gray.opacity(0.45)
                )
                glassThemeButton
            }
        }
    }

    private var glassThemeButton: some View {
        let isSelected = session.themeMode == "transparent"
        let title = EBookPreviewLocalization.text(.themeGlass)
        return Button {
            session.setThemeMode("transparent")
        } label: {
            VStack(spacing: TTZipTheme.Spacing.xxs) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [TTZipTheme.bambooGreen, TTZipTheme.kintsugiGold],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 22, height: 22)
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? TTZipTheme.bambooGreen : Color.clear,
                        lineWidth: 2
                    )
                )

                Text(title)
                    .font(.caption2.weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func themeOptionButton(name: String, key: String, fill: Color, stroke: Color) -> some View {
        let isSelected = session.themeMode == key
        return Button {
            session.setThemeMode(key)
        } label: {
            VStack(spacing: TTZipTheme.Spacing.xxs) {
                Circle()
                    .fill(fill)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle().strokeBorder(
                            isSelected ? TTZipTheme.bambooGreen : stroke,
                            lineWidth: isSelected ? 2 : 1
                        )
                    )

                Text(name)
                    .font(.caption2.weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    // MARK: Shared Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func chipFill(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
            .fill(isSelected ? TTZipTheme.bambooGreen.opacity(0.14) : TTZipTheme.subtleFill)
    }

    private func chipStroke(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
            .strokeBorder(
                isSelected ? TTZipTheme.bambooGreen.opacity(0.45) : TTZipTheme.hairlineBorder,
                lineWidth: 0.5
            )
    }
}
