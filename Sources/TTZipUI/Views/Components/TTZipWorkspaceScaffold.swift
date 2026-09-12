// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// Default title view for `TTZipWorkspaceScaffold` displaying a serif bold header.
public struct TTZipWorkspaceDefaultTitleView: View {
    public let title: String
    
    public init(_ title: String) {
        self.title = title
    }
    
    public var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold, design: .serif))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Unified workspace scaffold enforcing 52pt header, Y=90pt Kintsugi Gold Line, and macOS safe area isolation.
public struct TTZipWorkspaceScaffold<HeaderLeading: View, HeaderTrailing: View, Content: View>: View {
    public let headerLeading: HeaderLeading
    public let headerTrailing: HeaderTrailing
    public let content: Content
    public let isCardEnclosed: Bool
    public let isEdgeToEdge: Bool
    public let contentPadding: EdgeInsets
    
    public init(
        isCardEnclosed: Bool = true,
        isEdgeToEdge: Bool = false,
        contentPadding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        @ViewBuilder headerLeading: () -> HeaderLeading,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.headerLeading = headerLeading()
        self.headerTrailing = headerTrailing()
        self.content = content()
        self.isCardEnclosed = isCardEnclosed
        self.isEdgeToEdge = isEdgeToEdge
        self.contentPadding = contentPadding
    }
    
    public init(
        isCardEnclosed: Bool = true,
        isEdgeToEdge: Bool = false,
        contentPadding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        @ViewBuilder headerLeading: () -> HeaderLeading,
        @ViewBuilder content: () -> Content
    ) where HeaderTrailing == EmptyView {
        self.init(
            isCardEnclosed: isCardEnclosed,
            isEdgeToEdge: isEdgeToEdge,
            contentPadding: contentPadding,
            headerLeading: headerLeading,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. 52pt Header Bar (Top=38pt + Height=52pt -> Golden line strictly at Y = 90.0pt)
            HStack(alignment: .center, spacing: 12) {
                headerLeading
                
                Spacer()
                
                headerTrailing
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 20)
            .frame(height: TTZipTheme.Layout.headerBarHeight)
            
            // 2. 1.5pt Kintsugi Gold Line
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: TTZipTheme.Layout.kintsugiGoldLineHeight)
            
            // 3. Workspace Content Slot
            content
                .padding(contentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .modifyIf(isCardEnclosed && !isEdgeToEdge) { view in
            view
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
        }
        .padding(.top, TTZipTheme.Layout.topBarOffset)
        .padding(.horizontal, isEdgeToEdge ? 0 : TTZipTheme.Spacing.md)
        .padding(.bottom, isEdgeToEdge ? 0 : TTZipTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Backward-Compatible Initializers

extension TTZipWorkspaceScaffold where HeaderLeading == TTZipWorkspaceDefaultTitleView {
    public var title: String {
        headerLeading.title
    }
    
    public init(
        title: String,
        isCardEnclosed: Bool = true,
        isEdgeToEdge: Bool = false,
        contentPadding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            isCardEnclosed: isCardEnclosed,
            isEdgeToEdge: isEdgeToEdge,
            contentPadding: contentPadding,
            headerLeading: { TTZipWorkspaceDefaultTitleView(title) },
            headerTrailing: headerTrailing,
            content: content
        )
    }
    
    public init(
        title: String,
        isCardEnclosed: Bool = true,
        isEdgeToEdge: Bool = false,
        contentPadding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        @ViewBuilder content: () -> Content
    ) where HeaderTrailing == EmptyView {
        self.init(
            title: title,
            isCardEnclosed: isCardEnclosed,
            isEdgeToEdge: isEdgeToEdge,
            contentPadding: contentPadding,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
}

private extension View {
    @ViewBuilder
    func modifyIf<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
