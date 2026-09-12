// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import FileProvider
import Foundation

/// Coordinates registration and lifecycle of virtual archive mount domains with the macOS FileProvider daemon.
@MainActor
public final class ArchiveMountCoordinator: ObservableObject {
    public static let shared = ArchiveMountCoordinator()
    public static let appGroupId = "group.com.metastudyline.ttzip"

    @Published public private(set) var mountedArchives: [String: URL] = [:]

    private init() {
        refreshMountedDomains()
    }

    /// Mounts an archive file as a read-only virtual filesystem visible in Finder's sidebar.
    @discardableResult
    public func mountArchive(at url: URL) async throws -> NSFileProviderDomain {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
                NSLocalizedDescriptionKey: "Target archive does not exist at: \(url.path)"
            ])
        }

        let domainIdentifier = "ttzip_mount_" + UUID().uuidString.prefix(8).lowercased()
        let displayName = url.lastPathComponent
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifier),
            displayName: displayName
        )

        // Store archive path in the shared App Group defaults for extension consumption
        let defaults = UserDefaults(suiteName: Self.appGroupId)
        defaults?.set(url.path, forKey: "mount_domain_\(domainIdentifier)")

        // Register domain with the system FileProvider daemon
        try await NSFileProviderManager.add(domain)

        mountedArchives[domainIdentifier] = url
        return domain
    }

    /// Unmounts an active archive domain and invalidates its virtual hierarchy.
    public func unmountArchive(domainIdentifier: String) async throws {
        let domains = try await NSFileProviderManager.domains()
        guard let targetDomain = domains.first(where: { $0.identifier.rawValue == domainIdentifier }) else {
            return
        }

        try await NSFileProviderManager.remove(targetDomain)

        let defaults = UserDefaults(suiteName: Self.appGroupId)
        defaults?.removeObject(forKey: "mount_domain_\(domainIdentifier)")

        mountedArchives.removeValue(forKey: domainIdentifier)
    }

    /// Refreshes the local active mount registry against system daemon state.
    public func refreshMountedDomains() {
        Task {
            do {
                let domains = try await NSFileProviderManager.domains()
                let defaults = UserDefaults(suiteName: Self.appGroupId)
                var updated: [String: URL] = [:]

                for domain in domains {
                    let id = domain.identifier.rawValue
                    if id.hasPrefix("ttzip_mount_"),
                       let path = defaults?.string(forKey: "mount_domain_\(id)") {
                        updated[id] = URL(fileURLWithPath: path)
                    }
                }

                self.mountedArchives = updated
            } catch {
                // System daemon query may fail in sandboxed tests without entitlements
            }
        }
    }
}
