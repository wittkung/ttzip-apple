// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// Unified workspace scaffold enforcing 52pt header, Y=90pt Kintsugi Gold Line, and macOS safe area isolation.
public struct TTZipWorkspaceScaffold<HeaderTrailing: View, Content: View>: View {
    public let title: String
    public let headerTrailing: HeaderTrailing
    public let content: Content
    public let isCardEnclosed: Bool
    public let contentPadding: EdgeInsets
    
    public init(
        title: String,
        isCardEnclosed: Bool = true,
        contentPadding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isCardEnclosed = isCardEnclosed
        self.contentPadding = contentPadding
        self.headerTrailing = headerTrailing()
        self.content = content()
    }
    
    public init(
        title: String,
        isCardEnclosed: Bool = true,
        contentPadding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        @ViewBuilder content: () -> Content
    ) where HeaderTrailing == EmptyView {
        self.init(
            title: title,
            isCardEnclosed: isCardEnclosed,
            contentPadding: contentPadding,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. 52pt Header Bar (Top=38pt + Height=52pt -> Golden line strictly at Y = 90.0pt)
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
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
        .modifyIf(isCardEnclosed) { view in
            view
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
        }
        .padding(.top, TTZipTheme.Layout.topBarOffset)
        .padding(.horizontal, TTZipTheme.Spacing.md)
        .padding(.bottom, TTZipTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
