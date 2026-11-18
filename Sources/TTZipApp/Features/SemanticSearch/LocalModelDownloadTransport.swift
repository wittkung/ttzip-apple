// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipSearchKit

/// Progress snapshot emitted during on-demand GGUF model download.
public struct LocalModelDownloadProgress: Sendable, Equatable {
    public let bytesReceived: Int64
    public let totalBytesExpected: Int64

    public var fractionCompleted: Double {
        guard totalBytesExpected > 0 else { return 0 }
        return min(1.0, max(0.0, Double(bytesReceived) / Double(totalBytesExpected)))
    }

    public init(bytesReceived: Int64, totalBytesExpected: Int64) {
        self.bytesReceived = bytesReceived
        self.totalBytesExpected = totalBytesExpected
    }
}

/// Transport contract for streaming the local GGUF model to a staging `.part` file.
public protocol LocalModelDownloadTransport: Sendable {
    func downloadModel(
        from url: URL,
        to destinationPartURL: URL,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws
}

/// Production `URLSession`-backed download transport streaming response bytes directly to disk.
public struct URLSessionLocalModelDownloadTransport: LocalModelDownloadTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func downloadModel(
        from url: URL,
        to destinationPartURL: URL,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SemanticSearchError.downloadFailed(reason: "HTTP status \(code)")
        }

        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationPartURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destinationPartURL.path) {
            try fm.removeItem(at: destinationPartURL)
        }
        fm.createFile(atPath: destinationPartURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationPartURL)
        defer { try? handle.close() }

        let expectedTotal = http.expectedContentLength > 0
            ? http.expectedContentLength
            : Int64(SemanticModelSpec.expectedGGUFSizeBytes)
        try await streamBytes(
            from: asyncBytes,
            to: handle,
            expectedTotal: expectedTotal,
            onProgress: onProgress
        )
    }

    private func streamBytes(
        from asyncBytes: URLSession.AsyncBytes,
        to handle: FileHandle,
        expectedTotal: Int64,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws {
        let chunkCapacity = 256 * 1024
        var buffer = Data()
        buffer.reserveCapacity(chunkCapacity)
        var bytesReceived: Int64 = 0

        for try await byte in asyncBytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= chunkCapacity {
                try handle.write(contentsOf: buffer)
                bytesReceived += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await onProgress(
                    LocalModelDownloadProgress(
                        bytesReceived: bytesReceived,
                        totalBytesExpected: expectedTotal
                    )
                )
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            bytesReceived += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: false)
        }
        try handle.synchronize()
        await onProgress(
            LocalModelDownloadProgress(
                bytesReceived: bytesReceived,
                totalBytesExpected: expectedTotal
            )
        )
    }
}
