// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import AppKit
import TTKitDesign
import TTZipUI

/// Structural column displaying the center multi-mode file explorer container.
public struct ContentColumnView: View {
    @Environment(AppViewState.self) private var viewModel
    
    @Binding public var isLeftSidebarVisible: Bool
    @Binding public var isRightSidebarVisible: Bool
    public let width: CGFloat
    public let height: CGFloat
    public let dynamicTrafficLightMargin: CGFloat
    public let onOpenArchive: () -> Void
    
    public init(
        isLeftSidebarVisible: Binding<Bool>,
        isRightSidebarVisible: Binding<Bool>,
        width: CGFloat,
        height: CGFloat,
        dynamicTrafficLightMargin: CGFloat,
        onOpenArchive: @escaping () -> Void
    ) {
        self._isLeftSidebarVisible = isLeftSidebarVisible
        self._isRightSidebarVisible = isRightSidebarVisible
        self.width = width
        self.height = height
        self.dynamicTrafficLightMargin = dynamicTrafficLightMargin
        self.onOpenArchive = onOpenArchive
    }
    
    public var body: some View {
        HomeExplorerContainerView(
            viewModel: viewModel,
            isRightSidebarVisible: isRightSidebarVisible,
            isLeftSidebarVisible: isLeftSidebarVisible,
            onToggleLeftSidebar: {
                withAnimation(.ttLayout) {
                    isLeftSidebarVisible.toggle()
                }
            },
            onToggleRightSidebar: {
                withAnimation(.ttLayout) {
                    isRightSidebarVisible.toggle()
                }
            },
            onOpenArchive: onOpenArchive,
            onNewArchive: {
                withAnimation(.ttLayout) {
                    viewModel.openCompressWorkspace()
                    isRightSidebarVisible = true
                }
            },
            isActive: true
        )
        .padding(.leading, isLeftSidebarVisible ? 0 : dynamicTrafficLightMargin)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color.clear)
        .clipped()
    }
}
