// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

/// Masterpiece Zen glassmorphic playlist side drawer for native MPV video playback.
/// Features Kintsugi Gold active indicators, smooth scrolling, episode navigation, and file metadata metrics.
public struct MPVPlaylistDrawerView: View {
    public var playlistStore: MediaPlaylistStore
    public let onSelectItem: (MediaPlaylistItem) -> Void
    public let onClose: () -> Void
    
    @ObservedObject private var l10n = AppLocalizationState.shared
    @State private var hoveredItemId: String? = nil
    
    public init(
        playlistStore: MediaPlaylistStore = .shared,
        onSelectItem: @escaping (MediaPlaylistItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.playlistStore = playlistStore
        self.onSelectItem = onSelectItem
        self.onClose = onClose
    }
    
    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Drawer Header
            headerView
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            // MARK: - Playlist Items ScrollView
            if playlistStore.items.isEmpty {
                emptyStateView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(playlistStore.items.enumerated()), id: \.element.id) { index, item in
                                playlistRow(for: item, index: index)
                                    .id(item.id)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                    }
                    .onAppear {
                        if let currentId = playlistStore.items.first(where: { $0.url == playlistStore.currentURL })?.id {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(currentId, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            Spacer(minLength: 0)
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 16, x: -4, y: 0)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(TTZipTheme.kintsugiGold)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isChinese ? "播放列表" : "Playlist")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                
                if let currentIdx = playlistStore.currentIndex {
                    Text("\(currentIdx + 1) / \(playlistStore.items.count) \(isChinese ? "个视频" : "Videos")")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text("\(playlistStore.items.count) \(isChinese ? "个视频" : "Videos")")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            
            Spacer()
            
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(isChinese ? "关闭播放列表" : "Close Playlist")
        }
    }
    
    // MARK: - Row Item
    
    private func playlistRow(for item: MediaPlaylistItem, index: Int) -> some View {
        let isSelected = item.url == playlistStore.currentURL || item.url.path == playlistStore.currentURL?.path
        let isHovered = hoveredItemId == item.id
        
        return Button(action: { onSelectItem(item) }) {
            HStack(spacing: 10) {
                // Leading Index or Active Indicator
                ZStack {
                    if isSelected {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                    } else {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(width: 20)
                
                // Title and Metadata
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? TTZipTheme.kintsugiGold : .white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if !item.formattedSize.isEmpty {
                        Text(item.formattedSize)
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Circle()
                        .fill(TTZipTheme.kintsugiGold)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? TTZipTheme.kintsugiGold.opacity(0.18)
                            : (isHovered ? Color.white.opacity(0.08) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? TTZipTheme.kintsugiGold.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItemId = hovering ? item.id : nil
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text(isChinese ? "无播放列表项目" : "No Playlist Items")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
