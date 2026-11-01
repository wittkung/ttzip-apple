// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTKitDesign
import TTKitFluid
import TTZipUI
import TTZipPreviewKit

/// Pure layout geometry metrics container and calculation engine for MainView.
@MainActor
public struct MainLayoutMetrics: Sendable {
    // MARK: - Geometric & Layout Physical Invariants
    
    public static let minLeftSidebarWidth: CGFloat = 200.0
    public static let maxLeftSidebarWidth: CGFloat = 300.0
    public static let defaultLeftSidebarWidth: CGFloat = 200.0
    
    public static let minRightSidebarWidth: CGFloat = 220.0
    public static let defaultRightSidebarWidth: CGFloat = 340.0
    public static let minimumWindowContentHeight: CGFloat = 460.0
    /// Canonical proportional ratio for Right Inspector: 1/3 (giving Center 2/3 vs Right 1/3, i.e., 2:1 ratio).
    public static let defaultRightInspectorRatio: CGFloat = 1.0 / 3.0
    public static let maxRightInspectorErgonomicCap: CGFloat = 540.0
    public static let hairlineBorderWidth: CGFloat = UniversalTokens.Dimensions.hairlineWidth // 0.5pt
    public static let goldenRuleBaselineY: CGFloat = UniversalTokens.Layout.goldenBaselineY // 52.0pt
    
    // MARK: - Instance Metrics
    
    public let shouldShowLeft: Bool
    public let shouldShowRight: Bool
    public let availableContentWidth: CGFloat
    public let effectiveRightWidth: CGFloat
    public let effectiveMaxRightWidth: CGFloat
    public let minRightSidebarWidth: CGFloat
    public let centerWidth: CGFloat
    public let shouldShowSearch: Bool
    public let omnibarMaxWidth: CGFloat
    public let goldenLineBottomY: CGFloat
    public let trafficLightMargin: CGFloat
    
    public func isFluidPaused(viewModel: AppViewState) -> Bool {
        viewModel.overlayState.showImmersiveMediaBrowser || TTPreviewPlaybackManager.isPlaying
    }
    
    // MARK: - Fluid Gesture & Boundary Kinematics
    
    /// Continuous logarithmic rubber-band boundary damping for left sidebar dragging.
    /// Eliminates hard boundary cutoff and avoids jump-flash when over-dragging.
    public static func rubberBandClampLeftSidebar(
        offset: CGFloat,
        dimension: CGFloat = 120.0
    ) -> CGFloat {
        CGFloat(TTKitFluid.FluidGesturePhysics.rubberBandClamp(
            offset: Double(offset),
            range: Double(minLeftSidebarWidth)...Double(maxLeftSidebarWidth),
            dimension: Double(dimension)
        ))
    }
    
    /// Continuous logarithmic rubber-band boundary damping for right inspector dragging.
    /// Eliminates hard boundary cutoff and avoids jump-flash when over-dragging.
    public static func rubberBandClampRightSidebar(
        offset: CGFloat,
        minWidth: CGFloat = minRightSidebarWidth,
        maxWidth: CGFloat,
        dimension: CGFloat? = nil
    ) -> CGFloat {
        let safeMax = max(minWidth, maxWidth)
        let dim = dimension ?? max(100.0, safeMax - minWidth)
        return CGFloat(TTKitFluid.FluidGesturePhysics.rubberBandClamp(
            offset: Double(offset),
            range: Double(minWidth)...Double(safeMax),
            dimension: Double(dim)
        ))
    }
    
    // MARK: - Metrics Calculation Engine
    
    /// Computes the legal minimum window content width for the active visible column configuration.
    public static func minimumContentWidth(
        viewModel: AppViewState,
        isLeftVisible: Bool,
        isRightVisible: Bool,
        leftWidth: CGFloat = defaultLeftSidebarWidth
    ) -> CGFloat {
        let isMediaFocus = viewModel.navigationState.layoutMode == .mediaFocus
        if isMediaFocus {
            return 280.0
        }
        let isCompress = viewModel.navigationState.isCompressWorkspaceActive
        let isStorageInspector = viewModel.navigationState.isStorageInspectorActive
        let minSafeWorkspaceWidth: CGFloat = isCompress ? 360.0 : 280.0
        let minRightWidth: CGFloat = isCompress ? 280.0 : minRightSidebarWidth
        let dividerWidth = ResizableDividerHandle.gutterWidth
        let effectiveLeft = isLeftVisible ? max(minLeftSidebarWidth, leftWidth) + dividerWidth : 0
        let shouldIncludeRight = isRightVisible
            && viewModel.navigationState.activeTab == .home
            && !isStorageInspector
            && !viewModel.overlayState.showImmersiveMediaBrowser
        let effectiveRight = shouldIncludeRight ? (minRightWidth + dividerWidth) : 0
        let structuralMin = effectiveLeft + minSafeWorkspaceWidth + effectiveRight
        if shouldIncludeRight {
            return max(720.0, structuralMin)
        }
        return structuralMin
    }

    public static func compute(
        size: CGSize,
        viewModel: AppViewState,
        isLeftVisible: Bool,
        isRightVisible: Bool,
        leftWidth: CGFloat,
        rightRatio: CGFloat = defaultRightInspectorRatio,
        overrideRightWidth: CGFloat? = nil,
        lockedRightWidth: CGFloat? = nil
    ) -> MainLayoutMetrics {
        let totalWidth = size.width
        let isMediaFocus = viewModel.navigationState.layoutMode == .mediaFocus
        let isCompress = viewModel.navigationState.isCompressWorkspaceActive
        let isStorageInspector = viewModel.navigationState.isStorageInspectorActive
        let minSafeWorkspaceWidth: CGFloat = isCompress ? 360.0 : 280.0
        let minRightSidebarWidth: CGFloat = isCompress ? 280.0 : Self.minRightSidebarWidth
        let maxRightSidebarWidth: CGFloat = min(totalWidth * 0.45, maxRightInspectorErgonomicCap)
        
        let isRightPanelAvailable = (viewModel.navigationState.activeTab == .home && (totalWidth >= 720.0) && !isStorageInspector)
        let shouldShowRight = isRightVisible && isRightPanelAvailable && !viewModel.overlayState.showImmersiveMediaBrowser
        let shouldShowLeft = isLeftVisible && !isMediaFocus
        
        let dividerWidth = ResizableDividerHandle.gutterWidth
        let leftChrome = shouldShowLeft ? (leftWidth + dividerWidth) : 0
        let rightChrome = shouldShowRight ? dividerWidth : 0
        
        let availableContentWidth = max(0, totalWidth - leftChrome - rightChrome)
        let maxRightAllowedByWorkspace = max(0, availableContentWidth - minSafeWorkspaceWidth)
        let effectiveMaxRightWidth = max(minRightSidebarWidth, min(maxRightSidebarWidth, maxRightAllowedByWorkspace))
        
        let preferredRightWidth: CGFloat = {
            if let override = overrideRightWidth {
                return override
            }
            if let locked = lockedRightWidth {
                return locked
            }
            let proportionalWidth = availableContentWidth * rightRatio
            if isCompress && totalWidth < 1000 {
                return min(proportionalWidth, 280.0)
            }
            return proportionalWidth
        }()
        
        let effectiveRightWidth: CGFloat = {
            guard shouldShowRight && maxRightAllowedByWorkspace >= minRightSidebarWidth else { return 0 }
            if let _ = overrideRightWidth {
                return rubberBandClampRightSidebar(
                    offset: preferredRightWidth,
                    minWidth: minRightSidebarWidth,
                    maxWidth: effectiveMaxRightWidth
                )
            }
            return min(max(preferredRightWidth, minRightSidebarWidth), effectiveMaxRightWidth)
        }()
        
        let centerWorkspaceWidth = max(0, availableContentWidth - effectiveRightWidth)
        let centerWidth = isMediaFocus ? totalWidth : centerWorkspaceWidth
        let shouldShowSearch = !isMediaFocus && viewModel.navigationState.activeTab == .home
        let omnibarMaxWidth = min(480.0, max(220.0, totalWidth - 280.0))
        
        let margin: CGFloat = {
            guard let win = NSApplication.shared.windows.first(where: { $0.isKeyWindow || $0.isVisible }) else { return 78.0 }
            if win.styleMask.contains(.fullScreen) { return 12.0 }
            guard let zb = win.standardWindowButton(.zoomButton), let cb = win.standardWindowButton(.closeButton) else { return 78.0 }
            let trailing = max(zb.frame.maxX, cb.frame.maxX)
            let originX = zb.superview?.frame.origin.x ?? 0
            return max(originX + trailing + 14.0, 68.0)
        }()
        
        return MainLayoutMetrics(
            shouldShowLeft: shouldShowLeft,
            shouldShowRight: shouldShowRight,
            availableContentWidth: availableContentWidth,
            effectiveRightWidth: effectiveRightWidth,
            effectiveMaxRightWidth: effectiveMaxRightWidth,
            minRightSidebarWidth: minRightSidebarWidth,
            centerWidth: centerWidth,
            shouldShowSearch: shouldShowSearch,
            omnibarMaxWidth: omnibarMaxWidth,
            goldenLineBottomY: TTZipTheme.Layout.headerBarHeight,
            trafficLightMargin: margin
        )
    }
}
