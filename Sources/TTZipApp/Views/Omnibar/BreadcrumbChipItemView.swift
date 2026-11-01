// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import AppKit
import TTZipCore
import TTZipUI

/// Breadcrumb segment model for file path hierarchy representation.
public struct BreadcrumbPathSegment: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let iconName: String?
    public let url: URL
    public let isCurrent: Bool
    
    public init(id: String, name: String, iconName: String? = nil, url: URL, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.url = url
        self.isCurrent = isCurrent
    }
}

/// Display item in the folded breadcrumb bar: either a direct segment or a collapsed middle-segments menu.
public enum BreadcrumbDisplayItem: Identifiable, Hashable, Sendable {
    case segment(BreadcrumbPathSegment)
    case collapsedMiddle([BreadcrumbPathSegment])

    public var id: String {
        switch self {
        case .segment(let seg):
            return seg.id
        case .collapsedMiddle(let segments):
            return "collapsed:" + segments.map(\.id).joined(separator: "|")
        }
    }
}

/// Deterministic middle-segment breadcrumb folding calculator.
/// Retains the Root entry and Current directory while collapsing intermediate segments into `…` when space is tight.
public enum BreadcrumbMiddleFolder {
    /// Estimates the horizontal pixel width of a single breadcrumb chip (including chevron separator).
    public static func estimatedWidth(for segment: BreadcrumbPathSegment) -> CGFloat {
        var textCost: CGFloat = 0
        for scalar in segment.name.unicodeScalars {
            textCost += (scalar.value > 0x7F) ? 12.2 : 7.4
        }
        let clampedText = min(max(textCost, 18.0), segment.isCurrent ? 190.0 : 120.0)
        let iconCost: CGFloat = (segment.iconName != nil) ? 15.0 : 0.0
        let chevronCost: CGFloat = segment.isCurrent ? 10.0 : 22.0
        return clampedText + iconCost + chevronCost + 8.0
    }

    /// Computes the ordered display items for a breadcrumb trail within `availableWidth`.
    public static func computeDisplayItems(
        segments: [BreadcrumbPathSegment],
        availableWidth: CGFloat
    ) -> [BreadcrumbDisplayItem] {
        guard segments.count >= 3 else {
            return segments.map { .segment($0) }
        }

        let effectiveBudget = max(availableWidth - 44.0, 88.0)
        let totalUnfoldedWidth = segments.reduce(CGFloat(0)) { $0 + estimatedWidth(for: $1) }
        if totalUnfoldedWidth <= effectiveBudget {
            return segments.map { .segment($0) }
        }

        let rootSegment = segments[0]
        let currentSegment = segments[segments.count - 1]
        let ellipsisChipWidth: CGFloat = 38.0
        // Root segment shrinks to icon-only (~36pt) when availableWidth < 240pt
        let rootEffectiveWidth: CGFloat = (availableWidth < 240.0) ? 36.0 : estimatedWidth(for: rootSegment)
        var usedWidth = rootEffectiveWidth + ellipsisChipWidth + estimatedWidth(for: currentSegment)

        var keptTailIndices: [Int] = []
        if segments.count > 2 {
            for idx in stride(from: segments.count - 2, through: 1, by: -1) {
                let w = estimatedWidth(for: segments[idx])
                if usedWidth + w <= effectiveBudget {
                    usedWidth += w
                    keptTailIndices.insert(idx, at: 0)
                } else {
                    break
                }
            }
        }

        let firstTailIdx = keptTailIndices.first ?? (segments.count - 1)
        if firstTailIdx <= 1 {
            return segments.map { .segment($0) }
        }

        let collapsed = Array(segments[1..<firstTailIdx])
        var result: [BreadcrumbDisplayItem] = [.segment(rootSegment), .collapsedMiddle(collapsed)]
        for idx in firstTailIdx..<segments.count {
            result.append(.segment(segments[idx]))
        }
        return result
    }
}

/// Interactive `…` chip exposing folded intermediate path segments in a dropdown menu.
public struct BreadcrumbCollapsedMenuChipView: View {
    public let collapsedSegments: [BreadcrumbPathSegment]
    public let onSelect: (URL) -> Void

    @State private var isHovered: Bool = false
    private var l10n = AppLocalizationState.shared

    public init(
        collapsedSegments: [BreadcrumbPathSegment],
        onSelect: @escaping (URL) -> Void
    ) {
        self.collapsedSegments = collapsedSegments
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 1) {
            Menu {
                ForEach(collapsedSegments) { seg in
                    Button {
                        onSelect(seg.url)
                    } label: {
                        Label(seg.name, systemImage: seg.iconName ?? "folder")
                    }
                }
            } label: {
                Text("…")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .onHover { isHovered = $0 }
            .ttButtonHelp(collapsedTooltip)
            .accessibilityLabel(l10n.uiString(zh: "展开中间路径层级", en: "Intermediate Folders"))
            .accessibilityIdentifier("BreadcrumbCollapsedEllipsisMenu")

            Image(systemName: "chevron.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(0.60))
                .frame(width: 12, height: 20)
        }
        .layoutPriority(8.0)
    }

    private var collapsedTooltip: String {
        collapsedSegments.map(\.name).joined(separator: " / ")
    }
}

/// Interactive breadcrumb chip providing direct navigation and subdirectory dropdown traversal.
public struct BreadcrumbChipItemView: View {
    public let segment: BreadcrumbPathSegment
    public let isRootSegment: Bool
    public let hideTitle: Bool
    public let onSelect: (URL) -> Void
    public let onSelectSubdirectory: (URL) -> Void
    
    @State private var isHovered: Bool = false
    @State private var subdirectories: [URL] = []
    
    public init(
        segment: BreadcrumbPathSegment,
        isRootSegment: Bool = false,
        hideTitle: Bool = false,
        onSelect: @escaping (URL) -> Void,
        onSelectSubdirectory: @escaping (URL) -> Void
    ) {
        self.segment = segment
        self.isRootSegment = isRootSegment
        self.hideTitle = hideTitle
        self.onSelect = onSelect
        self.onSelectSubdirectory = onSelectSubdirectory
    }
    
    public var body: some View {
        HStack(spacing: 1) {
            // 1. Chip Main Navigation Button
            Button {
                onSelect(segment.url)
            } label: {
                HStack(spacing: 3.5) {
                    if let icon = segment.iconName, (isRootSegment || segment.isCurrent) {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isRootSegment ? TTZipTheme.bambooGreen : (segment.isCurrent ? Color.primary.opacity(0.85) : Color.secondary))
                    }
                    if !hideTitle {
                        Text(segment.name)
                            .font(.system(size: 11.5, weight: segment.isCurrent ? .semibold : .medium))
                            .foregroundStyle(segment.isCurrent ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: !segment.isCurrent, vertical: false)
                    }
                }
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .layoutPriority(1.0)
            .onHover { isHovered = $0 }
            .onDrag { NSItemProvider(object: segment.url as NSURL) }
            .ttButtonHelp(segment.url.path)
            .accessibilityIdentifier(segment.isCurrent ? "BreadcrumbCurrentSegment" : (isRootSegment ? "BreadcrumbRootSegment" : "BreadcrumbSegment_\(segment.name)"))
            
            // 2. Subdirectories Dropdown Triangle (Windows Explorer Chevron Menu)
            if !segment.isCurrent {
                Menu {
                    if subdirectories.isEmpty {
                        Text(String(localized: "No Subfolders"))
                    } else {
                        ForEach(subdirectories, id: \.path) { subURL in
                            Button {
                                onSelectSubdirectory(subURL)
                            } label: {
                                let name = TTZipPathPresentationService.shared.displayName(
                                    for: subURL,
                                    language: AppLocalizationState.shared.currentLanguage
                                )
                                Label(name, systemImage: "folder")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.60))
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .ttButtonHelp(AppLocalizationState.shared.uiString(zh: "显示子文件夹", en: "Show Subfolders"))
                .onHover { hovering in
                    if hovering && subdirectories.isEmpty {
                        loadSubdirectories()
                    }
                }
            }
        }
        .fixedSize(horizontal: !segment.isCurrent, vertical: false)
        .layoutPriority(segment.isCurrent ? 10.0 : (isRootSegment ? 6.0 : 4.0))
    }
    
    private func loadSubdirectories() {
        let targetURL = segment.url
        Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return }
            
            let filtered = contents.filter { url in
                let res = try? url.resourceValues(forKeys: Set(keys))
                return (res?.isDirectory == true) && (res?.isPackage != true)
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            
            await MainActor.run {
                self.subdirectories = filtered
            }
        }
    }
}
