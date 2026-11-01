// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Darwin
import TTZipCore
import TTZipUI

// MARK: - Forensic Path Protection & Candidate Verification

/// Forensic system boundary guard preventing accidental or malicious modification of protected system paths,
/// user credentials, version-controlled source trees, and out-of-scope targets.
public enum ForensicPathGuard {
    private static let forbiddenSystemPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/var",
        "/private",
        "/Applications",
        "/Library",
        "/Volumes",
        "/dev",
        "/cores",
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Keychains"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".gnupg"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".aws"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".kube"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".docker"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/gcloud"),
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari"),
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mail"),
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages"),
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/IdentityServices"),
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mobile Documents"),
    ]

    private static let allowedDeveloperCacheSubtrees: [String] = [
        "/private/var/folders",
        "/var/folders",
        "/tmp",
        "/private/tmp",
    ]

    private static let gradleMarkerFiles: [String] = [
        "build.gradle",
        "build.gradle.kts",
        "settings.gradle",
        "settings.gradle.kts",
    ]

    /// Standard Cache Directory Tagging Specification signature line.
    public static let cacheDirTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    /// Verifies whether the candidate path resides within a forbidden system or credential directory.
    public static func isProtectedSystemPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return true }
        if (trimmed as NSString).pathComponents.contains("..") {
            return true
        }

        let canonical = resolveCanonicalPath(trimmed)
        let homeCanonical = resolveCanonicalPath(NSHomeDirectory())
        if canonical == "/" || canonical == homeCanonical {
            return true
        }

        for allowedTemp in allowedDeveloperCacheSubtrees {
            let allowedCanonical = resolveCanonicalPath(allowedTemp)
            if isStrictDescendant(childPath: canonical, ofRootPath: allowedCanonical) {
                return false
            }
        }

        for forbidden in forbiddenSystemPrefixes {
            let forbiddenCanonical = resolveCanonicalPath(forbidden)
            if isSameOrDescendant(path: canonical, ofPrefix: forbiddenCanonical) {
                return true
            }
        }
        return false
    }

    /// Checks whether `childPath` is a strict descendant of `rootPath` using path component boundaries.
    public static func isStrictDescendant(childPath: String, ofRootPath rootPath: String) -> Bool {
        let childComponents = normalizedComponents(of: childPath)
        let rootComponents = normalizedComponents(of: rootPath)
        guard !rootComponents.isEmpty, childComponents.count > rootComponents.count else {
            return false
        }
        return Array(childComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Checks whether `path` is equal to `prefix` or a strict descendant of `prefix` on component boundaries.
    public static func isSameOrDescendant(path: String, ofPrefix prefix: String) -> Bool {
        let pathComponents = normalizedComponents(of: path)
        let prefixComponents = normalizedComponents(of: prefix)
        guard !prefixComponents.isEmpty, pathComponents.count >= prefixComponents.count else {
            return false
        }
        return Array(pathComponents.prefix(prefixComponents.count)) == prefixComponents
    }

    /// Resolves symlinks for existing path prefixes even if the leaf does not exist on disk.
    public static func resolveCanonicalPath(_ path: String) -> String {
        if let real = StorageEntryIdentity.resolveRealPath(path) {
            return real
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let parent = (standardized as NSString).deletingLastPathComponent
        let leaf = (standardized as NSString).lastPathComponent
        if !parent.isEmpty, parent != standardized, let parentReal = StorageEntryIdentity.resolveRealPath(parent) {
            return (parentReal as NSString).appendingPathComponent(leaf)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func normalizedComponents(of path: String) -> [String] {
        let standardized = (path as NSString).standardizingPath
        return (standardized as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }

    // MARK: - Candidate Subtree Safety Inspection

    /// Result of inspecting a candidate directory's full descendant tree for protected or unreadable content.
    public enum SubtreeSafetyInspectionResult: Sendable, Equatable {
        case clean(visitedEntries: Int)
        case containsProtectedContent(path: String)
        case incomplete(reason: String)
    }

    /// Default entry budget for candidate subtree safety inspection.
    public static let defaultSubtreeInspectionBudget: Int = 200_000

    private static let protectedSubtreeExactNames: Set<String> = [
        ".git", ".hg", ".svn",
        ".ssh", ".gnupg", ".aws", ".kube", ".docker",
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
    ]

    private static let protectedSubtreeSuffixes: [String] = [
        ".pem", ".keychain", ".keychain-db", ".p12", ".pfx",
    ]

    /// Returns true if an entry name inside a candidate subtree is a protected VCS or credential marker.
    public static func isProtectedSubtreeEntryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if protectedSubtreeExactNames.contains(lower) {
            return true
        }
        return protectedSubtreeSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Performs a bounded, cancellable POSIX traversal of `rootPath` to verify that no descendant
    /// contains protected VCS metadata, credentials, mount crossings, or unreadable directories.
    public static func inspectCandidateSubtreeSafety(
        atPath rootPath: String,
        cancelToken: StorageScanCancelToken = StorageScanCancelToken(),
        maxEntries: Int = defaultSubtreeInspectionBudget
    ) -> SubtreeSafetyInspectionResult {
        guard maxEntries > 0 else {
            return .incomplete(reason: "Subtree inspection budget exhausted")
        }
        var rootStat = Darwin.stat()
        guard Darwin.lstat(rootPath, &rootStat) == 0 else {
            return .incomplete(reason: "Unable to stat candidate root")
        }
        if (rootStat.st_mode & S_IFMT) != S_IFDIR {
            return .incomplete(reason: "Candidate root is not a directory")
        }

        let rootDev = UInt64(bitPattern: Int64(rootStat.st_dev))
        var stack: [String] = [rootPath]
        var visited = 0

        while let currentDir = stack.popLast() {
            if cancelToken.isCancelled {
                return .incomplete(reason: "Subtree inspection cancelled")
            }
            let step = inspectSingleDirectory(
                atPath: currentDir,
                rootDev: rootDev,
                cancelToken: cancelToken,
                maxEntries: maxEntries,
                visited: &visited,
                stack: &stack
            )
            if case .clean = step {
                continue
            }
            return step
        }
        return .clean(visitedEntries: visited)
    }

    private static func inspectSingleDirectory(
        atPath currentDir: String,
        rootDev: UInt64,
        cancelToken: StorageScanCancelToken,
        maxEntries: Int,
        visited: inout Int,
        stack: inout [String]
    ) -> SubtreeSafetyInspectionResult {
        guard let dirPtr = Darwin.opendir(currentDir) else {
            return .incomplete(reason: "Unreadable directory: \(currentDir)")
        }
        defer { Darwin.closedir(dirPtr) }

        while let entryPtr = Darwin.readdir(dirPtr) {
            if cancelToken.isCancelled {
                return .incomplete(reason: "Subtree inspection cancelled")
            }
            let name = extractDirentName(entryPtr)
            if name == "." || name == ".." || name == ".DS_Store" { continue }

            visited += 1
            if visited > maxEntries {
                return .incomplete(reason: "Subtree inspection budget exceeded (\(maxEntries))")
            }

            let childPath = (currentDir as NSString).appendingPathComponent(name)
            if isProtectedSubtreeEntryName(name) {
                return .containsProtectedContent(path: childPath)
            }

            if let stepFailure = classifySubtreeChildForTraversal(
                childPath: childPath,
                rootDev: rootDev,
                stack: &stack
            ) {
                return stepFailure
            }
        }
        return .clean(visitedEntries: visited)
    }

    private static func classifySubtreeChildForTraversal(
        childPath: String,
        rootDev: UInt64,
        stack: inout [String]
    ) -> SubtreeSafetyInspectionResult? {
        var st = Darwin.stat()
        guard Darwin.lstat(childPath, &st) == 0 else {
            return .incomplete(reason: "Unable to lstat \(childPath)")
        }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK {
            return nil
        }
        let dev = UInt64(bitPattern: Int64(st.st_dev))
        if dev != rootDev {
            return .incomplete(reason: "Cross-volume mount point inside candidate: \(childPath)")
        }
        if mode == S_IFDIR {
            stack.append(childPath)
        }
        return nil
    }

    // MARK: - Candidate Evidence Evaluation

    /// Evaluates whether a directory entry qualifies as a verified reclaimable cache, a name-only match,
    /// or a normal non-reclaimable entry.
    public static func evaluateCandidate(
        name: String,
        isDir: Bool,
        isSymlink: Bool,
        url: URL,
        scanRootPath: String = "",
        isInsidePackage: Bool = false,
        inspectSubtree: Bool = true,
        cancelToken: StorageScanCancelToken = StorageScanCancelToken(),
        maxSubtreeEntries: Int = defaultSubtreeInspectionBudget
    ) -> (category: TileCategory, verification: ReclaimVerificationStatus?, rule: ReclaimRuleKind?, reason: String) {
        let path = url.path
        if isSymlink || !isDir || isInsidePackage {
            let (cat, reason) = classifyRegularFileOrDirectory(name: name, isDir: isDir, url: url)
            return (cat, nil, nil, reason)
        }

        if isBlockedCandidateLocation(path: path, scanRootPath: scanRootPath) {
            return (.others, nil, nil, "Protected or version-controlled directory")
        }

        let hasCacheTag = hasValidCacheDirTag(inDirectory: path)
        if let matchedRule = matchNamedCacheRule(
            lowerName: name.lowercased(),
            displayName: name,
            path: path,
            hasValidCacheTag: hasCacheTag
        ) {
            return applySubtreeSafetyGate(
                candidate: matchedRule,
                path: path,
                inspectSubtree: inspectSubtree,
                cancelToken: cancelToken,
                maxSubtreeEntries: maxSubtreeEntries
            )
        }

        if hasCacheTag {
            let reason = ReclaimRuleKind.cacheDirTag.localizedReason(name: name)
            let rawCandidate: (TileCategory, ReclaimVerificationStatus?, ReclaimRuleKind?, String) = (
                .reclaimCache, .verified, .cacheDirTag, reason
            )
            return applySubtreeSafetyGate(
                candidate: rawCandidate,
                path: path,
                inspectSubtree: inspectSubtree,
                cancelToken: cancelToken,
                maxSubtreeEntries: maxSubtreeEntries
            )
        }

        let (cat, reason) = classifyRegularFileOrDirectory(name: name, isDir: isDir, url: url)
        return (cat, nil, nil, reason)
    }

    private static func applySubtreeSafetyGate(
        candidate: (category: TileCategory, verification: ReclaimVerificationStatus?, rule: ReclaimRuleKind?, reason: String),
        path: String,
        inspectSubtree: Bool,
        cancelToken: StorageScanCancelToken,
        maxSubtreeEntries: Int
    ) -> (category: TileCategory, verification: ReclaimVerificationStatus?, rule: ReclaimRuleKind?, reason: String) {
        guard inspectSubtree, candidate.verification == .verified else {
            return candidate
        }
        switch inspectCandidateSubtreeSafety(
            atPath: path,
            cancelToken: cancelToken,
            maxEntries: maxSubtreeEntries
        ) {
        case .clean:
            return candidate
        case .containsProtectedContent:
            let reason = StorageLocaleKey.outcomeRejectedSubtreeProtected.resolve()
            return (.others, .nameOnly, .unverifiedNameMatch, reason)
        case .incomplete:
            let reason = StorageLocaleKey.outcomeRejectedSubtreeIncomplete.resolve()
            return (.others, .nameOnly, .unverifiedNameMatch, reason)
        }
    }

    private static func isBlockedCandidateLocation(path: String, scanRootPath: String) -> Bool {
        if !scanRootPath.isEmpty {
            let candidateStandard = URL(fileURLWithPath: path).standardizedFileURL.path
            let rootStandard = URL(fileURLWithPath: scanRootPath).standardizedFileURL.path
            if candidateStandard == rootStandard {
                return true
            }
        }
        return containsVCSDirectory(atPath: path) || isProtectedSystemPath(path)
    }

    private static func matchNamedCacheRule(
        lowerName: String,
        displayName: String,
        path: String,
        hasValidCacheTag: Bool
    ) -> (TileCategory, ReclaimVerificationStatus?, ReclaimRuleKind?, String)? {
        let parentPath = (path as NSString).deletingLastPathComponent
        switch lowerName {
        case "node_modules":
            let ok = regularFileExists(in: parentPath, named: "package.json")
            return candidateOutcome(verified: ok, rule: .nodeModules, displayName: displayName)
        case "deriveddata":
            let ok = isVerifiedDerivedData(atPath: path)
            return candidateOutcome(verified: ok, rule: .xcodeDerivedData, displayName: displayName)
        case "target":
            let ok = isVerifiedCargoTarget(atPath: path, parentPath: parentPath, hasCacheTag: hasValidCacheTag)
            return candidateOutcome(verified: ok, rule: .cargoTarget, displayName: displayName)
        case ".build":
            let ok = regularFileExists(in: parentPath, named: "Package.swift") || hasValidCacheTag
            return candidateOutcome(verified: ok, rule: .swiftPMBuild, displayName: displayName)
        case "build":
            let ok = hasAnyRegularFile(in: parentPath, names: gradleMarkerFiles)
                || regularFileExists(in: path, named: "CMakeCache.txt")
                || hasValidCacheTag
            return candidateOutcome(verified: ok, rule: .gradleOrCMakeBuild, displayName: displayName)
        case ".gradle":
            let ok = hasAnyRegularFile(in: parentPath, names: gradleMarkerFiles) || hasValidCacheTag
            return candidateOutcome(verified: ok, rule: .gradleCache, displayName: displayName)
        case ".venv", "venv":
            let ok = regularFileExists(in: path, named: "pyvenv.cfg") || hasValidCacheTag
            return candidateOutcome(verified: ok, rule: .pythonVenv, displayName: displayName)
        case "__pycache__":
            let ok = isPurePycacheDirectory(atPath: path)
            return candidateOutcome(verified: ok, rule: .pythonPycache, displayName: displayName)
        default:
            return nil
        }
    }

    private static func candidateOutcome(
        verified: Bool,
        rule: ReclaimRuleKind,
        displayName: String
    ) -> (TileCategory, ReclaimVerificationStatus?, ReclaimRuleKind?, String) {
        if verified {
            return (.reclaimCache, .verified, rule, rule.localizedReason(name: displayName))
        }
        let reason = ReclaimRuleKind.unverifiedNameMatch.localizedReason(name: displayName)
        return (.others, .nameOnly, .unverifiedNameMatch, reason)
    }

    private static func isVerifiedDerivedData(atPath path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasSuffix("/Library/Developer/Xcode/DerivedData") {
            return true
        }
        let moduleCache = (path as NSString).appendingPathComponent("ModuleCache.noindex")
        return regularFileExists(atPath: moduleCache) || directoryExists(atPath: moduleCache)
    }

    private static func isVerifiedCargoTarget(
        atPath path: String,
        parentPath: String,
        hasCacheTag: Bool
    ) -> Bool {
        guard regularFileExists(in: parentPath, named: "Cargo.toml") else { return false }
        if hasCacheTag || regularFileExists(in: path, named: ".rustc_info.json") {
            return true
        }
        return hasCargoBuildProfileArtifacts(atPath: (path as NSString).appendingPathComponent("debug"))
            || hasCargoBuildProfileArtifacts(atPath: (path as NSString).appendingPathComponent("release"))
    }

    private static func hasCargoBuildProfileArtifacts(atPath profilePath: String) -> Bool {
        guard directoryExists(atPath: profilePath) else { return false }
        let hasDepsDir = directoryExists(atPath: (profilePath as NSString).appendingPathComponent("deps"))
        guard hasDepsDir else { return false }
        let hasFingerprintDir = directoryExists(atPath: (profilePath as NSString).appendingPathComponent(".fingerprint"))
        let hasCargoLock = regularFileExists(in: profilePath, named: ".cargo-lock")
        return hasFingerprintDir || hasCargoLock
    }

    /// Classifies a regular file or non-cache directory into a semantic `TileCategory`.
    public static func classifyRegularFileOrDirectory(name: String, isDir: Bool, url: URL) -> (TileCategory, String) {
        let ext = url.pathExtension.lowercased()
        if let mapped = extensionCategoryMap[ext] {
            return mapped
        }
        return (.others, isDir ? "Directory" : "General file")
    }

    private static let extensionCategoryMap: [String: (TileCategory, String)] = [
        "rs": (.generalCode, "Source code"), "swift": (.generalCode, "Source code"),
        "c": (.generalCode, "Source code"), "cpp": (.generalCode, "Source code"),
        "h": (.generalCode, "Source code"), "ts": (.generalCode, "Source code"),
        "js": (.generalCode, "Source code"), "go": (.generalCode, "Source code"),
        "py": (.generalCode, "Source code"), "json": (.generalCode, "Source code"),
        "toml": (.generalCode, "Source code"), "yaml": (.generalCode, "Source code"),
        "png": (.mediaImage, "Visual image"), "jpg": (.mediaImage, "Visual image"),
        "jpeg": (.mediaImage, "Visual image"), "heic": (.mediaImage, "Visual image"),
        "webp": (.mediaImage, "Visual image"), "svg": (.mediaImage, "Visual image"),
        "gif": (.mediaImage, "Visual image"),
        "mp4": (.mediaVideo, "Video stream"), "mov": (.mediaVideo, "Video stream"),
        "mkv": (.mediaVideo, "Video stream"), "webm": (.mediaVideo, "Video stream"),
        "avi": (.mediaVideo, "Video stream"),
        "mp3": (.mediaAudio, "Audio track"), "wav": (.mediaAudio, "Audio track"),
        "flac": (.mediaAudio, "Audio track"), "aac": (.mediaAudio, "Audio track"),
        "m4a": (.mediaAudio, "Audio track"),
        "zip": (.compressedArchive, "Compressed archive"), "tar": (.compressedArchive, "Compressed archive"),
        "gz": (.compressedArchive, "Compressed archive"), "7z": (.compressedArchive, "Compressed archive"),
        "rar": (.compressedArchive, "Compressed archive"), "bz2": (.compressedArchive, "Compressed archive"),
        "xz": (.compressedArchive, "Compressed archive"), "zst": (.compressedArchive, "Compressed archive"),
        "pdf": (.documentText, "Document"), "docx": (.documentText, "Document"),
        "xlsx": (.documentText, "Document"), "pptx": (.documentText, "Document"),
        "md": (.documentText, "Document"), "txt": (.documentText, "Document"),
        "csv": (.documentText, "Document"),
        "dylib": (.executableBinary, "Binary executable"), "so": (.executableBinary, "Binary executable"),
        "framework": (.executableBinary, "Binary executable"), "app": (.executableBinary, "Binary executable"),
    ]

    // MARK: - Pre-Cleanup Revalidation Gate

    /// Revalidates a candidate right before moving it to Trash, defending against TOCTOU symlink swaps,
    /// inode replacement, parent redirection, scope escape, evidence loss, and protected subtree contents.
    public static func revalidateBeforeTrash(
        item: ReclaimableStorageItem,
        authorizedScanRootPath: String,
        cancelToken: StorageScanCancelToken = StorageScanCancelToken(),
        maxSubtreeEntries: Int = defaultSubtreeInspectionBudget
    ) -> StorageCleanupRejectionReason? {
        guard item.verification == .verified else {
            return .unverifiedCandidate
        }

        let targetPath = item.path
        if isProtectedSystemPath(targetPath) {
            return .protectedSystemPath
        }

        let effectiveRoot = authorizedScanRootPath.isEmpty ? item.scanRootPath : authorizedScanRootPath
        if let scopeError = verifyScopeAndAncestors(item: item, effectiveRoot: effectiveRoot) {
            return scopeError
        }

        return verifyLiveIdentityAndEvidence(
            item: item,
            effectiveRoot: effectiveRoot,
            cancelToken: cancelToken,
            maxSubtreeEntries: maxSubtreeEntries
        )
    }

    private static func verifyScopeAndAncestors(
        item: ReclaimableStorageItem,
        effectiveRoot: String
    ) -> StorageCleanupRejectionReason? {
        let targetPath = item.path
        if !effectiveRoot.isEmpty {
            let rootReal = resolveCanonicalPath(effectiveRoot)
            if !isStrictDescendant(childPath: resolveCanonicalPath(targetPath), ofRootPath: rootReal) {
                return .outsideAuthorizedRoot
            }
        }

        let parentPath = (targetPath as NSString).deletingLastPathComponent
        guard let currentParentReal = StorageEntryIdentity.resolveRealPath(parentPath) else {
            return .symlinkOrParentChanged
        }
        if !item.identity.parentRealPath.isEmpty && currentParentReal != item.identity.parentRealPath {
            return .symlinkOrParentChanged
        }

        if !effectiveRoot.isEmpty && hasSymlinkOrMissingAncestor(from: parentPath, downTo: effectiveRoot) {
            return .symlinkOrParentChanged
        }
        return nil
    }

    private static func hasSymlinkOrMissingAncestor(from startParent: String, downTo rootPath: String) -> Bool {
        var cursor = startParent
        let stopPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        while cursor.count >= stopPath.count && cursor != "/" {
            var ancStat = Darwin.stat()
            if Darwin.lstat(cursor, &ancStat) != 0 || (ancStat.st_mode & S_IFMT) == S_IFLNK {
                return true
            }
            if cursor == stopPath { break }
            let next = (cursor as NSString).deletingLastPathComponent
            if next == cursor { break }
            cursor = next
        }
        return false
    }

    private static func verifyLiveIdentityAndEvidence(
        item: ReclaimableStorageItem,
        effectiveRoot: String,
        cancelToken: StorageScanCancelToken,
        maxSubtreeEntries: Int
    ) -> StorageCleanupRejectionReason? {
        let targetPath = item.path
        guard let liveIdentity = StorageEntryIdentity.capture(atPath: targetPath) else {
            return .identityChangedSinceScan
        }
        if liveIdentity.isSymlink || !liveIdentity.isDirectory {
            return .symlinkOrParentChanged
        }
        if item.identity.inode != 0 && (liveIdentity.inode != item.identity.inode || liveIdentity.device != item.identity.device) {
            return .identityChangedSinceScan
        }

        guard let targetReal = StorageEntryIdentity.resolveRealPath(targetPath) else {
            return .identityChangedSinceScan
        }
        if isProtectedSystemPath(targetReal) {
            return .protectedSystemPath
        }
        if !effectiveRoot.isEmpty && !isStrictDescendant(childPath: targetReal, ofRootPath: resolveCanonicalPath(effectiveRoot)) {
            return .outsideAuthorizedRoot
        }

        let recheck = evaluateCandidate(
            name: (targetPath as NSString).lastPathComponent,
            isDir: true,
            isSymlink: false,
            url: URL(fileURLWithPath: targetPath),
            scanRootPath: effectiveRoot,
            inspectSubtree: false
        )
        guard recheck.verification == .verified else {
            return .evidenceNoLongerValid
        }

        switch inspectCandidateSubtreeSafety(
            atPath: targetReal,
            cancelToken: cancelToken,
            maxEntries: maxSubtreeEntries
        ) {
        case .clean:
            return nil
        case .containsProtectedContent:
            return .subtreeContainsProtectedContent
        case .incomplete:
            return .subtreeInspectionIncomplete
        }
    }

    // MARK: - Low-Level POSIX Probes

    private static func extractDirentName(_ entryPtr: UnsafeMutablePointer<Darwin.dirent>) -> String {
        withUnsafePointer(to: entryPtr.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private static func regularFileExists(in dirPath: String, named fileName: String) -> Bool {
        regularFileExists(atPath: (dirPath as NSString).appendingPathComponent(fileName))
    }

    private static func hasAnyRegularFile(in dirPath: String, names: [String]) -> Bool {
        names.contains { regularFileExists(in: dirPath, named: $0) }
    }

    private static func regularFileExists(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func directoryExists(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func containsVCSDirectory(atPath dirPath: String) -> Bool {
        for vcs in [".git", ".hg", ".svn"] {
            var st = Darwin.stat()
            if Darwin.lstat((dirPath as NSString).appendingPathComponent(vcs), &st) == 0 {
                return true
            }
        }
        return false
    }

    private static func hasValidCacheDirTag(inDirectory dirPath: String) -> Bool {
        let tagPath = (dirPath as NSString).appendingPathComponent("CACHEDIR.TAG")
        guard regularFileExists(atPath: tagPath),
              let handle = FileHandle(forReadingAtPath: tagPath) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64),
              let prefix = String(data: data, encoding: .utf8) else {
            return false
        }
        return prefix.hasPrefix(cacheDirTagSignature)
    }

    private static func isPurePycacheDirectory(atPath dirPath: String) -> Bool {
        guard let dir = Darwin.opendir(dirPath) else { return false }
        defer { Darwin.closedir(dir) }

        var pycCount = 0
        while let entryPtr = Darwin.readdir(dir) {
            let name = extractDirentName(entryPtr)
            if name == "." || name == ".." || name == ".DS_Store" { continue }
            let lower = name.lowercased()
            if lower.hasSuffix(".pyc") || lower.hasSuffix(".pyo") {
                pycCount += 1
            } else {
                return false
            }
        }
        return pycCount > 0
    }
}
