// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Transfer direction for Android file operations.
public enum AndroidTransferDirection: String, Sendable, Hashable, Codable {
    case macToAndroid = "MacToAndroid"
    case androidToMac = "AndroidToMac"
    case directPipelineExtract = "DirectPipelineExtract"
}

/// Lifecycle status for an ongoing Android transfer operation.
public enum AndroidTransferStatus: String, Sendable, Hashable, Codable {
    case queued = "Queued"
    case transferring = "Transferring"
    case paused = "Paused"
    case cancelling = "Cancelling"
    case completed = "Completed"
    case failed = "Failed"
}

/// Conflict resolution policy when a target file or object with the same name already exists.
public enum AndroidTransferConflictPolicy: UInt8, Sendable, Hashable, Codable {
    /// Stage/upload new payload first, verify integrity, then replace existing target.
    case overwrite = 0
    /// Preserve existing target unchanged and skip transferring.
    case skip = 1
    /// Allocate a non-colliding sibling name (`name (1).ext`) and preserve existing target.
    case keepBoth = 2
}

/// Explicit integrity verification level achieved by a transfer operation, preventing UI or callers
/// from conflating source-stream + remote-size verification with full remote content readback SHA-256 verification.
public enum AndroidTransferVerificationLevel: String, Sendable, Hashable, Codable {
    /// No verification completed yet (queued, transferring, skipped, or failed).
    case none = "None"
    /// Actual streamed source bytes matched expected SHA-256 and remote STAT / GetObjectInfo matched exact size.
    case sourceStreamAndRemoteSizeVerified = "SourceStreamAndRemoteSizeVerified"
    /// Full remote or staged payload readback SHA-256 matched expected SHA-256.
    case remoteReadbackSha256Verified = "RemoteReadbackSha256Verified"
}

/// Discrete commit phase for cooperative cancellation and atomic recovery.
public enum AndroidTransferCommitPhase: String, Sendable, Hashable, Codable {
    case uncommitted = "Uncommitted"
    case committed = "Committed"
    case unknown = "Unknown"
}

/// Snapshot model capturing active file transfer metrics and explicit verification tiers.
public struct AndroidTransferJobInfo: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let deviceId: String
    public let direction: AndroidTransferDirection
    public let fileName: String
    public let sourcePath: String
    public let destinationPath: String
    public let totalBytes: UInt64
    public var transferredBytes: UInt64
    public var currentSpeedBps: UInt64
    public var status: AndroidTransferStatus
    public var errorMessage: String?
    public var storageId: UInt32
    public var objectHandle: UInt32
    public var conflictPolicy: AndroidTransferConflictPolicy
    public var verifiedSha256Hex: String?
    public var verificationLevel: AndroidTransferVerificationLevel
    public var sourceStreamSha256Verified: Bool
    public var remoteSizeVerified: Bool
    public var remoteReadbackSha256Verified: Bool
    public var isSkipped: Bool
    public var commitPhase: AndroidTransferCommitPhase

    public var progress: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(transferredBytes) / Double(totalBytes)))
    }

    public var speedMBs: Double {
        Double(currentSpeedBps) / 1_048_576.0
    }

    public var remainingSeconds: Double? {
        guard currentSpeedBps > 0, transferredBytes < totalBytes else { return nil }
        let remainingBytes = totalBytes - transferredBytes
        return Double(remainingBytes) / Double(currentSpeedBps)
    }

    public init(
        id: String = UUID().uuidString,
        deviceId: String = "",
        direction: AndroidTransferDirection,
        fileName: String,
        sourcePath: String,
        destinationPath: String,
        totalBytes: UInt64,
        transferredBytes: UInt64 = 0,
        currentSpeedBps: UInt64 = 0,
        status: AndroidTransferStatus = .transferring,
        errorMessage: String? = nil,
        storageId: UInt32 = 0,
        objectHandle: UInt32 = 0,
        conflictPolicy: AndroidTransferConflictPolicy = .overwrite,
        verifiedSha256Hex: String? = nil,
        verificationLevel: AndroidTransferVerificationLevel = .none,
        sourceStreamSha256Verified: Bool = false,
        remoteSizeVerified: Bool = false,
        remoteReadbackSha256Verified: Bool = false,
        isSkipped: Bool = false,
        commitPhase: AndroidTransferCommitPhase = .uncommitted
    ) {
        self.id = id
        self.deviceId = deviceId
        self.direction = direction
        self.fileName = fileName
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.currentSpeedBps = currentSpeedBps
        self.status = status
        self.errorMessage = errorMessage
        self.storageId = storageId
        self.objectHandle = objectHandle
        self.conflictPolicy = conflictPolicy
        self.verifiedSha256Hex = verifiedSha256Hex
        self.verificationLevel = verificationLevel
        self.sourceStreamSha256Verified = sourceStreamSha256Verified
        self.remoteSizeVerified = remoteSizeVerified
        self.remoteReadbackSha256Verified = remoteReadbackSha256Verified
        self.isSkipped = isSkipped
        self.commitPhase = commitPhase
    }
}

