// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Right contextual file feeder column for Compress Workspace.
///
/// Directly embeds and reuses the canonical multi-column FinderMillerColumnsView,
/// providing high-concurrency directory cascade exploration, native dragging into
/// center compress targets, and one-click item delivery.
public struct RightSideCompressFilePickerView: View {
    public var viewModel: AppViewState
    public var onClose: (() -> Void)? = nil
    private var l10n = AppLocalizationState.shared
    
    @State private var rootURL: URL
    @State private var selectedItem: DiskItemInfo? = nil
    
    public init(viewModel: AppViewState, onClose: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onClose = onClose
        self._rootURL = State(initialValue: viewModel.navigationState.currentDirectory)
    }
    
    private var canNavigateUp: Bool {
        let parent = rootURL.deletingLastPathComponent()
        return parent.path != rootURL.path && FileManager.default.fileExists(atPath: parent.path)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.horizontal, 14)
                .frame(height: TTZipTheme.Layout.headerBarHeight)
            
            TTKintsugiDivider(.horizontal, falloff: false)
                .frame(height: TTZipTheme.Layout.kintsugiGoldLineHeight)
            
            // Reusing canonical production-grade FinderMillerColumnsView directly
            FinderMillerColumnsView(
                viewModel: viewModel,
                rootDirectory: rootURL,
                isActive: true,
                onNavigateUp: canNavigateUp ? { navigateUp() } : nil,
                onCompressPath: { path in
                    viewModel.compressSession.addPaths([path])
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                },
                onSelectItem: { item in
                    self.selectedItem = item
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            
            bottomStatusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            VStack(alignment: .leading, spacing: 1) {
                L10nText(L10n.Compress.sourceFeeder)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                
                Text(TTZipPathPresentationService.shared.displayName(for: rootURL, language: l10n.currentLanguage))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .ttButtonHelp(rootURL.path)
            
            Spacer(minLength: 4)
            
            // Parent directory button
            Button {
                navigateUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t(L10n.Explorer.parentDirectory))
            .disabled(!canNavigateUp)
            
            // Preset locations menu
            Menu {
                let home = URL(fileURLWithPath: NSHomeDirectory())
                let desktop = home.appendingPathComponent("Desktop")
                let downloads = home.appendingPathComponent("Downloads")
                let documents = home.appendingPathComponent("Documents")
                
                Button(l10n.t(L10n.Sidebar.home)) { rootURL = home }
                Button(l10n.t(L10n.Sidebar.desktop)) { rootURL = desktop }
                Button(l10n.t(L10n.Sidebar.downloads)) { rootURL = downloads }
                Button(l10n.t(L10n.Sidebar.documents)) { rootURL = documents }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28, height: 28)
            .help(l10n.t(L10n.Sidebar.favorites))
            
            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.t(L10n.Compress.collapseFeeder))
            }
        }
    }
    
    // MARK: - Bottom Status Bar
    
    private var bottomStatusBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            L10nText(L10n.Compress.feederDragPrompt)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            
            Spacer(minLength: 4)
            
            let activeItem = selectedItem ?? viewModel.selectedDiskItem
            if let sel = activeItem {
                Button {
                    viewModel.compressSession.addPaths([sel.path])
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 9.5))
                        L10nText(L10n.Compress.addSelected)
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(TTZipTheme.bambooGreen.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("DeliverSelectedItemButton")
                .accessibilityLabel(l10n.t(L10n.Compress.addSelected))
            }

            
            if let onClose {
                Button {
                    onClose()
                } label: {
                    L10nText(L10n.Compress.hideFeeder)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(l10n.t(L10n.Compress.hideFeederHelp))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .top) {
            Rectangle().fill(TTZipTheme.hairlineBorder).frame(height: TTZipTheme.Layout.hairlineBorderWidth)
        }
    }
    
    private func navigateUp() {
        let parent = rootURL.deletingLastPathComponent()
        if parent.path != rootURL.path && FileManager.default.fileExists(atPath: parent.path) {
            rootURL = parent
        }
    }
}
