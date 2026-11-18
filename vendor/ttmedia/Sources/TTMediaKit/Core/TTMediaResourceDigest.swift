// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation

public enum TTMediaResourceDigest {
    nonisolated public static func sha256Hex(for url: URL) async -> String? {
        guard !Task.isCancelled else { return nil }
        let computeTask = Task.detached(priority: .utility) { () -> String? in
            guard !Task.isCancelled else { return nil }
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                guard !Task.isCancelled else { return nil }
                let digest = SHA256.hash(data: data)
                guard !Task.isCancelled else { return nil }
                return digest.map { String(format: "%02x", $0) }.joined()
            }
            guard !Task.isCancelled else { return nil }
            if let provider = EPUBChapterContentLoaderActor.customDataProvider,
               let data = await provider(url) {
                guard !Task.isCancelled else { return nil }
                let digest = SHA256.hash(data: data)
                guard !Task.isCancelled else { return nil }
                return digest.map { String(format: "%02x", $0) }.joined()
            }
            return nil
        }
        return await withTaskCancellationHandler {
            await computeTask.value
        } onCancel: {
            computeTask.cancel()
        }
    }
}
