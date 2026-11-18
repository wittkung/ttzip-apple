// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Auxiliary audio preview formatting and inspection utilities for TTMediaKit audio pipeline.
public enum AudioPreviewFormatHelper {
    /// Determines whether the given file extension represents a lossless acoustic format.
    public static func isLosslessFormat(extension ext: String) -> Bool {
        let normalized = ext.lowercased()
        return ["flac", "ape", "wav", "aiff", "aifc", "alac", "dsf", "dff", "wv"].contains(normalized)
    }

    /// Determines whether a file extension is a waveform-only preview format (.ogg/.oga/.opus)
    /// when native AVAudioEngine playback is not verified.
    public static func isWaveformOnlyExtension(_ ext: String) -> Bool {
        let normalized = ext.lowercased()
        return ["ogg", "oga", "opus"].contains(normalized)
    }
}
