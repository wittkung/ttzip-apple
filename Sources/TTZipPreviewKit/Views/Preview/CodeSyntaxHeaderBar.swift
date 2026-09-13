// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// Header bar component for code syntax and text preview.
struct CodeSyntaxHeaderBar: View {
    let isCompact: Bool
    let fileName: String
    let lineCount: Int
    let byteCount: Int64
    let isEdited: Bool
    let isWritableFile: Bool
    let saveErrorMessage: String?
    let isSavedToastPresented: Bool
    let isCopiedToastPresented: Bool
    @Binding var showLineNumbers: Bool
    let onCopy: () -> Void
    let onSave: () -> Void
    
    var body: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            // 1. Language Tag (Unbroken single line with concise name)
            languageBadge(isCompact: isCompact)
            
            // 2. File Metrics (Size & Line Count, shown in regular mode)
            if !isCompact {
                fileMetricsCard
            }
            
            // 3. Unsaved indicator
            if isEdited {
                unsavedBadge
            }
            
            Spacer()
            
            // 4. Notifications (Save Error / Saved Toast)
            if let errorMsg = saveErrorMessage {
                saveErrorNotice(errorMsg)
            } else if isSavedToastPresented {
                savedToastView
            }
            
            // 5. Line numbers toggle button
            lineNumbersToggleButton
            
            // 6. Copy code button
            copyButton
            
            // 7. Save Button (Strictly guarded by isEdited and isWritableFile)
            if isWritableFile && isEdited {
                saveButton(isCompact: isCompact)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }
    
    // MARK: - Subviews
    
    private func languageBadge(isCompact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "curlybraces")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(languageName(isCompact: isCompact))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(TTZipTheme.bambooGreen.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private var fileMetricsCard: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(fileSizeDescription) • \(lineCount) lines")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private var unsavedBadge: some View {
        headerBadge(icon: "circle.fill", text: "Unsaved", color: .orange, bgColor: Color.orange.opacity(0.12))
    }
    
    private var savedToastView: some View {
        headerBadge(icon: "checkmark.circle.fill", text: "Saved", color: TTZipTheme.bambooGreen, bgColor: TTZipTheme.bambooGreen.opacity(0.12))
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    
    private func saveErrorNotice(_ errorMsg: String) -> some View {
        headerBadge(icon: "exclamationmark.circle.fill", text: errorMsg, color: .red, bgColor: Color.red.opacity(0.1))
    }
    
    private func headerBadge(icon: String, text: String, color: Color, bgColor: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(bgColor)
        .clipShape(Capsule())
    }
    
    private var lineNumbersToggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                showLineNumbers.toggle()
            }
        }) {
            Image(systemName: "list.number")
                .font(.system(size: 11, weight: showLineNumbers ? .bold : .regular))
                .foregroundStyle(showLineNumbers ? TTZipTheme.bambooGreen : Color.primary.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(showLineNumbers ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(showLineNumbers ? "Hide Line Numbers" : "Show Line Numbers")
    }
    
    private var copyButton: some View {
        Button(action: { onCopy() }) {
            Image(systemName: isCopiedToastPresented ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isCopiedToastPresented ? TTZipTheme.bambooGreen : Color.primary.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isCopiedToastPresented ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isCopiedToastPresented ? "Copied to clipboard" : "Copy Source Code")
    }
    
    @ViewBuilder
    private func saveButton(isCompact: Bool) -> some View {
        Button(action: { onSave() }) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(isCompact ? "Save" : "Save (⌘S)")
                    .font(.system(size: isCompact ? 10.5 : 11, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, isCompact ? 8 : 10)
            .padding(.vertical, 4)
            .background(TTZipTheme.bambooGreen)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command])
        .help("Save changes to local file (⌘S)")
    }
    
    // MARK: - Formatters & Language Detection
    
    private var fileSizeDescription: String {
        ByteCountFormatterFlyweight.shared.string(fromByteCount: byteCount)
    }
    
    private static let extensionMap: [String: String] = [
        "swift": "Swift", "kt": "Kotlin", "kts": "Kotlin", "java": "Java",
        "py": "Python", "js": "JavaScript", "jsx": "JavaScript", "ts": "TypeScript",
        "tsx": "TypeScript", "c": "C", "h": "C", "rs": "Rust", "go": "Go",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "html": "HTML", "htm": "HTML",
        "css": "CSS", "scss": "CSS", "less": "CSS", "json": "JSON", "json5": "JSON",
        "yaml": "YAML", "yml": "YAML", "md": "Markdown", "markdown": "Markdown", "sql": "SQL"
    ]
    
    private func languageName(isCompact: Bool) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let mapped = Self.extensionMap[ext] {
            return mapped
        }
        switch ext {
        case "cpp", "hpp", "cc", "cxx", "m", "mm":
            return isCompact ? "C++" : "C++ / ObjC"
        case "xml", "plist":
            return isCompact ? "XML" : "XML / Plist"
        default:
            return ext.isEmpty ? "Plain Text" : ext.uppercased()
        }
    }
}
