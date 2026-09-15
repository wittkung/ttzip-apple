// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import AppKit
import TTZipPluginKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

@MainActor
public enum AppLogoCache {
    public static let sharedLogoImage: NSImage? = {
        if let bundleImage = NSImage(named: "AppIcon") {
            return bundleImage
        }
        if let resourcePath = Bundle.main.path(forResource: "TTZip_AppIcon_1024x1024", ofType: "png") {
            return NSImage(contentsOfFile: resourcePath)
        }
        return nil
    }()
}

public struct MainView: View {
    var l10n = AppLocalizationState.shared
    var registry = TTZipPluginRegistry.shared
    @State var viewModel = AppViewState()
    @State var isRightSidebarVisible: Bool = true
    @State var isLeftSidebarVisible: Bool = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State var presentedSecondaryTool: WorkspaceTab? = nil
    @State private var isDropTargeted: Bool = false
    
    public init() {}
    
    @AppStorage("TTZip_UserLeftSidebarWidth") private var userLeftSidebarWidth: Double = 190.0
    @AppStorage("TTZip_UserRightSidebarWidth") private var userRightSidebarWidth: Double = 340.0
    @AppStorage("TTZip_UserRightInspectorRatio") private var userRightInspectorRatio: Double = 0.38
    @State private var initialLeftWidth: CGFloat = 190.0
    @State private var rightSidebarWidth: CGFloat = 340
    @State private var initialRightWidth: CGFloat = 340
    
    @State var searchService = SpotlightSearchService()
    @State var searchQuery: String = ""
    
    public var body: some View {
        mainGeometryLayout
            .ignoresSafeArea()
            .environment(viewModel)
            .mainViewSheets(viewModel: viewModel, presentedSecondaryTool: $presentedSecondaryTool)
            .overlay {
                rootOverlays
            }
            .mainViewNotifications(
                viewModel: viewModel,
                l10n: l10n,
                userRightSidebarWidth: userRightSidebarWidth,
                rightSidebarWidth: $rightSidebarWidth
            )
    }
    
    @ViewBuilder
    private var detailArea: some View {
        HomeExplorerContainerView(
            viewModel: viewModel,
            isRightSidebarVisible: isRightSidebarVisible,
            isLeftSidebarVisible: isLeftSidebarVisible,
            onToggleLeftSidebar: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isLeftSidebarVisible.toggle()
                }
            },
            onToggleRightSidebar: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isRightSidebarVisible.toggle()
                }
            },
            onOpenArchive: {
                pickAndOpenArchive()
            },
            onNewArchive: {
                withAnimation {
                    viewModel.openCompressWorkspace()
                    viewModel.showCompressModal = true
                }
            },
            isActive: true
        )
    }
    
    private func liquidGlassSearchResultsOverlay(maxWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            if searchService.isSearching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(l10n.t(L10n.Common.processing)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else if searchService.searchResults.isEmpty {
                Text(l10n.t(L10n.Explorer.emptyDirectory)).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(searchService.searchResults, id: \.path) { item in
                            Button(action: {
                                searchQuery = ""
                                if item.isDirectory {
                                    viewModel.currentDirectory = URL(fileURLWithPath: item.path)
                                } else {
                                    viewModel.selectedDiskItem = item
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                        .foregroundStyle(item.isDirectory ? TTZipTheme.bambooGreen : .secondary)
                                    Text(item.name).font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(item.kindText).font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: maxWidth)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5))
        .padding(.top, 42)
    }
    
    // MARK: - Workspace Geometry Layout
    
    @ViewBuilder
    private var mainGeometryLayout: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let totalHeight = geo.size.height
            let tier = WindowLayoutTier.evaluate(width: totalWidth)
            let isMediaFocus = viewModel.navigationState.layoutMode == .mediaFocus
            
            let minSafeWorkspaceWidth: CGFloat = (tier == .compact) ? 430.0 : 460.0
            let minRightSidebarWidth: CGFloat = (tier == .compact) ? 220.0 : 240.0
            let maxRightSidebarWidth: CGFloat = totalWidth * 0.5
            
            let isRightPanelAvailable: Bool = (viewModel.activeTab == .home && (totalWidth >= 420.0))
            let shouldShowRightPanel = isRightSidebarVisible && isRightPanelAvailable
            
            let isLeftPanelAvailable: Bool = !isMediaFocus
            let shouldShowLeftPanel = isLeftSidebarVisible && isLeftPanelAvailable
            
            let dividerWidth: CGFloat = ResizableDividerHandle.gutterWidth
            let leftChrome = shouldShowLeftPanel ? (CGFloat(userLeftSidebarWidth) + dividerWidth) : 0
            let rightChrome = shouldShowRightPanel ? dividerWidth : 0
            
            let availableContentWidth = max(0, totalWidth - leftChrome - rightChrome)
            let maxRightAllowedByWorkspace = max(minRightSidebarWidth, totalWidth - leftChrome - rightChrome - minSafeWorkspaceWidth)
            let effectiveMaxRightWidth = max(minRightSidebarWidth, min(maxRightSidebarWidth, maxRightAllowedByWorkspace))
            let targetRightWidth = availableContentWidth * CGFloat(userRightInspectorRatio)
            let effectiveRightWidth: CGFloat = shouldShowRightPanel ? min(max(targetRightWidth, minRightSidebarWidth), effectiveMaxRightWidth) : 0
            
            let goldenLineBottomY = TTZipTheme.Layout.topBarOffset + TTZipTheme.Layout.headerBarHeight + TTZipTheme.Layout.kintsugiGoldLineHeight
            
            ZStack(alignment: .topLeading) {
                // Layer 0: Global Organic Bamboo Green Fluid Dynamic Background
                TTZipFluidBackgroundView(mode: .organic)
                    .frame(width: totalWidth, height: totalHeight)
                    .allowsHitTesting(false)
                
                // Layer 1: Macro Geometry Layout
                HStack(alignment: .top, spacing: 0) {
                    // Column 1: Left Finder & Locations Sidebar
                    if shouldShowLeftPanel {
                        FinderFavoritesSidebarView(
                            currentDirectory: viewModel.currentDirectory,
                            onSelectDirectory: { url in
                                viewModel.currentDirectory = url
                                viewModel.selectedDiskItem = nil
                            }
                        )
                        .frame(width: CGFloat(userLeftSidebarWidth), height: totalHeight, alignment: .topLeading)
                        .clipped()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        
                        // Left Resizable Divider
                        ResizableDividerHandle(
                            topInset: goldenLineBottomY,
                            onDragStart: { initialLeftWidth = CGFloat(userLeftSidebarWidth) },
                            onDragChanged: { translation in
                                let newWidth = initialLeftWidth + translation
                                let clamped = min(max(newWidth, 160.0), 300.0)
                                userLeftSidebarWidth = Double(clamped)
                            },
                            onDoubleClick: {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    userLeftSidebarWidth = 190.0
                                }
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            }
                        )
                        .frame(height: totalHeight)
                        .transition(.opacity)
                    }
                    
                    // Column 2: Center Explorer Workspace
                    detailArea
                        .frame(minWidth: isMediaFocus ? 0 : minSafeWorkspaceWidth, maxWidth: .infinity, maxHeight: totalHeight, alignment: .topLeading)
                    
                    // Column 3: Right Contextual Inspector
                    if shouldShowRightPanel {
                        ResizableDividerHandle(
                            topInset: goldenLineBottomY,
                            onDragStart: { initialRightWidth = effectiveRightWidth },
                            onDragChanged: { translation in
                                let newWidth = initialRightWidth - translation
                                let clamped = min(max(newWidth, minRightSidebarWidth), effectiveMaxRightWidth)
                                rightSidebarWidth = clamped
                                if availableContentWidth > 0 {
                                    userRightInspectorRatio = Double(clamped / availableContentWidth)
                                }
                            },
                            onDragEnd: {
                                userRightSidebarWidth = Double(rightSidebarWidth)
                                if availableContentWidth > 0 {
                                    userRightInspectorRatio = Double(rightSidebarWidth / availableContentWidth)
                                }
                            },
                            onDoubleClick: {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    userRightInspectorRatio = 0.38
                                    let targetWidth = availableContentWidth * 0.38
                                    rightSidebarWidth = min(max(targetWidth, minRightSidebarWidth), effectiveMaxRightWidth)
                                    userRightSidebarWidth = Double(rightSidebarWidth)
                                }
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            }
                        )
                        .frame(height: totalHeight)
                        .transition(.opacity)
                        
                        RightInspectorSidePanel(viewModel: viewModel)
                            .padding(.top, TTZipTheme.Layout.topBarOffset)
                            .frame(width: effectiveRightWidth, height: totalHeight, alignment: .topLeading)
                            .clipped()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
                
                if !isMediaFocus && viewModel.activeTab == .home {
                    if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let omnibarMaxWidth = min(480.0, max(220.0, totalWidth - 280.0))
                        HStack {
                            Spacer()
                            liquidGlassSearchResultsOverlay(maxWidth: omnibarMaxWidth)
                            Spacer()
                        }
                        .frame(width: totalWidth, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(999)
                    }
                }
            }
            .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
            .clipped()
            .simultaneousGesture(TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) })
            .onAppear {
                let baseWidth = availableContentWidth > 0 ? targetRightWidth : CGFloat(userRightSidebarWidth)
                self.rightSidebarWidth = min(max(baseWidth, minRightSidebarWidth), effectiveMaxRightWidth)
            }
            .onChange(of: viewModel.selectedDiskItem) { _, _ in
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .onChange(of: viewModel.activeTab) { _, newTab in
                NSApp.keyWindow?.makeFirstResponder(nil)
                if newTab == .compressWorkspace {
                    viewModel.showCompressModal = true
                    viewModel.activeTab = .home
                } else if newTab != .home {
                    presentedSecondaryTool = newTab
                    viewModel.activeTab = .home
                }
            }
            .onChange(of: viewModel.currentDirectory) { _, _ in NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }
    
    @ViewBuilder
    private var rootOverlays: some View {
        if viewModel.showPasswordPrompt, let targetPath = viewModel.pendingEncryptedPath {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { viewModel.cancelPasswordPrompt() }
                PasswordPromptSheetView(
                    archivePath: targetPath,
                    onSubmitPassword: { pwd async in await viewModel.loadArchive(path: targetPath, password: pwd) },
                    onCancel: { viewModel.cancelPasswordPrompt() }
                )
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: viewModel.showPasswordPrompt)
        }
        
        if viewModel.overlayState.showImmersiveMediaBrowser,
           let item = viewModel.overlayState.immersiveMediaItem {
            ImmersiveMediaBrowserView(
                item: item,
                onClose: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        viewModel.closeImmersiveMedia()
                    }
                },
                onNavigatePrevious: viewModel.hasPreviousMedia ? {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.navigatePreviousMedia()
                    }
                } : nil,
                onNavigateNext: viewModel.hasNextMedia ? {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.navigateNextMedia()
                    }
                } : nil
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(1000)
        }
    }
}

// MARK: - View Modifiers Deconstruction

private extension View {
    @ViewBuilder
    func mainViewSheets(
        viewModel: AppViewState,
        presentedSecondaryTool: Binding<WorkspaceTab?>
    ) -> some View {
        @Bindable var vm = viewModel
        self
            .sheet(item: presentedSecondaryTool) { tab in
                SecondaryToolSheetContainer(tab: tab, onDismiss: { presentedSecondaryTool.wrappedValue = nil })
            }
            .sheet(isPresented: $vm.showCompressModal) {
                CompressModalView(
                    isPresented: $vm.showCompressModal,
                    initialInputPaths: vm.selectedPathsToCompress,
                    onCompleteOpenArchive: { archivePath in
                        vm.showCompressModal = false
                        vm.openArchiveAsFolder(url: URL(fileURLWithPath: archivePath))
                    }
                )
                .frame(minWidth: 720, idealWidth: 840, maxWidth: 960, minHeight: 520, idealHeight: 620, maxHeight: 760)
            }
            .sheet(isPresented: $vm.showExtractModal) {
                let targetPath = vm.selectedDiskItem?.path ?? vm.currentArchivePath ?? ""
                ExtractModalView(archivePath: targetPath, isPresented: $vm.showExtractModal)
            }
            .sheet(isPresented: $vm.showArchiveInspectorModal) {
                let targetPath = vm.inspectingArchivePath ?? vm.selectedDiskItem?.path ?? vm.currentArchivePath ?? ""
                ArchiveInspectorContainerView(archivePath: targetPath)
            }
            .sheet(isPresented: Binding(
                get: { AppErrorReporter.shared.isPresentingError },
                set: { if !$0 { AppErrorReporter.shared.dismiss() } }
            )) {
                if let payload = AppErrorReporter.shared.activeError {
                    ErrorPresentationSheetView(payload: payload) {
                        AppErrorReporter.shared.dismiss()
                    }
                }
            }
    }

    @ViewBuilder
    func mainViewNotifications(
        viewModel: AppViewState,
        l10n: AppLocalizationState,
        userRightSidebarWidth: Double,
        rightSidebarWidth: Binding<CGFloat>
    ) -> some View {
        self
            .onAppear {
                AppIntentDispatcher.shared.bind(state: viewModel)
                (NSApp.delegate as? AppDelegate)?.registerHandler { url in
                    Task { @MainActor in
                        if let envelope = AppIntentParser.parse(url: url) {
                            AppIntentDispatcher.shared.dispatch(envelope)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipEncryptedArchivePromptRequired"))) { notif in
                if let path = notif.object as? String {
                    viewModel.pendingEncryptedPath = path
                    viewModel.showPasswordPrompt = true
                    viewModel.statusMessage = l10n.t(L10n.Errors.passwordRequired)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipToggleMediaFocusNotification"))) { notif in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    if viewModel.overlayState.showImmersiveMediaBrowser {
                        viewModel.closeImmersiveMedia()
                    } else {
                        if let item = notif.object as? ImmersiveMediaItem {
                            viewModel.openImmersiveMedia(url: item.url, name: item.name, fileSizeBytes: item.fileSizeBytes)
                        } else if let url = notif.object as? URL {
                            let name = (notif.userInfo?["name"] as? String) ?? url.lastPathComponent
                            viewModel.openImmersiveMedia(url: url, name: name)
                        } else if let item = viewModel.selectedDiskItem {
                            let u = URL(fileURLWithPath: item.path)
                            viewModel.openImmersiveMedia(url: u, name: item.name, fileSizeBytes: item.fileSizeBytes)
                        } else if let url = viewModel.activePreviewFileURL, let name = viewModel.activePreviewFileName {
                            viewModel.openImmersiveMedia(url: url, name: name)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.navigationState.layoutMode = .standard
                    rightSidebarWidth.wrappedValue = CGFloat(userRightSidebarWidth)
                }
            }
            .onChange(of: viewModel.activePreviewFileURL) { _, newURL in
                if newURL == nil && viewModel.navigationState.layoutMode == .mediaFocus {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.navigationState.layoutMode = .standard
                        rightSidebarWidth.wrappedValue = CGFloat(userRightSidebarWidth)
                    }
                }
            }
    }
}

