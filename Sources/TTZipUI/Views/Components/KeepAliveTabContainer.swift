// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// Lazy-loaded and keep-alive persistent tab container with lifecycle propagation.
///
/// Prevents redundant destruction and recreation of view hierarchy and ViewModels during tab switching
/// while delivering active/inactive lifecycle states to child tabs.
public struct KeepAliveTabContainer<Content: View>: View {
    public let activeTab: WorkspaceTab
    public let content: (WorkspaceTab, Bool) -> Content
    
    @State private var visitedTabs: Set<WorkspaceTab> = []
    
    public init(
        activeTab: WorkspaceTab,
        @ViewBuilder content: @escaping (WorkspaceTab, Bool) -> Content
    ) {
        self.activeTab = activeTab
        self.content = content
    }
    
    public init(
        activeTab: WorkspaceTab,
        @ViewBuilder content: @escaping (WorkspaceTab) -> Content
    ) {
        self.activeTab = activeTab
        self.content = { tab, _ in content(tab) }
    }
    
    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(visitedTabs).sorted(by: { $0.id < $1.id })) { tab in
                let isActive = (activeTab == tab)
                content(tab, isActive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(isActive ? 1.0 : 0.0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            visitedTabs.insert(activeTab)
        }
        .onChange(of: activeTab) { _, newTab in
            if !visitedTabs.contains(newTab) {
                visitedTabs.insert(newTab)
            }
        }
    }
}
