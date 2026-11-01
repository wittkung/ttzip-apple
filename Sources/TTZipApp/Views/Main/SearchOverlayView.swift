// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import AppKit
import TTKitDesign
import TTZipUI

/// Liquid-glass search and command palette overlay for Omnibar and Spotlight results.
public struct SearchOverlayView: View {
    @Environment(AppViewState.self) private var viewModel
    private var l10n = AppLocalizationState.shared
    
    @Binding public var searchQuery: String
    public let searchService: SpotlightSearchService
    public let maxWidth: CGFloat
    
    public init(
        searchQuery: Binding<String>,
        searchService: SpotlightSearchService,
        maxWidth: CGFloat
    ) {
        self._searchQuery = searchQuery
        self.searchService = searchService
        self.maxWidth = maxWidth
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if searchService.isSearching {
                loadingIndicator
            } else if searchService.searchResults.isEmpty {
                emptyResultsView
            } else {
                resultsList
            }
        }
        .frame(width: maxWidth)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5))
        .padding(.top, 42)
    }
    
    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text(l10n.t(L10n.Common.processing))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }
    
    private var emptyResultsView: some View {
        Text(l10n.t(L10n.Explorer.emptyDirectory))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
    }
    
    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(searchService.searchResults, id: \.path) { item in
                    resultRow(for: item)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 280)
    }
    
    private func resultRow(for item: DiskItemInfo) -> some View {
        Button {
            searchQuery = ""
            if item.isDirectory {
                viewModel.navigationState.currentDirectory = URL(fileURLWithPath: item.path)
            } else {
                viewModel.selectedDiskItem = item
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(item.isDirectory ? TTZipTheme.bambooGreen : .secondary)
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(item.kindText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
