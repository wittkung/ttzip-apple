// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import SwiftUI
import TTMediaKit
import TTZipUI

/// Width-driven responsive layout tier for the PDF bottom control bar.
enum PDFToolbarLayoutTier: String, Equatable, Sendable, CaseIterable {
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
struct PDFToolbarLayoutMetrics: Equatable, Sendable {
    static let ultraCompactMaxWidth: CGFloat = 240
    static let compactMaxWidth: CGFloat = 420
    static let regularMaxWidth: CGFloat = 620
    static let barHeight: CGFloat = 36

    let availableWidth: CGFloat
    let reservedTrailingWidth: CGFloat
    let tier: PDFToolbarLayoutTier

    var effectiveAvailableWidth: CGFloat {
        max(0, availableWidth - reservedTrailingWidth)
    }

    init(availableWidth: CGFloat, reservedTrailingWidth: CGFloat = 0) {
        let clamped = max(0, availableWidth)
        let clampedReserved = max(0, reservedTrailingWidth)
        self.availableWidth = clamped
        self.reservedTrailingWidth = clampedReserved
        let effective = max(0, clamped - clampedReserved)
        if effective < Self.compactMaxWidth {
            self.tier = .compact
        } else if effective < Self.regularMaxWidth {
            self.tier = .regular
        } else {
            self.tier = .wide
        }
    }

    var usesCompactZoomMenu: Bool {
        effectiveAvailableWidth < Self.ultraCompactMaxWidth
    }

    var usesCompactLayoutMenu: Bool {
        tier == .compact
    }

    var showsLayoutModeLabels: Bool {
        tier == .wide
    }

    var showsZoomFitText: Bool {
        tier == .wide
    }

    var horizontalPadding: CGFloat {
        switch tier {
        case .compact: return TTZipTheme.Spacing.xs
        case .regular: return TTZipTheme.Spacing.sm
        case .wide: return TTZipTheme.Spacing.md
        }
    }

    var sectionSpacing: CGFloat {
        switch tier {
        case .compact: return TTZipTheme.Spacing.xxs
        case .regular: return TTZipTheme.Spacing.xs
        case .wide: return TTZipTheme.Spacing.sm
        }
    }
}

struct TTZipPDFToolbar: View {
    struct Pagination {
        let currentIndex: Int
        let totalPages: Int
        let canNavigate: Bool

        var currentPageOneBased: Int { min(max(1, currentIndex + 1), displayPageCount) }
        var displayPageCount: Int { max(1, totalPages) }
        var canGoPrevious: Bool { canNavigate && currentIndex > 0 }
        var canGoNext: Bool { canNavigate && currentIndex + 1 < totalPages }
    }

    enum Action {
        case previousPage
        case nextPage
        case zoomOut
        case zoomFit
        case zoomIn
        case selectLayout(PDFLayoutMode)
    }

    @Environment(\.previewBottomTrailingReservedWidth) private var bottomTrailingReservedWidth
    let metrics: PDFToolbarLayoutMetrics
    let pagination: Pagination
    let layoutMode: PDFLayoutMode
    let onAction: (Action) -> Void

    private var effectiveMetrics: PDFToolbarLayoutMetrics {
        let totalReserved = max(metrics.reservedTrailingWidth, bottomTrailingReservedWidth)
        guard totalReserved != metrics.reservedTrailingWidth else {
            return metrics
        }
        return PDFToolbarLayoutMetrics(
            availableWidth: metrics.availableWidth,
            reservedTrailingWidth: totalReserved
        )
    }

    var body: some View {
        let activeMetrics = effectiveMetrics
        let leadingPad: CGFloat = activeMetrics.usesCompactZoomMenu ? 4 : activeMetrics.horizontalPadding
        let trailingBase: CGFloat = bottomTrailingReservedWidth > 0
            ? (activeMetrics.usesCompactZoomMenu ? 4 : max(activeMetrics.horizontalPadding, 12))
            : activeMetrics.horizontalPadding
        return VStack(spacing: 0) {
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: TTZipTheme.Layout.hairlineBorderWidth)

            HStack(spacing: activeMetrics.usesCompactZoomMenu ? 2 : activeMetrics.sectionSpacing) {
                pageNavigationGroup(activeMetrics)
                toolbarDivider
                zoomControlGroup(activeMetrics)
                Spacer(minLength: activeMetrics.usesCompactZoomMenu ? 2 : TTZipTheme.Spacing.xxs)
                toolbarDivider
                layoutModeControlGroup(activeMetrics)
            }
            .padding(.leading, leadingPad)
            .padding(.trailing, trailingBase + bottomTrailingReservedWidth)
            .frame(maxWidth: .infinity)
            .frame(height: PDFToolbarLayoutMetrics.barHeight)
            .background(.ultraThinMaterial)
            .background(
                TTZipPDFToolbarStateProbe(
                    metrics: activeMetrics,
                    layoutMode: layoutMode,
                    currentPageOneBased: pagination.currentPageOneBased,
                    totalPages: pagination.displayPageCount
                )
                .frame(width: 0, height: 0)
            )
        }
        .animation(TTZipTheme.Motion.micro, value: activeMetrics.tier)
        .animation(TTZipTheme.Motion.micro, value: layoutMode)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(TTZipTheme.hairlineBorder)
            .frame(width: TTZipTheme.Layout.hairlineBorderWidth, height: 14)
    }

    private func pageNavigationGroup(_ activeMetrics: PDFToolbarLayoutMetrics) -> some View {
        let buttonWidth: CGFloat = activeMetrics.usesCompactZoomMenu ? 18 : 22
        let indicatorText = activeMetrics.usesCompactZoomMenu
            ? "\(pagination.currentPageOneBased)/\(pagination.displayPageCount)"
            : TTZipPDFPreviewLocalization.pageIndicator(currentOneBased: pagination.currentPageOneBased, total: pagination.displayPageCount)
        return HStack(spacing: activeMetrics.usesCompactZoomMenu ? 2 : TTZipTheme.Spacing.xxs) {
            Button(action: { onAction(.previousPage) }) {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .frame(width: buttonWidth, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!pagination.canGoPrevious)
            .opacity(pagination.canGoPrevious ? 1.0 : 0.35)
            .ttButtonHelp(TTZipPDFPreviewLocalization.text(.previousPage))

            Text(indicatorText)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, activeMetrics.usesCompactZoomMenu ? 2 : TTZipTheme.Spacing.xxs)

            Button(action: { onAction(.nextPage) }) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: buttonWidth, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!pagination.canGoNext)
            .opacity(pagination.canGoNext ? 1.0 : 0.35)
            .ttButtonHelp(TTZipPDFPreviewLocalization.text(.nextPage))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func zoomControlGroup(_ activeMetrics: PDFToolbarLayoutMetrics) -> some View {
        if activeMetrics.usesCompactZoomMenu {
            Menu {
                Button(action: { onAction(.zoomOut) }) {
                    Label(TTZipPDFPreviewLocalization.text(.zoomOut), systemImage: "minus.magnifyingglass")
                }
                Button(action: { onAction(.zoomFit) }) {
                    Label(TTZipPDFPreviewLocalization.text(.zoomFit), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button(action: { onAction(.zoomIn) }) {
                    Label(TTZipPDFPreviewLocalization.text(.zoomIn), systemImage: "plus.magnifyingglass")
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 4)
                    .frame(height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .ttButtonHelp(TTZipPDFPreviewLocalization.text(.zoomFit))
        } else {
            HStack(spacing: TTZipTheme.Spacing.xxs) {
                Button(action: { onAction(.zoomOut) }) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ttButtonHelp(TTZipPDFPreviewLocalization.text(.zoomOut))

                Button(action: { onAction(.zoomFit) }) {
                    HStack(spacing: TTZipTheme.Spacing.xxs) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.semibold))
                        if activeMetrics.showsZoomFitText {
                            Text(TTZipPDFPreviewLocalization.text(.zoomFit))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.horizontal, activeMetrics.showsZoomFitText ? TTZipTheme.Spacing.xs : 4)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                            .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: TTZipTheme.Layout.hairlineBorderWidth)
                    )
                }
                .buttonStyle(.plain)
                .ttButtonHelp(TTZipPDFPreviewLocalization.text(.zoomFit))

                Button(action: { onAction(.zoomIn) }) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ttButtonHelp(TTZipPDFPreviewLocalization.text(.zoomIn))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func layoutModeControlGroup(_ activeMetrics: PDFToolbarLayoutMetrics) -> some View {
        if activeMetrics.usesCompactLayoutMenu {
            Menu {
                ForEach(PDFLayoutMode.allCases, id: \.self) { mode in
                    Button {
                        onAction(.selectLayout(mode))
                    } label: {
                        Label(mode.localizedTitle, systemImage: mode.icon)
                    }
                }
            } label: {
                HStack(spacing: activeMetrics.usesCompactZoomMenu ? 2 : 4) {
                    Image(systemName: layoutMode.icon)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, activeMetrics.usesCompactZoomMenu ? 4 : TTZipTheme.Spacing.xs)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                        .fill(TTZipTheme.accentColor.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                        .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: TTZipTheme.Layout.hairlineBorderWidth)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .ttButtonHelp(layoutMode.localizedTitle)
        } else {
            HStack(spacing: TTZipTheme.Spacing.xxs) {
                ForEach(PDFLayoutMode.allCases, id: \.self) { mode in
                    layoutModeButton(for: mode, activeMetrics: activeMetrics)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func layoutModeButton(for mode: PDFLayoutMode, activeMetrics: PDFToolbarLayoutMetrics) -> some View {
        let isSelected = (layoutMode == mode)
        return Button {
            onAction(.selectLayout(mode))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.caption.weight(.semibold))
                if activeMetrics.showsLayoutModeLabels {
                    Text(mode.localizedTitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, activeMetrics.showsLayoutModeLabels ? TTZipTheme.Spacing.xs : 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                    .fill(isSelected ? TTZipTheme.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .ttButtonHelp(mode.localizedTitle)
    }
}

/// AppKit probe view exposing live toolbar width tier, bar geometry, and page state for window tests.
final class PDFToolbarStateProbeNSView: NSView {
    var availableWidth: CGFloat = 0
    var layoutTier: PDFToolbarLayoutTier = .wide
    var layoutMode: PDFLayoutMode = .singleFullWidth
    var currentPageOneBased: Int = 1
    var totalPages: Int = 1
    var barHeight: CGFloat = PDFToolbarLayoutMetrics.barHeight
}

private struct TTZipPDFToolbarStateProbe: NSViewRepresentable {
    let metrics: PDFToolbarLayoutMetrics
    let layoutMode: PDFLayoutMode
    let currentPageOneBased: Int
    let totalPages: Int

    func makeNSView(context: Context) -> PDFToolbarStateProbeNSView {
        let view = PDFToolbarStateProbeNSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("TTZipPDFToolbar")
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
