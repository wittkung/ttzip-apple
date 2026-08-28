// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI

/// Auxiliary audio preview formatting and inspection utilities for TTZip audio pipeline.
public enum AudioPreviewFormatHelper {
    /// Determines whether the given file extension represents a lossless acoustic format.
    public static func isLosslessFormat(extension ext: String) -> Bool {
        let normalized = ext.lowercased()
        return ["flac", "ape", "wav", "aiff", "aifc", "alac", "dsf", "dff", "wv"].contains(normalized)
    }
}


