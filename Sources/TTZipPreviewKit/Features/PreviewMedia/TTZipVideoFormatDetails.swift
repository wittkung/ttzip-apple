// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit

@MainActor
struct TTZipVideoFormatBadgeButton: View {
    let badgeText: String
    let isCompact: Bool
    let state: VideoFormatPresentationState
    @Binding var isPopoverPresented: Bool
    let onUserInteraction: () -> Void

    init(
        badgeText: String,
        isCompact: Bool,
        state: VideoFormatPresentationState,
        isPopoverPresented: Binding<Bool>,
        onUserInteraction: @escaping () -> Void
    ) {
        self.badgeText = badgeText
        self.isCompact = isCompact
        self.state = state
        self._isPopoverPresented = isPopoverPresented
        self.onUserInteraction = onUserInteraction
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
            onUserInteraction()
        } label: {
            Text(badgeText)
                .font(.system(size: isCompact ? 9 : 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .ttzipVideoUtilityCapsule(isCompact: isCompact)
        }
        .buttonStyle(.plain)
        .background(
            FormatBadgeAppKitButtonBridge(badgeText: badgeText) {
                isPopoverPresented.toggle()
                onUserInteraction()
            }
        )
        .accessibilityIdentifier("video_format_badge_button")
        .accessibilityLabel(TTZipVideoInteractionLocalization.text(.formatDetails))
        .accessibilityValue(badgeText)
        .ttButtonHelp(TTZipVideoInteractionLocalization.text(.formatDetails))
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            TTZipVideoFormatDetailsPopover(state: state)
        }
    }
}

@MainActor
private struct FormatBadgeAppKitButtonBridge: NSViewRepresentable {
    let badgeText: String
    let onPress: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = FormatBadgeNSButton(title: badgeText, target: context.coordinator, action: #selector(Coordinator.handlePress))
        button.isBordered = false
        button.alphaValue = 0.01
        button.setAccessibilityIdentifier("video_format_badge_button")
        button.setAccessibilityLabel(TTZipVideoInteractionLocalization.text(.formatDetails))
        button.setAccessibilityValue(badgeText)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onPress = onPress
        nsView.title = badgeText
        nsView.setAccessibilityLabel(TTZipVideoInteractionLocalization.text(.formatDetails))
        nsView.setAccessibilityValue(badgeText)
    }

    @MainActor
    final class FormatBadgeNSButton: NSButton {
        override func accessibilityPerformPress() -> Bool {
            _ = sendAction(action, to: target)
            return true
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPress: @MainActor () -> Void
        init(onPress: @escaping @MainActor () -> Void) { self.onPress = onPress }
        @objc func handlePress() { onPress() }
    }
}

@MainActor
private struct TTZipVideoFormatDetailsPopover: View {
    let state: VideoFormatPresentationState

    init(state: VideoFormatPresentationState) {
        self.state = state
    }

    var body: some View {
        let snapshot = state.comparisonSnapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(snapshot.headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(snapshot.namedSourceAndOutputBadgeText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }

            Divider()

            sectionView(
                title: snapshot.sourceSection.title,
                rows: snapshot.sourceSection.rows
            )

            Divider()

            sectionView(
                title: snapshot.outputSection.title,
                rows: snapshot.outputSection.rows
            )
        }
        .padding(14)
        .frame(width: 420)
        .accessibilityIdentifier("video_format_details_popover")
    }

    @ViewBuilder
    private func sectionView(title: String, rows: [TTZipVideoFormatDetailRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 128, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 11, weight: row.isProvided ? .medium : .regular, design: .monospaced))
                        .foregroundStyle(row.isProvided ? .primary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
