// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

extension ExplorerItemInspectorView {
    func itemIconName(for item: DiskItemInfo) -> String {
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
        if item.isDirectory {
            return LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) {
            return LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    // MARK: - Editorial Metadata & Segmented Quick Action Helpers
    
    @ViewBuilder
    func metadataBentoView(for item: DiskItemInfo, metadata: [String: String], dims: String?) -> some View {
        let dimensions = dims ?? metadata["Dimensions (Pixels)"]
        let colorProfile = metadata["ICC Profile"] ?? metadata["Color Model"]
        let bitDepth = metadata["Bit Depth"]
        let camera = metadata["Camera Hardware"] ?? metadata["EXIF: Lens Model"]

        VStack(alignment: .leading, spacing: 14) {
            if dimensions != nil || colorProfile != nil || bitDepth != nil {
                mediaSpecsBentoSection(
                    for: item,
                    dimensions: dimensions,
                    colorProfile: colorProfile,
                    bitDepth: bitDepth
                )
            }
            if let cam = camera {
                cameraExifBentoSection(camera: cam, metadata: metadata)
            }
            overviewAttributesBentoSection(for: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func mediaSpecsBentoSection(
        for item: DiskItemInfo,
        dimensions: String?,
        colorProfile: String?,
        bitDepth: String?
    ) -> some View {
        let l10n = AppLocalizationState.shared
        let probeURL = effectivePreviewURL ?? URL(fileURLWithPath: item.path)
        let isVideo = resolvedPreviewType?.isVideoPreview
            ?? MediaPreviewFactory.detectType(url: probeURL).isVideoPreview
        VStack(alignment: .leading, spacing: 8) {
            L10nText(isVideo ? L10n.Inspector.videoSpecs : L10n.Inspector.imageSpecs)
                .font(.system(size: 9, weight: .bold, design: .serif))
                .tracking(2)
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                if let d = dimensions {
                    detailGridRow(label: l10n.t(L10n.Inspector.resolution), value: d, isHighlight: true)
                }
                if let c = colorProfile {
                    detailGridRow(label: l10n.t(L10n.Inspector.colorSpace), value: c)
                }
                if let b = bitDepth {
                    detailGridRow(label: l10n.t(L10n.Inspector.bitDepth), value: b)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cameraExifBentoSection(camera: String, metadata: [String: String]) -> some View {
        let l10n = AppLocalizationState.shared
        let params = [
            metadata["EXIF: F-Number"],
            metadata["EXIF: Exposure Time"],
            metadata["EXIF: ISO Speed"],
            metadata["EXIF: Focal Length"]
        ].compactMap { $0 }.joined(separator: " · ")

        VStack(alignment: .leading, spacing: 8) {
            L10nText(L10n.Inspector.cameraExif)
                .font(.system(size: 9, weight: .bold, design: .serif))
                .tracking(2)
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                detailGridRow(label: l10n.t(L10n.Inspector.camera), value: camera)
                if !params.isEmpty {
                    detailGridRow(label: l10n.t(L10n.Inspector.exposure), value: params)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func overviewAttributesBentoSection(for item: DiskItemInfo) -> some View {
        let l10n = AppLocalizationState.shared
        let rawExt = (item.name as NSString).pathExtension.uppercased()
        let stemExt = ((item.name as NSString).deletingPathExtension as NSString).pathExtension.uppercased()
        let ext = (!stemExt.isEmpty && rawExt.allSatisfy(\.isNumber)) ? "\(stemExt).\(rawExt)" : rawExt
        let displayPath = Self.normalizedDisplayPath(item.path)

        VStack(alignment: .leading, spacing: 8) {
            L10nText(L10n.Inspector.overviewAttributes)
                .font(.system(size: 9, weight: .bold, design: .serif))
                .tracking(2)
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                detailGridRow(label: l10n.t(L10n.Inspector.size), value: item.sizeText.isEmpty ? "--" : item.sizeText, isHighlight: true)
                if !ext.isEmpty {
                    detailGridRow(label: l10n.t(L10n.Explorer.kindHeader), value: ext)
                }
                if let modDate = item.modificationDate {
                    detailGridRow(label: l10n.t(L10n.Inspector.modified), value: DateFormatterCache.shared.string(from: modDate, format: "yyyy/MM/dd HH:mm"))
                }
                detailGridRow(label: l10n.t(L10n.Inspector.whereLocation), value: (displayPath as NSString).deletingLastPathComponent, isPath: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func normalizedDisplayPath(_ rawPath: String) -> String {
        if rawPath.hasPrefix("file://"), let parsed = URL(string: rawPath), parsed.isFileURL {
            return parsed.path
        }
        return rawPath
    }
    
    private func detailGridRow(label: String, value: String, isHighlight: Bool = false, isPath: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.secondary)
                .gridColumnAlignment(.leading)
            
            Text(value)
                .font(.system(size: 11, weight: isHighlight ? .semibold : .medium, design: isPath ? .default : .monospaced))
                .foregroundStyle(isHighlight ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(isPath ? 2 : 1)
                .truncationMode(isPath ? .middle : .tail)
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    
    @ViewBuilder
    func quickActionButtons(
        for item: DiskItemInfo,
        onPreview: @escaping () -> Void,
        onCompress: @escaping () -> Void,
        onSelectArchive: @escaping (String) -> Void
    ) -> some View {
        let l10n = AppLocalizationState.shared
        let isArchive = item.isArchive || Self.isComicArchiveItem(item)
        
        HStack(spacing: 4) {
            InspectorActionSegmentButton(
                icon: "arrow.up.left.and.arrow.down.right",
                title: l10n.t(L10n.Explorer.quickLook),
                shortcut: "Space",
                helpText: l10n.t(L10n.Inspector.quickLookHelp),
                action: onPreview
            )
            
            InspectorActionSegmentButton(
                icon: "folder",
                title: l10n.t(L10n.Common.revealInFinder),
                shortcut: nil,
                helpText: l10n.t(L10n.Inspector.revealInFinderHelp),
                action: {
                    let target: String
                    if item.path.hasPrefix("file://"), let parsed = URL(string: item.path), parsed.isFileURL {
                        target = parsed.path
                    } else if URL(string: item.path)?.query?.contains("subpath=") == true {
                        target = URL(string: item.path)?.path ?? item.path
                    } else {
                        target = item.path
                    }
                    NSWorkspace.shared.selectFile(target, inFileViewerRootedAtPath: "")
                }
            )
            
            InspectorActionSegmentButton(
                icon: isArchive ? "archivebox.and.arrow.trianglehead.down" : "doc.zipper",
                title: isArchive ? l10n.t(L10n.Extract.title) : l10n.t(L10n.Compress.startAction),
                shortcut: nil,
                helpText: isArchive ? l10n.t(L10n.Inspector.extractArchiveHelp) : l10n.t(L10n.Inspector.compressFileHelp),
                action: {
                    if isArchive {
                        onSelectArchive(item.path)
                    } else {
                        onCompressPath(item.path)
                    }
                }
            )
        }
        .frame(height: 28)
        .padding(.vertical, 2)
    }

    // MARK: - F4 Immersive Identity & Archive Sibling Builders

    public typealias ResolvedImmersiveF4Identity = MediaPreviewView.ResolvedImmersiveF4Identity

    public static func resolveImmersiveF4Identity(
        url: URL,
        name: String,
        selectedDiskItemPath: String?,
        currentArchivePath: String?,
        currentEntries: [ArchiveEntry],
        sourceArchivePath: String?,
        archiveSubpath: String?,
        resourceCacheKey: String?,
        explicitEditable: Bool?
    ) -> ResolvedImmersiveF4Identity {
        MediaPreviewView.resolveImmersiveF4Identity(
            url: url,
            name: name,
            selectedDiskItemPath: selectedDiskItemPath,
            currentArchivePath: currentArchivePath,
            currentEntries: currentEntries,
            sourceArchivePath: sourceArchivePath,
            archiveSubpath: archiveSubpath,
            resourceCacheKey: resourceCacheKey,
            explicitEditable: explicitEditable
        )
    }

    public static func buildArchiveMediaSiblings(
        entries: [ArchiveEntry],
        archivePath: String?,
        fallbackURL: URL
    ) -> [ImmersiveMediaItem] {
        MediaPreviewView.buildArchiveMediaSiblings(
            entries: entries,
            archivePath: archivePath,
            fallbackURL: fallbackURL
        )
    }
}

// MARK: - Inset Segmented Inspector Action Button

private struct InspectorActionSegmentButton: View {
    let icon: String
    let title: String
    let shortcut: String?
    let helpText: String
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isHovering ? TTZipTheme.bambooGreen : Color.secondary)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isHovering ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
        .ttButtonHelp(helpText)
        .accessibilityLabel(title)
    }
}
