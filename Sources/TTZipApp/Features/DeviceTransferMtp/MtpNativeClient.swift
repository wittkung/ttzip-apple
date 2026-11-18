// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import os
import TTZipAppCore

/// Maximum payload size supported by standard 32-bit PTP `SendObjectInfo` (`0x100C`) and `SendObject` (`0x100D`).
public let kMaxMtpSendObjectBytes: UInt64 = UInt64(UInt32.max - 12)

/// Verified outcome returned by the UniFFI MTP upload bridge (`MtpUploadOutcome`).
public struct MtpUploadBridgeOutcome: Sendable, Equatable {
    public let createdHandle: UInt32
    public let finalFilename: String
    public let bytesTransferred: UInt64
    public let sha256Hex: String
    public let sourceStreamSha256Verified: Bool
    public let remoteSizeVerified: Bool
    public let remoteReadbackSha256Verified: Bool
    public let skipped: Bool

    public init(
        createdHandle: UInt32,
        finalFilename: String,
        bytesTransferred: UInt64,
        sha256Hex: String,
        sourceStreamSha256Verified: Bool,
        remoteSizeVerified: Bool,
        remoteReadbackSha256Verified: Bool = false,
        skipped: Bool
    ) {
        self.createdHandle = createdHandle
        self.finalFilename = finalFilename
        self.bytesTransferred = bytesTransferred
        self.sha256Hex = sha256Hex
        self.sourceStreamSha256Verified = sourceStreamSha256Verified
        self.remoteSizeVerified = remoteSizeVerified
        self.remoteReadbackSha256Verified = remoteReadbackSha256Verified
        self.skipped = skipped
    }
}

/// Verified outcome returned by the UniFFI MTP download bridge (`MtpDownloadOutcome`).
public struct MtpDownloadBridgeOutcome: Sendable, Equatable {
    public let bytesTransferred: UInt64
    public let sha256Hex: String

    public init(bytesTransferred: UInt64, sha256Hex: String) {
        self.bytesTransferred = bytesTransferred
        self.sha256Hex = sha256Hex
    }
}

/// Standard UniFFI-aligned Swift bridge protocol corresponding to `mtp_pull_file_to_local_staged`,
/// `mtp_push_local_file_verified`, and `mtp_delete_remote_object` in `ttzip_app_core`.
///
/// Contains zero `@_silgen_name` or raw pointer callbacks. H wires the generated UniFFI free functions
/// (`mtpPullFileToLocalStaged`, `mtpPushLocalFileVerified`, `mtpDeleteRemoteObject`) to this provider
/// after running `generate_uniffi.sh`.
public protocol MtpTransferBridgeProvider: Sendable {
    func pullFileToLocalStaged(
        serialOrId: String,
        storageId: UInt32,
        objectHandle: UInt32,
        remotePath: String,
        stagedLocalURL: URL,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Bool
    ) throws -> MtpDownloadBridgeOutcome

    func pushLocalFileVerified(
        serialOrId: String,
        storageId: UInt32,
        parentDirOrHandle: String,
        fileName: String,
        localSourceURL: URL,
        expectedSha256Hex: String,
        conflictPolicy: AndroidTransferConflictPolicy,
        maxKeepBothCandidates: Int,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Bool
    ) throws -> MtpUploadBridgeOutcome

    func deleteRemoteObject(
        serialOrId: String,
        storageId: UInt32,
        objectHandle: UInt32,
        remotePath: String
    ) throws
}

private final class UniFFIMtpProgressForwarder: MtpTransferProgressCallback, @unchecked Sendable {
    private let handler: @Sendable (UInt64, UInt64) -> Bool

    init(handler: @escaping @Sendable (UInt64, UInt64) -> Bool) {
        self.handler = handler
    }

    func onProgress(transferredBytes: UInt64, totalBytes: UInt64) -> Bool {
        handler(transferredBytes, totalBytes)
    }
}

/// Production `MtpTransferBridgeProvider` backed directly by the generated `TTZipAppCore` UniFFI functions.
public struct UniFFIMtpTransferBridgeProvider: MtpTransferBridgeProvider, Sendable {
    public static let shared = UniFFIMtpTransferBridgeProvider()

    public init() {}

    public func pullFileToLocalStaged(
        serialOrId: String,
        storageId: UInt32,
        objectHandle: UInt32,
        remotePath: String,
        stagedLocalURL: URL,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Bool
    ) throws -> MtpDownloadBridgeOutcome {
        let outcome = try TTZipAppCore.mtpPullFileToLocalStaged(
            serialOrId: serialOrId,
            storageId: storageId,
            objectHandle: objectHandle,
            remotePath: remotePath,
            stagedLocalPath: stagedLocalURL.path,
            progress: UniFFIMtpProgressForwarder(handler: onProgress)
        )
        return MtpDownloadBridgeOutcome(
            bytesTransferred: outcome.bytesTransferred,
            sha256Hex: outcome.sha256Hex
        )
    }

    public func pushLocalFileVerified(
        serialOrId: String,
        storageId: UInt32,
        parentDirOrHandle: String,
        fileName: String,
        localSourceURL: URL,
        expectedSha256Hex: String,
        conflictPolicy: AndroidTransferConflictPolicy,
        maxKeepBothCandidates: Int,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Bool
    ) throws -> MtpUploadBridgeOutcome {
        let uniffiPolicy: MtpConflictPolicy
        switch conflictPolicy {
        case .overwrite:
            uniffiPolicy = .overwrite
        case .skip:
            uniffiPolicy = .skip
        case .keepBoth:
            uniffiPolicy = .keepBoth
        }
        let clampedCandidates = UInt32(clamping: max(1, maxKeepBothCandidates))
        let outcome = try TTZipAppCore.mtpPushLocalFileVerified(
            serialOrId: serialOrId,
            storageId: storageId,
            parentDirOrHandle: parentDirOrHandle,
            filename: fileName,
            localSourcePath: localSourceURL.path,
            expectedSha256Hex: expectedSha256Hex,
            conflictPolicy: uniffiPolicy,
            maxKeepBothCandidates: clampedCandidates,
            progress: UniFFIMtpProgressForwarder(handler: onProgress)
        )
        return MtpUploadBridgeOutcome(
            createdHandle: outcome.createdHandle,
            finalFilename: outcome.finalFilename,
            bytesTransferred: outcome.bytesTransferred,
            sha256Hex: outcome.sha256Hex,
            sourceStreamSha256Verified: outcome.sourceStreamSha256Verified,
            remoteSizeVerified: outcome.remoteSizeVerified,
            remoteReadbackSha256Verified: outcome.remoteReadbackSha256Verified,
            skipped: outcome.skipped
        )
    }

    public func deleteRemoteObject(
        serialOrId: String,
        storageId: UInt32,
        objectHandle: UInt32,
        remotePath: String
    ) throws {
        try TTZipAppCore.mtpDeleteRemoteObject(
            serialOrId: serialOrId,
            storageId: storageId,
            objectHandle: objectHandle,
            remotePath: remotePath
        )
    }
}

/// Bridges Swift application transfers to the UniFFI MTP streaming provider without `@_silgen_name`.
public enum MtpNativeClient {
    private static let providerLock = OSAllocatedUnfairLock<MtpTransferBridgeProvider?>(
        initialState: UniFFIMtpTransferBridgeProvider.shared
    )

    /// Registers the active UniFFI MTP transfer bridge provider (or restores the production UniFFI provider when `nil` is passed).
    public static func registerBridgeProvider(_ provider: MtpTransferBridgeProvider?) {
        providerLock.withLock { state in
            state = provider ?? UniFFIMtpTransferBridgeProvider.shared
        }
    }

    /// Returns the currently registered UniFFI MTP transfer bridge provider.
    public static func currentBridgeProvider() -> MtpTransferBridgeProvider? {
        providerLock.withLock { $0 }
    }

    /// Streams an MTP object from a connected USB MTP device to a staged local file via the UniFFI bridge.
    public static func pullFileToStagedURL(
        serial: String,
        storageId: UInt32 = 0,
        objectHandle: UInt32 = 0,
        remotePath: String,
        stagedLocalURL: URL,
        onProgress: @escaping @Sendable (UInt64, UInt64) throws -> Void
    ) throws -> MtpDownloadBridgeOutcome {
        guard let provider = currentBridgeProvider() else {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "UniFFI MtpTransferBridgeProvider is not registered; H must wire generated UniFFI bindings"
            )
        }

        let capturedError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let outcome = try provider.pullFileToLocalStaged(
            serialOrId: serial,
            storageId: storageId,
            objectHandle: objectHandle,
            remotePath: remotePath,
            stagedLocalURL: stagedLocalURL
        ) { received, total in
            do {
                try onProgress(received, total)
                return true
            } catch {
                capturedError.withLock { $0 = error }
                return false
            }
        }
        if let err = capturedError.withLock({ $0 }) {
            throw err
        }
        return outcome
    }

    /// Streams a local file in bounded 64 KiB chunks to an MTP device, verifying that the actual streamed
    /// SHA-256 matches `expectedSha256Hex` and that the remote object size matches before committing.
    public static func pushFileVerified(
        serial: String,
        storageId: UInt32 = 0,
        parentDir: String,
        fileName: String,
        localURL: URL,
        expectedSha256Hex: String,
        conflictPolicy: AndroidTransferConflictPolicy = .overwrite,
        maxKeepBothCandidates: Int = 10_000,
        onProgress: @escaping @Sendable (UInt64, UInt64) throws -> Void
    ) throws -> MtpUploadBridgeOutcome {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if fileSize > kMaxMtpSendObjectBytes {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "MTP upload size \(fileSize) bytes exceeds 32-bit PTP SendObjectInfo limit (\(kMaxMtpSendObjectBytes) bytes); rejected before creating remote object"
            )
        }

        guard let provider = currentBridgeProvider() else {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "UniFFI MtpTransferBridgeProvider is not registered; H must wire generated UniFFI bindings"
            )
        }

        let capturedError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let outcome = try provider.pushLocalFileVerified(
            serialOrId: serial,
            storageId: storageId,
            parentDirOrHandle: parentDir,
            fileName: fileName,
            localSourceURL: localURL,
            expectedSha256Hex: expectedSha256Hex,
            conflictPolicy: conflictPolicy,
            maxKeepBothCandidates: maxKeepBothCandidates
        ) { sent, total in
            do {
                try onProgress(sent, total)
                return true
            } catch {
                capturedError.withLock { $0 = error }
                return false
            }
        }
        if let err = capturedError.withLock({ $0 }) {
            throw err
        }
        return outcome
    }

    /// Deletes a remote object on a connected USB MTP device via the UniFFI bridge.
    public static func deleteObject(
        serial: String,
        storageId: UInt32 = 0,
        objectHandle: UInt32 = 0,
        remotePath: String
    ) throws {
        guard let provider = currentBridgeProvider() else {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "UniFFI MtpTransferBridgeProvider is not registered; H must wire generated UniFFI bindings"
            )
        }
        try provider.deleteRemoteObject(
            serialOrId: serial,
            storageId: storageId,
            objectHandle: objectHandle,
            remotePath: remotePath
        )
    }

    /// Streams a local file in bounded 64 KiB chunks (`FileHandle.read(upToCount: 65_536)`), computing
    /// its actual streamed SHA-256 without loading the whole file into memory.
    public static func streamLocalFileBounded64KiB(
        localURL: URL,
        declaredSize: UInt64,
        onChunk: (Data, UInt64, UInt64) throws -> Void
    ) throws -> (bytesRead: UInt64, actualStreamedSha256Hex: String) {
        if declaredSize > kMaxMtpSendObjectBytes {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "MTP upload size \(declaredSize) bytes exceeds 32-bit PTP SendObjectInfo limit (\(kMaxMtpSendObjectBytes) bytes); rejected before creating remote object"
            )
        }
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalSent: UInt64 = 0
        while totalSent < declaredSize {
            let remaining = Int(min(UInt64(65_536), declaredSize - totalSent))
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw AdbSmartSocketError.syncProtocolError(
                    reason: "Source stream ended prematurely at \(totalSent) of \(declaredSize) bytes"
                )
            }
            hasher.update(data: chunk)
            totalSent += UInt64(chunk.count)
            try onChunk(chunk, totalSent, declaredSize)
        }
        if let trailing = try handle.read(upToCount: 1), !trailing.isEmpty {
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Source stream grew beyond declared \(declaredSize) bytes during upload"
            )
        }
        let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (totalSent, digestHex)
    }
}

