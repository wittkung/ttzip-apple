// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

// MARK: - EPUB Typography & Theme Popover

public struct EPUBTypographyPopoverView: View {
    @Binding public var fontFamily: String
    @Binding public var fontSize: Int
    @Binding public var themeMode: String
    public var cjkFontFamily: Binding<String>?
    public var layoutMode: Binding<String>?

    public init(
        fontFamily: Binding<String>,
        fontSize: Binding<Int>,
        themeMode: Binding<String>,
        layoutMode: Binding<String>? = nil,
        cjkFontFamily: Binding<String>? = nil
    ) {
        self._fontFamily = fontFamily
        self._fontSize = fontSize
        self._themeMode = themeMode
        self.layoutMode = layoutMode
        self.cjkFontFamily = cjkFontFamily
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar
            Divider()
            layoutModeSection
            fontFamilySection
            independentCJKFontSection
            fontSizeSection
            themeSection
        }
        .padding(14)
        .frame(width: 250)
    }

    @ViewBuilder
    private var independentCJKFontSection: some View {
        if let cjkFontFamily {
            VStack(alignment: .leading) {
                Text(EPUBReaderWorkspaceLocalization.text(.cjkFont)).font(.caption)
                Picker(EPUBReaderWorkspaceLocalization.text(.cjkFont), selection: cjkFontFamily) {
                    Text(EBookPreviewLocalization.text(.fontSerif)).tag("serif")
                    Text(EBookPreviewLocalization.text(.fontKaiti)).tag("kaiti")
                    Text(EBookPreviewLocalization.text(.fontSansSerif)).tag("sans")
                    Text(EBookPreviewLocalization.text(.fontFangsong)).tag("fangsong")
                }.labelsHidden()
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Image(systemName: "textformat")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)
            Text(EBookPreviewLocalization.text(.typographyAndThemeTitle))
                .font(.system(size: 12, weight: .bold))
            Spacer()
        }
    }

    @ViewBuilder
    private var layoutModeSection: some View {
        if let layoutModeBinding = layoutMode {
            VStack(alignment: .leading, spacing: 6) {
                Text(EPUBPaginationLocalization.text(.layoutModeLabel))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    layoutChip(
                        title: EPUBPaginationLocalization.text(.layoutModePaginated),
                        systemImage: "book.pages",
                        key: "paginated",
                        binding: layoutModeBinding
                    )
                    layoutChip(
                        title: EPUBPaginationLocalization.text(.layoutModeScrolling),
                        systemImage: "scroll",
                        key: "scrolling",
                        binding: layoutModeBinding
                    )
                }
            }
        }
    }

    private func layoutChip(
        title: String,
        systemImage: String,
        key: String,
        binding: Binding<String>
    ) -> some View {
        let isSelected = binding.wrappedValue == key
        return Button(action: { binding.wrappedValue = key }) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var fontFamilySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(EPUBReaderWorkspaceLocalization.text(.latinFont))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                fontChip("Charter / Georgia", key: "serif")
                fontChip("Helvetica / Arial", key: "sans")
                fontChip("Menlo / Courier", key: "mono")
            }
        }
    }

    private var fontSizeSection: some View {
        let decreaseHelp = EBookPreviewLocalization.text(.decreaseFontSizeHelp)
        let increaseHelp = EBookPreviewLocalization.text(.increaseFontSizeHelp)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(EBookPreviewLocalization.text(.fontSizeLabel))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(fontSize) pt")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 8) {
                Button(action: { fontSize = max(fontSize - 1, 12) }) {
                    Text("A-")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 24)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(decreaseHelp)
                .ttButtonHelp(decreaseHelp)

                Slider(value: Binding(
                    get: { Double(fontSize) },
                    set: { fontSize = Int($0) }
                ), in: 12...36, step: 1)
                .tint(Color.accentColor)

                Button(action: { fontSize = min(fontSize + 1, 36) }) {
                    Text("A+")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 24)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(increaseHelp)
                .ttButtonHelp(increaseHelp)
            }
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(EBookPreviewLocalization.text(.themeLabel))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
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
        Button(action: { themeMode = "transparent" }) {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 22, height: 22)
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay(
                    Circle().strokeBorder(
                        themeMode == "transparent" ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
                )

                Text(EBookPreviewLocalization.text(.themeGlass))
                    .font(.system(size: 9, weight: themeMode == "transparent" ? .bold : .regular))
                    .foregroundStyle(themeMode == "transparent" ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func fontChip(_ title: String, key: String) -> some View {
        Button(action: { fontFamily = key }) {
            Text(title)
                .font(.system(size: 10, weight: fontFamily == key ? .bold : .medium))
                .foregroundStyle(fontFamily == key ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(fontFamily == key ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(
                        fontFamily == key ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func themeOptionButton(name: String, key: String, fill: Color, stroke: Color) -> some View {
        Button(action: { themeMode = key }) {
            VStack(spacing: 3) {
                Circle()
                    .fill(fill)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle().strokeBorder(
                            themeMode == key ? Color.accentColor : stroke,
                            lineWidth: themeMode == key ? 2 : 1
                        )
                    )

                Text(name)
                    .font(.system(size: 9, weight: themeMode == key ? .bold : .regular))
                    .foregroundStyle(themeMode == key ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
