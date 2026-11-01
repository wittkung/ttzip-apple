// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Proprietary UTType strictly isolating TTZip internal sidebar bookmark reordering from file ingestion.
    public static let ttzipSidebarItem = UTType(
        exportedAs: "com.metastudyline.ttzip.sidebar-item",
        conformingTo: .data
    )
}

/// Strongly-typed transferable payload for internal sidebar shortcut items.
public struct SidebarShortcutTransferItem: Codable, Transferable, Sendable, Hashable {
    public let id: UUID
    public let path: String
    public let customName: String?

    public init(id: UUID, path: String, customName: String? = nil) {
        self.id = id
        self.path = path
        self.customName = customName
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ttzipSidebarItem)
            .visibility(.ownProcess)
    }
}

/// Outbound drag source model providing internal process isolation with external URL proxy fallback.
public struct SidebarRowDragSource: Transferable, Sendable {
    public let item: SidebarShortcutTransferItem

    public init(item: SidebarShortcutTransferItem) {
        self.item = item
    }

    public static var transferRepresentation: some TransferRepresentation {
        // Internal priority: dedicated type restricted to own process
        ProxyRepresentation(exporting: { $0.item })
            .visibility(.ownProcess)

        // External fallback: allows dragging paths to Terminal, external editors, or Finder
        ProxyRepresentation(exporting: { URL(fileURLWithPath: $0.item.path) })
            .visibility(.all)
    }
}

/// Inbound drop destination payload cleanly discriminating between internal reordering and external file ingestion.
public enum SidebarDropPayload: Transferable, Sendable {
    case internalShortcut(SidebarShortcutTransferItem)
    case externalFiles([URL])

    public static var transferRepresentation: some TransferRepresentation {
        // Tier 1: Proprietary internal shortcut representation
        ProxyRepresentation(importing: { (item: SidebarShortcutTransferItem) in
            SidebarDropPayload.internalShortcut(item)
        })

        // Tier 2: Generic external file URL representation
        ProxyRepresentation(importing: { (url: URL) in
            SidebarDropPayload.externalFiles([url])
        })

        // Tier 3: Terminal & text drag-and-drop containing POSIX file path or file:// URL strings
        ProxyRepresentation(importing: { (text: String) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("file://"), let fileURL = URL(string: trimmed), fileURL.isFileURL {
                return SidebarDropPayload.externalFiles([fileURL])
            }
            if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
                return SidebarDropPayload.externalFiles([URL(fileURLWithPath: trimmed)])
            }
            return SidebarDropPayload.externalFiles([])
        })
    }
}
