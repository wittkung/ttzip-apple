// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// An elegant Zen minimalist placeholder view for empty directories in Miller Columns.
/// Features WSJ subtle typography, soft gold/bamboo accents, quick actions, and smooth fade-in.
public struct EmptyFolderPlaceholderView: View {
    private var l10n = AppLocalizationState.shared
    
    public let dirURL: URL
    public let allowsCreation: Bool
    public let onTriggerNewFolder: (URL) -> Void
    public let onTriggerNewFile: (URL) -> Void
    
    @State private var isHoveringFolderButton: Bool = false
    @State private var isHoveringFileButton: Bool = false
    @State private var isAppeared: Bool = false
    
    public init(
        dirURL: URL,
        allowsCreation: Bool = true,
        onTriggerNewFolder: @escaping (URL) -> Void,
        onTriggerNewFile: @escaping (URL) -> Void
    ) {
        self.dirURL = dirURL
        self.allowsCreation = allowsCreation
        self.onTriggerNewFolder = onTriggerNewFolder
        self.onTriggerNewFile = onTriggerNewFile
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            
            VStack(spacing: 14) {
                // Subtle Watermark Icon
                ZStack {
                    Circle()
                        .fill(TTZipTheme.kintsugiGold.opacity(0.06))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: "folder")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.55))
                }
                
                // Typography Section
                VStack(spacing: 4) {
                    Text(l10n.t(L10n.Explorer.emptyDirectory))
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .lineLimit(1)
                    
                    if allowsCreation {
                        Text(String(localized: "Drop files here or create new items"))
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 16)
                    }
                }
                
                if allowsCreation {
                    // Quick Action Ghost Buttons
                    HStack(spacing: 8) {
                        Button(action: { onTriggerNewFolder(dirURL) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 10, weight: .medium))
                                Text(l10n.t(L10n.Explorer.newFolder))
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(isHoveringFolderButton ? TTZipTheme.bambooGreen : Color.primary.opacity(0.7))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isHoveringFolderButton ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.035))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isHoveringFolderButton ? TTZipTheme.bambooGreen.opacity(0.3) : TTZipTheme.hairlineBorder, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringFolderButton = $0 }
                        .help("Create a new subfolder here")
                    
                        Button(action: { onTriggerNewFile(dirURL) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 10, weight: .medium))
                                Text(l10n.t(L10n.Explorer.newFile))
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(isHoveringFileButton ? TTZipTheme.bambooGreen : Color.primary.opacity(0.7))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isHoveringFileButton ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.035))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isHoveringFileButton ? TTZipTheme.bambooGreen.opacity(0.3) : TTZipTheme.hairlineBorder, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringFileButton = $0 }
                        .help("Create a new empty file here")
                    }
                    .padding(.top, 4)
                }
            }
            .opacity(isAppeared ? 1.0 : 0.0)
            .scaleEffect(isAppeared ? 1.0 : 0.96)
            .onAppear {
                withAnimation(.easeOut(duration: 0.22)) {
                    isAppeared = true
                }
            }
            
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }
}

/// Dedicated placeholder rendered when a non-empty search query yields zero matches.
/// Explicitly distinguishes search zero-match from an empty folder (`allowsCreation == false`,
/// never displays "Empty Folder" or "New Folder / New File" actions).
public struct SearchNoMatchesPlaceholderView: View {
    private var l10n = AppLocalizationState.shared

    public let query: String
    public let scopeDisplayPath: String
    public let isTruncatedScope: Bool
    public let visitedEntryCount: Int
    public let onClearQuery: (() -> Void)?

    public var allowsCreation: Bool { false }

    public init(
        query: String,
        scopeDisplayPath: String = "",
        isTruncatedScope: Bool = false,
        visitedEntryCount: Int = 0,
        onClearQuery: (() -> Void)? = nil
    ) {
        self.query = query
        self.scopeDisplayPath = scopeDisplayPath
        self.isTruncatedScope = isTruncatedScope
        self.visitedEntryCount = visitedEntryCount
        self.onClearQuery = onClearQuery
    }

    public var titleText: String {
        if isTruncatedScope {
            return l10n.uiString(
                zh: "已扫描部分范围未找到匹配",
                en: "No matches in partially scanned scope"
            )
        }
        return l10n.uiString(zh: "未找到匹配", en: "No matches found")
    }

    public var subtitleText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTruncatedScope {
            return l10n.uiString(
                zh: "当前仅搜索部分范围（已检查 \(visitedEntryCount) 项，达到扫描预算或深度上限），更深或后续目录可能仍有匹配",
                en: "Only a partial scope was searched (\(visitedEntryCount) entries checked before budget/depth limit); deeper items may still match"
            )
        }
        if scopeDisplayPath.isEmpty {
            return l10n.uiString(
                zh: "没有与“\(trimmed)”匹配的项目",
                en: "No items matched \"\(trimmed)\""
            )
        }
        return l10n.uiString(
            zh: "在 \(scopeDisplayPath) 中未找到与“\(trimmed)”匹配的项目",
            en: "No items matched \"\(trimmed)\" in \(scopeDisplayPath)"
        )
    }

    public var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 20)

            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 48, height: 48)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.secondary.opacity(0.75))
            }

            VStack(spacing: 4) {
                Text(titleText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
            }

            if let onClearQuery {
                Button(action: onClearQuery) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 10.5, weight: .medium))
                        Text(l10n.uiString(zh: "清空搜索", en: "Clear Search"))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SearchNoMatchesClearButton")
            }

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SearchNoMatchesPlaceholderView")
    }
}
