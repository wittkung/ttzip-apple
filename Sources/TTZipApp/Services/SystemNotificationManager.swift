// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import UserNotifications
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Background task completion and disaster notification dispatcher.
public final class SystemNotificationManager: Sendable {
    public static let shared = SystemNotificationManager()
    
    private init() {}
    
    private var isNotificationSupported: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        guard NSClassFromString("XCTestCase") == nil else { return false }
        return true
    }
    
    /// Requests notification permissions on macOS.
    public func requestAuthorization() {
        guard isNotificationSupported else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let err = error {
                TTLogger.error("Failed to request notification permission: \(err.localizedDescription)")
            }
        }
    }
    
    /// Posts a system banner notification when a long-running compression or extraction finishes.
    public func postTaskCompletedNotification(
        taskName: String,
        operationType: String,
        durationSeconds: Double,
        bytesProcessed: Int64
    ) {
        guard isNotificationSupported else { return }
        let manager = TTZipLocalizationManager.shared
        let content = UNMutableNotificationContent()
        let titleTemplate = manager.string(for: L10n.Notification.taskCompletedTitle)
        content.title = String(format: titleTemplate, operationType.capitalized)
        
        let formattedSize = ByteSizeFormatter.format(bytes: bytesProcessed, style: .metricSI, language: manager.currentLanguage)
        let bodyTemplate = manager.string(for: L10n.Notification.taskCompletedBody)
        content.body = String(format: bodyTemplate, taskName, formattedSize, durationSeconds)
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Immediate delivery
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let err = error {
                TTLogger.error("Error scheduling task completed notification: \(err.localizedDescription)")
            }
        }
    }
    
    /// Posts an alert notification when a task fails.
    public func postTaskFailedNotification(taskName: String, errorMessage: String) {
        guard isNotificationSupported else { return }
        let manager = TTZipLocalizationManager.shared
        let content = UNMutableNotificationContent()
        content.title = manager.string(for: L10n.Notification.taskFailedTitle)
        let bodyTemplate = manager.string(for: L10n.Notification.taskFailedBody)
        content.body = String(format: bodyTemplate, taskName, errorMessage)
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Posts a security warning notification when a malicious traversal entry is blocked.
    public func postThreatInterceptedNotification(entryPath: String) {
        guard isNotificationSupported else { return }
        let manager = TTZipLocalizationManager.shared
        let content = UNMutableNotificationContent()
        content.title = manager.string(for: L10n.Notification.threatInterceptedTitle)
        let bodyTemplate = manager.string(for: L10n.Notification.threatInterceptedBody)
        content.body = String(format: bodyTemplate, entryPath)
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Posts a general user-facing notification with optional error styling.
    public func postNotification(title: String, subtitle: String? = nil, body: String, isError: Bool = false) {
        guard isNotificationSupported else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let err = error {
                TTLogger.error("Error dispatching general notification: \(err.localizedDescription)")
            }
        }
    }
}
