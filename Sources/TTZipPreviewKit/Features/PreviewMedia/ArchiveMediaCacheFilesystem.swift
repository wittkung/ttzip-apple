// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Darwin
import Foundation

extension ArchiveMediaCachePool {
    nonisolated static func setupCacheDirectory(at root: URL) {
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    nonisolated static func pathVariants(for url: URL) -> [String] {
        let standard = url.standardizedFileURL.path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return standard == resolved ? [standard] : [standard, resolved]
    }

    nonisolated static func pruneUnprotectedItems(
        in directory: URL,
        protectedPaths: Set<String>
    ) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for child in children {
            let candidates = pathVariants(for: child)
            if candidates.contains(where: { protectedPaths.contains($0) }) {
                continue
            }
            let isAncestor = candidates.contains { candidate in
                let prefix = candidate.hasSuffix("/") ? candidate : candidate + "/"
                return protectedPaths.contains { $0.hasPrefix(prefix) }
            }
            if isAncestor {
                pruneUnprotectedItems(in: child, protectedPaths: protectedPaths)
            } else {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    public nonisolated static func sourceFileIdentityToken(at archivePath: String) -> String {
        var st = stat()
        guard stat(archivePath, &st) == 0 else {
            return "absent"
        }
        return "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec)"
    }

    public nonisolated static func computeCacheKey(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32
    ) -> String {
        cacheKey(
            archivePath: archivePath,
            sourceIdentity: sourceFileIdentityToken(at: archivePath),
            entryPath: entryPath,
            uncompressedSize: uncompressedSize,
            crc32: crc32
        )
    }

    nonisolated static func cacheKey(
        archivePath: String,
        sourceIdentity: String,
        entryPath: String,
        uncompressedSize: Int64,
        crc32: UInt32
    ) -> String {
        sha256Hex("\(archivePath)\0\(sourceIdentity)\0\(entryPath)\0\(uncompressedSize)\0\(crc32)")
    }

    public nonisolated static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func sanitizeFileName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let base = (last as NSString).deletingPathExtension
        let ext = (last as NSString).pathExtension

        let invalidChars = CharacterSet(charactersIn: "/\\?%*|\"<>:;\0")
        let cleanedBase = base.components(separatedBy: invalidChars).joined(separator: "_")
        let safeBase = cleanedBase.isEmpty ? "media_item" : cleanedBase

        if ext.isEmpty {
            return safeBase
        } else {
            return "\(safeBase).\(ext)"
        }
    }

    private nonisolated static func isRegularNonSymlinkFile(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private nonisolated static func isSymbolicLink(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private nonisolated static func isCandidateWithinDirectory(_ fileURL: URL, directory: URL) -> Bool {
        guard !isSymbolicLink(at: directory.path),
              isRegularNonSymlinkFile(at: fileURL.path) else {
            return false
        }
        let dirStandard = directory.standardizedFileURL.path
        let fileStandard = fileURL.standardizedFileURL.path
        let dirStandardPrefix = dirStandard.hasSuffix("/") ? dirStandard : dirStandard + "/"
        guard fileStandard.hasPrefix(dirStandardPrefix) else { return false }

        let relTail = String(fileStandard.dropFirst(dirStandardPrefix.count))
        var stepURL = URL(fileURLWithPath: dirStandard, isDirectory: true)
        for seg in relTail.split(separator: "/").map(String.init) {
            if seg.isEmpty || seg == "." || seg == ".." { return false }
            stepURL.appendPathComponent(seg)
            if isSymbolicLink(at: stepURL.path) { return false }
        }

        let dirResolved = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let fileResolved = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let dirResolvedPrefix = dirResolved.hasSuffix("/") ? dirResolved : dirResolved + "/"
        return fileResolved.hasPrefix(dirResolvedPrefix)
    }

    nonisolated static func locateExtractedFile(in directory: URL, expectedName: String) -> URL? {
        let direct = directory.appendingPathComponent(expectedName)
        if isCandidateWithinDirectory(direct, directory: directory) {
            return direct
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            guard sanitizeFileName(fileURL.lastPathComponent) == expectedName || fileURL.lastPathComponent == expectedName else {
                continue
            }
            if isCandidateWithinDirectory(fileURL, directory: directory) {
                return fileURL
            }
        }
        return nil
    }
}
