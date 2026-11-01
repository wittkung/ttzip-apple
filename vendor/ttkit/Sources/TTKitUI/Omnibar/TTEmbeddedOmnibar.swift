// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitCore
import TTKitDesign

/// Embedded header Omnibar component conforming to TTKit Architecture Spec §4.
/// Enforces elastic space budgeting: pinned trailing actions, flexible center, and responsive search collapse.
public struct TTEmbeddedOmnibar<Leading: View, Center: View, Trailing: View>: View {
    public let leading: Leading
    public let center: Center
    public let trailing: Trailing
    
    public init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }
    
    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 1. Leading navigation cluster (priority 5.0)
            leading
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(5.0)
            
            // 2. Elastic center omnibar zone (priority 1.0)
            center
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1.0)
            
            // 3. Pinned trailing action cluster (priority 10.0)
            trailing
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(10.0)
        }
        .frame(height: UniversalTokens.Layout.headerBarHeight)
    }
}

/// Responsive search capsule supporting full input and compact 28x28 icon mode.
public struct TTSearchCapsuleView: View {
    @Binding public var searchText: String
    public var placeholder: String
    public var isCompactIcon: Bool
    public var onCommit: (() -> Void)?
    
    @FocusState private var isFieldFocused: Bool
    @State private var isExpandedInCompact = false
    
    public init(
        searchText: Binding<String>,
        placeholder: String = "Search...",
        isCompactIcon: Bool = false,
        onCommit: (() -> Void)? = nil
    ) {
        self._searchText = searchText
        self.placeholder = placeholder
        self.isCompactIcon = isCompactIcon
        self.onCommit = onCommit
    }
    
    public var body: some View {
        if isCompactIcon && !isExpandedInCompact && searchText.isEmpty {
            // Compact 28x28 icon button
            Button {
                withAnimation(.ttMicro) {
                    isExpandedInCompact = true
                    isFieldFocused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(placeholder)
        } else {
            // Expanded capsule field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                
                TextField(placeholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFieldFocused)
                    .onSubmit {
                        onCommit?()
                    }
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        if isCompactIcon {
                            withAnimation(.ttMicro) {
                                isExpandedInCompact = false
                            }
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 100, idealWidth: 140, maxWidth: 200)
            .frame(height: 28)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isFieldFocused ? TTKitTheme.kintsugiGold.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}
