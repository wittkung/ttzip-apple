// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipWorkspace

extension WorkspaceTabSession {
    public var titleKey: (any LocaleKeyProtocol)? {
        guard customTitle == nil else { return nil }
        switch kind {
        case .compressWorkspace:
            return L10n.Sidebar.newArchive
        case .storageInspector:
            return L10n.Sidebar.storageInspector
        case .archive:
            return nil
        case .directory:
            let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
            if historyStack.current.standardizedFileURL.path == homeURL.path {
                return L10n.Sidebar.home
            }
            return nil
        }
    }

    public var displayTitle: String {
        if let customTitle { return customTitle }
        switch kind {
        case .compressWorkspace:
            return TTZipLocalizationManager.shared.string(for: L10n.Sidebar.newArchive)
        case .storageInspector:
            return TTZipLocalizationManager.shared.string(for: L10n.Sidebar.storageInspector)
        case .archive(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .directory:
            let path = historyStack.current.path
            let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
            if historyStack.current.standardizedFileURL.path == homeURL.path {
                return TTZipLocalizationManager.shared.string(for: L10n.Sidebar.home)
            }
            if path == "/" {
                return "Macintosh HD"
            }
            return historyStack.current.lastPathComponent.isEmpty ? path : historyStack.current.lastPathComponent
        }
    }

    public var title: String {
        displayTitle
    }

    public var iconName: String {
        switch kind {
        case .compressWorkspace:
            return "doc.zipper"
        case .storageInspector:
            return "chart.pie.fill"
        case .archive:
            return "doc.zipper"
        case .directory:
            let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
            if historyStack.current.standardizedFileURL.path == homeURL.path {
                return "house.fill"
            }
            if historyStack.current.standardizedFileURL.path == "/" {
                return "internaldrive"
            }
            return "folder.fill"
        }
    }
}
