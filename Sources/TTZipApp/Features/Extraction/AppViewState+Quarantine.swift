// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI

extension AppViewState {
    // MARK: - Out-of-Process Quarantine Extraction & Fault Tolerance

    /// Extracts an untrusted or quarantined archive using the isolated sandbox worker.
    /// Shields the main application from native crashes, segfaults, and memory pressure.
    @MainActor
    @discardableResult
    public func extractQuarantinedArchive(
        archiveURL: URL,
        destinationDirectory: URL
    ) async -> Bool {
        let l10n = AppLocalizationState.shared
        // MM49: the sandbox extraction holds its own busy identity. It may run inside a
        // tracked extraction; both identities are alive at the same time and each of them
        // releases only its own.
        let busyOperationID = self.taskState.beginBusyOperation()
        self.statusMessage = l10n.uiString(
            zh: "正在隔离沙盒中安全解压外来归档...",
            en: "Extracting quarantined archive in isolated sandbox..."
        )
        self.progressValue = 0.0

        defer {
            self.taskState.endBusyOperation(id: busyOperationID)
        }

        do {
            let client = QuarantineWorkerClient.shared
            let totalBytes = try await client.extractQuarantinedArchive(
                url: archiveURL,
                destinationDirectory: destinationDirectory
            )
            self.progressValue = 1.0
            let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
            self.statusMessage = l10n.uiString(
                zh: "沙盒安全解压完成（\(formattedSize)）",
                en: "Quarantine extraction completed successfully (\(formattedSize))."
            )
            return true
        } catch let error as QuarantineWorkerError {
            switch error {
            case .workerCrashed(let code, let reason):
                self.statusMessage = l10n.uiString(
                    zh: "隔离沙盒进程异常退出（代码 \(code)），主应用依然安全。原因：\(reason)",
                    en: "Isolated quarantine worker crashed (exit code \(code)). The host app remains safe. Reason: \(reason)"
                )
            case .zipSlipDetected(let path):
                self.statusMessage = l10n.uiString(
                    zh: "已拦截恶意 Zip Slip 目录穿越攻击：\(path)",
                    en: "Blocked malicious Zip Slip directory traversal: \(path)"
                )
            default:
                self.statusMessage = l10n.uiString(
                    zh: "沙盒解压失败：\(error.localizedDescription)",
                    en: "Quarantine extraction failed: \(error.localizedDescription)"
                )
            }
            return false
        } catch {
            self.statusMessage = l10n.uiString(
                zh: "沙盒解压失败：\(error.localizedDescription)",
                en: "Quarantine extraction failed: \(error.localizedDescription)"
            )
            return false
        }
    }
}
