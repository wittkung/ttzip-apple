// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import TTZipUI

@MainActor
struct TTZipSubtitleQuickSettings: View {
    let subtitleOptions: [SubtitleMenuOption]
    let selectedSubtitleID: String?
    let selectedSecondarySubtitleID: String
    let style: SubtitleStyleConfiguration
    let activeSubtitleCodec: String?
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

    static func syncInteractionDepth(
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

            TTZipSubtitleRelativeScaleSettings(
                style: style,
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
            Text(TTZipSubtitlePresentationLocalization.text(.subtitleFont))
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
            .ttButtonHelp(TTZipSubtitlePresentationLocalization.text(.subtitleFontChoose))
            .popover(isPresented: $showFontPickerPopover, arrowEdge: .trailing) {
                TTZipSubtitleFontPicker(
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
                                    style.textColor == preset ? TTZipTheme.accentColor : Color.gray.opacity(0.45),
                                    lineWidth: style.textColor == preset ? 2.0 : 1.0
                                )
                        )
                }
                .buttonStyle(.plain)
                .ttButtonHelp(colorHelp(for: preset))
            }
        }
    }

    private func colorHelp(for preset: SubtitleColorPreset) -> String {
        switch preset {
        case .white: MediaLocalization.text(.colorWhite)
        case .yellow: MediaLocalization.text(.colorYellow)
        case .cyan: MediaLocalization.text(.colorCyan)
        case .green: MediaLocalization.text(.colorGreen)
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

extension SubtitleColorPreset {
    var color: Color {
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
}
