// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitCore
import TTKitDesign

/// Production three-column desktop workspace container conforming to TTKit Architecture Spec §2.
/// Integrates responsive thresholding, ResizableDividerHandle splitters, and spring layout transitions.
public struct TTThreeColumnWorkspace<Sidebar: View, Content: View, Inspector: View>: View {
    @Binding public var isSidebarVisible: Bool
    @Binding public var isIconRail: Bool
    @Binding public var isInspectorVisible: Bool
    
    @State private var sidebarWidth: CGFloat = 220
    @State private var inspectorWidth: CGFloat = 320
    
    public let sidebar: Sidebar
    public let content: Content
    public let inspector: Inspector
    
    public init(
        isSidebarVisible: Binding<Bool>,
        isIconRail: Binding<Bool>,
        isInspectorVisible: Binding<Bool>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder inspector: () -> Inspector
    ) {
        self._isSidebarVisible = isSidebarVisible
        self._isIconRail = isIconRail
        self._isInspectorVisible = isInspectorVisible
        self.sidebar = sidebar()
        self.content = content()
        self.inspector = inspector()
    }
    
    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Column 1: Left Navigation Sidebar
                if isSidebarVisible {
                    sidebar
                        .frame(width: isIconRail ? 64 : sidebarWidth)
                        .clipped()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    
                    if !isIconRail {
                        ResizableDividerHandle(
                            onDragChanged: { delta in
                                let newWidth = sidebarWidth + delta
                                sidebarWidth = min(max(newWidth, 180), 280)
                            },
                            onDoubleClick: {
                                withAnimation(.ttLayout) {
                                    sidebarWidth = 220
                                }
                            }
                        )
                    }
                }
                
                // Column 2: Center Content Workspace
                content
                    .frame(minWidth: 360, maxWidth: .infinity)
                
                // Column 3: Right Contextual Inspector
                if isInspectorVisible {
                    ResizableDividerHandle(
                        onDragChanged: { delta in
                            let newWidth = inspectorWidth - delta
                            inspectorWidth = min(max(newWidth, 280), 420)
                        },
                        onDoubleClick: {
                            withAnimation(.ttLayout) {
                                inspectorWidth = 320
                            }
                        }
                    )
                    
                    inspector
                        .frame(width: inspectorWidth)
                        .clipped()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                evaluateResponsiveThresholds(totalWidth: newWidth)
            }
            .onAppear {
                evaluateResponsiveThresholds(totalWidth: geometry.size.width)
            }
        }
    }
    
    private func evaluateResponsiveThresholds(totalWidth: CGFloat) {
        if totalWidth < 640 {
            if !isIconRail {
                withAnimation(.ttLayout) {
                    isIconRail = true
                }
            }
        } else if totalWidth >= 640 && totalWidth < 900 {
            if isInspectorVisible {
                withAnimation(.ttLayout) {
                    isInspectorVisible = false
                }
            }
        }
    }
}
