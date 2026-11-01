// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

@Observable
@MainActor
public final class ArchiveIntegrityViewModel {
    public var isVerifying: Bool = false
    public var progressFraction: Double = 0.0
    public var currentVerifyingEntry: String = ""
    public var report: ArchiveIntegrityReport?
    public var errorMessage: String?
    
    public init() {}
    
    public func startIntegrityCheck(archivePath: String, password: String? = nil) {
        isVerifying = true
        progressFraction = 0.0
        currentVerifyingEntry = "Initializing..."
        report = nil
        errorMessage = nil
        
        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0)
        Task { [weak self] in
            guard let self else { return }
            do {
                let checker = ArchiveIntegrityChecker()
                let result = try await checker.checkArchiveIntegrity(
                    archivePath: archivePath,
                    password: password
                ) { [weak self] progress, entry in
                    if progress >= 1.0 || throttler.shouldEmit() {
                        Task { @MainActor [weak self] in
                            self?.progressFraction = progress
                            self?.currentVerifyingEntry = entry
                        }
                    }
                }
                self.report = result
                self.progressFraction = 1.0
                self.isVerifying = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isVerifying = false
            }
        }
    }
}
