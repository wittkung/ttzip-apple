// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public enum IntentDispatchResult: Sendable, Equatable {
    case success
    case rejected(reason: String)
    case queued
}

@MainActor
public enum AppIntentRouter {
    package static var dispatchHandler: (@MainActor (AppIntent, AppIntentSource) -> IntentDispatchResult)?

    @discardableResult
    public static func dispatch(_ intent: AppIntent, from source: AppIntentSource) -> IntentDispatchResult {
        guard let handler = dispatchHandler else {
            return .rejected(reason: "AppIntentRouter.dispatchHandler is not configured")
        }
        return handler(intent, source)
    }
}
