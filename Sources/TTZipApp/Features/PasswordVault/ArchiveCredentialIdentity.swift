// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import TTZipCore

/// Binds a remembered credential to the path and file generation of every archive volume.
public struct ArchiveCredentialIdentity: Equatable, Sendable {
    public let sourcePath: String
    public let volumePaths: [String]
    public let logicalKey: String
    public let key: String

    public static func logicalKey(for archivePath: String) -> String {
        let path = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
        let source: String
        if let suffix = path.range(of: #"\.\d{3}$"#, options: .regularExpression) {
            source = String(path[..<suffix.lowerBound]) + ".001"
        } else {
            source = path
        }
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func resolve(
        archivePath: String,
        fileManager: FileManager = .default
    ) -> ArchiveCredentialIdentity? {
        let requested = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
        let firstPath: String
        if let suffix = requested.range(of: #"\.\d{3}$"#, options: .regularExpression) {
            firstPath = String(requested[..<suffix.lowerBound]) + ".001"
        } else {
            firstPath = requested
        }

        let paths: [String]
        if firstPath != requested || firstPath.hasSuffix(".001") {
            guard let discovered = try? detectSplitVolumeChain(seedPath: firstPath),
                  !discovered.isEmpty else { return nil }
            paths = discovered.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            guard paths.contains(requested) else { return nil }
        } else {
            paths = [requested]
        }

        var components: [String] = []
        for path in paths {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else {
                return nil
            }
            let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
            components.append("\(path)\u{0}\(device)\u{0}\(inode)\u{0}\(size)\u{0}\(modified.timeIntervalSince1970.bitPattern)\u{0}\(created)")
        }

        let contentDigest = SHA256.hash(data: Data(components.joined(separator: "\u{1}").utf8))
        return ArchiveCredentialIdentity(
            sourcePath: paths[0],
            volumePaths: paths,
            logicalKey: logicalKey(for: requested),
            key: contentDigest.map { String(format: "%02x", $0) }.joined()
        )
    }
}
