// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public final class MockDarwinNotificationHarness: @unchecked Sendable {
    private let notificationName: String
    private var handler: (@Sendable () -> Void)?
    private var isDelivered = false
    private let lock = NSLock()
    
    public init(notificationName: String) {
        self.notificationName = notificationName
    }
    
    public func startObserving(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let instance = Unmanaged<MockDarwinNotificationHarness>.fromOpaque(observer).takeUnretainedValue()
                instance.lock.withLock {
                    instance.isDelivered = true
                }
                instance.handler?()
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
    
    public func waitForNotification(timeout: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let delivered = lock.withLock { isDelivered }
            if delivered { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return lock.withLock { isDelivered }
    }
    
    public func stopObserving() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(notificationName as CFString), nil)
    }
}
