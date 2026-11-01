// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import TTZipUI
#if !SWIFT_PACKAGE
import TTZipApp
#endif

if NSClassFromString("XCTestCase") == nil {
    LayoutStateMigration.migrateIfNeeded()
    TTZipApp.main()
}

