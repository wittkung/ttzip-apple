// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import TTZipUI

enum MarkdownPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case rich = "Rich Preview"
    case source = "Source Code"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .rich: return "doc.richtext.fill"
        case .source: return "curlybraces"
        }
    }

    @MainActor
    var localizedTitle: String {
        switch self {
        case .rich: return TTZipMarkdownHexPreviewLocalization.text(.markdownModeRich)
        case .source: return TTZipMarkdownHexPreviewLocalization.text(.markdownModeSource)
        }
    }
}

struct TTZipMarkdownPreviewToolbar: View {
    let isCompact: Bool
    let lineCount: Int
    let wordCount: Int
    let characterCount: Int
    let byteCount: Int64?
    let encodingBadge: String?
    let isNativeWritableMarkdown: Bool
    let isEdited: Bool
    let isSavedToastPresented: Bool
    @Binding var mode: MarkdownPreviewMode
    let onCopy: () -> Void
    let onSave: () -> Void

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullToolbar
            mediumToolbar
            compactToolbar
            minimalToolbar
        }
        .padding(.horizontal, isCompact ? 6 : 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var fullToolbar: some View {
        HStack(spacing: 8) {
            documentTypeBadge
            if let enc = encodingBadge, !enc.isEmpty {
                encodingTagBadge(enc)
            }
            statusBadgeView
            Spacer(minLength: 4)
            documentStatsView
            modeSegmentedSwitcher(isCompact: false, iconOnly: false)
            copyButton
            if isSavedToastPresented {
                savedToastView
            }
            if isNativeWritableMarkdown && isEdited {
                saveButton(isCompact: false)
            }
        }
    }

    private var mediumToolbar: some View {
        HStack(spacing: 6) {
            documentTypeBadge
            if let enc = encodingBadge, !enc.isEmpty {
                encodingTagBadge(enc)
            }
            statusBadgeView
            Spacer(minLength: 4)
            compactStatsView
            modeSegmentedSwitcher(isCompact: true, iconOnly: false)
            copyButton
            if isSavedToastPresented {
                savedToastView
            } else if isNativeWritableMarkdown && isEdited {
                saveButton(isCompact: true)
            }
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 6) {
            modeSegmentedSwitcher(isCompact: true, iconOnly: false)
            statusBadgeView
            Spacer(minLength: 4)
            copyButton
            if isSavedToastPresented {
                savedToastView
            } else if isNativeWritableMarkdown && isEdited {
                saveButton(isCompact: true)
            }
        }
    }

    private var minimalToolbar: some View {
        HStack(spacing: 4) {
            modeSegmentedSwitcher(isCompact: true, iconOnly: true)
            if !isNativeWritableMarkdown {
                readOnlyBadge
            }
            Spacer(minLength: 2)
            copyButton
            if isNativeWritableMarkdown && isEdited {
                saveButton(isCompact: true)
            }
        }
    }

    @ViewBuilder
    private var statusBadgeView: some View {
        if isNativeWritableMarkdown && isEdited {
            unsavedBadge
        } else if !isNativeWritableMarkdown {
            readOnlyBadge
        }
    }

    private var documentTypeBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TTZipTheme.accentColor)
            Text("MARKDOWN")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(TTZipTheme.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func encodingTagBadge(_ encodingText: String) -> some View {
        Text(encodingText)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var unsavedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
            Text(TextAndDocumentPreviewLocalization.text(.unsavedBadge))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.12))
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var readOnlyBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9.5, weight: .bold))
            Text(TextAndDocumentPreviewLocalization.text(.readOnlyBadge))
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var documentStatsView: some View {
        HStack(spacing: 6) {
            if let byteCount {
                Text(Self.byteCountFormatter.string(fromByteCount: max(0, byteCount)))
                Text("•")
            }
            Text(TTZipMarkdownHexPreviewLocalization.lineCount(lineCount))
            Text("•")
            Text(TTZipMarkdownHexPreviewLocalization.wordCount(wordCount))
            Text("•")
            Text(TTZipMarkdownHexPreviewLocalization.charCount(characterCount))
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactStatsView: some View {
        HStack(spacing: 4) {
            if let byteCount {
                Text(Self.byteCountFormatter.string(fromByteCount: max(0, byteCount)))
                Text("•")
            }
            Text(TTZipMarkdownHexPreviewLocalization.lineCount(lineCount))
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func modeSegmentedSwitcher(isCompact: Bool, iconOnly: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(MarkdownPreviewMode.allCases) { m in
                Button(action: {
                    withAnimation(TTZipTheme.Motion.micro) {
                        mode = m
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: m.icon)
                            .font(.system(size: 10, weight: .bold))
                        if !iconOnly {
                            Text(m.localizedTitle)
                                .font(.system(size: 10.5, weight: mode == m ? .bold : .medium))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, isCompact ? 6 : 8)
                    .padding(.vertical, 4)
                    .background(mode == m ? TTZipTheme.accentColor : Color.clear)
                    .foregroundStyle(mode == m ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .ttButtonHelp(m.localizedTitle)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var copyButton: some View {
        Button(action: { onCopy() }) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(TTZipMarkdownHexPreviewLocalization.text(.copyRawMarkdownHelp))
    }

    private var savedToastView: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(TextAndDocumentPreviewLocalization.text(.savedBadge))
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(TTZipTheme.accentColor)
        .fixedSize(horizontal: true, vertical: false)
        .transition(.opacity)
    }

    @ViewBuilder
    private func saveButton(isCompact: Bool) -> some View {
        Button(action: { onSave() }) {
            if isCompact {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(TextAndDocumentPreviewLocalization.text(.saveButton))
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(TTZipTheme.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(TextAndDocumentPreviewLocalization.saveWithShortcut("⌘S"))
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(isEdited ? Color.white : TTZipTheme.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isEdited ? TTZipTheme.accentColor : TTZipTheme.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .keyboardShortcut("s", modifiers: [.command])
        .ttButtonHelp(TextAndDocumentPreviewLocalization.saveChangesHelp("⌘S"))
    }
}
