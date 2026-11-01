// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitDesign
import TTZipCore

// MARK: - Treemap Tile Category Taxonomy

/// Semantic classification of treemap tiles with associated Display P3 palette.
public enum TileCategory: UInt8, Sendable, CaseIterable, Codable {
    case generalCode = 0
    case mediaImage = 1
    case mediaVideo = 2
    case mediaAudio = 3
    case compressedArchive = 4
    case documentText = 5
    case executableBinary = 6
    case reclaimCache = 7
    case systemMeta = 8
    case others = 9

    /// Canonical Display P3 color mapping conforming to MetastudyLine design tokens.
    public var displayP3Color: Color {
        switch self {
        case .generalCode:
            // Bamboo Green
            return Color(.displayP3, red: 0.15, green: 0.68, blue: 0.38, opacity: 1.0)
        case .mediaImage:
            // Warm Amber
            return Color(.displayP3, red: 0.95, green: 0.65, blue: 0.15, opacity: 1.0)
        case .mediaVideo:
            // Deep Amber
            return Color(.displayP3, red: 0.98, green: 0.52, blue: 0.16, opacity: 1.0)
        case .mediaAudio:
            // Warm Gold
            return Color(.displayP3, red: 0.88, green: 0.72, blue: 0.20, opacity: 1.0)
        case .compressedArchive:
            // Sky Azure
            return Color(.displayP3, red: 0.20, green: 0.58, blue: 0.92, opacity: 1.0)
        case .documentText:
            // Slate Teal
            return Color(.displayP3, red: 0.45, green: 0.62, blue: 0.70, opacity: 1.0)
        case .executableBinary:
            // Royal Violet
            return Color(.displayP3, red: 0.62, green: 0.40, blue: 0.88, opacity: 1.0)
        case .reclaimCache:
            // Coral Amber (Distinctive reclaimable highlight)
            return Color(.displayP3, red: 0.92, green: 0.42, blue: 0.22, opacity: 1.0)
        case .systemMeta:
            // Muted Steel
            return Color(.displayP3, red: 0.48, green: 0.50, blue: 0.54, opacity: 1.0)
        case .others:
            // Neutral Granite
            return Color(.displayP3, red: 0.40, green: 0.42, blue: 0.45, opacity: 1.0)
        }
    }

    /// Localized display name for the current active language.
    public var displayName: String {
        localizedName(for: TTZipLocalizationManager.shared.currentLanguage)
    }

    /// Localized category label across supported languages.
    public func localizedName(for language: AppLanguage) -> String {
        guard let triple = Self.localizedNames[self] else { return "Others" }
        switch language {
        case .zhHans: return triple.zhHans
        case .zhHant: return triple.zhHant
        default: return triple.en
        }
    }

    private static let localizedNames: [TileCategory: (en: String, zhHans: String, zhHant: String)] = [
        .generalCode: ("Code", "代码", "程式碼"),
        .mediaImage: ("Images", "图像", "圖像"),
        .mediaVideo: ("Videos", "视频", "影片"),
        .mediaAudio: ("Audio", "音频", "音訊"),
        .compressedArchive: ("Archives", "归档", "歸檔"),
        .documentText: ("Documents", "文档", "文件"),
        .executableBinary: ("Binaries", "可执行文件", "可執行檔"),
        .reclaimCache: ("Reclaimable Cache", "可清理缓存", "可清理快取"),
        .systemMeta: ("System Metadata", "系统元数据", "系統中繼資料"),
        .others: ("Others", "其他", "其他"),
    ]
}

// MARK: - Treemap Tile Flags

/// Bitmask flags encoding node attributes, aligned with Feature 233 data contract.
public struct TileFlags: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let isDir         = TileFlags(rawValue: 1 << 0)
    public static let isLeaf        = TileFlags(rawValue: 1 << 1)
    public static let tailCollapsed = TileFlags(rawValue: 1 << 2)
    public static let reclaimable   = TileFlags(rawValue: 1 << 3)
    public static let cloudStub     = TileFlags(rawValue: 1 << 4)
    public static let selected      = TileFlags(rawValue: 1 << 5)
}

// MARK: - Treemap Tile Layout Model

/// Compact 32-byte squarified treemap tile projection.
public struct TreemapTile: Identifiable, Sendable, Equatable, Hashable {
    public let id: UInt32
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var nodeId: UInt32
    public var depth: UInt16
    public var category: TileCategory
    public var flags: TileFlags
    public var bytes: UInt64
    public var name: String
    public var relativePath: String

    public init(
        id: UInt32? = nil,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        nodeId: UInt32,
        depth: UInt16 = 0,
        category: TileCategory = .others,
        flags: TileFlags = [],
        bytes: UInt64 = 0,
        name: String = "",
        relativePath: String = ""
    ) {
        self.id = id ?? nodeId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.nodeId = nodeId
        self.depth = depth
        self.category = category
        self.flags = flags
        self.bytes = bytes
        self.name = name
        self.relativePath = relativePath
    }

    /// Compute pixel bounding rectangle within the target container dimensions.
    public func pixelRect(in containerSize: CGSize) -> CGRect {
        if width <= 1.001 && height <= 1.001 && containerSize.width > 1 && containerSize.height > 1 {
            return CGRect(
                x: x * containerSize.width,
                y: y * containerSize.height,
                width: width * containerSize.width,
                height: height * containerSize.height
            )
        } else {
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}

// MARK: - 120Hz ProMotion Treemap Canvas View

/// High-performance SwiftUI Canvas renderer executing batched 120Hz ProMotion treemap drawing.
public struct TTZipTreemapCanvasView: View {
    public let tiles: [TreemapTile]
    public let selectedTileId: UInt32?
    public var onSelectTile: ((TreemapTile) -> Void)? = nil
    public var onDrillDown: ((TreemapTile) -> Void)? = nil

    @State private var hoveredTileId: UInt32? = nil
    @State private var currentCursorLocation: CGPoint? = nil

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter
    }()

    public init(
        tiles: [TreemapTile],
        selectedTileId: UInt32? = nil,
        onSelectTile: ((TreemapTile) -> Void)? = nil,
        onDrillDown: ((TreemapTile) -> Void)? = nil
    ) {
        self.tiles = tiles
        self.selectedTileId = selectedTileId
        self.onSelectTile = onSelectTile
        self.onDrillDown = onDrillDown
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, canvasSize in
                drawTreemap(context: &context, size: canvasSize)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    currentCursorLocation = location
                    updateHover(at: location, in: size)
                case .ended:
                    currentCursorLocation = nil
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        hoveredTileId = nil
                    }
                }
            }
            .gesture(
                TapGesture(count: 2).onEnded {
                    if let hoveredTileId,
                       let tile = tiles.first(where: { $0.id == hoveredTileId }),
                       !tile.flags.contains(.tailCollapsed),
                       !tile.relativePath.isEmpty {
                        onDrillDown?(tile)
                    }
                }
                .exclusively(
                    before: TapGesture(count: 1).onEnded {
                        if let hoveredTileId, let tile = tiles.first(where: { $0.id == hoveredTileId }) {
                            onSelectTile?(tile)
                        }
                    }
                )
            )
        }
    }

    // MARK: - Batched Drawing Subsystem

    private func drawTreemap(context: inout GraphicsContext, size: CGSize) {
        guard size.width > 2 && size.height > 2 else { return }

        // Render unselected / unhovered tiles first, then selected / hovered on top
        var selectedOverlay: (TreemapTile, CGRect)? = nil
        var hoveredOverlay: (TreemapTile, CGRect)? = nil

        for tile in tiles {
            let rect = tile.pixelRect(in: size)
            guard rect.width >= 1.0 && rect.height >= 1.0 else { continue }

            let isHovered = (tile.id == hoveredTileId)
            let isSelected = (tile.id == selectedTileId)

            if isHovered {
                hoveredOverlay = (tile, rect)
            } else if isSelected {
                selectedOverlay = (tile, rect)
            } else {
                renderSingleTile(
                    tile: tile,
                    rect: rect,
                    context: &context,
                    isHovered: false,
                    isSelected: false
                )
            }
        }

        if let (tile, rect) = selectedOverlay {
            renderSingleTile(
                tile: tile,
                rect: rect,
                context: &context,
                isHovered: false,
                isSelected: true
            )
        }

        // Render active hovered tile with elevation & parallax micro-spring scale
        if let (tile, rect) = hoveredOverlay {
            let isSelected = (tile.id == selectedTileId)
            let dw = rect.width * 0.015
            let dh = rect.height * 0.015
            let scaledRect = rect.insetBy(dx: -dw / 2, dy: -dh / 2)

            renderSingleTile(
                tile: tile,
                rect: scaledRect,
                context: &context,
                isHovered: true,
                isSelected: isSelected
            )
        }
    }

    private func renderSingleTile(
        tile: TreemapTile,
        rect: CGRect,
        context: inout GraphicsContext,
        isHovered: Bool,
        isSelected: Bool
    ) {
        let drawRect = rect.insetBy(dx: 1.0, dy: 1.0)
        guard drawRect.width > 0 && drawRect.height > 0 else { return }

        let cornerRadius: CGFloat = min(4.0, min(drawRect.width, drawRect.height) / 4)
        let path = Path(roundedRect: drawRect, cornerRadius: cornerRadius)

        // 1. Draw tile body with Display P3 color
        var baseColor = tile.category.displayP3Color
        if isHovered {
            baseColor = baseColor.opacity(0.95)
        } else {
            baseColor = baseColor.opacity(0.85)
        }
        context.fill(path, with: .color(baseColor))

        // 2. Draw Reclaimable diagonal hatch pattern
        if tile.flags.contains(.reclaimable) || tile.category == .reclaimCache {
            context.drawLayer { hatchContext in
                hatchContext.clip(to: path)
                var hatchPath = Path()
                let totalSpan = drawRect.width + drawRect.height
                var offset: CGFloat = 0
                while offset < totalSpan {
                    let startPoint = CGPoint(x: drawRect.minX + offset, y: drawRect.minY)
                    let endPoint = CGPoint(x: drawRect.minX, y: drawRect.minY + offset)
                    hatchPath.move(to: startPoint)
                    hatchPath.addLine(to: endPoint)
                    offset += 7.0
                }
                hatchContext.stroke(hatchPath, with: .color(Color.white.opacity(0.22)), lineWidth: 1.5)
            }
        }

        // 3. Draw border and selection glow
        if isSelected {
            context.stroke(path, with: .color(Color.white), lineWidth: 2.0)
        } else if isHovered {
            context.stroke(path, with: .color(Color.white.opacity(0.65)), lineWidth: 1.2)
        } else {
            context.stroke(path, with: .color(Color.black.opacity(0.18)), lineWidth: 0.5)
        }

        // 4. Render labels if tile dimensions permit
        if drawRect.width >= 44.0 && drawRect.height >= 26.0 {
            renderTileLabels(tile: tile, in: drawRect, context: &context)
        }
    }

    private func renderTileLabels(tile: TreemapTile, in rect: CGRect, context: inout GraphicsContext) {
        let padding: CGFloat = 4.0

        let titleString = tile.name.isEmpty ? (tile.flags.contains(.tailCollapsed) ? "Others" : "Item") : tile.name
        let sizeString = Self.byteFormatter.string(fromByteCount: Int64(tile.bytes))

        let titleText = Text(titleString)
            .font(.system(size: min(11.0, max(8.5, rect.height * 0.28)), weight: .semibold))
            .foregroundColor(.white)

        let sizeText = Text(sizeString)
            .font(.system(size: min(9.5, max(7.5, rect.height * 0.22)), weight: .regular))
            .foregroundColor(Color.white.opacity(0.82))

        let titleResolved = context.resolve(titleText)
        let sizeResolved = context.resolve(sizeText)

        let titlePt = CGPoint(x: rect.minX + padding, y: rect.minY + padding + 1)
        context.draw(titleResolved, at: titlePt, anchor: .topLeading)

        if rect.height >= 38.0 {
            let sizePt = CGPoint(x: rect.minX + padding, y: rect.minY + padding + 15)
            context.draw(sizeResolved, at: sizePt, anchor: .topLeading)
        }
    }

    private func updateHover(at location: CGPoint, in containerSize: CGSize) {
        for tile in tiles.reversed() {
            let rect = tile.pixelRect(in: containerSize)
            if rect.contains(location) {
                if hoveredTileId != tile.id {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        hoveredTileId = tile.id
                    }
                }
                return
            }
        }
        if hoveredTileId != nil {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                hoveredTileId = nil
            }
        }
    }
}
