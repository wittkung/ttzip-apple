// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitCore
import TTKitDesign

// MARK: - Bulk Drag Stacking Tiers

/// Three-tier adaptive aggregation architecture for bulk dragging.
/// Prevents WindowServer and pasteboard daemon IPC lockups when dragging massive file sets.
public enum BulkDragTier: Int, Sendable, Comparable, CaseIterable {
    /// Level 1 (N <= 100): Direct individual file promise array.
    case direct = 1
    /// Level 2 (100 < N <= 2,000): Aggregated bulk drag proxy with 3-card stack and count badge.
    case aggregated = 2
    /// Level 3 (N > 2,000): Desktop Spill Guard active; auto-bundled into temporary container.
    case spillGuarded = 3

    public static func < (lhs: BulkDragTier, rhs: BulkDragTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Resolves the appropriate drag tier for an arbitrary item count.
    public static func tier(forCount count: Int) -> BulkDragTier {
        if count <= 100 {
            return .direct
        } else if count <= 2000 {
            return .aggregated
        } else {
            return .spillGuarded
        }
    }
}

// MARK: - Drag Item Model

/// Metadata representing an item within a bulk drag gesture.
public struct BulkDragItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let fileExtension: String
    public let byteSize: Int64
    public let iconSystemName: String
    public let isDirectory: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        fileExtension: String = "",
        byteSize: Int64 = 0,
        iconSystemName: String = "doc.fill",
        isDirectory: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension.isEmpty ? (name as NSString).pathExtension : fileExtension
        self.byteSize = byteSize
        self.iconSystemName = iconSystemName
        self.isDirectory = isDirectory
    }

    /// Formatted human-readable file size.
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

// MARK: - Drag Payload Aggregate

/// Aggregate model representing a bulk drag transaction.
public struct BulkDragPayload: Sendable, Hashable {
    public let items: [BulkDragItem]
    public let totalItemCount: Int
    public let totalByteSize: Int64

    public var tier: BulkDragTier {
        BulkDragTier.tier(forCount: totalItemCount)
    }

    public init(items: [BulkDragItem], totalItemCount: Int? = nil, totalByteSize: Int64? = nil) {
        self.items = items
        let resolvedCount = totalItemCount ?? items.count
        self.totalItemCount = resolvedCount
        self.totalByteSize = totalByteSize ?? items.reduce(0) { $0 + $1.byteSize }
    }

    /// Formatted localized item count badge label (e.g. "1,420 items").
    public var formattedCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let countString = formatter.string(from: NSNumber(value: totalItemCount)) ?? "\(totalItemCount)"
        return totalItemCount == 1 ? "1 item" : "\(countString) items"
    }

    /// Formatted total byte size.
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalByteSize, countStyle: .file)
    }
}

// MARK: - Drag Thumbnail Anchor

/// Anchor coordinate configuration for system drag visuals.
public struct BulkDragThumbnailAnchor: Sendable, Hashable {
    public let anchorPoint: CGPoint
    public let visualOffset: CGSize

    public init(
        anchorPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        visualOffset: CGSize = .zero
    ) {
        self.anchorPoint = anchorPoint
        self.visualOffset = visualOffset
    }

    public static let standardCenter = BulkDragThumbnailAnchor()
    public static let cursorOffset = BulkDragThumbnailAnchor(
        anchorPoint: CGPoint(x: 0.2, y: 0.2),
        visualOffset: CGSize(width: 8, height: 8)
    )
}

// MARK: - Cascaded Floating Stack Card View

/// Individual card inside the 3-tier bulk drag stack.
@MainActor
public struct BulkDragCardView: View {
    public let item: BulkDragItem
    public let cardIndex: Int

    public init(item: BulkDragItem, cardIndex: Int) {
        self.item = item
        self.cardIndex = cardIndex
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconSystemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.isDirectory ? TTKitTheme.archivalAmber : TTKitTheme.bambooGreen)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                if item.byteSize > 0 {
                    Text(item.formattedSize)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 170, height: 42)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: UniversalTokens.Dimensions.hairlineWidth
                )
        }
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
    }
}

// MARK: - Cascaded Floating Stack Preview (Max 3 Cards)

/// Cascaded floating stack preview rendering at most 3 layered item cards.
/// Strictly enforces Axiom IV: Max 3 Stacking Layers.
@MainActor
public struct BulkDragStackView: View {
    public let previewItems: [BulkDragItem]

    public init(items: [BulkDragItem]) {
        self.previewItems = Array(items.prefix(3))
    }

    public var body: some View {
        ZStack {
            if previewItems.count >= 3 {
                // Layer 3: Bottom card (slight positive rotation and offset)
                BulkDragCardView(item: previewItems[2], cardIndex: 2)
                    .rotationEffect(.degrees(4.0))
                    .offset(x: 8, y: 6)
                    .opacity(0.70)
            }

            if previewItems.count >= 2 {
                // Layer 2: Middle card (slight negative rotation and offset)
                BulkDragCardView(item: previewItems[1], cardIndex: 1)
                    .rotationEffect(.degrees(-3.5))
                    .offset(x: 4, y: 3)
                    .opacity(0.85)
            }

            if let topItem = previewItems.first {
                // Layer 1: Top card (aligned, primary focus)
                BulkDragCardView(item: topItem, cardIndex: 0)
                    .rotationEffect(.zero)
                    .offset(x: 0, y: 0)
                    .opacity(1.0)
            }
        }
        .frame(width: 190, height: 56)
    }
}

// MARK: - Compact Badge Count View

/// High-contrast pill badge displaying total item count and aggregation status.
@MainActor
public struct BulkDragBadgeView: View {
    public let formattedCount: String
    public let tier: BulkDragTier

    public init(formattedCount: String, tier: BulkDragTier) {
        self.formattedCount = formattedCount
        self.tier = tier
    }

    private var accentColor: Color {
        switch tier {
        case .direct:
            return TTKitTheme.bambooGreen
        case .aggregated:
            return TTKitTheme.archivalAmber
        case .spillGuarded:
            return TTKitTheme.cinnabarRed
        }
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)

            Text(formattedCount)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .fill(accentColor.opacity(0.12))
                )
        }
        .overlay {
            Capsule()
                .strokeBorder(accentColor.opacity(0.40), lineWidth: UniversalTokens.Dimensions.hairlineWidth)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Desktop Spill Guard Banner

/// Alert indicator informing user that large payloads have been bundled into a folder.
@MainActor
public struct DesktopSpillGuardBanner: View {
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TTKitTheme.archivalAmber)

            Text("Desktop Spill Guard: Auto-bundled into container")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            TTKitTheme.archivalAmber.opacity(0.35),
                            lineWidth: UniversalTokens.Dimensions.hairlineWidth
                        )
                )
        }
    }
}

// MARK: - Complete Bulk Drag Representation

/// Complete composite 3-tier bulk drag visual representation.
@MainActor
public struct BulkDragRepresentationView: View {
    public let payload: BulkDragPayload
    public let anchor: BulkDragThumbnailAnchor

    public init(
        payload: BulkDragPayload,
        anchor: BulkDragThumbnailAnchor = .standardCenter
    ) {
        self.payload = payload
        self.anchor = anchor
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                BulkDragStackView(items: payload.items)

                // Item count badge anchored to top-right
                BulkDragBadgeView(
                    formattedCount: payload.formattedCount,
                    tier: payload.tier
                )
                .offset(x: 10, y: -8)
            }

            if payload.tier == .spillGuarded {
                DesktopSpillGuardBanner()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .offset(anchor.visualOffset)
    }
}
