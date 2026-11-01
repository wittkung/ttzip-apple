// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation
import NetFS
import Observation
import TTZipCore
import TTZipUI

/// Pluggable transport boundary for mounting network shares (SMB/AFP/NFS).
/// Allows deterministic, zero-network unit testing of connection lifecycle states
/// while delegating production connections to macOS `NetFS` (`NetFSMountURLSync` on a background queue).
public protocol ServerMountTransport: Sendable {
    func mountShare(
        endpoint: ValidatedServerEndpoint,
        allowAuthenticationUI: Bool
    ) async throws -> [URL]
}

/// Production transport using macOS public `NetFS.framework` (`NetFSMountURLSync` executed off the main thread)
/// so the system Keychain and native macOS authentication dialog handle credentials without TTZip ever touching passwords.
public struct SystemNetFSMountTransport: ServerMountTransport {
    public init() {}

    public func mountShare(
        endpoint: ValidatedServerEndpoint,
        allowAuthenticationUI: Bool
    ) async throws -> [URL] {
        guard let url = endpoint.sanitizedURL else {
            throw ServerConnectionFailureReason.validationError(.invalidSyntax(endpoint.sanitizedAddressString))
        }
        try Task.checkCancellation()

        return try await Task.detached(priority: .userInitiated) { () throws -> [URL] in
            try Task.checkCancellation()
            let uiOptionValue: String = allowAuthenticationUI ? kNAUIOptionAllowUI : kNAUIOptionNoUI
            let openOptionsDict: [String: Any] = [kNAUIOptionKey: uiOptionValue]
            let openOptions = CFDictionaryCreateMutableCopy(
                kCFAllocatorDefault,
                0,
                openOptionsDict as CFDictionary
            )
            let mountOptions = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, nil, nil)
            var mountpointsUnmanaged: Unmanaged<CFArray>?

            let status = NetFSMountURLSync(
                url as CFURL,
                nil,
                endpoint.username as CFString?,
                nil,
                openOptions,
                mountOptions,
                &mountpointsUnmanaged
            )

            try Task.checkCancellation()

            if status == 0, let arrayRef = mountpointsUnmanaged?.takeRetainedValue() as? [String], !arrayRef.isEmpty {
                return arrayRef.map { URL(fileURLWithPath: $0).standardizedFileURL }
            }

            if status == Int32(userCanceledErr) || status == ECANCELED {
                throw CancellationError()
            }
            throw ServerConnectionService.classifyNetFSStatus(status, host: endpoint.host, sharePath: endpoint.sharePath)
        }.value
    }
}

/// Metadata describing a currently mounted filesystem volume for exact endpoint identity matching.
public struct MountedVolumeSourceDescriptor: Sendable, Equatable {
    public let mountPointURL: URL
    public let volumeName: String
    public let fileSystemTypeName: String
    public let mountFromName: String

    public init(
        mountPointURL: URL,
        volumeName: String = "",
        fileSystemTypeName: String,
        mountFromName: String
    ) {
        self.mountPointURL = mountPointURL
        self.volumeName = volumeName.isEmpty ? mountPointURL.lastPathComponent : volumeName
        self.fileSystemTypeName = fileSystemTypeName
        self.mountFromName = mountFromName
    }
}

/// Service managing user-initiated network server connections ("Connect to Server..." -- Slice C).
///
/// Security & Architecture Invariants:
/// 1. Explicit User Initiation Only: Never scans the LAN (`Bonjour` / `NWBrowser`) or auto-connects to unrequested hosts.
/// 2. Zero Password Persistence: Strips any embedded password from user-typed URLs immediately during validation;
///    never writes passwords to `recentServerAddresses`, logs, URL strings, or `UserDefaults`.
/// 3. Exact Existing Mount Reuse: Parses `statfs` (`f_fstypename` + `f_mntfromname`) and matches protocol,
///    case-insensitive host, effective port, and percent-decoded case-sensitive share path without substring guessing.
/// 4. Attempt Generation Isolation: Every connect attempt is bound to a monotonically increasing `activeAttemptGeneration`;
///    cancelled or superseded attempts never overwrite newer state or trigger stale window navigation.
@Observable
@MainActor
public final class ServerConnectionService {
    public static let shared = ServerConnectionService()

    public static let recentServersKey = "com.metastudyline.ttzip.recent_servers.v1"
    public static let maxRecentServers = 10

    public private(set) var state: ServerConnectionState = .idle
    public private(set) var recentServerAddresses: [String] = []
    public private(set) var activeAttemptGeneration: UInt64 = 0

    private let transport: any ServerMountTransport
    private let userDefaults: UserDefaults
    private var activeLaunchTask: Task<Void, Never>?
    private var activeConnectTask: Task<URL?, Never>?

    /// Optional hook for tests to override already-mounted volume lookup directly.
    public var existingMountLookupOverride: ((ValidatedServerEndpoint) -> URL?)?

    /// Optional hook providing mounted volume source metadata for deterministic endpoint matching tests.
    public var mountedVolumeSourcesProvider: (() -> [MountedVolumeSourceDescriptor])?

    /// Optional hook for sandbox access verification on mounted network volumes.
    public var volumeAccessCheckOverride: ((URL) async -> Bool)?

    public init(
        transport: any ServerMountTransport = SystemNetFSMountTransport(),
        userDefaults: UserDefaults = .standard,
        loadRecentsOnInit: Bool = true
    ) {
        self.transport = transport
        self.userDefaults = userDefaults
        if loadRecentsOnInit {
            loadRecentServers()
        }
    }

    // MARK: - Channel Capability Reporting

    public static var channelCapabilitySummary: (isSandboxedMASBuild: Bool, description: String) {
        #if DIRECT_DISTRIBUTION || DIRECT_BUILD
        return (
            false,
            AppLocalizationState.shared.uiString(
                zh: "Direct 渠道：支持 SMB/AFP/NFS 系统挂载并直接浏览已挂载卷",
                en: "Direct Channel: Supports SMB/AFP/NFS system mounting and direct volume browsing"
            )
        )
        #else
        return (
            true,
            AppLocalizationState.shared.uiString(
                zh: "MAS 沙盒渠道：支持 SMB/AFP/NFS 系统认证挂载，首次访问挂载点若需沙盒授权将自动请求文件夹权限",
                en: "MAS Sandboxed Channel: Supports SMB/AFP/NFS system mount; prompts for folder access if required by App Sandbox"
            )
        )
        #endif
    }

    // MARK: - URL Parsing, Validation & Password Scrubbing

    public nonisolated static func defaultPort(for scheme: SupportedNetworkShareScheme) -> Int {
        switch scheme {
        case .smb: return 445
        case .afp: return 548
        case .nfs: return 2049
        }
    }

    /// Validates raw user input and returns a credential-scrubbed `ValidatedServerEndpoint`.
    public nonisolated static func validateServerInput(
        _ rawInput: String,
        defaultScheme: SupportedNetworkShareScheme = .smb
    ) -> Result<ValidatedServerEndpoint, ServerAddressValidationError> {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        let normalizedResult = normalizeSchemePrefix(trimmed, defaultScheme: defaultScheme)
        guard case .success(let normalizedString) = normalizedResult else {
            if case .failure(let err) = normalizedResult { return .failure(err) }
            return .failure(.invalidSyntax(trimmed))
        }

        guard let components = URLComponents(string: normalizedString),
              components.percentEncodedQuery == nil,
              components.fragment == nil else {
            return .failure(.invalidSyntax(trimmed))
        }
        guard let schemeRaw = components.scheme?.lowercased(),
              let scheme = SupportedNetworkShareScheme(rawValue: schemeRaw) else {
            return .failure(.unsupportedScheme(components.scheme ?? ""))
        }
        guard let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return .failure(.missingHost)
        }
        guard let cleanSharePath = normalizeDecodedSharePath(fromPercentEncodedPath: components.percentEncodedPath) else {
            return .failure(.invalidSyntax(trimmed))
        }

        let endpoint = ValidatedServerEndpoint(
            scheme: scheme,
            host: host,
            port: components.port,
            sharePath: cleanSharePath,
            username: sanitizeUsername(components.user)
        )
        guard endpoint.sanitizedURL != nil else {
            return .failure(.invalidSyntax(trimmed))
        }
        return .success(endpoint)
    }

    private nonisolated static func normalizeSchemePrefix(
        _ trimmed: String,
        defaultScheme: SupportedNetworkShareScheme
    ) -> Result<String, ServerAddressValidationError> {
        if let schemeRange = trimmed.range(of: "://") {
            let rawScheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
            guard SupportedNetworkShareScheme(rawValue: rawScheme) != nil else {
                return .failure(.unsupportedScheme(rawScheme))
            }
            return .success(trimmed)
        }
        if let firstColon = trimmed.firstIndex(of: ":"), !trimmed.hasPrefix("[") {
            let prefixBeforeColon = String(trimmed[..<firstColon]).lowercased()
            let afterColon = String(trimmed[trimmed.index(after: firstColon)...])
            let portCandidate = afterColon.split(separator: "/", maxSplits: 1).first.map(String.init) ?? afterColon
            if UInt16(portCandidate) != nil {
                return .success("\(defaultScheme.rawValue)://\(trimmed)")
            }
            guard SupportedNetworkShareScheme(rawValue: prefixBeforeColon) != nil else {
                return .failure(.unsupportedScheme(prefixBeforeColon))
            }
            return .success(trimmed)
        }
        return .success("\(defaultScheme.rawValue)://\(trimmed)")
    }

    /// Splits a percent-encoded path by `/` prior to percent-decoding so escaped slashes (`%2F`)
    /// are rejected rather than misinterpreted as path separators, and normalizes segments to NFC.
    public nonisolated static func normalizeDecodedSharePath(fromPercentEncodedPath encodedPath: String) -> String? {
        if encodedPath.isEmpty || encodedPath == "/" {
            return ""
        }
        let rawSegments = encodedPath.split(separator: "/", omittingEmptySubsequences: true)
        var decodedSegments: [String] = []
        decodedSegments.reserveCapacity(rawSegments.count)

        for rawSeg in rawSegments {
            let lowerSeg = rawSeg.lowercased()
            if lowerSeg.contains("%2f") || lowerSeg.contains("%5c") || lowerSeg.contains("%00") {
                return nil
            }
            guard let decoded = String(rawSeg).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != ".." else {
                return nil
            }
            decodedSegments.append(decoded.precomposedStringWithCanonicalMapping)
        }
        return decodedSegments.isEmpty ? "" : "/" + decodedSegments.joined(separator: "/")
    }

    private nonisolated static func sanitizeUsername(_ rawUser: String?) -> String? {
        guard let u = rawUser?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty else {
            return nil
        }
        return u
    }

    public nonisolated static func sanitizeURLForPersistence(_ rawInput: String) -> String? {
        guard case .success(let endpoint) = validateServerInput(rawInput) else {
            return nil
        }
        return endpoint.sanitizedAddressString
    }

    // MARK: - Connection Lifecycle (Connect / Cancel / Reuse Existing Mount)

    @discardableResult
    public func connect(
        rawInput: String,
        defaultScheme: SupportedNetworkShareScheme = .smb,
        allowAuthenticationUI: Bool = true,
        commitMountedURL: ((URL) -> Void)? = nil
    ) async -> Result<URL, ServerConnectionFailureReason> {
        activeLaunchTask?.cancel()
        activeLaunchTask = nil
        activeConnectTask?.cancel()
        activeConnectTask = nil
        activeAttemptGeneration &+= 1
        let attemptGen = activeAttemptGeneration

        switch Self.validateServerInput(rawInput, defaultScheme: defaultScheme) {
        case .failure(let validationError):
            let reason = ServerConnectionFailureReason.validationError(validationError)
            state = .failed(reason)
            return .failure(reason)

        case .success(let endpoint):
            state = .connecting(endpoint: endpoint)
            return await executeValidatedConnect(
                endpoint: endpoint,
                allowAuthenticationUI: allowAuthenticationUI,
                attemptGen: attemptGen,
                commitMountedURL: commitMountedURL
            )
        }
    }

    public func beginConnect(
        rawInput: String,
        defaultScheme: SupportedNetworkShareScheme = .smb,
        allowAuthenticationUI: Bool = true,
        commitMountedURL: @escaping (URL) -> Void
    ) {
        activeLaunchTask?.cancel()
        activeLaunchTask = nil
        activeConnectTask?.cancel()
        activeConnectTask = nil
        activeAttemptGeneration &+= 1
        let attemptGen = activeAttemptGeneration

        switch Self.validateServerInput(rawInput, defaultScheme: defaultScheme) {
        case .failure(let validationError):
            state = .failed(.validationError(validationError))
            return

        case .success(let endpoint):
            state = .connecting(endpoint: endpoint)
            let commit = commitMountedURL
            activeLaunchTask = Task { @MainActor [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.activeAttemptGeneration == attemptGen else {
                    return
                }
                _ = await self.executeValidatedConnect(
                    endpoint: endpoint,
                    allowAuthenticationUI: allowAuthenticationUI,
                    attemptGen: attemptGen,
                    commitMountedURL: commit
                )
            }
        }
    }

    private func executeValidatedConnect(
        endpoint: ValidatedServerEndpoint,
        allowAuthenticationUI: Bool,
        attemptGen: UInt64,
        commitMountedURL: ((URL) -> Void)?
    ) async -> Result<URL, ServerConnectionFailureReason> {
        guard !Task.isCancelled, activeAttemptGeneration == attemptGen else {
            return .failure(.mountFailed(code: ECANCELED, message: "Connection superseded or cancelled"))
        }

        if let existingURL = findAlreadyMountedVolume(for: endpoint) {
            return await reuseMountedVolume(
                existingURL,
                endpoint: endpoint,
                attemptGen: attemptGen,
                commitMountedURL: commitMountedURL
            )
        }

        let task = Task<URL?, Never> { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.activeAttemptGeneration == attemptGen else {
                return nil
            }
            return await self.performTransportMount(
                endpoint: endpoint,
                allowAuthenticationUI: allowAuthenticationUI,
                attemptGen: attemptGen
            )
        }

        activeConnectTask = task
        let mountedURL = await task.value
        guard activeAttemptGeneration == attemptGen else {
            return .failure(.mountFailed(code: ECANCELED, message: "Connection superseded or cancelled"))
        }
        activeConnectTask = nil
        activeLaunchTask = nil

        if let mountedURL, !Task.isCancelled {
            commitMountedURL?(mountedURL)
            return .success(mountedURL)
        }
        if case .failed(let reason) = state {
            return .failure(reason)
        }
        return .failure(.mountFailed(code: ECANCELED, message: "Connection cancelled"))
    }

    private func reuseMountedVolume(
        _ existingURL: URL,
        endpoint: ValidatedServerEndpoint,
        attemptGen: UInt64,
        commitMountedURL: ((URL) -> Void)?
    ) async -> Result<URL, ServerConnectionFailureReason> {
        guard !Task.isCancelled, activeAttemptGeneration == attemptGen else {
            return .failure(.mountFailed(code: ECANCELED, message: "Cancelled"))
        }
        let authorized = await verifyOrRequestVolumeAccess(for: existingURL)
        guard activeAttemptGeneration == attemptGen else {
            return .failure(.mountFailed(code: ECANCELED, message: "Cancelled"))
        }
        guard !Task.isCancelled else {
            state = .cancelled
            return .failure(.mountFailed(code: ECANCELED, message: "Cancelled"))
        }
        guard authorized else {
            let reason = ServerConnectionFailureReason.sandboxAuthorizationDeclined(existingURL.path)
            state = .failed(reason)
            return .failure(reason)
        }
        recordRecentServer(endpoint: endpoint)
        MountedVolumeManager.shared.refresh()
        state = .connected(mountPointURL: existingURL, reusedExistingMount: true)
        commitMountedURL?(existingURL)
        return .success(existingURL)
    }

    private func performTransportMount(
        endpoint: ValidatedServerEndpoint,
        allowAuthenticationUI: Bool,
        attemptGen: UInt64
    ) async -> URL? {
        guard !Task.isCancelled, activeAttemptGeneration == attemptGen else {
            return nil
        }
        do {
            let mountedURLs = try await transport.mountShare(
                endpoint: endpoint,
                allowAuthenticationUI: allowAuthenticationUI
            )
            guard activeAttemptGeneration == attemptGen else {
                return nil
            }
            guard !Task.isCancelled else {
                state = .cancelled
                return nil
            }
            guard let primaryURL = mountedURLs.first else {
                state = .failed(.shareNotFound(endpoint.sanitizedAddressString))
                return nil
            }
            let authorized = await verifyOrRequestVolumeAccess(for: primaryURL)
            guard activeAttemptGeneration == attemptGen else {
                return nil
            }
            guard !Task.isCancelled else {
                state = .cancelled
                return nil
            }
            guard authorized else {
                state = .failed(.sandboxAuthorizationDeclined(primaryURL.path))
                return nil
            }
            recordRecentServer(endpoint: endpoint)
            MountedVolumeManager.shared.refresh()
            state = .connected(mountPointURL: primaryURL, reusedExistingMount: false)
            return primaryURL
        } catch {
            applyTransportError(error, attemptGen: attemptGen)
            return nil
        }
    }

    private func applyTransportError(_ error: Error, attemptGen: UInt64) {
        guard activeAttemptGeneration == attemptGen else { return }
        if error is CancellationError {
            state = .cancelled
        } else if let reason = error as? ServerConnectionFailureReason {
            state = .failed(reason)
        } else {
            state = .failed(.mountFailed(code: -1, message: error.localizedDescription))
        }
    }

    public func cancelActiveConnection(resetToIdle: Bool = false) {
        activeAttemptGeneration &+= 1
        activeLaunchTask?.cancel()
        activeLaunchTask = nil
        activeConnectTask?.cancel()
        activeConnectTask = nil
        state = resetToIdle ? .idle : .cancelled
    }

    public func resetState() {
        cancelActiveConnection(resetToIdle: true)
    }

    // MARK: - Exact Mounted Volume Endpoint Identity Matching

    public func findAlreadyMountedVolume(for endpoint: ValidatedServerEndpoint) -> URL? {
        if let override = existingMountLookupOverride {
            return override(endpoint)
        }
        let targetShare = endpoint.sharePath.precomposedStringWithCanonicalMapping
        guard !targetShare.isEmpty else {
            return nil
        }
        let targetHost = endpoint.host.lowercased()
        let targetPort = endpoint.port ?? Self.defaultPort(for: endpoint.scheme)

        let descriptors = mountedVolumeSourcesProvider?() ?? Self.readSystemMountedVolumeSources()
        for desc in descriptors {
            guard let parsed = Self.parseMountedVolumeEndpoint(from: desc) else { continue }
            if parsed.scheme == endpoint.scheme,
               parsed.host == targetHost,
               parsed.effectivePort == targetPort,
               parsed.sharePath == targetShare {
                return desc.mountPointURL.standardizedFileURL
            }
        }
        return nil
    }

    private static func readSystemMountedVolumeSources() -> [MountedVolumeSourceDescriptor] {
        var list: [MountedVolumeSourceDescriptor] = []
        for volume in MountedVolumeManager.shared.mountedVolumes where volume.path != "/" {
            var sfs = statfs()
            guard volume.path.withCString({ statfs($0, &sfs) }) == 0 else { continue }
            let fsType = withUnsafePointer(to: &sfs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                    String(cString: $0)
                }
            }
            let mountFrom = withUnsafePointer(to: &sfs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                    String(cString: $0)
                }
            }
            list.append(
                MountedVolumeSourceDescriptor(
                    mountPointURL: volume.url.standardizedFileURL,
                    volumeName: volume.name,
                    fileSystemTypeName: fsType,
                    mountFromName: mountFrom
                )
            )
        }
        return list
    }

    public nonisolated static func parseMountedVolumeEndpoint(
        from descriptor: MountedVolumeSourceDescriptor
    ) -> (scheme: SupportedNetworkShareScheme, host: String, effectivePort: Int, sharePath: String)? {
        guard let fsScheme = resolveFileSystemScheme(descriptor.fileSystemTypeName) else {
            return nil
        }
        let rawMountFrom = descriptor.mountFromName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let urlString = buildCandidateMountURLString(rawMountFrom: rawMountFrom, fsScheme: fsScheme),
              let components = URLComponents(string: urlString),
              components.percentEncodedQuery == nil,
              components.fragment == nil,
              let rawHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty,
              let sharePath = normalizeDecodedSharePath(fromPercentEncodedPath: components.percentEncodedPath),
              !sharePath.isEmpty else {
            return nil
        }
        let port = components.port ?? defaultPort(for: fsScheme)
        return (scheme: fsScheme, host: rawHost.lowercased(), effectivePort: port, sharePath: sharePath)
    }

    private nonisolated static func resolveFileSystemScheme(_ fsTypeName: String) -> SupportedNetworkShareScheme? {
        switch fsTypeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "smbfs", "cifs": return .smb
        case "afpfs": return .afp
        case "nfs": return .nfs
        default: return nil
        }
    }

    private nonisolated static func buildCandidateMountURLString(
        rawMountFrom: String,
        fsScheme: SupportedNetworkShareScheme
    ) -> String? {
        guard !rawMountFrom.isEmpty else { return nil }
        if let range = rawMountFrom.range(of: "://") {
            let explicitScheme = String(rawMountFrom[..<range.lowerBound]).lowercased()
            let mappedScheme: SupportedNetworkShareScheme? = (explicitScheme == "cifs")
                ? .smb
                : SupportedNetworkShareScheme(rawValue: explicitScheme)
            guard mappedScheme == fsScheme else { return nil }
            return rawMountFrom
        }
        if rawMountFrom.hasPrefix("//") {
            guard fsScheme == .smb || fsScheme == .afp else { return nil }
            return "\(fsScheme.rawValue):\(rawMountFrom)"
        }
        if fsScheme == .nfs, let colonIdx = rawMountFrom.firstIndex(of: ":") {
            let hostPart = String(rawMountFrom[..<colonIdx])
            let pathPart = String(rawMountFrom[rawMountFrom.index(after: colonIdx)...])
            guard !hostPart.isEmpty,
                  !hostPart.contains("/"),
                  !hostPart.contains("@"),
                  pathPart.hasPrefix("/") else {
                return nil
            }
            return "nfs://\(hostPart)\(pathPart)"
        }
        return nil
    }

    private func verifyOrRequestVolumeAccess(for mountURL: URL) async -> Bool {
        if let override = volumeAccessCheckOverride {
            return await override(mountURL)
        }
        if FileManager.default.isReadableFile(atPath: mountURL.path) {
            _ = RootFolderAccessManager.shared.persistBookmark(for: mountURL)
            return true
        }
        return await RootFolderAccessManager.shared.ensureAccess(for: mountURL, promptIfMissing: true)
    }

    // MARK: - Recent Server Addresses (Sanitized, Zero Credentials)

    public func recordRecentServer(endpoint: ValidatedServerEndpoint) {
        let sanitized = endpoint.sanitizedAddressString
        guard !sanitized.isEmpty else { return }
        var updated = recentServerAddresses.filter { $0.caseInsensitiveCompare(sanitized) != .orderedSame }
        updated.insert(sanitized, at: 0)
        if updated.count > Self.maxRecentServers {
            updated = Array(updated.prefix(Self.maxRecentServers))
        }
        recentServerAddresses = updated
        userDefaults.set(updated, forKey: Self.recentServersKey)
    }

    public func removeRecentServer(_ address: String) {
        recentServerAddresses.removeAll { $0 == address }
        userDefaults.set(recentServerAddresses, forKey: Self.recentServersKey)
    }

    public func clearRecentServers() {
        recentServerAddresses.removeAll()
        userDefaults.removeObject(forKey: Self.recentServersKey)
    }

    public func loadRecentServers() {
        let rawList = userDefaults.stringArray(forKey: Self.recentServersKey) ?? []
        var scrubbed: [String] = []
        for entry in rawList {
            if case .success(let endpoint) = Self.validateServerInput(entry) {
                let clean = endpoint.sanitizedAddressString
                if !scrubbed.contains(clean) {
                    scrubbed.append(clean)
                }
            }
        }
        recentServerAddresses = Array(scrubbed.prefix(Self.maxRecentServers))
    }

    // MARK: - NetFS Error Classification

    public nonisolated static func classifyNetFSStatus(
        _ status: Int32,
        host: String,
        sharePath: String
    ) -> ServerConnectionFailureReason {
        switch status {
        case EACCES, EPERM, Int32(afpAccessDenied):
            return .permissionDenied(host)
        case EAUTH, ENEEDAUTH, Int32(afpBadUAM), Int32(afpUserNotAuth):
            return .authenticationFailed(host)
        case ENOENT:
            return .shareNotFound(sharePath.isEmpty ? host : sharePath)
        case ETIMEDOUT, EHOSTDOWN, EHOSTUNREACH, ENETUNREACH, ECONNREFUSED:
            return .hostUnreachable(host)
        default:
            return .mountFailed(
                code: status,
                message: "Unable to mount server share “\(host)” (NetFS status \(status))."
            )
        }
    }
}
