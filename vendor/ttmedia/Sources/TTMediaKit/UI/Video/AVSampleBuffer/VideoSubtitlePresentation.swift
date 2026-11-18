// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI

@MainActor
public struct VideoSubtitlePresentation {
    public struct TextOverlay: Sendable {
        public let primaryText: String
        public let secondaryText: String
        public let style: SubtitleStyleConfiguration
        public let geometry: SubtitleVideoContentGeometry
    }

    public typealias Selection = @MainActor @Sendable (URL?) -> Void
    public typealias DismissFailure = @MainActor () -> Void

    let pickFile: @MainActor (URL, [String], @escaping Selection) -> Void
    let attachFailureAlert: @MainActor (AnyView, String?, @escaping DismissFailure) -> AnyView
    let renderTextOverlay: (@MainActor (TextOverlay) -> AnyView)?

    public init(
        pickFile: @escaping @MainActor (URL, [String], @escaping Selection) -> Void,
        attachFailureAlert: @escaping @MainActor (AnyView, String?, @escaping DismissFailure) -> AnyView,
        renderTextOverlay: (@MainActor (TextOverlay) -> AnyView)? = nil
    ) {
        self.pickFile = pickFile
        self.attachFailureAlert = attachFailureAlert
        self.renderTextOverlay = renderTextOverlay
    }
}
