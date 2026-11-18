// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipWorkspace

extension NavigationState {
    public convenience init() {
        self.init(initialDirectory: RootFolderAccessManager.defaultInitialDirectoryURL()) {
            URL(fileURLWithPath: (NSHomeDirectory() as NSString).expandingTildeInPath + "/Downloads")
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }
    }

    public func refresh() {
        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipDirectoryRefreshNotification"),
            object: currentDirectory
        )
    }
}

extension DirectoryTabItem {
    @MainActor
    public var title: String {
        let l10n = AppLocalizationState.shared
        if isCompressWorkspace {
            return l10n.t(L10n.Sidebar.newArchive)
        }
        if isStorageInspector {
            return l10n.t(L10n.Sidebar.storageInspector)
        }
        return customTitle ?? TTZipPathPresentationService.shared.displayName(
            for: url,
            language: l10n.currentLanguage
        )
    }
}
