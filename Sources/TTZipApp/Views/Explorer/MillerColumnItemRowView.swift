// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import QuickLookThumbnailing
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public struct MillerColumnItemRowView: View, Equatable {
    public nonisolated static func == (lhs: MillerColumnItemRowView, rhs: MillerColumnItemRowView) -> Bool {
        lhs.item.path == rhs.item.path &&
        lhs.item.displayName == rhs.item.displayName &&
        lhs.item.sizeText == rhs.item.sizeText &&
        lhs.columnIndex == rhs.columnIndex &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isColumnActive == rhs.isColumnActive &&
        lhs.isColumnParentSelected == rhs.isColumnParentSelected &&
        lhs.showsSizeMetadata == rhs.showsSizeMetadata &&
        lhs.dirURL == rhs.dirURL &&
        lhs.multiSelectedPaths == rhs.multiSelectedPaths
    }

    public let item: DiskItemInfo
    public let columnIndex: Int
    public let isSelected: Bool
    public let isColumnParentSelected: Bool
    public let isColumnActive: Bool
    public let showsSizeMetadata: Bool
    public let dirURL: URL
    public let multiSelectedPaths: Set<String>
    public let onSelectArchive: (String) -> Void
    public let onCompressPath: (String) -> Void
    public let onSelectItem: (DiskItemInfo, Int, Bool, Bool, URL?) -> Void
    public let onActivateItem: ((DiskItemInfo, Int, URL?) -> Void)?
    public let onTriggerNewFolder: (URL) -> Void
    public let onTriggerNewFile: (URL) -> Void
    private let formattedDisplayName: String

    @State private var isHovered: Bool = false
    @State private var thumbnail: NSImage? = nil
    @State private var isInlineRenaming: Bool = false
    @State private var draftRenameText: String = ""
    @FocusState private var isRenameFieldFocused: Bool
    
    private var isVirtualItem: Bool {
        guard let url = URL(string: item.path), url.isFileURL else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "subpath" }) == true
    }
    
    public init(
        item: DiskItemInfo,
        columnIndex: Int,
        isSelected: Bool,
        isColumnParentSelected: Bool = false,
        isColumnActive: Bool = true,
        showsSizeMetadata: Bool = true,
        dirURL: URL,
        multiSelectedPaths: Set<String>,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onSelectItem: @escaping (DiskItemInfo, Int, Bool, Bool, URL?) -> Void,
        onActivateItem: ((DiskItemInfo, Int, URL?) -> Void)? = nil,
        onTriggerNewFolder: @escaping (URL) -> Void,
        onTriggerNewFile: @escaping (URL) -> Void
    ) {
        self.item = item
        self.formattedDisplayName = Self.formatDisplayName(item.displayName)
        self.columnIndex = columnIndex
        self.isSelected = isSelected
        self.isColumnParentSelected = isColumnParentSelected
        self.isColumnActive = isColumnActive
        self.showsSizeMetadata = showsSizeMetadata
        self.dirURL = dirURL
        self.multiSelectedPaths = multiSelectedPaths
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onSelectItem = onSelectItem
        self.onActivateItem = onActivateItem
        self.onTriggerNewFolder = onTriggerNewFolder
        self.onTriggerNewFile = onTriggerNewFile
    }
    
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"
    ]
    private static let textExtensions: Set<String> = [
        "swift", "js", "ts", "py", "json", "html", "css", "cpp", "c", "h", "rs", "go", "sh", "xml", "md", "txt"
    ]

    @inline(__always)
    public nonisolated static func pathExtension(of name: String) -> String {
        guard let dotIndex = name.lastIndex(of: ".") else { return "" }
        if dotIndex == name.startIndex { return "" }
        return String(name[name.index(after: dotIndex)...]).lowercased()
    }

    private var isEncryptedLockItem: Bool {
        item.isEncryptedLockItem
    }
    
    private var iconName: String {
        if isEncryptedLockItem { return "lock.doc.fill" }
        if item.isDirectory { return "folder.fill" }
        
        let ext = Self.pathExtension(of: item.name)
        if ext == "epub" {
            return "book.fill"
        }
        if ext == "dmg" {
            return "internaldrive.fill"
        }
        if ext == "iso" {
            return "opticaldisc.fill"
        }
        if let fmt = ArchiveCompressionFormat.from(extensionOrName: ext) {
            return fmt.iconName
        }
        if Self.imageExtensions.contains(ext) {
            return "photo.fill"
        }
        if MediaPreviewFactory.videoExtensions.contains(ext) {
            return "film.fill"
        }
        if MediaPreviewFactory.audioExtensions.contains(ext) {
            return "music.note"
        }
        if ext == "pdf" {
            return "doc.richtext.fill"
        }
        if Self.textExtensions.contains(ext) {
            return "doc.text.fill"
        }
        if item.isArchive {
            return "archivebox.fill"
        }
        return "doc.fill"
    }
    
    private var iconColor: Color {
        if isEncryptedLockItem { return TTZipTheme.archiveAmber }
        if item.isDirectory { return TTZipTheme.bambooGreen.opacity(0.85) }
        
        let ext = Self.pathExtension(of: item.name)
        if ext == "epub" {
            return Color.orange
        }
        if ext == "dmg" {
            return Color.indigo
        }
        if ext == "iso" {
            return Color.purple
        }
        if let fmt = ArchiveCompressionFormat.from(extensionOrName: ext) {
            switch fmt.category {
            case .standard:
                return TTZipTheme.bambooGreen
            case .unixPackage:
                return Color.orange
            case .diskImage:
                return Color.indigo
            case .modernStream:
                return Color.teal
            }
        }
        if Self.imageExtensions.contains(ext) {
            return TTZipUniversalTokens.Mineral.gold
        }
        if MediaPreviewFactory.videoExtensions.contains(ext) {
            return Color.secondary
        }
        if MediaPreviewFactory.audioExtensions.contains(ext) {
            return Color.teal
        }
        if ext == "pdf" {
            return Color.red
        }
        if item.isArchive {
            return TTZipTheme.bambooGreen
        }
        return Color.secondary
    }

    /// Formats display name ensuring typographical ellipsis (\u{2026}) and normalized full-width punctuation
    /// (such as Chinese full-width colons) for clean typographical baseline alignment.
    /// Employs an ultra-fast guard to eliminate string allocations for typical filenames.
    public static func formatDisplayName(_ name: String) -> String {
        guard name.contains("...") || name.contains("：") || name.contains("\u{3000}") else {
            return name
        }
        var formatted = name
        if formatted.contains("....") {
            formatted = formatted.replacingOccurrences(of: "....", with: "…")
        } else if formatted.contains("...") {
            formatted = formatted.replacingOccurrences(of: "...", with: "…")
        }
        if formatted.contains("：") {
            formatted = formatted.replacingOccurrences(of: "： ", with: ": ")
                                 .replacingOccurrences(of: "：", with: ": ")
        }
        if formatted.contains("\u{3000}") {
            formatted = formatted.replacingOccurrences(of: "\u{3000}", with: " ")
        }
        return formatted
    }
    
    private var isRowSelected: Bool {
        isSelected || isColumnParentSelected
    }

    private var rowBackgroundColor: Color {
        if isRowSelected {
            return isColumnActive ? TTZipTheme.bambooGreen.opacity(0.14) : TTZipTheme.bambooGreen.opacity(0.08)
        }
        if isHovered {
            return Color.primary.opacity(0.045)
        }
        return Color.clear
    }

    private var rowBorderColor: Color {
        if isRowSelected {
            return isColumnActive ? TTZipTheme.bambooGreen.opacity(0.32) : TTZipTheme.bambooGreen.opacity(0.18)
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
    
    private var rowBorderLineWidth: CGFloat {
        0.5
    }

    private var isMediaFile: Bool {
        guard !item.isDirectory && !isEncryptedLockItem else { return false }
        let ext = Self.pathExtension(of: item.name)
        return MediaPreviewFactory.imageExtensions.contains(ext)
            || MediaPreviewFactory.videoExtensions.contains(ext)
    }

    private nonisolated static func resolveFileURLForThumbnail(path: String) async -> URL? {
        await Task.detached(priority: .utility) {
            let (archivePath, subpath) = parseVirtualURL(path)
            if !subpath.isEmpty {
                let filename = (subpath as NSString).lastPathComponent
                let hash = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archivePath, subpath: subpath)
                return PreviewLRUCacheManager.shared.existingCachedURL(forKey: hash, filename: filename)
            } else {
                let url: URL
                if let u = URL(string: path), u.scheme != nil {
                    url = u
                } else {
                    url = URL(fileURLWithPath: path)
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
                return nil
            }
        }.value
    }

    private func loadThumbnailIfNeeded() async {
        guard isMediaFile else { return }
        if let cached = MillerColumnThumbnailCache.shared.image(forKey: item.path) {
            self.thumbnail = cached
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        guard let url = await Self.resolveFileURLForThumbnail(path: item.path) else { return }
        guard !Task.isCancelled else { return }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 32, height: 32),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = rep.nsImage
            MillerColumnThumbnailCache.shared.setImage(image, forKey: item.path)
            if !Task.isCancelled {
                self.thumbnail = image
            }
        } catch {
            // Keep fallback SF Symbol on failure
        }
    }

    @ViewBuilder
    private var itemIconView: some View {
        if isMediaFile, let thumb = thumbnail {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        } else {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 16)
        }
    }
    
    public var body: some View {
        HStack(spacing: 6) {
            itemIconView
            
            if isInlineRenaming {
                TextField("", text: $draftRenameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Color.primary)
                    .focused($isRenameFieldFocused)
                    .onSubmit { commitInlineRename() }
                    .onExitCommand { cancelInlineRename() }
            } else {
                Text(formattedDisplayName)
                    .font(.system(size: 11, weight: isRowSelected ? .semibold : .regular))
                    .foregroundStyle(isRowSelected ? Color.primary : (isEncryptedLockItem ? TTZipTheme.archiveAmber : Color.primary.opacity(0.88)))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer(minLength: 4)
            
            if showsSizeMetadata && !item.isDirectory && item.rawSizeBytes > 0 && !item.sizeText.isEmpty {
                Text(item.sizeText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary.opacity(0.65))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            
            if item.isDirectory || FinderMillerColumnsView.isNavigableArchiveFolder(item) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(rowBorderColor, lineWidth: rowBorderLineWidth)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .task(id: item.path) {
            await loadThumbnailIfNeeded()
        }
        .onTapGesture {
            if !isInlineRenaming {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            let flags = NSEvent.modifierFlags
            let isCommand = flags.contains(.command)
            let isShift = flags.contains(.shift)
            
            onSelectItem(item, columnIndex, isCommand, isShift, dirURL)
        }
        .onDrag {
            let providers = buildDragProviders()
            return providers.first ?? Self.makeDragItemProvider(for: item)
        }
        .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .nativeContextMenu(
            onMenuWillOpen: {
                if !item.isDirectory && !multiSelectedPaths.contains(item.path) {
                    onSelectItem(item, columnIndex, false, false, dirURL)
                }
            },
            onDoubleClick: (isInlineRenaming || onActivateItem == nil) ? nil : {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onActivateItem?(item, columnIndex, dirURL)
            },
            target: {
                if !isVirtualItem, multiSelectedPaths.count > 1, multiSelectedPaths.contains(item.path),
                   multiSelectedPaths.allSatisfy({ path in
                       guard let url = URL(string: path), url.isFileURL else { return true }
                       return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                           .contains(where: { $0.name == "subpath" }) != true
                   }) {
                    let urls = Array(multiSelectedPaths).map { URL(fileURLWithPath: $0) }
                    return .multipleItems(urls: urls)
                } else if isVirtualItem {
                    let (archivePath, subpath) = Self.parseVirtualURL(item.path)
                    return .virtualArchiveEntry(
                        archivePath: archivePath,
                        subpath: subpath,
                        isDirectory: item.isDirectory
                    )
                } else {
                    let url = URL(fileURLWithPath: item.path)
                    return .singleItem(
                        url: url,
                        isDirectory: item.isDirectory,
                        isArchive: item.isArchive
                    )
                }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipStartInlineRenameNotification"))) { note in
            if let targetPath = note.object as? String, targetPath == item.path, !isVirtualItem {
                startInlineRenaming()
            }
        }
    }

    // MARK: - Inline Renaming Handlers
    
    private func startInlineRenaming() {
        draftRenameText = item.name
        isInlineRenaming = true
        Task { @MainActor in
            isRenameFieldFocused = true
        }
    }
    
    private func cancelInlineRename() {
        isInlineRenaming = false
        draftRenameText = ""
        isRenameFieldFocused = false
    }
    
    private func commitInlineRename() {
        let trimmed = draftRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, !trimmed.contains("/"), !trimmed.contains(":") else {
            cancelInlineRename()
            return
        }
        
        let sourceURL = URL(fileURLWithPath: item.path)
        let newURL = dirURL.appendingPathComponent(trimmed)
        
        do {
            try FileManager.default.moveItem(at: sourceURL, to: newURL)
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipItemRenamedNotification"),
                object: nil,
                userInfo: [
                    "oldPath": item.path,
                    "newURL": newURL,
                    "columnIndex": columnIndex
                ]
            )
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipArchiveUnlockedRefresh"),
                object: nil
            )
        } catch {
            TTLogger.error("Failed to rename item from \(item.path) to \(newURL.path): \(error)")
        }
        cancelInlineRename()
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let targetPath = item.isDirectory ? item.path : dirURL.absoluteString
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let srcURL = url, Self.isPhysicalDropSource(srcURL) else { return }
                Task { @MainActor in
                    if targetPath.contains("?subpath=") {
                        let (archivePath, subpath) = Self.parseVirtualURL(targetPath)
                        let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                        try? await InPlaceMutationCoordinator.shared.appendFiles(
                            archivePath: archivePath,
                            sourceFilePaths: [srcURL.path],
                            destinationVirtualFolder: subpath.isEmpty ? nil : subpath,
                            password: pwd
                        )
                    } else {
                        let targetDir = item.isDirectory ? URL(fileURLWithPath: item.path) : dirURL
                        _ = try? await FileDragDropHelper.performMove(sources: [srcURL], to: targetDir)
                    }
                }
            }
        }
        return true
    }
    
    private func buildDragProviders() -> [NSItemProvider] {
        let isMulti = multiSelectedPaths.contains(item.path) && multiSelectedPaths.count > 1
        let targets: [String] = isMulti ? Array(multiSelectedPaths) : [item.path]
        return targets.map { (path: String) -> NSItemProvider in
            if path == item.path {
                return Self.makeDragItemProvider(for: item)
            }
            let dummyItem = DiskItemInfo(
                virtualName: (path as NSString).lastPathComponent,
                virtualURL: URL(string: path) ?? URL(fileURLWithPath: path),
                isDirectory: false,
                isArchive: false,
                sizeText: "",
                rawSizeBytes: 0,
                kindText: ""
            )
            return Self.makeDragItemProvider(for: dummyItem)
        }
    }
    
    public nonisolated static func parseVirtualURL(_ path: String) -> (archivePath: String, subpath: String) {
        if let u = URL(string: path),
           let comp = URLComponents(url: u, resolvingAgainstBaseURL: false),
           let sub = comp.queryItems?.first(where: { $0.name == "subpath" })?.value {
            var arch = u.path
            if arch.isEmpty { arch = path }
            return (arch, sub)
        }
        return (path, "")
    }
    
    public nonisolated static func makeDragItemProvider(for item: DiskItemInfo) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let source = URL(string: item.path).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(fileURLWithPath: item.path)
        // Browsing is not entry export; even a preview cache hit cannot become a move source.
        guard isPhysicalDropSource(source) else { return provider }
        provider.registerObject(source as NSURL, visibility: .all)
        return provider
    }

    /// Both drop entry points reject virtual identities before any path-based file operation.
    public nonisolated static func isPhysicalDropSource(_ url: URL) -> Bool {
        guard AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedQuery == nil, components.fragment == nil,
              components.path.hasPrefix("/") else { return false }
        return true
    }
}

// MARK: - In-Memory Thumbnail Cache

@MainActor
private final class MillerColumnThumbnailCache {
    static let shared = MillerColumnThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    
    private init() {
        cache.countLimit = 300
    }
    
    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }
    
    func setImage(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}


