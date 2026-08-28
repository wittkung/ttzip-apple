// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation

/// Structured failure diagnostics payload with recovery metadata.
public struct AppErrorPayload: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String
    public let diagnosticCode: String
    public let technicalDetails: String?
    public let recoveryActionTitle: String?
    public let recoveryHandler: (@Sendable () -> Void)?
    
    public init(
        id: UUID = UUID(),
        title: String,
        message: String,
        diagnosticCode: String = "ERR_GENERIC",
        technicalDetails: String? = nil,
        recoveryActionTitle: String? = nil,
        recoveryHandler: (@Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.diagnosticCode = diagnosticCode
        self.technicalDetails = technicalDetails
        self.recoveryActionTitle = recoveryActionTitle
        self.recoveryHandler = recoveryHandler
    }
}

/// Universal application error boundary and user notification coordinator.
@Observable
@MainActor
public final class AppErrorReporter {
    public static let shared = AppErrorReporter()
    
    public var activeError: AppErrorPayload? = nil
    public var isPresentingError: Bool = false
    
    private init() {}
    
    /// Reports an error and displays a non-destructive diagnostic alert sheet.
    public func reportError(
        title: String,
        message: String,
        code: String = "ERR_GENERIC",
        details: String? = nil,
        recoveryTitle: String? = nil,
        onRecovery: (@Sendable () -> Void)? = nil
    ) {
        let payload = AppErrorPayload(
            title: title,
            message: message,
            diagnosticCode: code,
            technicalDetails: details,
            recoveryActionTitle: recoveryTitle,
            recoveryHandler: onRecovery
        )
        self.activeError = payload
        self.isPresentingError = true
    }
    
    /// Reports an arbitrary Swift Error object with intelligent diagnostic mapping.
    public func reportError(_ error: Error, contextTitle: String = "Operation Failed") {
        let code = String(describing: error)
        let message = error.localizedDescription
        reportError(
            title: contextTitle,
            message: message,
            code: "ERR_\(type(of: error))",
            details: code
        )
    }
    
    /// Dismisses the currently presented error sheet.
    public func dismiss() {
        self.activeError = nil
        self.isPresentingError = false
    }
}
