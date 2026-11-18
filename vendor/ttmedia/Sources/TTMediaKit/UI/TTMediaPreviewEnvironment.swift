// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI

private struct TTMediaImmersiveFullscreenKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct TTPreviewBottomTrailingReservedWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    public var isImmersiveFullscreen: Bool {
        get { self[TTMediaImmersiveFullscreenKey.self] }
        set { self[TTMediaImmersiveFullscreenKey.self] = newValue }
    }

    /// Horizontal width (including gap) reserved by the outer host's bottom-trailing corner action button (`[ ↙↗ ]`).
    public var previewBottomTrailingReservedWidth: CGFloat {
        get { self[TTPreviewBottomTrailingReservedWidthKey.self] }
        set { self[TTPreviewBottomTrailingReservedWidthKey.self] = newValue }
    }
}

// MARK: - Media Notifications

extension Notification.Name {
    /// Notification posted to request or notify a media focus toggle (e.g. fullscreen / theater transition).
    public static let ttMediaToggleMediaFocusNotification = Notification.Name("TTMediaToggleMediaFocusNotification")
}
