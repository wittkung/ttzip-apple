// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

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
        lhs.dirURL == rhs.dirURL
    }

    public let item: DiskItemInfo
    public let columnIndex: Int
    public let isSelected: Bool
    public let isColumnParentSelected: Bool
    public let isColumnActive: Bool
    public let dirURL: URL
    public let multiSelectedPaths: Set<String>
    public let onSelectArchive: (String) -> Void
    public let onCompressPath: (String) -> Void
    public let onSelectItem: (DiskItemInfo, Int, Bool, Bool, URL?) -> Void
    public let onTriggerNewFolder: (URL) -> Void
    public let onTriggerNewFile: (URL) -> Void

    @State private var isHovered: Bool = false
    @State private var thumbnail: NSImage? = nil
    
    public init(
        item: DiskItemInfo,
        columnIndex: Int,
        isSelected: Bool,
        isColumnParentSelected: Bool = false,
        isColumnActive: Bool = true,
        dirURL: URL,
        multiSelectedPaths: Set<String>,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onSelectItem: @escaping (DiskItemInfo, Int, Bool, Bool, URL?) -> Void,
        onTriggerNewFolder: @escaping (URL) -> Void,
        onTriggerNewFile: @escaping (URL) -> Void
    ) {
        self.item = item
        self.columnIndex = columnIndex
        self.isSelected = isSelected
        self.isColumnParentSelected = isColumnParentSelected
        self.isColumnActive = isColumnActive
        self.dirURL = dirURL
        self.multiSelectedPaths = multiSelectedPaths
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onSelectItem = onSelectItem
        self.onTriggerNewFolder = onTriggerNewFolder
        self.onTriggerNewFile = onTriggerNewFile
    }
    
    private var isEncryptedLockItem: Bool {
        item.isEncryptedLockItem
    }
    
    private var iconName: String {
        if isEncryptedLockItem { return "lock.doc.fill" }
        if item.isDirectory { return "folder.fill" }
        
        let ext = (item.name as NSString).pathExtension.lowercased()
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
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) {
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
        if ["swift", "js", "ts", "py", "json", "html", "css", "cpp", "c", "h", "rs", "go", "sh", "xml", "md", "txt"].contains(ext) {
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
        
        let ext = (item.name as NSString).pathExtension.lowercased()
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
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) {
            return Color.white.opacity(0.75)
        }
        if MediaPreviewFactory.videoExtensions.contains(ext) {
            return Color.white.opacity(0.75)
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
        return Color.white.opacity(0.75)
    }

    /// Formatted display name ensuring typographical ellipsis (\u{2026}) and normalized full-width punctuation
    /// (such as Chinese full-width colons) for clean typographical baseline alignment.
    private var formattedDisplayName: String {
        var name = item.displayName
        if name.contains("....") {
            name = name.replacingOccurrences(of: "....", with: "…")
        } else if name.contains("...") {
            name = name.replacingOccurrences(of: "...", with: "…")
        }
        if name.contains("：") {
            name = name.replacingOccurrences(of: "： ", with: ": ")
                       .replacingOccurrences(of: "：", with: ": ")
        }
        if name.contains("\u{3000}") {
            name = name.replacingOccurrences(of: "\u{3000}", with: " ")
        }
        return name
    }
    
    private var isRowSelected: Bool {
        isSelected || isColumnParentSelected
    }

    private var rowBackgroundColor: Color {
        if isRowSelected {
            return isColumnActive ? TTZipTheme.bambooGreen.opacity(0.12) : TTZipTheme.bambooGreen.opacity(0.07)
        }
        if isHovered {
            return Color.primary.opacity(0.045)
        }
        return Color.clear
    }

    private var rowBorderColor: Color {
        if isRowSelected {
            return isColumnActive ? TTZipTheme.bambooGreen.opacity(0.28) : TTZipTheme.bambooGreen.opacity(0.16)
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
        let ext = (item.name as NSString).pathExtension.lowercased()
        return MediaPreviewFactory.imageExtensions.contains(ext)
            || MediaPreviewFactory.videoExtensions.contains(ext)
    }

    private nonisolated static func resolveFileURLForThumbnail(path: String) async -> URL? {
        await Task.detached(priority: .utility) {
            let (archivePath, subpath) = parseVirtualURL(path)
            if !subpath.isEmpty {
                let filename = (subpath as NSString).lastPathComponent
                let hash = abs(archivePath.hashValue).description + "_" + abs(filename.hashValue).description
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
            
            Text(formattedDisplayName)
                .font(.system(size: 11, weight: isRowSelected ? .semibold : .regular))
                .foregroundStyle(isRowSelected ? Color.white : (isEncryptedLockItem ? TTZipTheme.archiveAmber : (item.isArchive ? TTZipTheme.bambooGreen : Color.white.opacity(0.95))))
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
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
            NSApp.keyWindow?.makeFirstResponder(nil)
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
            target: {
                if multiSelectedPaths.count > 1 && multiSelectedPaths.contains(item.path) {
                    let urls = Array(multiSelectedPaths).map { URL(fileURLWithPath: $0) }
                    return .multipleItems(urls: urls)
                } else if item.path.contains("?subpath=") {
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
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let targetPath = item.isDirectory ? item.path : dirURL.absoluteString
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let srcURL = url, srcURL.isFileURL {
                    DispatchQueue.main.async {
                        if targetPath.contains("?subpath=") {
                            let (archivePath, subpath) = Self.parseVirtualURL(targetPath)
                            let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                            Task {
                                try? await InPlaceMutationCoordinator.shared.appendFiles(
                                    archivePath: archivePath,
                                    sourceFilePaths: [srcURL.path],
                                    destinationVirtualFolder: subpath.isEmpty ? nil : subpath,
                                    password: pwd
                                )
                            }
                        } else {
                            let targetDir = item.isDirectory ? URL(fileURLWithPath: item.path) : dirURL
                            FileDragDropHelper.performMove(sources: [srcURL], to: targetDir)
                        }
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
        let (archivePath, subpath) = parseVirtualURL(item.path)
        if !subpath.isEmpty {
            let filename = (subpath as NSString).lastPathComponent
            let hash = abs(archivePath.hashValue).description + "_" + abs(filename.hashValue).description
            if let cached = PreviewLRUCacheManager.shared.existingCachedURL(forKey: hash, filename: filename) {
                let provider = NSItemProvider(object: cached as NSURL)
                provider.suggestedName = filename
                return provider
            } else {
                let provider = NSItemProvider()
                provider.suggestedName = filename
                if let u = URL(string: item.path), u.scheme != nil {
                    provider.registerObject(u as NSURL, visibility: .all)
                } else {
                    provider.registerObject(URL(fileURLWithPath: item.path) as NSURL, visibility: .all)
                }
                return provider
            }
        } else {
            let fileURL = URL(fileURLWithPath: item.path)
            let provider = NSItemProvider(object: fileURL as NSURL)
            provider.suggestedName = item.name
            return provider
        }
    }
}

extension DiskItemInfo {
    /// Determines whether this item represents an encrypted/password-protected archive entry.
    public var isEncryptedLockItem: Bool {
        kindText == "Password-Protected Archive"
            || sizeText == "Password Required"
            || name.localizedCaseInsensitiveContains("Encrypted Archive")
            || name.contains("受密码保护")
            || name.contains("已被加密")
            || kindText.localizedCaseInsensitiveContains("Password-Protected")
            || kindText.contains("受密码保护")
    }
}

// MARK: - In-Memory Thumbnail Cache

@MainActor
private final class MillerColumnThumbnailCache: @unchecked Sendable {
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


