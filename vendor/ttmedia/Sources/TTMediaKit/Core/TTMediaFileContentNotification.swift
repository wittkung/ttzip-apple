// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public extension NSNotification.Name {
    /// Posted after an in-place save succeeds. The object is the saved file URL.
    static let ttMediaFileContentDidChange = NSNotification.Name("TTMediaFileContentDidChangeNotification")
}
