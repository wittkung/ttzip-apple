// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import AppKit
import TTKitDesign
import TTKitFluid
import TTZipUI

/// Structural column displaying the left navigation sidebar and resizable divider.
public struct SidebarColumnView: View {
    @Environment(AppViewState.self) private var viewModel
    @AppStorage("TTZip_UserLeftSidebarWidth") private var userLeftSidebarWidth: Double = Double(MainLayoutMetrics.defaultLeftSidebarWidth)
    
    @Binding public var width: CGFloat
    public let totalHeight: CGFloat
    public let goldenLineBottomY: CGFloat
    
    @State private var initialDragWidth: CGFloat = MainLayoutMetrics.defaultLeftSidebarWidth
    
    public init(
        width: Binding<CGFloat>,
        totalHeight: CGFloat,
        goldenLineBottomY: CGFloat = TTZipTheme.Layout.headerBarHeight
    ) {
        self._width = width
        self.totalHeight = totalHeight
        self.goldenLineBottomY = goldenLineBottomY
    }
    
    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            FinderFavoritesSidebarView(
                currentDirectory: viewModel.navigationState.currentDirectory,
                activeAndroidDeviceID: AndroidDeviceViewModel.shared.activeDevice(forWindow: viewModel.windowID)?.deviceId,
                onSelectDirectory: { url in
                    AndroidDeviceViewModel.shared.bindWindow(viewModel.windowID, toDevice: nil)
                    let clickUptime = ProcessInfo.processInfo.systemUptime
                    let scopeID = "window_\(viewModel.windowID.uuidString)_col_0"
                    Task {
                        await DiskDirectoryScanner.shared.recordSelectionStart(forScope: scopeID, uptime: clickUptime)
                    }
                    viewModel.closeCurrentArchive()
                    if url.absoluteString == StorageInspectorView.storageInspectorURL.absoluteString {
                        viewModel.navigationState.openStorageInspectorTab()
                    } else {
                        viewModel.navigationState.showDirectory(at: url)
                    }
                    viewModel.selectedDiskItem = nil
                },
                onSelectAndroidDevice: { dev in
                    AndroidDeviceViewModel.shared.bindWindow(viewModel.windowID, toDevice: dev)
                },
                onOpenSettings: {
                    viewModel.navigationState.activeTab = .settings
                },
                onOpenInNewWindow: { url in
                    BrowserWindowRouter.shared.openInNewWindow(url: url)
                },
                onToggleSidebar: {
                    withAnimation(.ttLayout) {
                        viewModel.navigationState.isLeftSidebarVisible.toggle()
                    }
                }
            )
            .frame(width: width, height: totalHeight, alignment: .topLeading)
            .clipped()
            .transition(.move(edge: .leading).combined(with: .opacity))
            
            ResizableDividerHandle(
                topInset: goldenLineBottomY,
                onDragStart: {
                    initialDragWidth = width
                },
                onDragChanged: { translation in
                    let candidate = initialDragWidth + translation
                    width = MainLayoutMetrics.rubberBandClampLeftSidebar(offset: candidate)
                },
                onDragEnd: {
                    let clamped = min(max(width, MainLayoutMetrics.minLeftSidebarWidth), MainLayoutMetrics.maxLeftSidebarWidth)
                    if clamped != width {
                        withAnimation(.ttLayout) {
                            width = clamped
                        }
                    }
                    userLeftSidebarWidth = Double(clamped)
                },
                onDoubleClick: {
                    withAnimation(.ttLayout) {
                        width = MainLayoutMetrics.defaultLeftSidebarWidth
                        userLeftSidebarWidth = Double(MainLayoutMetrics.defaultLeftSidebarWidth)
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
            )
            .frame(height: totalHeight)
            .transition(.opacity)
        }
    }
}
