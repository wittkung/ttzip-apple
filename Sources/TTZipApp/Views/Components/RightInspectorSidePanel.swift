// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Right contextual Inspector side panel supporting Home and Compress modes.
public struct RightInspectorSidePanel: View {
    public var viewModel: AppViewState
    @Binding public var rightVerticalTopHeight: CGFloat
    
    public init(viewModel: AppViewState, rightVerticalTopHeight: Binding<CGFloat> = .constant(300)) {
        self.viewModel = viewModel
        self._rightVerticalTopHeight = rightVerticalTopHeight
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Subordinate 44pt Inspector Header (Distinct from 52pt Primary Workspace)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.selectedDiskItem?.isDirectory == true ? "DIRECTORY CANVAS" : "INSPECTOR")
                        .font(.system(size: 8.5, weight: .bold, design: .serif))
                        .tracking(1.8)
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                    
                    Text(viewModel.selectedDiskItem?.name ?? (viewModel.selectedDiskItem?.isDirectory == true ? "Folder Properties" : "File Properties"))
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if let item = viewModel.selectedDiskItem, item.isArchive {
                    Button(action: {
                        viewModel.overlayState.inspectingArchivePath = item.path
                        viewModel.overlayState.showArchiveInspectorModal = true
                    }) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(TTZipTheme.archiveAmber)
                    }
                    .buttonStyle(.plain)
                    .help("View archive standards and compliance diagnostics...")
                }
                
                if viewModel.selectedDiskItem != nil {
                    Button(action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.selectedDiskItem = nil
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            
            // Subtle Hairline Divider (Replaces full-bleed 1.5pt gold line to avoid Y=90pt visual merge)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.8)
            
            VStack(alignment: .leading, spacing: 0) {
                if let item = viewModel.selectedDiskItem {
                    InspectorColumnView(
                        item: item,
                        onSelectArchive: { archivePath in
                            Task { await viewModel.loadArchive(path: archivePath) }
                        },
                        onCompressPath: { folderPath in
                            viewModel.openCompressWorkspace(paths: [folderPath])
                        },
                        onPreviewFile: { _ in }
                    )
                    .id(item.path)
                    .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("Select a file or folder in the explorer")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Selected items can be previewed directly")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.primary.opacity(0.018))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8)
        )
    }
}
