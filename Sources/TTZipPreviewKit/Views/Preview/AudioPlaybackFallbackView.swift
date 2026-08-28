// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipUI

public struct AudioPlaybackFallbackView: View {
    public let url: URL
    public let fileName: String
    public let containerName: String
    public let errorMessage: String?
    
    public init(
        url: URL,
        fileName: String,
        containerName: String = "",
        errorMessage: String? = nil
    ) {
        self.url = url
        self.fileName = fileName
        self.containerName = containerName.isEmpty ? url.pathExtension.uppercased() : containerName
        self.errorMessage = errorMessage
    }
    
    public var body: some View {
        UnifiedAudioPlayerView(url: url, fileName: fileName)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
