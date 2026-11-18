// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTZipChannelAdapters

@MainActor
package enum AppChannelWiring {
    package static var manualUpdateAction: (@MainActor () -> Void)? {
        UpdateManager.manualUpdateAction
    }
}
