// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit

private enum InspectorHeaderActionMenuMetrics {
    static let accessibilityID = "InspectorHeaderActionsMenu"
    static let controlSize: ControlSize = .regular
    static let labelFrameSize: CGFloat = 28
    static let symbolPointSize: CGFloat = 13
}

struct InspectorHeaderActionMenu<MenuItems: View>: View {
    let accessibilityLabelText: String
    private let items: MenuItems

    init(
        accessibilityLabelText: String,
        @ViewBuilder items: () -> MenuItems
    ) {
        self.accessibilityLabelText = accessibilityLabelText
        self.items = items()
    }

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: InspectorHeaderActionMenuMetrics.symbolPointSize))
                .foregroundStyle(Color.secondary)
                .frame(
                    width: InspectorHeaderActionMenuMetrics.labelFrameSize,
                    height: InspectorHeaderActionMenuMetrics.labelFrameSize
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .controlSize(InspectorHeaderActionMenuMetrics.controlSize)
        .l10nHelp(L10n.Inspector.itemActionsHelp)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityIdentifier(InspectorHeaderActionMenuMetrics.accessibilityID)
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension RightInspectorSidePanel {
    public static func isVirtualArchiveEntry(_ item: DiskItemInfo) -> Bool {
        guard let url = URL(string: item.path), let query = url.query else {
            return item.path.contains("?subpath=")
        }
        return query.contains("subpath=")
    }

    public static func finderRevealTargetPath(
        for item: DiskItemInfo,
        activeArchivePath: String? = nil
    ) -> String {
        if isVirtualArchiveEntry(item) {
            if let url = URL(string: item.path), !url.path.isEmpty {
                return url.path
            }
            if let activeArchivePath, !activeArchivePath.isEmpty {
                return activeArchivePath
            }
        }
        if item.path.hasPrefix("file://"), let parsed = URL(string: item.path), parsed.isFileURL {
            return parsed.path
        }
        return item.path
    }

    func headerActionMenu(for item: DiskItemInfo) -> some View {
        let isVirtualEntry = Self.isVirtualArchiveEntry(item)
        let revealTargetPath = Self.finderRevealTargetPath(
            for: item,
            activeArchivePath: activeArchivePath
        )

        return InspectorHeaderActionMenu(
            accessibilityLabelText: l10n.t(L10n.Inspector.itemActionsHelp)
        ) {
            Button(action: {
                onPreviewFile?(item)
            }) {
                Label(l10n.t(L10n.Inspector.quickLookShortcut), systemImage: "arrow.up.left.and.arrow.down.right")
            }

            Button(action: {
                onRevealInFinder?(revealTargetPath)
            }) {
                Label(l10n.t(L10n.Common.revealInFinder), systemImage: "folder")
            }

            Button(action: {
                copyPathToPasteboard(item.path)
            }) {
                Label(l10n.t(L10n.Common.copyPath), systemImage: "doc.on.doc")
            }

            if item.isArchive {
                Button(action: {
                    onInspectArchive?(item.path)
                }) {
                    Label(l10n.t(L10n.Diagnostics.title), systemImage: "doc.badge.gearshape")
                }
            }

            Divider()

            Button(role: .destructive, action: {
                guard !isVirtualEntry else { return }
                onMoveToTrash?(item.path)
            }) {
                Label(l10n.t(L10n.Menu.moveToTrash), systemImage: "trash")
            }
            .disabled(isVirtualEntry)
        }
    }

    /// Resolved title displayed in the 52pt directory header when mode is `.empty`.
    public var resolvedDirectoryHeaderTitle: String {
        guard let url = currentDirectoryURL else { return l10n.t(L10n.Inspector.title) }
        return TTZipPathPresentationService.shared.displayName(
            for: url,
            language: l10n.currentLanguage
        )
    }

    @ViewBuilder
    var directoryHeader: some View {
        let dirName = resolvedDirectoryHeaderTitle
        let iconName: String = {
            guard let url = currentDirectoryURL else { return "folder.fill" }
            return TTZipPathPresentationService.shared.icon(for: url.path, isDirectory: true)
        }()
        let fullPath = currentDirectoryURL?.path ?? ""

        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 28, height: 28)
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(dirName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .accessibilityIdentifier("InspectorHeaderTitle")

                Text(l10n.t(L10n.Explorer.folderShort))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("InspectorHeaderSubtitle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ttButtonHelp(fullPath)
            .contextMenu {
                if !fullPath.isEmpty {
                    Button {
                        copyPathToPasteboard(fullPath)
                    } label: {
                        Label(l10n.t(L10n.Common.copyPath), systemImage: "doc.on.doc")
                    }
                }
            }

            if !fullPath.isEmpty {
                InspectorHeaderActionMenu(
                    accessibilityLabelText: l10n.t(L10n.Inspector.itemActionsHelp)
                ) {
                    Button {
                        copyPathToPasteboard(fullPath)
                    } label: {
                        Label(l10n.t(L10n.Common.copyPath), systemImage: "doc.on.doc")
                    }

                    Button {
                        onRevealInFinder?(fullPath)
                    } label: {
                        Label(l10n.t(L10n.Common.revealInFinder), systemImage: "folder")
                    }

                    Button {
                        onCompressPath?(fullPath)
                    } label: {
                        Label(l10n.t(L10n.Compress.compressFolder), systemImage: "archivebox")
                    }
                }
            }
        }
    }

    func copyPathToPasteboard(_ path: String) {
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Visual Helpers

    func itemIconName(for item: DiskItemInfo) -> String {
        if item.isDirectory { return "folder.fill" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if let fmt = ArchiveCompressionFormat.from(extensionOrName: ext) {
            return fmt.iconName
        }
        if item.isArchive { return "archivebox.fill" }
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) { return "photo.fill" }
        if MediaPreviewFactory.videoExtensions.contains(ext) { return "film.fill" }
        if MediaPreviewFactory.audioExtensions.contains(ext) { return "music.note" }
        if ext == "pdf" { return "doc.richtext.fill" }
        if ["html", "htm", "xhtml", "mhtml"].contains(ext) { return "globe" }
        if ["swift", "js", "ts", "py", "json", "css", "cpp", "c", "h", "rs", "go", "sh", "xml"].contains(ext) { return "doc.text.fill" }
        return "doc.fill"
    }

    func itemIconGradient(for item: DiskItemInfo) -> LinearGradient {
        LinearGradient(
            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
