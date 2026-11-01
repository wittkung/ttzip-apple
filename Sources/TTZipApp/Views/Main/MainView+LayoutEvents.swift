// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTKitDesign
import TTZipUI

package extension View {
    @ViewBuilder
    func mainViewLayoutEvents(
        viewModel: AppViewState,
        leftWidth: Binding<CGFloat>,
        userLeft: Double,
        metrics: MainLayoutMetrics,
        isRightVisible: Binding<Bool>,
        presentedTool: Binding<WorkspaceTab?>
    ) -> some View {
        self
            .onAppear {
                leftWidth.wrappedValue = max(MainLayoutMetrics.minLeftSidebarWidth, CGFloat(userLeft))
                if viewModel.navigationState.isCompressWorkspaceActive && !isRightVisible.wrappedValue {
                    isRightVisible.wrappedValue = true
                }
            }
            .onChange(of: viewModel.navigationState.isCompressWorkspaceActive) { _, isCompressActive in
                if isCompressActive && !isRightVisible.wrappedValue {
                    withAnimation(.ttLayout) {
                        isRightVisible.wrappedValue = true
                    }
                }
            }
            .onChange(of: viewModel.selectedDiskItem) { _, _ in
                if !viewModel.navigationState.isCompressWorkspaceActive {
                    BrowserWindowRegistry.shared.nsWindow(for: viewModel.windowID)?.makeFirstResponder(nil)
                }
            }
            .onChange(of: viewModel.navigationState.activeTab) { _, newTab in
                BrowserWindowRegistry.shared.nsWindow(for: viewModel.windowID)?.makeFirstResponder(nil)
                if newTab == .compressWorkspace {
                    viewModel.openCompressWorkspace()
                    viewModel.navigationState.activeTab = .home
                    withAnimation(.ttLayout) {
                        isRightVisible.wrappedValue = true
                    }
                } else if newTab != .home {
                    presentedTool.wrappedValue = newTab
                    viewModel.navigationState.activeTab = .home
                }
            }
            .onChange(of: viewModel.navigationState.currentDirectory) { _, _ in
                BrowserWindowRegistry.shared.nsWindow(for: viewModel.windowID)?.makeFirstResponder(nil)
            }
            .inspectorWindowGeometryEvents(viewModel: viewModel)
    }

    @ViewBuilder
    private func inspectorWindowGeometryEvents(viewModel: AppViewState) -> some View {
        self
            .onChange(of: viewModel.navigationState.isInspectorVisible) { _, _ in
                InspectorWindowGeometryCoordinator.coordinator(
                    for: viewModel.windowID,
                    initialVisibility: viewModel.navigationState.isInspectorVisible
                ).synchronizeGeometryForCurrentVisibility(of: viewModel)
            }
            .onChange(of: viewModel.navigationState.isLeftSidebarVisible) { _, _ in
                if let window = BrowserWindowRegistry.shared.nsWindow(for: viewModel.windowID) {
                    InspectorWindowGeometryCoordinator.coordinator(
                        for: viewModel.windowID,
                        initialVisibility: viewModel.navigationState.isInspectorVisible
                    ).updateWindowMinimumSize(
                        window: window,
                        viewModel: viewModel,
                        isRightVisible: viewModel.navigationState.isInspectorVisible
                    )
                }
            }
    }
}
