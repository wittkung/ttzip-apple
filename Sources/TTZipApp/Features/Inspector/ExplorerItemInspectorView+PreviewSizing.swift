// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreMedia
import Foundation
import SwiftUI
import TTMediaKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI

extension ExplorerItemInspectorView {
    func previewAccessibilityModeName(for item: DiskItemInfo) -> String {
        if item.isArchive || Self.isComicArchiveItem(item) {
            return "archive"
        }
        let effectiveType = Self.resolveEffectivePreviewTypeForHeight(
            item: item,
            previewURL: effectivePreviewURL,
            resolvedPreviewType: resolvedPreviewType
        )
        switch effectiveType {
        case .markdown:
            return "markdown"
        case .image:
            return "image"
        case .text, .htmlWeb, .spreadsheetTable, .officeSpreadsheet, .officePresentation, .docxDocument:
            return "code"
        case .hexViewer:
            return "binary"
        default:
            let ext = (item.name as NSString).pathExtension.lowercased()
            if ext == "md" || ext == "markdown" { return "markdown" }
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg", "tiff"].contains(ext) { return "image" }
            return "binary"
        }
    }

    // MARK: - Zen Empty State

    @ViewBuilder
    var zenPlaceholderView: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                Circle()
                    .fill(TTZipTheme.kintsugiGold.opacity(0.06))
                    .frame(width: 56, height: 56)

                Image(systemName: "circle.dotted")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.6))
            }

            VStack(spacing: 4) {
                Text(l10n.uiString(zh: "禅意工作台", en: "Zen Workspace"))
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.primary.opacity(0.8))

                Text(l10n.uiString(zh: "在资源管理器中选择项目以检视详情", en: "Select an item in the explorer to inspect"))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("InspectorEmptyPlaceholder")
    }

    // MARK: - Adaptive Aspect Ratio & Detected Preview Type Height Engine (U1-003)

    private func parseDimensionsAspectRatio(_ dims: String?) -> CGFloat? {
        guard let dims = dims else { return nil }
        let cleaned = dims.replacingOccurrences(of: "px", with: "")
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: "x×*")).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), h > 0 {
            return CGFloat(w / h)
        }
        return nil
    }

    func computeNaturalAdaptiveHeight(
        for item: DiskItemInfo,
        contentWidth: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let currentSize = effectivePreviewURL.flatMap { VideoPlaybackPresentation.orientedSize(for: $0) }
        let currentRatio = currentSize.flatMap { $0.height > 0 ? $0.width / $0.height : nil }
        let parsedRatio = parseDimensionsAspectRatio(deepMetadataDict["Dimensions (Pixels)"])
            ?? parseDimensionsAspectRatio(asyncDimensions)
        return Self.computeAdaptivePreviewHeight(
            for: item,
            previewURL: effectivePreviewURL,
            resolvedPreviewType: resolvedPreviewType,
            parsedAspectRatio: orientedVideoAspectRatio ?? currentRatio ?? parsedRatio,
            contentWidth: contentWidth,
            availableHeight: availableHeight
        )
    }

    public static func computeAdaptivePreviewHeight(
        for item: DiskItemInfo,
        previewURL: URL?,
        resolvedPreviewType: MediaPreviewType? = nil,
        parsedAspectRatio: CGFloat? = nil,
        contentWidth: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let effectiveType = resolveEffectivePreviewTypeForHeight(
            item: item,
            previewURL: previewURL,
            resolvedPreviewType: resolvedPreviewType
        )
        return heightForResolvedPreviewType(
            effectiveType,
            parsedAspectRatio: parsedAspectRatio,
            contentWidth: contentWidth,
            availableHeight: availableHeight
        )
    }

    static func resolveEffectivePreviewTypeForHeight(
        item: DiskItemInfo,
        previewURL: URL?,
        resolvedPreviewType: MediaPreviewType?
    ) -> MediaPreviewType {
        let probeURL = previewURL ?? URL(fileURLWithPath: item.path)
        if let resolved = resolvedPreviewType {
            if case .unsupported(let msg) = resolved, msg == "Loading..." {
                return MediaPreviewFactory.fastTypeByExtension(url: probeURL)
            }
            return resolved
        }
        return MediaPreviewFactory.fastTypeByExtension(url: probeURL)
    }

    private static func heightForResolvedPreviewType(
        _ previewType: MediaPreviewType,
        parsedAspectRatio: CGFloat?,
        contentWidth: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let safeWidth = max(contentWidth, 200.0)
        switch previewType {
        case .audio:
            return min(300.0, max(220.0, availableHeight * 0.42))
        case .video:
            let ratio = parsedAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (16.0 / 9.0)
            // The enclosing vertical ScrollView accommodates portrait video at full content width.
            return safeWidth / ratio
        case .image(let nsImage):
            let imgRatio: CGFloat? = (nsImage.size.width > 0 && nsImage.size.height > 0)
                ? (nsImage.size.width / nsImage.size.height)
                : nil
            let ratio = parsedAspectRatio ?? imgRatio ?? (4.0 / 3.0)
            let computed = safeWidth / ratio
            return min(max(180.0, computed), min(440.0, max(200.0, availableHeight * 0.56)))
        case .unsupported(let msg) where msg != "Loading...":
            return min(200.0, max(150.0, availableHeight * 0.28))
        default:
            // All structured documents (.text, .markdown, .htmlWeb, .spreadsheetTable,
            // .officeSpreadsheet, .officePresentation, .pdf, .pdfData, .docxDocument,
            // .epubBook, .ebook, .hexViewer, .quickLook)
            return min(560.0, max(320.0, availableHeight * 0.62))
        }
    }
}
