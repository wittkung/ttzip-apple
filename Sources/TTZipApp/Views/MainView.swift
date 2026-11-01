// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTKitDesign
import TTKitFluid

/// Canonical root content container mounted inside `TTZipApp`'s `WindowGroup(id: "main")` and shared
/// 1:1 with offscreen `NSWindow` layout tests so production scene minimum-size constraints and test harness
/// roots never diverge.
public struct MainWindowSceneRootView: View {
    private let initialViewModel: AppViewState?

    public init(viewModel: AppViewState? = nil) {
        self.initialViewModel = viewModel
    }

    public var body: some View {
        Group {
            if let initialViewModel {
                MainView(viewModel: initialViewModel)
            } else {
                MainView()
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
    }
}

/// Unified main window view presenting three-column layout, ambient fluid background, and overlays.
public struct MainView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    var l10n = AppLocalizationState.shared
    @State var viewModel = AppViewState()
    private var coordinator: PresentationCoordinator { viewModel.presentationCoordinator }

    public var presentedSecondaryTool: WorkspaceTab? {
        if case .secondaryTool(let tool) = coordinator.activeModal {
            return tool
        }
        return nil
    }

    private var presentedSecondaryToolBinding: Binding<WorkspaceTab?> {
        Binding(
            get: {
                if case .secondaryTool(let tool) = coordinator.activeModal {
                    return tool
                }
                return nil
            },
            set: { newTool in
                if let newTool {
                    coordinator.present(.secondaryTool(newTool))
                } else if case .secondaryTool = coordinator.activeModal {
                    coordinator.dismiss()
                }
            }
        )
    }
    
    private var isLeftSidebarVisibleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.navigationState.isLeftSidebarVisible },
            set: { viewModel.navigationState.isLeftSidebarVisible = $0 }
        )
    }
    
    private var isInspectorVisibleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.navigationState.isInspectorVisible },
            set: { newValue in
                let coordinator = InspectorWindowGeometryCoordinator.coordinator(
                    for: viewModel.windowID,
                    initialVisibility: viewModel.navigationState.isInspectorVisible
                )
                coordinator.setInspectorVisible(
                    newValue,
                    for: viewModel,
                    userRightRatio: CGFloat(userRightInspectorRatio)
                )
            }
        )
    }
    
    @AppStorage("TTZip_UserLeftSidebarWidth") private var userLeftSidebarWidth: Double = Double(MainLayoutMetrics.defaultLeftSidebarWidth)
    @AppStorage("TTZip_UserRightInspectorRatio") private var userRightInspectorRatio: Double = Double(MainLayoutMetrics.defaultRightInspectorRatio)
    @State private var leftSidebarWidth: CGFloat = MainLayoutMetrics.defaultLeftSidebarWidth
    @State private var activeDragRightWidth: CGFloat? = nil
    
    @State var searchService = SpotlightSearchService()
    @State var searchQuery: String = ""
    @State private var openURLRegistrationToken: AppDelegate.RegistrationToken?
    @AppStorage("ttzip_accent_theme") private var accentTheme: String = "bamboo"
    
    private var activeMineralAccent: Color {
        switch accentTheme.lowercased() {
        case "gold", "kintsugigold":
            return TTZipTheme.kintsugiGold
        case "cinnabar", "cinnabarred":
            return TTZipTheme.cinnabarRed
        case "amber", "archiveamber":
            return TTZipTheme.archiveAmber
        case "purple", "celestial", "celestialpurple":
            return TTZipTheme.celestialPurple
        default:
            return TTZipTheme.bambooGreen
        }
    }
    
    public init(viewModel: AppViewState = AppViewState()) {
        self._viewModel = State(initialValue: viewModel)
    }
    
    public var body: some View {
        GeometryReader { geo in
            let inspectorCoordinator = InspectorWindowGeometryCoordinator.coordinator(
                for: viewModel.windowID,
                initialVisibility: viewModel.navigationState.isInspectorVisible
            )
            let m = MainLayoutMetrics.compute(
                size: geo.size,
                viewModel: viewModel,
                isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
                isRightVisible: viewModel.navigationState.isInspectorVisible,
                leftWidth: leftSidebarWidth,
                rightRatio: CGFloat(userRightInspectorRatio),
                overrideRightWidth: activeDragRightWidth,
                lockedRightWidth: inspectorCoordinator.lockedExpandedRightWidth
            )
            let _ = inspectorCoordinator.recordLiveLayout(
                windowWidth: geo.size.width,
                leftSidebarWidth: leftSidebarWidth,
                metrics: m,
                isRightVisible: viewModel.navigationState.isInspectorVisible,
                isDraggingDivider: activeDragRightWidth != nil
            )
            ZStack(alignment: .topLeading) {
                // Layer 1: Ambient fluid with stronger light-mode color beneath the frosted finish (0.60 dark / 0.38 light).
                TTKitFluidBackgroundView(
                    engine: .metalCached,
                    config: FluidBackgroundConfig(
                        baseColor: activeMineralAccent,
                        isRunning: viewModel.isLoading,
                        isFocusPaused: m.isFluidPaused(viewModel: viewModel),
                        isActive: true,
                        isDarkMode: colorScheme == .dark,
                        fluidOpacity: colorScheme == .dark ? 0.60 : 0.38,
                        isFrosted: true
                    )
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
                
                // Layer 2: Monolithic Frameless Three-Column Layout (Pervasive Fluid Substrate)
                HStack(alignment: .top, spacing: 0) {
                    if m.shouldShowLeft {
                        SidebarColumnView(width: $leftSidebarWidth, totalHeight: geo.size.height, goldenLineBottomY: m.goldenLineBottomY)
                            .accessibilityIdentifier("MainLeftSidebarColumn")
                    }
                    ContentColumnView(
                        isLeftSidebarVisible: isLeftSidebarVisibleBinding,
                        isRightSidebarVisible: isInspectorVisibleBinding,
                        width: m.centerWidth,
                        height: geo.size.height,
                        dynamicTrafficLightMargin: m.trafficLightMargin,
                        onOpenArchive: { pickAndOpenArchive() }
                    )
                    .accessibilityIdentifier("MainCenterContentColumn")
                    if m.shouldShowRight {
                        InspectorColumnView(
                            isRightSidebarVisible: isInspectorVisibleBinding,
                            activeDragRightWidth: $activeDragRightWidth,
                            effectiveRightWidth: m.effectiveRightWidth,
                            minRightSidebarWidth: m.minRightSidebarWidth,
                            effectiveMaxRightWidth: m.effectiveMaxRightWidth,
                            availableContentWidth: m.availableContentWidth,
                            totalHeight: geo.size.height,
                            goldenLineBottomY: m.goldenLineBottomY,
                            onRatioChanged: { newRatio in
                                userRightInspectorRatio = newRatio
                            }
                        )
                        .accessibilityIdentifier("MainRightInspectorColumn")
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                
                if m.shouldShowSearch && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let leftOffset = m.shouldShowLeft ? (leftSidebarWidth + ResizableDividerHandle.gutterWidth) : 0
                    HStack {
                        Spacer()
                        SearchOverlayView(searchQuery: $searchQuery, searchService: searchService, maxWidth: m.omnibarMaxWidth)
                        Spacer()
                    }
                    .frame(width: m.centerWidth, alignment: .top)
                    .offset(x: leftOffset)
                    .zIndex(999)
                }
            }
            .frame(
                minWidth: MainLayoutMetrics.minimumContentWidth(
                    viewModel: viewModel,
                    isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
                    isRightVisible: viewModel.navigationState.isInspectorVisible,
                    leftWidth: leftSidebarWidth
                ),
                minHeight: MainLayoutMetrics.minimumWindowContentHeight
            )
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .mainViewLayoutEvents(
                viewModel: viewModel,
                leftWidth: $leftSidebarWidth,
                userLeft: userLeftSidebarWidth,
                metrics: m,
                isRightVisible: isInspectorVisibleBinding,
                presentedTool: presentedSecondaryToolBinding
            )
        }
        .frame(
            minWidth: MainLayoutMetrics.minimumContentWidth(
                viewModel: viewModel,
                isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
                isRightVisible: viewModel.navigationState.isInspectorVisible,
                leftWidth: leftSidebarWidth
            ),
            minHeight: MainLayoutMetrics.minimumWindowContentHeight
        )
        .ignoresSafeArea()
        .environment(viewModel)
        .focusedSceneValue(\.appViewState, viewModel)
        .sheet(item: activeModalSheetBinding) { presentation in
            activeModalSheetContent(presentation: presentation)
        }
        .overlay { MainRootOverlaysView().environment(viewModel) }
        .mainViewNotifications(viewModel: viewModel, l10n: l10n, openURLRegistrationToken: $openURLRegistrationToken)
        .background {
            ZStack {
                tabRoutingFenceOverlay
                BrowserWindowLifecycleBridge(viewModel: viewModel)
                    .frame(width: 0, height: 0)
            }
        }
        .onAppear {
            BrowserWindowRouter.shared.swiftUIWindowOpener = {
                openWindow(id: "main")
            }
            viewModel.undoManager = undoManager
            viewModel.presentationCoordinator.bind(to: viewModel)
            AppIntentDispatcher.shared.bind(state: viewModel)
            if !viewModel.hasAppliedLaunchSeed {
                if let seed = BrowserWindowRegistry.shared.consumeNextLaunchSeed() {
                    viewModel.applyLaunchSeed(seed)
                } else {
                    viewModel.markLaunchSeedChecked()
                }
            }
        }
        .onChange(of: undoManager) { _, newManager in
            viewModel.undoManager = newManager
        }
    }

    // MARK: - Direct Modal & Sheet Presentation Binding

    private var activeModalSheetBinding: Binding<ActiveModalPresentation?> {
        Binding(
            get: {
                if let modal = coordinator.activeModal, modal.tier == 2 {
                    return modal
                }
                let isTargetWindow = BrowserWindowRegistry.shared.activeWindowID == nil
                    || BrowserWindowRegistry.shared.activeWindowID == viewModel.windowID
                if isTargetWindow && AndroidDeviceViewModel.shared.showAdbGuideSheet {
                    return .adbGuide
                }
                if isTargetWindow && AppErrorReporter.shared.isPresentingError {
                    return .errorAlert
                }
                return nil
            },
            set: { newModal in
                if newModal == nil {
                    if coordinator.activeModal?.tier == 2 {
                        coordinator.dismiss()
                    }
                    if AndroidDeviceViewModel.shared.showAdbGuideSheet {
                        AndroidDeviceViewModel.shared.showAdbGuideSheet = false
                    }
                    if AppErrorReporter.shared.isPresentingError {
                        AppErrorReporter.shared.dismiss()
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func activeModalSheetContent(presentation: ActiveModalPresentation) -> some View {
        switch presentation {
        case .secondaryTool(let tab):
            SecondaryToolSheetContainer(tab: tab, onDismiss: {
                coordinator.dismiss()
            })
        case .extract:
            let targetPath = viewModel.selectedDiskItem?.path ?? viewModel.explorerState.currentArchivePath ?? ""
            ExtractModalView(
                archivePath: targetPath,
                isPresented: Binding(
                    get: { coordinator.activeModal == .extract },
                    set: { if !$0 { coordinator.dismiss(.extract) } }
                )
            )
        case .archiveInspector:
            let targetPath = viewModel.overlayState.inspectingArchivePath ?? viewModel.selectedDiskItem?.path ?? viewModel.explorerState.currentArchivePath ?? ""
            ArchiveInspectorContainerView(archivePath: targetPath)
        case .archiveIntegrity:
            let targetPath = viewModel.overlayState.integrityArchivePath ?? viewModel.selectedDiskItem?.path ?? viewModel.explorerState.currentArchivePath ?? ""
            ArchiveIntegrityView(archivePath: targetPath)
                .ttOverlayGlassPlate(cornerRadius: 18)
        case .adbGuide:
            AdbEnableGuideSheet(isPresented: Binding(
                get: { AndroidDeviceViewModel.shared.showAdbGuideSheet },
                set: { AndroidDeviceViewModel.shared.showAdbGuideSheet = $0 }
            ))
        case .errorAlert:
            if let payload = AppErrorReporter.shared.activeError {
                ErrorPresentationSheetView(payload: payload) {
                    coordinator.dismiss(.errorAlert)
                    AppErrorReporter.shared.dismiss()
                }
                .ttOverlayGlassPlate(cornerRadius: 18)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Key-Routing Fence & Tab Navigation Shortcuts

    private var tabRoutingFenceOverlay: some View {
        Group {
            // Direct Tab Index Jump: ⌥⌘1 .. ⌥⌘8
            ForEach(0..<8, id: \.self) { idx in
                Button("") {
                    if idx < viewModel.navigationState.directoryTabs.count {
                        viewModel.navigationState.selectTab(at: idx)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.option, .command])
                .opacity(0)
            }
            
            // Jump to Last Tab: ⌥⌘9
            Button("") {
                let count = viewModel.navigationState.directoryTabs.count
                if count > 0 {
                    viewModel.navigationState.selectTab(at: count - 1)
                }
            }
            .keyboardShortcut("9", modifiers: [.option, .command])
            .opacity(0)

            // Close Active Tab: ⌘W (Preserved strictly for tab closure)
            Button("") {
                let nav = viewModel.navigationState
                if nav.directoryTabs.count > 1 || nav.isCompressWorkspaceActive || nav.isStorageInspectorActive {
                    nav.closeTab(at: nav.activeTabIndex)
                } else if viewModel.explorerState.currentArchivePath != nil {
                    viewModel.reset()
                }
            }
            .keyboardShortcut("w", modifiers: [.command])
            .opacity(0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
