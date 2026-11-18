// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Status presented by a video viewport. Only a failed viewport offers a retry.
public enum VideoPlaybackStatus {
    case hidden
    case loading
    case failed(detail: String?, retry: @MainActor () -> Void)
}
