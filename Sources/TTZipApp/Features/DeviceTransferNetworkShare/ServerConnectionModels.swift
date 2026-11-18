// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Network file sharing protocols explicitly supported by TTZip's Connect to Server workflow.
public enum SupportedNetworkShareScheme: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case smb = "smb"
    case afp = "afp"
    case nfs = "nfs"

    public var defaultPrefix: String {
        "\(rawValue)://"
    }

    public var displayBadge: String {
        rawValue.uppercased()
    }
}

/// Validated, credential-scrubbed network share endpoint descriptor.
/// Guarantees that passwords are NEVER stored in URL strings, recents, logs, or UserDefaults.
public struct ValidatedServerEndpoint: Sendable, Equatable, Hashable, Codable {
    public let scheme: SupportedNetworkShareScheme
    public let host: String
    public let port: Int?
    public let sharePath: String
    public let username: String?

    public init(
        scheme: SupportedNetworkShareScheme,
        host: String,
        port: Int? = nil,
        sharePath: String = "",
        username: String? = nil
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.sharePath = sharePath
        self.username = username
    }

    /// Reconstructs a sanitized URL suitable for mounting and persistence (never contains a password).
    public var sanitizedURL: URL? {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        if let username, !username.isEmpty {
            components.user = username
        }
        components.password = nil
        if sharePath.isEmpty {
            components.path = ""
        } else {
            components.path = sharePath.hasPrefix("/") ? sharePath : "/" + sharePath
        }
        return components.url
    }

    /// Canonical display string without credentials for recents and UI labels (e.g. `smb://nas.local/media`).
    public var sanitizedAddressString: String {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        if sharePath.isEmpty {
            components.path = ""
        } else {
            components.path = sharePath.hasPrefix("/") ? sharePath : "/" + sharePath
        }
        return components.string ?? "\(scheme.rawValue)://\(host)\(sharePath)"
    }
}

/// Validation errors when parsing user-supplied server addresses.
public enum ServerAddressValidationError: Error, LocalizedError, Sendable, Equatable {
    case emptyInput
    case unsupportedScheme(String)
    case missingHost
    case invalidSyntax(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Please enter a server address (for example, smb://server/share)."
        case .unsupportedScheme(let scheme):
            return "Unsupported protocol “\(scheme)://”. TTZip supports SMB (smb://), AFP (afp://), and NFS (nfs://)."
        case .missingHost:
            return "Server hostname or IP address is missing."
        case .invalidSyntax(let raw):
            return "Invalid server address format: \(raw)"
        }
    }
}

/// Lifecycle state of a user-initiated network server connection attempt.
public enum ServerConnectionState: Sendable, Equatable {
    case idle
    case connecting(endpoint: ValidatedServerEndpoint)
    case connected(mountPointURL: URL, reusedExistingMount: Bool)
    case cancelled
    case failed(ServerConnectionFailureReason)

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}

/// Classified failure reasons for a network share connection attempt.
public enum ServerConnectionFailureReason: Error, LocalizedError, Sendable, Equatable {
    case validationError(ServerAddressValidationError)
    case authenticationFailed(String)
    case hostUnreachable(String)
    case shareNotFound(String)
    case permissionDenied(String)
    case sandboxAuthorizationDeclined(String)
    case mountFailed(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .validationError(let err):
            return err.errorDescription
        case .authenticationFailed(let host):
            return "Authentication failed or was declined for \(host)."
        case .hostUnreachable(let host):
            return "Server “\(host)” is unreachable or timed out."
        case .shareNotFound(let share):
            return "The requested network share “\(share)” could not be found."
        case .permissionDenied(let host):
            return "Access to “\(host)” was denied by the server."
        case .sandboxAuthorizationDeclined(let path):
            return "Read access to the mounted volume at “\(path)” was not granted."
        case .mountFailed(_, let message):
            return message
        }
    }
}
