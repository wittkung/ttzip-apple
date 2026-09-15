// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipUI
import TTZipCore

/// Dedicated interactive breadcrumb path capsule for workspace navigation.
///
/// Features segmented path navigation with micro-glow hover states, photonic crisp white text,
/// and smooth horizontal scrolling for deeply nested directory hierarchies.
public struct SegmentedBreadcrumbCapsuleView: View {
    public var viewModel: AppViewState
    @State private var hoveredCrumbID: String? = nil
    @State private var isHoveringCapsule: Bool = false

    private let capsuleHeight: CGFloat = 30.0

    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Leading folder indicator icon
            Image(systemName: rootIconName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
                .padding(.leading, 8)

            // Interactive horizontal breadcrumb segment list
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    let crumbs = buildBreadcrumbs()
                    ForEach(crumbs) { crumb in
                        breadcrumbSegment(for: crumb)

                        if !crumb.isCurrent {
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            }
        }
        .frame(height: capsuleHeight)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(nsColor: .controlBackgroundColor).opacity(isHoveringCapsule ? 0.65 : 0.5)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isHoveringCapsule ? Color.white.opacity(0.2) : Color.white.opacity(0.1),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHoveringCapsule = hovering
            }
        }
    }

    // MARK: - Breadcrumb Segment

    private func breadcrumbSegment(for crumb: BreadcrumbSegment) -> some View {
        Button {
            viewModel.currentDirectory = crumb.url
            if viewModel.selectedDiskItem?.path != crumb.url.path {
                viewModel.selectedDiskItem = nil
            }
        } label: {
            HStack(spacing: 3.5) {
                if let icon = crumb.iconName {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: crumb.isCurrent ? .semibold : .medium))
                        .foregroundStyle(crumb.isCurrent ? Color.white : Color.white.opacity(0.75))
                }

                Text(crumb.name)
                    .font(.system(size: 11.5, weight: crumb.isCurrent ? .semibold : .regular))
                    .foregroundStyle(crumb.isCurrent ? Color.white : Color.white.opacity(0.85))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        hoveredCrumbID == crumb.id
                            ? Color.white.opacity(0.08)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredCrumbID = hovering ? crumb.id : nil
        }
    }

    // MARK: - Icon & Breadcrumb Computation

    private var rootIconName: String {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let current = effectiveActiveDirectory
        if current.path == homeURL.path || current.path.hasPrefix(homeURL.path) {
            return "folder.fill"
        }
        return "internaldrive"
    }

    private var effectiveActiveDirectory: URL {
        if let selected = viewModel.selectedDiskItem {
            let itemURL: URL
            if let u = URL(string: selected.path), u.scheme != nil {
                itemURL = u.standardizedFileURL
            } else {
                itemURL = URL(fileURLWithPath: selected.path).standardizedFileURL
            }
            if selected.isDirectory {
                return itemURL
            } else {
                return itemURL.deletingLastPathComponent().standardizedFileURL
            }
        }
        return viewModel.currentDirectory.standardizedFileURL
    }

    private func buildBreadcrumbs() -> [BreadcrumbSegment] {
        var items: [BreadcrumbSegment] = []
        let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let current = effectiveActiveDirectory

        if current.path == "/" {
            items.append(BreadcrumbSegment(
                id: "/",
                name: FileManager.default.displayName(atPath: "/"),
                iconName: "internaldrive",
                url: URL(fileURLWithPath: "/"),
                isCurrent: true
            ))
            return items
        }

        if current.path == homeURL.path {
            items.append(BreadcrumbSegment(
                id: homeURL.path,
                name: "~",
                iconName: "house.fill",
                url: homeURL,
                isCurrent: true
            ))
            return items
        }

        if current.path.hasPrefix(homeURL.path) {
            items.append(BreadcrumbSegment(
                id: homeURL.path,
                name: "~",
                iconName: "house.fill",
                url: homeURL,
                isCurrent: false
            ))
            let relativePath = String(current.path.dropFirst(homeURL.path.count))
            let segments = relativePath.split(separator: "/").map(String.init)
            var cumulative = homeURL
            for (idx, seg) in segments.enumerated() {
                cumulative.appendPathComponent(seg)
                let isLast = (idx == segments.count - 1)
                items.append(BreadcrumbSegment(
                    id: cumulative.path,
                    name: FileManager.default.displayName(atPath: cumulative.path),
                    iconName: nil,
                    url: cumulative,
                    isCurrent: isLast
                ))
            }
        } else {
            items.append(BreadcrumbSegment(
                id: "/",
                name: FileManager.default.displayName(atPath: "/"),
                iconName: "internaldrive",
                url: URL(fileURLWithPath: "/"),
                isCurrent: false
            ))
            let segments = current.path.split(separator: "/").map(String.init)
            var cumulative = URL(fileURLWithPath: "/")
            for (idx, seg) in segments.enumerated() {
                cumulative.appendPathComponent(seg)
                let isLast = (idx == segments.count - 1)
                items.append(BreadcrumbSegment(
                    id: cumulative.path,
                    name: FileManager.default.displayName(atPath: cumulative.path),
                    iconName: nil,
                    url: cumulative,
                    isCurrent: isLast
                ))
            }
        }

        return items
    }
}

// MARK: - Breadcrumb Data Segment

public struct BreadcrumbSegment: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let iconName: String?
    public let url: URL
    public let isCurrent: Bool

    public init(id: String, name: String, iconName: String?, url: URL, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.url = url
        self.isCurrent = isCurrent
    }
}
