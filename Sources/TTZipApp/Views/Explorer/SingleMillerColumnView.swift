// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Miller column component displaying directory items with native LazyVStack rendering.
public struct SingleMillerColumnView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var l10n = AppLocalizationState.shared
    public let index: Int
    public let dirURL: URL
    public let selectedPath: String?
    public let currentSort: DiskSortOption
    public let items: [DiskItemInfo]?
    public let currentWidth: CGFloat
    public let canGoParent: Bool
    public let isColumnActive: Bool
    public let multiSelectedPaths: Set<String>
    public let showTrailingDivider: Bool
    public let activeSearchQuery: String
    public let onClearSearchQuery: (() -> Void)?
    
    @State private var isDividerHovered: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragStartWidth: CGFloat = 0
    
    public let onPrependParent: () -> Void
    public let onChangeSort: (DiskSortOption) -> Void
    public let onSelectArchive: (String) -> Void
    public let onCompressPath: (String) -> Void
    public let onSelectItem: (DiskItemInfo, Int, Bool, Bool, URL?) -> Void
    public let onActivateItem: ((DiskItemInfo, Int, URL?) -> Void)?
    public let onTriggerNewFolder: (URL) -> Void
    public let onTriggerNewFile: (URL) -> Void
    public let onRefresh: () -> Void
    public let onSelectAll: () -> Void
    public let onWidthChanged: (CGFloat) -> Void
    
    public static let defaultWidth: CGFloat = 260
    public static let minComfortableWidth: CGFloat = 200
    public static let rowPitch: CGFloat = 28.0
    public static let topPadding: CGFloat = 6.0

    public init(
        index: Int,
        dirURL: URL,
        selectedPath: String?,
        currentSort: DiskSortOption,
        items: [DiskItemInfo]?,
        currentWidth: CGFloat = SingleMillerColumnView.defaultWidth,
        showTrailingDivider: Bool = true,
        canGoParent: Bool,
        isColumnActive: Bool = true,
        multiSelectedPaths: Set<String>,
        activeSearchQuery: String = "",
        onClearSearchQuery: (() -> Void)? = nil,
        onPrependParent: @escaping () -> Void,
        onChangeSort: @escaping (DiskSortOption) -> Void,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onSelectItem: @escaping (DiskItemInfo, Int, Bool, Bool, URL?) -> Void,
        onActivateItem: ((DiskItemInfo, Int, URL?) -> Void)? = nil,
        onTriggerNewFolder: @escaping (URL) -> Void,
        onTriggerNewFile: @escaping (URL) -> Void,
        onRefresh: @escaping () -> Void,
        onSelectAll: @escaping () -> Void,
        onWidthChanged: @escaping (CGFloat) -> Void
    ) {
        self.index = index
        self.dirURL = dirURL
        self.selectedPath = selectedPath
        self.currentSort = currentSort
        self.items = items
        self.currentWidth = currentWidth
        self.canGoParent = canGoParent
        self.isColumnActive = isColumnActive
        self.multiSelectedPaths = multiSelectedPaths
        self.showTrailingDivider = showTrailingDivider
        self.activeSearchQuery = activeSearchQuery
        self.onClearSearchQuery = onClearSearchQuery
        self.onPrependParent = onPrependParent
        self.onChangeSort = onChangeSort
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onSelectItem = onSelectItem
        self.onActivateItem = onActivateItem
        self.onTriggerNewFolder = onTriggerNewFolder
        self.onTriggerNewFile = onTriggerNewFile
        self.onRefresh = onRefresh
        self.onSelectAll = onSelectAll
        self.onWidthChanged = onWidthChanged
    }
    
    private var isArchiveColumn: Bool {
        URLComponents(url: dirURL, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "subpath" }) == true
    }

    public var isShowingSearchNoMatchesState: Bool {
        !activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (items?.isEmpty == true)
    }

    public var isShowingEmptyDirectoryPlaceholder: Bool {
        activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (items?.isEmpty == true)
    }

    public var body: some View {
        contentContainer
            .frame(width: max(currentWidth, Self.minComfortableWidth))
            .overlay(alignment: .trailing) {
                if showTrailingDivider {
                    columnResizeHandle
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Sort Action

    private var sortMenu: some View {
        Menu {
            ForEach(DiskSortOption.allCases) { opt in
                Button(action: { onChangeSort(opt) }) {
                    if currentSort == opt {
                        Label(opt.localizedTitle, systemImage: "checkmark")
                    } else {
                        Text(opt.localizedTitle)
                    }
                }
            }
        } label: {
            Label(AppLocalizationState.shared.uiString(zh: "排序方式", en: "Sort By", zhHant: "排序方式", ja: "並び替え", ko: "정렬 기준", de: "Sortieren nach", fr: "Trier par", es: "Ordenar por"), systemImage: "arrow.up.arrow.down")
        }
    }

    // MARK: - Content Container

    @ViewBuilder
    private var contentContainer: some View {
        Group {
            if let items = items {
                if items.count == 1 && items.first?.isEncryptedLockItem == true && items.first?.kindText == "Access Authorization" {
                    FolderAccessRequiredView(
                        dirURL: dirURL,
                        onAuthorize: {
                            RootFolderAccessManager.shared.requestRootAccess(for: dirURL) { granted in
                                if granted {
                                    onRefresh()
                                }
                            }
                        }
                    )
                } else if items.isEmpty {
                    let trimmedQuery = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedQuery.isEmpty {
                        SearchNoMatchesPlaceholderView(
                            query: trimmedQuery,
                            scopeDisplayPath: dirURL.lastPathComponent.isEmpty ? dirURL.path : dirURL.lastPathComponent,
                            onClearQuery: onClearSearchQuery
                        )
                    } else {
                        EmptyFolderPlaceholderView(
                            dirURL: dirURL,
                            allowsCreation: !isArchiveColumn,
                            onTriggerNewFolder: onTriggerNewFolder,
                            onTriggerNewFile: onTriggerNewFile
                        )
                        .contextMenu {
                            contextMenuItems
                        }
                    }
                } else {
                    nativeLazyScrollView(items: items)
                }
            } else {
                loadingIndicatorView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Native Lazy Scroll View

    private func nativeLazyScrollView(items: [DiskItemInfo]) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        MillerColumnItemRowView(
                            item: item,
                            columnIndex: index,
                            isSelected: selectedPath == item.path,
                            isColumnParentSelected: false,
                            isColumnActive: isColumnActive,
                            showsSizeMetadata: currentWidth >= 240,
                            dirURL: dirURL,
                            multiSelectedPaths: multiSelectedPaths,
                            onSelectArchive: onSelectArchive,
                            onCompressPath: onCompressPath,
                            onSelectItem: onSelectItem,
                            onActivateItem: onActivateItem,
                            onTriggerNewFolder: onTriggerNewFolder,
                            onTriggerNewFile: onTriggerNewFile
                        )
                        .id(item.path)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, Self.topPadding)
                .padding(.bottom, 12)

                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentShape(Rectangle())
                    .contextMenu {
                        contextMenuItems
                    }
            }
            .scrollContentBackground(.hidden)
            .background(ConfigureNSScrollView())
            .contextMenu {
                contextMenuItems
            }
            .onChange(of: selectedPath) { _, newPath in
                if let p = newPath {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        scrollProxy.scrollTo(p, anchor: nil)
                    }
                }
            }
            .onChange(of: isColumnActive) { _, active in
                if active, let p = selectedPath {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        scrollProxy.scrollTo(p, anchor: nil)
                    }
                }
            }
        }
    }

    // MARK: - Subviews & Helpers

    private var loadingIndicatorView: some View {
        VStack(spacing: 8) {
            Spacer()
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(l10n.t(L10n.Common.loading))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var columnResizeHandle: some View {
        Rectangle()
            .fill(isDividerHovered || isDragging ? TTZipTheme.kintsugiGold.opacity(0.55) : TTZipTheme.hairlineBorder)
            .frame(width: isDividerHovered || isDragging ? 1.0 : 0.5)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isDividerHovered = hovering
                        if hovering { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    onWidthChanged(Self.defaultWidth)
                                }
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            }
                    )
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { gesture in
                                if !isDragging {
                                    isDragging = true
                                    dragStartWidth = currentWidth
                                }
                                let updated = min(max(dragStartWidth + gesture.translation.width, Self.minComfortableWidth), 800)
                                onWidthChanged(updated)
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.85), value: isDividerHovered || isDragging)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        sortMenu
        
        Divider()
        
        if !isArchiveColumn {
            Button {
                onTriggerNewFolder(dirURL)
            } label: {
                Label(l10n.t(L10n.Explorer.newFolder), systemImage: "folder.badge.plus")
            }
        
            Button {
                onTriggerNewFile(dirURL)
            } label: {
                Label(l10n.t(L10n.Explorer.newFile), systemImage: "doc.badge.plus")
            }
        
            Divider()
        
            Button {
                FileClipboardStore.shared.paste(to: dirURL)
            } label: {
                Label(l10n.t(L10n.Common.paste), systemImage: "doc.on.clipboard")
            }
            .disabled(!FileClipboardStore.shared.canPaste)
        
            Divider()
        
        }

        Button {
            onRefresh()
        } label: {
            Label(AppLocalizationState.shared.uiString(zh: "刷新", en: "Refresh", zhHant: "重新整理", ja: "更新", ko: "새로고침", de: "Aktualisieren", fr: "Actualiser", es: "Actualizar"), systemImage: "arrow.clockwise")
        }
        
        Button {
            NSWorkspace.shared.selectFile(dirURL.path, inFileViewerRootedAtPath: "")
        } label: {
            Label(l10n.t(L10n.Common.revealInFinder), systemImage: "folder")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                guard let srcURL = url as? URL,
                      MillerColumnItemRowView.isPhysicalDropSource(srcURL) else { return }
                Task { @MainActor in
                    if isArchiveColumn {
                        let (archivePath, subpath) = MillerColumnItemRowView.parseVirtualURL(dirURL.absoluteString)
                        let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                        try? await InPlaceMutationCoordinator.shared.appendFiles(
                            archivePath: archivePath,
                            sourceFilePaths: [srcURL.path],
                            destinationVirtualFolder: subpath.isEmpty ? nil : subpath,
                            password: pwd
                        )
                    } else {
                        _ = try? await FileDragDropHelper.performMove(sources: [srcURL], to: dirURL)
                    }
                }
            }
        }
        return true
    }
}
