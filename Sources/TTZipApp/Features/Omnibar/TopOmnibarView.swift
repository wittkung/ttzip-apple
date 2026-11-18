// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipUI

/// Top Navigation Bar facade aligning strictly with Windows File Explorer ergonomics.
///
/// Integrates:
/// 1. Navigation control group (Back ←, Forward →, Up ↑);
/// 2. Dual-mode address bar (Breadcrumb chips traversal + Click-to-edit absolute POSIX path + Integrated Refresh 🔄);
/// 3. Directory-scoped search capsule (🔍 Search current directory).
public struct TopOmnibarView: View {
    public var viewModel: AppViewState
    @Binding public var searchQuery: String
    public var isCompact: Bool
    public var isSearchIconOnly: Bool
    
    public init(
        viewModel: AppViewState,
        searchQuery: Binding<String>,
        isCompact: Bool = false,
        isSearchIconOnly: Bool = true
    ) {
        self.viewModel = viewModel
        self._searchQuery = searchQuery
        self.isCompact = isCompact
        self.isSearchIconOnly = isSearchIconOnly
    }
    
    public var body: some View {
        HStack(spacing: isCompact ? 5 : 6) {
            // Group 1: Navigation Control Group (←, →, ↑)
            NavigationControlGroupView(viewModel: viewModel)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(5.0)
            
            // Group 2: Dual-Mode Address Bar (Breadcrumb Chips + Select-All POSIX Text + Refresh 🔄)
            DualModeAddressBarView(viewModel: viewModel)
                .layoutPriority(2.0)
            
            // Group 3: Directory-Scoped Search Box (🔍) — higher priority than address bar expansion so search never collapses
            ExplorerSearchCapsuleView(
                viewModel: viewModel,
                searchQuery: $searchQuery,
                isCompact: isCompact,
                isSearchIconOnly: isSearchIconOnly
            )
            .layoutPriority(3.0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
