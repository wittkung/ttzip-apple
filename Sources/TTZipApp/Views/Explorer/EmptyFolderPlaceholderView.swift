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

/// An elegant Zen minimalist placeholder view for empty directories in Miller Columns.
/// Features WSJ subtle typography, soft gold/bamboo accents, quick actions, and smooth fade-in.
public struct EmptyFolderPlaceholderView: View {
    private var l10n = AppLocalizationState.shared
    
    public let dirURL: URL
    public let onTriggerNewFolder: (URL) -> Void
    public let onTriggerNewFile: (URL) -> Void
    
    @State private var isHoveringFolderButton: Bool = false
    @State private var isHoveringFileButton: Bool = false
    @State private var isAppeared: Bool = false
    
    public init(
        dirURL: URL,
        onTriggerNewFolder: @escaping (URL) -> Void,
        onTriggerNewFile: @escaping (URL) -> Void
    ) {
        self.dirURL = dirURL
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
                    
                    Text("Drop files here or create new items")
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                }
                
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
                                .strokeBorder(isHoveringFolderButton ? TTZipTheme.bambooGreen.opacity(0.3) : TTZipTheme.hairlineBorder, lineWidth: 0.8)
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
                                .strokeBorder(isHoveringFileButton ? TTZipTheme.bambooGreen.opacity(0.3) : TTZipTheme.hairlineBorder, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringFileButton = $0 }
                    .help("Create a new empty file here")
                }
                .padding(.top, 4)
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
