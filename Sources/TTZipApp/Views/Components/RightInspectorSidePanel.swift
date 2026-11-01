// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Right contextual Inspector side panel supporting Single, Multiple, Storage, and Empty modes.
/// Decoupled from monolithic AppViewState to bind strictly to InspectorSurfaceMode.
public struct RightInspectorSidePanel: View {
    public let mode: InspectorSurfaceMode
    public var currentDirectoryURL: URL?
    public var onSelectArchive: ((String) -> Void)?
    public var onCompressPath: ((String) -> Void)?
    public var onPreviewFile: ((DiskItemInfo) -> Void)?
    public var onRevealInFinder: ((String) -> Void)?
    public var onInspectArchive: ((String) -> Void)?
    public var onMoveToTrash: ((String) -> Void)?
    public var onClearInspectedFile: (() -> Void)?
    public var activeArchivePath: String?
    public var onForgetArchivePassword: ((String) -> Void)?

    private var l10n = AppLocalizationState.shared

    public init(
        mode: InspectorSurfaceMode,
        currentDirectoryURL: URL? = nil,
        onSelectArchive: ((String) -> Void)? = nil,
        onCompressPath: ((String) -> Void)? = nil,
        onPreviewFile: ((DiskItemInfo) -> Void)? = nil,
        onRevealInFinder: ((String) -> Void)? = nil,
        onInspectArchive: ((String) -> Void)? = nil,
        onMoveToTrash: ((String) -> Void)? = nil,
        onClearInspectedFile: (() -> Void)? = nil,
        activeArchivePath: String? = nil,
        onForgetArchivePassword: ((String) -> Void)? = nil
    ) {
        self.mode = mode
        self.currentDirectoryURL = currentDirectoryURL
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onPreviewFile = onPreviewFile
        self.onRevealInFinder = onRevealInFinder
        self.onInspectArchive = onInspectArchive
        self.onMoveToTrash = onMoveToTrash
        self.onClearInspectedFile = onClearInspectedFile
        self.activeArchivePath = activeArchivePath
        self.onForgetArchivePassword = onForgetArchivePassword
    }

    /// Convenience initializer decoupling AppViewState into InspectorSurfaceMode and closures.
    public init(viewModel: AppViewState) {
        let derivedMode: InspectorSurfaceMode
        let items = viewModel.selectionState.selectedDiskItems
        if viewModel.navigationState.isStorageInspectorActive {
            derivedMode = .storageInspectorActive
        } else if let items = items, items.count > 1 {
            derivedMode = .multiple(metrics: AggregatedSelectionMetrics.placeholder(count: items.count))
        } else if let item = Self.resolveEffectiveItem(viewModel: viewModel) {
            derivedMode = .single(metadata: FileSystemEntryMetadata(diskItem: item))
        } else {
            derivedMode = .empty
        }

        self.init(
            mode: derivedMode,
            currentDirectoryURL: viewModel.navigationState.currentDirectory.standardizedFileURL.resolvingSymlinksInPath(),
            onSelectArchive: { archivePath in
                Task { await viewModel.loadArchive(path: archivePath) }
            },
            onCompressPath: { folderPath in
                viewModel.openCompressWorkspace(paths: [folderPath])
            },
            onPreviewFile: { item in
                viewModel.openImmersiveMedia(for: item)
            },
            onRevealInFinder: { path in
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            },
            onInspectArchive: { path in
                viewModel.overlayState.inspectingArchivePath = path
                viewModel.overlayState.showArchiveInspectorModal = true
            },
            onMoveToTrash: { path in
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                viewModel.clearInspectedFile()
            },
            onClearInspectedFile: {
                viewModel.clearInspectedFile()
            },
            activeArchivePath: viewModel.explorerState.currentArchivePath,
            onForgetArchivePassword: viewModel.archiveRememberedPasswordController == nil ? nil : { path in
                Task { await viewModel.forgetArchivePassword(at: path) }
            }
        )
    }

    public static func resolveEffectiveItem(viewModel: AppViewState) -> DiskItemInfo? {
        if let currentArchive = viewModel.explorerState.currentArchivePath {
            if let entryID = viewModel.selectionState.selectedEntryID,
               !entryID.isEmpty {
                if let selected = viewModel.selectionState.selectedDiskItem, selected.path.contains("?subpath=") {
                    return selected
                }
                let baseArchiveURL = URL(fileURLWithPath: currentArchive)
                let basePrefix = baseArchiveURL.absoluteString + "?subpath="
                let encodedSubpath = entryID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entryID
                if let virtualURL = URL(string: basePrefix + encodedSubpath) {
                    var isDir = entryID.hasSuffix("/")
                    var sizeBytes: Int64 = 0
                    if let entry = viewModel.explorerState.currentEntries.first(where: { $0.path == entryID }) {
                        isDir = entry.isDirectory
                        sizeBytes = entry.uncompressedSize
                    } else if let session = viewModel.explorerState.vfsSession,
                              let nodeId = try? session.resolvePath(path: entryID),
                              let detail = try? session.getNodeDetail(nodeId: nodeId) {
                        isDir = detail.isDir
                        sizeBytes = Int64(detail.size)
                    }
                    let filename = (entryID as NSString).lastPathComponent
                    let sizeText = isDir ? "Folder" : ByteCountFormatterFlyweight.shared.string(fromByteCount: sizeBytes)
                    let ext = (filename as NSString).pathExtension.lowercased()
                    let kindText = isDir ? "Archive Folder" : (ext.isEmpty ? "File" : "\(ext.uppercased()) File")
                    return DiskItemInfo(
                        virtualName: filename,
                        virtualURL: virtualURL,
                        isDirectory: isDir,
                        isArchive: false,
                        sizeText: sizeText,
                        rawSizeBytes: sizeBytes,
                        kindText: kindText
                    )
                }
            } else {
                let archiveURL = URL(fileURLWithPath: currentArchive)
                return DiskItemInfo(url: archiveURL)
            }
        }
        return viewModel.selectionState.selectedDiskItem
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.horizontal, 16)
                .frame(height: TTZipTheme.Layout.headerBarHeight)

            TTKintsugiDivider(.horizontal, falloff: false)
                .frame(height: TTZipTheme.Layout.kintsugiGoldLineHeight)

            if let activeArchivePath {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            onForgetArchivePassword?(activeArchivePath)
                        } label: {
                            Label(
                                l10n.uiString(zh: "忘记此压缩包密码", en: "Forget archive password"),
                                systemImage: "key.slash"
                            )
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .disabled(onForgetArchivePassword == nil)
                        Text(URL(fileURLWithPath: activeArchivePath).lastPathComponent)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }

            contentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Color.clear)
    }

    // MARK: - Contextual Content Router

    @ViewBuilder
    private var contentView: some View {
        switch mode {
        case .single(let metadata):
            let diskItem = metadata.toDiskItemInfo()
            if !diskItem.isDirectory {
                ExplorerItemInspectorView(
                    item: diskItem,
                    onSelectArchive: { onSelectArchive?($0) },
                    onCompressPath: { onCompressPath?($0) },
                    onPreviewFile: { _ in onPreviewFile?(diskItem) }
                )
                .id(diskItem.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                FolderMediaArtboardView(
                    item: diskItem,
                    onCompressPath: { onCompressPath?($0) }
                )
                .id(diskItem.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

        case .multiple(let metrics):
            multipleSelectionContent(metrics: metrics)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .workspace:
            storageInspectorPlaceholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            if let dirURL = currentDirectoryURL {
                let folderItem = DiskItemInfo(url: dirURL)
                if folderItem.isDirectory {
                    FolderMediaArtboardView(
                        item: folderItem,
                        onCompressPath: { onCompressPath?($0) }
                    )
                    .id(dirURL.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    zenPlaceholderView
                }
            } else {
                zenPlaceholderView
            }
        }
    }

    // MARK: - Multi-Selection View

    @ViewBuilder
    private func multipleSelectionContent(metrics: AggregatedSelectionMetrics) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                multipleSelectionHeaderBanner(metrics: metrics)
                multipleSelectionStats(metrics: metrics)
                multipleSelectionTypeChips(topMimeTypes: metrics.topMimeTypes)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func multipleSelectionHeaderBanner(metrics: AggregatedSelectionMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
                Text(l10n.format(L10n.Inspector.multiItemsFormat, metrics.totalItemCount))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
            }
            Text(ByteCountFormatterFlyweight.shared.string(fromByteCount: metrics.totalByteSize))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func multipleSelectionStats(metrics: AggregatedSelectionMetrics) -> some View {
        VStack(spacing: 6) {
            metricRow(
                title: l10n.t(L10n.Inspector.filesLabel),
                value: "\(metrics.fileCount)",
                icon: "doc.fill"
            )
            metricRow(
                title: l10n.t(L10n.Inspector.foldersLabel),
                value: "\(metrics.directoryCount)",
                icon: "folder.fill"
            )
            if let largest = metrics.largestItemName, metrics.largestItemBytes > 0 {
                metricRow(
                    title: l10n.t(L10n.Inspector.largestItem),
                    value: "\(largest) (\(ByteCountFormatterFlyweight.shared.string(fromByteCount: metrics.largestItemBytes)))",
                    icon: "arrow.up.circle.fill"
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func multipleSelectionTypeChips(topMimeTypes: [String: Int]) -> some View {
        if !topMimeTypes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                L10nText(L10n.Inspector.fileTypes)
                    .font(.system(size: 10.5, weight: .bold, design: .serif))
                    .foregroundStyle(.secondary)

                TTFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(topMimeTypes.sorted(by: { $0.value > $1.value }), id: \.key) { ext, count in
                        HStack(spacing: 3) {
                            Text(ext.uppercased())
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            Text("×\(count)")
                                .font(.system(size: 9, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private func metricRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Placeholders

    @ViewBuilder
    private var zenPlaceholderView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "circle.dashed")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(TTZipTheme.bambooGreen.opacity(0.4))
            L10nText(L10n.Inspector.selectToInspect)
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var storageInspectorPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial.opacity(0.6))
            L10nText(L10n.Inspector.storageActive)
                .font(.system(size: 11.5, weight: .medium, design: .serif))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Header Components

    @ViewBuilder
    private var headerView: some View {
        switch mode {
        case .single(let metadata):
            selectedItemHeader(for: metadata.toDiskItemInfo())
        case .multiple(let metrics):
            multiSelectionHeader(count: metrics.totalItemCount)
        case .workspace:
            storageHeader
        case .empty:
            directoryHeader
        }
    }

    @ViewBuilder
    private func multiSelectionHeader(count: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
            L10nText(L10n.Inspector.multiSelectionTitle)
                .font(.system(size: 11.5, weight: .bold, design: .serif))
                .foregroundStyle(Color.primary)
            Text("(\(count))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var storageHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
            L10nText(L10n.Sidebar.storageInspector)
                .font(.system(size: 11.5, weight: .bold, design: .serif))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func selectedItemHeader(for item: DiskItemInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(itemIconGradient(for: item))
                    .frame(width: 28, height: 28)
                Image(systemName: itemIconName(for: item))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .accessibilityIdentifier("InspectorHeaderTitle")

                HStack(spacing: 4) {
                    if item.isDirectory {
                        let folderTitle = l10n.t(L10n.Explorer.folderShort)
                        Text(folderTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("InspectorHeaderSubtitle")
                    } else {
                        if !item.sizeText.isEmpty {
                            Text(item.sizeText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)

                            Text("•")
                                .font(.system(size: 7))
                                .foregroundStyle(.tertiary)
                        }

                        let rawExt = (item.name as NSString).pathExtension.uppercased()
                        let stemExt = ((item.name as NSString).deletingPathExtension as NSString).pathExtension.uppercased()
                        let ext = (!stemExt.isEmpty && rawExt.allSatisfy(\.isNumber)) ? "\(stemExt).\(rawExt)" : rawExt
                        Text(ext.isEmpty ? item.kindText : ext)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityIdentifier("InspectorHeaderSubtitle")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ttButtonHelp(item.path)
            .contextMenu {
                Button {
                    copyPathToPasteboard(item.path)
                } label: {
                    Label(l10n.t(L10n.Common.copyPath), systemImage: "doc.on.doc")
                }
            }

            Menu {
                Button(action: {
                    onPreviewFile?(item)
                }) {
                    Label(l10n.t(L10n.Inspector.quickLookShortcut), systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button(action: {
                    onRevealInFinder?(item.path)
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
                    onMoveToTrash?(item.path)
                }) {
                    Label(l10n.t(L10n.Menu.moveToTrash), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .controlSize(.mini)
            .l10nHelp(L10n.Inspector.itemActionsHelp)
            .accessibilityLabel(l10n.t(L10n.Inspector.itemActionsHelp))
            .accessibilityIdentifier("InspectorHeaderActionsMenu")
            .fixedSize(horizontal: true, vertical: false)
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
    private var directoryHeader: some View {
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
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)
                .l10nHelp(L10n.Inspector.itemActionsHelp)
                .accessibilityLabel(l10n.t(L10n.Inspector.itemActionsHelp))
                .accessibilityIdentifier("InspectorHeaderActionsMenu")
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func copyPathToPasteboard(_ path: String) {
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Visual Helpers

    private func itemIconName(for item: DiskItemInfo) -> String {
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

    private func itemIconGradient(for item: DiskItemInfo) -> LinearGradient {
        LinearGradient(
            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
