// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import AppKit
@preconcurrency import PDFKit
import TTKitDesign

// MARK: - PDF Stage Timing Telemetry (Feedback 9 PDF Portion)

/// Structured stage timing metrics for a single PDF preview load generation.
/// - `loadReadyStageMs` records when background I/O + `PDFDocument` parsing finishes and state is ready to apply.
/// - `firstFrameStageMs` remains `nil` (unmeasured) until a reliable on-screen display observation explicitly records it.
public struct PDFPreviewStageMetrics: Equatable, Sendable {
    public let generation: UInt64
    public let identityKey: String
    public let loadStageMs: Double
    public let parseStageMs: Double
    public let loadReadyStageMs: Double
    public var firstFrameStageMs: Double?
    public var thumbnailStageMs: Double?
    public let wasCacheHit: Bool

    public init(
        generation: UInt64,
        identityKey: String,
        loadStageMs: Double,
        parseStageMs: Double,
        loadReadyStageMs: Double? = nil,
        firstFrameStageMs: Double? = nil,
        thumbnailStageMs: Double? = nil,
        wasCacheHit: Bool = false
    ) {
        let clampedLoad = max(0, loadStageMs)
        let clampedParse = max(0, parseStageMs)
        self.generation = generation
        self.identityKey = identityKey
        self.loadStageMs = clampedLoad
        self.parseStageMs = clampedParse
        self.loadReadyStageMs = max(clampedLoad + clampedParse, loadReadyStageMs ?? (clampedLoad + clampedParse))
        self.firstFrameStageMs = firstFrameStageMs.map { max(0, $0) }
        self.thumbnailStageMs = thumbnailStageMs.map { max(0, $0) }
        self.wasCacheHit = wasCacheHit
    }

    public var totalLoadAndParseMs: Double {
        loadStageMs + parseStageMs
    }
}

// MARK: - Responsive Toolbar Width Tiers & Metrics (Feedback 7)

/// Width-driven responsive layout tier for the PDF bottom control bar.
public enum PDFToolbarLayoutTier: String, Equatable, Sendable, CaseIterable {
    /// Narrow inspector / sidebar (`< 420 pt`, e.g., `240–320 pt`).
    /// Collapses layout mode switcher into a single compact menu button and uses icon-only zoom fit.
    case compact
    /// Medium pane (`420 ..< 620 pt`).
    /// Displays segmented icon-only layout mode buttons alongside page and zoom controls.
    case regular
    /// Full window or wide preview (`>= 620 pt`).
    /// Displays full icon + single-line text labels for layout modes and zoom fit.
    case wide
}

/// Pure layout policy computing responsive PDF toolbar geometry from the container's available width.
public struct PDFToolbarLayoutMetrics: Equatable, Sendable {
    public static let compactMaxWidth: CGFloat = 420
    public static let regularMaxWidth: CGFloat = 620
    public static let barHeight: CGFloat = 36

    public let availableWidth: CGFloat
    public let tier: PDFToolbarLayoutTier

    public init(availableWidth: CGFloat) {
        let clamped = max(0, availableWidth)
        self.availableWidth = clamped
        if clamped < Self.compactMaxWidth {
            self.tier = .compact
        } else if clamped < Self.regularMaxWidth {
            self.tier = .regular
        } else {
            self.tier = .wide
        }
    }

    public var usesCompactLayoutMenu: Bool {
        tier == .compact
    }

    public var showsLayoutModeLabels: Bool {
        tier == .wide
    }

    public var showsZoomFitText: Bool {
        tier == .wide
    }

    public var horizontalPadding: CGFloat {
        switch tier {
        case .compact: return TTMediaTheme.Spacing.xs
        case .regular: return TTMediaTheme.Spacing.sm
        case .wide: return TTMediaTheme.Spacing.md
        }
    }

    public var sectionSpacing: CGFloat {
        switch tier {
        case .compact: return TTMediaTheme.Spacing.xxs
        case .regular: return TTMediaTheme.Spacing.xs
        case .wide: return TTMediaTheme.Spacing.sm
        }
    }
}

// MARK: - AppKit Inspection Probe for Window Layout Verification

public typealias PDFPreviewLayoutMode = PDFLayoutMode

extension PDFLayoutMode {
    public var iconName: String { icon }
}

/// AppKit probe view exposing live toolbar width tier, bar geometry, and page state for window tests.
public final class PDFToolbarStateProbeNSView: NSView {
    public var availableWidth: CGFloat = 0
    public var layoutTier: PDFToolbarLayoutTier = .wide
    public var layoutMode: PDFLayoutMode = .singleFullWidth
    public var currentPageOneBased: Int = 1
    public var totalPages: Int = 1
    public var barHeight: CGFloat = PDFToolbarLayoutMetrics.barHeight
}

struct PDFToolbarStateProbeRepresentable: NSViewRepresentable {
    let metrics: PDFToolbarLayoutMetrics
    let layoutMode: PDFPreviewLayoutMode
    let currentPageOneBased: Int
    let totalPages: Int

    func makeNSView(context: Context) -> PDFToolbarStateProbeNSView {
        let view = PDFToolbarStateProbeNSView(frame: .zero)
        sync(view)
        return view
    }

    func updateNSView(_ nsView: PDFToolbarStateProbeNSView, context: Context) {
        sync(nsView)
    }

    private func sync(_ nsView: PDFToolbarStateProbeNSView) {
        nsView.availableWidth = metrics.availableWidth
        nsView.layoutTier = metrics.tier
        nsView.layoutMode = layoutMode
        nsView.currentPageOneBased = currentPageOneBased
        nsView.totalPages = totalPages
        nsView.barHeight = PDFToolbarLayoutMetrics.barHeight
    }
}

// MARK: - Non-Overlapping Adaptive PDF Bottom Toolbar

/// Dedicated non-overlapping bottom toolbar for `InteractivePDFPreviewContainerView`.
/// Adapts across `.compact`, `.regular`, and `.wide` width tiers without multiline text wrapping
/// or occluding PDF page content.
public struct PDFAdaptiveToolbarView: View {
    public let metrics: PDFToolbarLayoutMetrics
    public let currentPageOneBased: Int
    public let totalPages: Int
    public let canGoPrevious: Bool
    public let canGoNext: Bool
    public let layoutMode: PDFPreviewLayoutMode
    public let onPreviousPage: () -> Void
    public let onNextPage: () -> Void
    public let onZoomOut: () -> Void
    public let onZoomFit: () -> Void
    public let onZoomIn: () -> Void
    public let onSelectLayoutMode: (PDFPreviewLayoutMode) -> Void

    public init(
        metrics: PDFToolbarLayoutMetrics,
        currentPageOneBased: Int,
        totalPages: Int,
        canGoPrevious: Bool,
        canGoNext: Bool,
        layoutMode: PDFPreviewLayoutMode,
        onPreviousPage: @escaping () -> Void,
        onNextPage: @escaping () -> Void,
        onZoomOut: @escaping () -> Void,
        onZoomFit: @escaping () -> Void,
        onZoomIn: @escaping () -> Void,
        onSelectLayoutMode: @escaping (PDFPreviewLayoutMode) -> Void
    ) {
        self.metrics = metrics
        self.currentPageOneBased = max(1, currentPageOneBased)
        self.totalPages = max(1, totalPages)
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.layoutMode = layoutMode
        self.onPreviousPage = onPreviousPage
        self.onNextPage = onNextPage
        self.onZoomOut = onZoomOut
        self.onZoomFit = onZoomFit
        self.onZoomIn = onZoomIn
        self.onSelectLayoutMode = onSelectLayoutMode
    }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(TTMediaTheme.Border.subtle)
                .frame(height: 0.5)

            HStack(spacing: metrics.sectionSpacing) {
                pageNavigationGroup
                toolbarDivider
                zoomControlGroup
                Spacer(minLength: TTMediaTheme.Spacing.xxs)
                toolbarDivider
                layoutModeControlGroup
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: PDFToolbarLayoutMetrics.barHeight)
            .background(.ultraThinMaterial)
            .background(
                PDFToolbarStateProbeRepresentable(
                    metrics: metrics,
                    layoutMode: layoutMode,
                    currentPageOneBased: currentPageOneBased,
                    totalPages: totalPages
                )
                .frame(width: 0, height: 0)
            )
        }
        .animation(TTMediaTheme.Motion.micro, value: metrics.tier)
        .animation(TTMediaTheme.Motion.micro, value: layoutMode)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(TTMediaTheme.Border.subtle)
            .frame(width: 0.5, height: 14)
    }

    private var pageNavigationGroup: some View {
        HStack(spacing: TTMediaTheme.Spacing.xxs) {
            Button(action: onPreviousPage) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoPrevious)
            .opacity(canGoPrevious ? 1.0 : 0.35)
            .ttButtonHelp(PDFPreviewLocalization.text(.previousPage))

            Text(PDFPreviewLocalization.pageIndicator(currentOneBased: currentPageOneBased, total: totalPages))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, TTMediaTheme.Spacing.xxs)

            Button(action: onNextPage) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNext)
            .opacity(canGoNext ? 1.0 : 0.35)
            .ttButtonHelp(PDFPreviewLocalization.text(.nextPage))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var zoomControlGroup: some View {
        HStack(spacing: TTMediaTheme.Spacing.xxs) {
            Button(action: onZoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ttButtonHelp(PDFPreviewLocalization.text(.zoomOut))

            Button(action: onZoomFit) {
                HStack(spacing: TTMediaTheme.Spacing.xxs) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                    if metrics.showsZoomFitText {
                        Text(PDFPreviewLocalization.text(.zoomFit))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, metrics.showsZoomFitText ? TTMediaTheme.Spacing.xs : 4)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous)
                        .strokeBorder(TTMediaTheme.Border.subtle, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .ttButtonHelp(PDFPreviewLocalization.text(.zoomFit))

            Button(action: onZoomIn) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ttButtonHelp(PDFPreviewLocalization.text(.zoomIn))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var layoutModeControlGroup: some View {
        if metrics.usesCompactLayoutMenu {
            Menu {
                ForEach(PDFPreviewLayoutMode.allCases, id: \.self) { mode in
                    Button {
                        onSelectLayoutMode(mode)
                    } label: {
                        Label(mode.localizedTitle, systemImage: mode.iconName)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: layoutMode.iconName)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, TTMediaTheme.Spacing.xs)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous)
                        .strokeBorder(TTMediaTheme.Border.subtle, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .ttButtonHelp(layoutMode.localizedTitle)
        } else {
            HStack(spacing: TTMediaTheme.Spacing.xxs) {
                ForEach(PDFPreviewLayoutMode.allCases, id: \.self) { mode in
                    layoutModeButton(for: mode)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func layoutModeButton(for mode: PDFPreviewLayoutMode) -> some View {
        let isSelected = (layoutMode == mode)
        return Button {
            onSelectLayoutMode(mode)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 11, weight: .semibold))
                if metrics.showsLayoutModeLabels {
                    Text(mode.localizedTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, metrics.showsLayoutModeLabels ? TTMediaTheme.Spacing.xs : 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .ttButtonHelp(mode.localizedTitle)
    }
}
