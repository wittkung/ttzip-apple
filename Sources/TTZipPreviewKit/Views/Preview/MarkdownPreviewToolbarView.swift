// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipUI

/// Adaptive top toolbar for Markdown preview, supporting compact inspector and regular modes.
struct MarkdownPreviewToolbarView: View {
    let isCompact: Bool
    let fileName: String
    let fileURL: URL?
    let lineCount: Int
    let wordCount: Int
    let characterCount: Int
    let isNativeWritableMarkdown: Bool
    let isEdited: Bool
    let isSavedToastPresented: Bool
    @Binding var mode: MarkdownPreviewMode
    let onCopy: () -> Void
    let onSave: () -> Void
    
    var body: some View {
        HStack(spacing: isCompact ? 8 : 10) {
            if isCompact {
                // Compact Inspector Mode (<= 480pt):
                // Eliminates redundant badges, file names, and stats cards that duplicate the inspector header.
                modeSegmentedSwitcher(isCompact: true)
                
                copyButton
                
                if isSavedToastPresented {
                    savedToastView
                } else if isNativeWritableMarkdown && isEdited {
                    saveButton(isCompact: true)
                }
                
                Spacer()
                
                fullscreenButton
            } else {
                // Regular Full-Featured Mode (> 480pt):
                documentTypeBadge
                
                fileNameText
                
                if isNativeWritableMarkdown && isEdited {
                    unsavedBadge
                }
                
                Spacer()
                
                documentStatsView
                modeSegmentedSwitcher(isCompact: false)
                copyButton
                
                if isSavedToastPresented {
                    savedToastView
                }
                if isNativeWritableMarkdown {
                    saveButton(isCompact: false)
                }
                
                fullscreenButton
            }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Subviews
    
    private var documentTypeBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text("MARKDOWN")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(TTZipTheme.bambooGreen.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private var fileNameText: some View {
        Text(fileName)
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
    }
    
    private var unsavedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
            Text("Unsaved")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.12))
        .clipShape(Capsule())
    }
    
    private var documentStatsView: some View {
        HStack(spacing: 8) {
            Text("\(lineCount) lines")
            Text("•")
            Text("\(wordCount) words")
            Text("•")
            Text("\(characterCount) chars")
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    private func modeSegmentedSwitcher(isCompact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(MarkdownPreviewMode.allCases) { m in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        mode = m
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: m.icon)
                            .font(.system(size: 10, weight: .bold))
                        Text(m.rawValue)
                            .font(.system(size: 10.5, weight: mode == m ? .bold : .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, isCompact ? 6 : 8)
                    .padding(.vertical, 4)
                    .background(mode == m ? TTZipTheme.bambooGreen : Color.clear)
                    .foregroundStyle(mode == m ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .help("Copy Raw Markdown")
    }
    
    private var fullscreenButton: some View {
        Button(action: {
            if let fileURL = fileURL {
                let userInfo: [String: Any] = [
                    "url": fileURL,
                    "name": fileName
                ]
                NotificationCenter.default.post(
                    name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
                    object: fileURL,
                    userInfo: userInfo
                )
            } else {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
                    object: nil
                )
            }
        }) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Toggle Fullscreen Preview")
    }
    
    private var savedToastView: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
            Text("Saved")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(TTZipTheme.bambooGreen)
        .transition(.opacity)
    }
    
    @ViewBuilder
    private func saveButton(isCompact: Bool) -> some View {
        Button(action: { onSave() }) {
            if isCompact {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(TTZipTheme.bambooGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("Save (⌘S)")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .foregroundStyle(isEdited ? Color.white : TTZipTheme.bambooGreen)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isEdited ? TTZipTheme.bambooGreen : TTZipTheme.bambooGreen.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command])
        .help("Save changes to local file (⌘S)")
    }
}
