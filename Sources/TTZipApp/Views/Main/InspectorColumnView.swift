// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import AppKit
import TTKitDesign
import TTKitFluid
import TTZipUI

/// Structural column displaying the right contextual inspector or compress file feeder.
/// Decoupled from monolithic AppViewState by binding presentation to InspectorSurfaceMode.
public struct InspectorColumnView: View {
    @Environment(AppViewState.self) private var viewModel
    @AppStorage("TTZip_UserRightInspectorRatio") private var userRightInspectorRatio: Double = Double(MainLayoutMetrics.defaultRightInspectorRatio)
    
    @Binding public var isRightSidebarVisible: Bool
    @Binding public var activeDragRightWidth: CGFloat?
    public let effectiveRightWidth: CGFloat
    public let minRightSidebarWidth: CGFloat
    public let effectiveMaxRightWidth: CGFloat
    public let availableContentWidth: CGFloat
    public let totalHeight: CGFloat
    public let goldenLineBottomY: CGFloat
    public var onRatioChanged: ((Double) -> Void)?
    public var explicitMode: InspectorSurfaceMode?
    
    @State private var initialDragRightWidth: CGFloat = MainLayoutMetrics.defaultRightSidebarWidth
    @State private var multiSelectionMetrics: AggregatedSelectionMetrics?
    
    public init(
        isRightSidebarVisible: Binding<Bool>,
        activeDragRightWidth: Binding<CGFloat?>,
        effectiveRightWidth: CGFloat,
        minRightSidebarWidth: CGFloat = MainLayoutMetrics.minRightSidebarWidth,
        effectiveMaxRightWidth: CGFloat,
        availableContentWidth: CGFloat,
        totalHeight: CGFloat,
        goldenLineBottomY: CGFloat = TTZipTheme.Layout.headerBarHeight,
        onRatioChanged: ((Double) -> Void)? = nil,
        explicitMode: InspectorSurfaceMode? = nil
    ) {
        self._isRightSidebarVisible = isRightSidebarVisible
        self._activeDragRightWidth = activeDragRightWidth
        self.effectiveRightWidth = effectiveRightWidth
        self.minRightSidebarWidth = minRightSidebarWidth
        self.effectiveMaxRightWidth = effectiveMaxRightWidth
        self.availableContentWidth = availableContentWidth
        self.totalHeight = totalHeight
        self.goldenLineBottomY = goldenLineBottomY
        self.onRatioChanged = onRatioChanged
        self.explicitMode = explicitMode
    }
    
    private var surfaceMode: InspectorSurfaceMode {
        if let explicit = explicitMode {
            return explicit
        }
        if viewModel.navigationState.isStorageInspectorActive {
            return .storageInspectorActive
        }
        if AndroidDeviceViewModel.shared.activeDevice(forWindow: viewModel.windowID) != nil {
            return AndroidDeviceViewModel.shared.inspectorSurfaceMode(forWindow: viewModel.windowID)
        }
        if let items = viewModel.selectionState.selectedDiskItems, items.count > 1 {
            if let metrics = multiSelectionMetrics {
                return .multiple(metrics: metrics)
            }
            return .multiple(metrics: AggregatedSelectionMetrics.placeholder(count: items.count))
        }
        if let item = RightInspectorSidePanel.resolveEffectiveItem(viewModel: viewModel) {
            return .single(metadata: FileSystemEntryMetadata(diskItem: item))
        }
        return .empty
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ResizableDividerHandle(
                topInset: goldenLineBottomY,
                onDragStart: {
                    initialDragRightWidth = effectiveRightWidth
                    activeDragRightWidth = effectiveRightWidth
                },
                onDragChanged: { translation in
                    let candidate = initialDragRightWidth - translation
                    let clamped = MainLayoutMetrics.rubberBandClampRightSidebar(
                        offset: candidate,
                        minWidth: minRightSidebarWidth,
                        maxWidth: effectiveMaxRightWidth
                    )
                    activeDragRightWidth = clamped
                },
                onDragEnd: {
                    let current = activeDragRightWidth ?? effectiveRightWidth
                    let clamped = min(max(current, minRightSidebarWidth), effectiveMaxRightWidth)
                    if availableContentWidth > 0 {
                        let newRatio = Double(clamped / availableContentWidth)
                        userRightInspectorRatio = newRatio
                        onRatioChanged?(newRatio)
                    }
                    InspectorWindowGeometryCoordinator.coordinator(
                        for: viewModel.windowID,
                        initialVisibility: viewModel.navigationState.isInspectorVisible
                    ).recordUserDividerCommit(clampedRightWidth: clamped)
                    activeDragRightWidth = nil
                },
                onDoubleClick: {
                    withAnimation(.ttLayout) {
                        let defaultRatio = Double(MainLayoutMetrics.defaultRightInspectorRatio)
                        userRightInspectorRatio = defaultRatio
                        onRatioChanged?(defaultRatio)
                        let resetWidth = min(
                            max(availableContentWidth * MainLayoutMetrics.defaultRightInspectorRatio, minRightSidebarWidth),
                            effectiveMaxRightWidth
                        )
                        InspectorWindowGeometryCoordinator.coordinator(
                            for: viewModel.windowID,
                            initialVisibility: viewModel.navigationState.isInspectorVisible
                        ).recordUserDividerCommit(clampedRightWidth: resetWidth)
                        activeDragRightWidth = nil
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
            )
            .frame(height: totalHeight)
            .transition(.opacity)
            
            if AndroidDeviceViewModel.shared.activeDeviceByWindow[viewModel.windowID] != nil {
                AndroidLocationInspectorView(
                    location: AndroidDeviceViewModel.shared.currentLocation(forWindow: viewModel.windowID)
                )
                .frame(width: effectiveRightWidth, height: totalHeight, alignment: .topLeading)
                .clipped()
            } else if viewModel.navigationState.isCompressWorkspaceActive {
                RightSideCompressFilePickerView(
                    viewModel: viewModel,
                    onClose: {
                        withAnimation(.ttLayout) {
                            isRightSidebarVisible = false
                        }
                    }
                )
                .frame(width: effectiveRightWidth, height: totalHeight, alignment: .topLeading)
                .clipped()
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                RightInspectorSidePanel(
                    mode: surfaceMode,
                    currentDirectoryURL: viewModel.navigationState.currentDirectory.standardizedFileURL.resolvingSymlinksInPath(),
                    onSelectArchive: { archivePath in
                        Task { await viewModel.loadArchive(path: archivePath) }
                    },
                    onCompressPath: { folderPath in
                        viewModel.openCompressWorkspace(paths: [folderPath])
                    },
                    onPreviewFile: { item in
                        viewModel.openImmersiveMedia(for: item)
                    },
                    onRevealInFinder: { path in
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    },
                    onInspectArchive: { path in
                        viewModel.overlayState.inspectingArchivePath = path
                        viewModel.overlayState.showArchiveInspectorModal = true
                    },
                    onMoveToTrash: { path in
                        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                        viewModel.clearInspectedFile()
                    },
                    onClearInspectedFile: {
                        viewModel.clearInspectedFile()
                    },
                    activeArchivePath: viewModel.explorerState.currentArchivePath,
                    onForgetArchivePassword: viewModel.archiveRememberedPasswordController == nil ? nil : { path in
                        Task { await viewModel.forgetArchivePassword(at: path) }
                    }
                )
                .frame(width: effectiveRightWidth, height: totalHeight, alignment: .topLeading)
                .clipped()
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .task(id: viewModel.selectionState.selectedDiskItems) {
            guard AndroidDeviceViewModel.shared.activeDeviceByWindow[viewModel.windowID] == nil,
                  let items = viewModel.selectionState.selectedDiskItems, items.count > 1 else {
                multiSelectionMetrics = nil
                return
            }
            multiSelectionMetrics = nil
            let metrics = await SelectionMetricsAggregator.shared.aggregate(items: items)
            if !Task.isCancelled {
                multiSelectionMetrics = metrics
            }
        }
    }
}
