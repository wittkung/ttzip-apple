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
    @ObservedObject var l10n = AppLocalizationState.shared
    @ObservedObject var registry = TTZipPluginRegistry.shared
    @State var viewModel = AppViewState()
    @State var isRightSidebarVisible: Bool = true
    @State var isLeftSidebarVisible: Bool = true
    @State var presentedSecondaryTool: WorkspaceTab? = nil
    @State private var isDropTargeted: Bool = false
    
    public init() {}
    
    @AppStorage("TTZip_UserLeftSidebarWidth") private var userLeftSidebarWidth: Double = 190.0
    @State private var leftSidebarWidth: CGFloat = 190
    @State private var initialLeftWidth: CGFloat = 190
    
    @AppStorage("TTZip_UserRightSidebarWidth") private var userRightSidebarWidth: Double = 280.0
    @State private var rightSidebarWidth: CGFloat = 280
    @State private var initialRightWidth: CGFloat = 280
    @State private var rightVerticalTopHeight: CGFloat = 300
    
    @StateObject private var searchService = SpotlightSearchService()
    @State private var searchQuery: String = ""
    
    public var body: some View {
        @Bindable var viewModel = viewModel
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let totalHeight = geo.size.height
            let tier = WindowLayoutTier.evaluate(width: totalWidth)
            let isMediaFocus = viewModel.navigationState.layoutMode == .mediaFocus
            
            // Fixed Chrome Geometry & Safety Clamping Constants
            let dividerWidth: CGFloat = ResizableDividerHandle.gutterWidth
            let rightPanelPadding: CGFloat = 14.0 // leading: 4 + trailing: 10
            let minSafeWorkspaceWidth: CGFloat = 380.0
            
            let minLeftSidebarWidth: CGFloat = 150.0
            let maxLeftSidebarWidth: CGFloat = 280.0
            let isLeftPanelAvailable: Bool = (tier != .compact && viewModel.activeTab == .home)
            let shouldShowLeftPanel = !isMediaFocus && isLeftSidebarVisible && isLeftPanelAvailable
            
            let effectiveLeftWidth: CGFloat = {
                if !shouldShowLeftPanel { return 0 }
                return min(max(leftSidebarWidth, minLeftSidebarWidth), maxLeftSidebarWidth)
            }()
            
            let minRightSidebarWidth: CGFloat = 200.0
            let maxRightSidebarWidth: CGFloat = max(850.0, totalWidth * 0.55)
            let isRightPanelAvailable: Bool = (tier != .compact && viewModel.activeTab == .home)
            let shouldShowRightPanel = !isMediaFocus && isRightSidebarVisible && isRightPanelAvailable
            
            let leftChrome = shouldShowLeftPanel ? (effectiveLeftWidth + dividerWidth) : 0
            let rightChrome = shouldShowRightPanel ? (dividerWidth + rightPanelPadding) : 0
            let maxRightAllowedByWorkspace = max(minRightSidebarWidth, totalWidth - leftChrome - rightChrome - minSafeWorkspaceWidth)
            let effectiveMaxRightWidth = min(maxRightSidebarWidth, maxRightAllowedByWorkspace)
            
            let effectiveRightWidth: CGFloat = {
                if !shouldShowRightPanel { return 0 }
                return min(max(rightSidebarWidth, minRightSidebarWidth), effectiveMaxRightWidth)
            }()
            
            ZStack(alignment: .topLeading) {
                TTZipFluidBackgroundView(baseColor: TTZipTheme.bambooGreen)
                    .frame(width: totalWidth, height: totalHeight)
                    .allowsHitTesting(false)
                
                HStack(alignment: .top, spacing: 0) {
                    if shouldShowLeftPanel {
                        FinderFavoritesSidebarView(
                            currentDirectory: viewModel.currentDirectory,
                            onSelectDirectory: { url in
                                viewModel.currentDirectory = url
                                viewModel.selectedDiskItem = nil
                            }
                        )
                        .frame(width: effectiveLeftWidth, height: totalHeight, alignment: .topLeading)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        
                        if tier != .compact {
                            ResizableDividerHandle(
                                onDragStart: { initialLeftWidth = leftSidebarWidth },
                                onDragChanged: { translation in
                                    let newWidth = initialLeftWidth + translation
                                    leftSidebarWidth = min(max(newWidth, minLeftSidebarWidth), maxLeftSidebarWidth)
                                },
                                onDragEnd: { userLeftSidebarWidth = Double(leftSidebarWidth) }
                            )
                            .frame(height: totalHeight)
                            .transition(.opacity)
                        }
                    }
                    
                    detailArea
                        .frame(minWidth: isMediaFocus ? 0 : minSafeWorkspaceWidth, maxWidth: .infinity, maxHeight: totalHeight, alignment: .topLeading)
                    
                    if shouldShowRightPanel {
                        ResizableDividerHandle(
                            onDragStart: { initialRightWidth = rightSidebarWidth },
                            onDragChanged: { translation in
                                let newWidth = initialRightWidth - translation
                                rightSidebarWidth = min(max(newWidth, minRightSidebarWidth), effectiveMaxRightWidth)
                            },
                            onDragEnd: { userRightSidebarWidth = Double(rightSidebarWidth) }
                        )
                        .frame(height: totalHeight)
                        .transition(.opacity)
                        
                        RightInspectorSidePanel(viewModel: viewModel, rightVerticalTopHeight: $rightVerticalTopHeight)
                            .frame(width: effectiveRightWidth, alignment: .topLeading)
                            .padding(.top, TTZipTheme.Layout.topBarOffset)
                            .padding(.leading, 4)
                            .padding(.trailing, 10)
                            .padding(.bottom, TTZipTheme.Spacing.md)
                            .frame(maxHeight: totalHeight, alignment: .topLeading)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
                .clipped()
                
                if !isMediaFocus && viewModel.activeTab == .home {
                    let omnibarMaxWidth = min(480.0, max(180.0, totalWidth - 280.0))
                    HStack(spacing: 0) {
                        Spacer(minLength: 140)
                        LiquidGlassOmnibar(
                            searchQuery: $searchQuery,
                            searchService: searchService,
                            viewModel: viewModel,
                            maxContainerWidth: omnibarMaxWidth
                        )
                        .frame(minWidth: 180, idealWidth: 380, maxWidth: omnibarMaxWidth)
                        Spacer(minLength: 140)
                    }
                    .padding(.top, 2)
                    .padding(.horizontal, 16)
                    .frame(width: totalWidth, alignment: .top)
                    .zIndex(998)
                    
                    if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        liquidGlassSearchResultsOverlay(maxWidth: omnibarMaxWidth)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(999)
                    }
                }
            }
            .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
            .clipped()
            .simultaneousGesture(TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) })
            .onAppear {
                self.leftSidebarWidth = CGFloat(userLeftSidebarWidth)
                self.rightSidebarWidth = CGFloat(userRightSidebarWidth)
            }
            .onChange(of: viewModel.selectedDiskItem) { _, _ in NSApp.keyWindow?.makeFirstResponder(nil) }
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
        .ignoresSafeArea()
        .toolbar {
            mainToolbarContent
        }
        .sheet(item: $presentedSecondaryTool) { tab in
            SecondaryToolSheetContainer(tab: tab, onDismiss: { presentedSecondaryTool = nil })
        }
        .sheet(isPresented: $viewModel.showCompressModal) {
            CompressModalView(
                isPresented: $viewModel.showCompressModal,
                initialInputPaths: viewModel.selectedPathsToCompress,
                onCompleteOpenArchive: { archivePath in
                    viewModel.showCompressModal = false
                    viewModel.openArchiveAsFolder(url: URL(fileURLWithPath: archivePath))
                }
            )
            .frame(minWidth: 720, idealWidth: 840, maxWidth: 960, minHeight: 520, idealHeight: 620, maxHeight: 760)
        }
        .sheet(isPresented: $viewModel.showExtractModal) {
            let targetPath = viewModel.selectedDiskItem?.path ?? viewModel.currentArchivePath ?? ""
            ExtractModalView(archivePath: targetPath, isPresented: $viewModel.showExtractModal)
        }
        .sheet(isPresented: $viewModel.showArchiveInspectorModal) {
            let targetPath = viewModel.inspectingArchivePath ?? viewModel.selectedDiskItem?.path ?? viewModel.currentArchivePath ?? ""
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
        .overlay {
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
        }
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipQuickExtractArchive"))) { notif in
            if let path = notif.object as? String {
                Task { await viewModel.quickExtractArchive(archivePath: path) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipOpenArchiveInspector"))) { notif in
            if let path = notif.object as? String {
                viewModel.overlayState.inspectingArchivePath = path
                viewModel.overlayState.showArchiveInspectorModal = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipOpenCompressWorkspaceWithPaths"))) { notif in
            if let paths = notif.object as? [String] {
                viewModel.openCompressWorkspace(paths: paths)
                viewModel.showCompressModal = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipToggleMediaFocusNotification"))) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                viewModel.navigationState.toggleMediaFocusMode()
            }
            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
                window.toggleFullScreen(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            // Window is entering fullscreen; maintain alignment with active presentation
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                viewModel.navigationState.layoutMode = .standard
                self.leftSidebarWidth = CGFloat(userLeftSidebarWidth)
                self.rightSidebarWidth = CGFloat(userRightSidebarWidth)
            }
        }
        .onChange(of: viewModel.activePreviewFileURL) { _, newURL in
            if newURL == nil && viewModel.navigationState.layoutMode == .mediaFocus {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.navigationState.layoutMode = .standard
                    self.leftSidebarWidth = CGFloat(userLeftSidebarWidth)
                    self.rightSidebarWidth = CGFloat(userRightSidebarWidth)
                }
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }),
                   window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
    }
    
    @ViewBuilder
    private var detailArea: some View {
        if let previewURL = viewModel.activePreviewFileURL, let name = viewModel.activePreviewFileName {
            if viewModel.navigationState.layoutMode == .mediaFocus {
                MediaPreviewView(fileURL: previewURL, fileName: name)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TTZipWorkspaceScaffold(
                    title: name,
                    isCardEnclosed: true
                ) {
                    Button(action: { viewModel.closeMediaPreview() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                            Text(l10n.t(L10n.Common.close))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(TTZipTheme.cinnabarRed.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } content: {
                    MediaPreviewView(fileURL: previewURL, fileName: name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            HomeExplorerContainerView(viewModel: viewModel, isRightSidebarVisible: isRightSidebarVisible, isActive: true)
        }
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
}
