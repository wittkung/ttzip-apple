// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import Observation
import TTZipCore
import TTZipUI

/// Validated target resolved by `GoToFolderNavigationService` for the "Go to Folder..." panel.
public enum GoToFolderResolvedTarget: Sendable, Equatable {
    case directory(URL)
    case archiveFile(URL)
    case plainFileReveal(URL)

    public var url: URL {
        switch self {
        case .directory(let url), .archiveFile(let url), .plainFileReveal(let url):
            return url
        }
    }
}

/// Validation or resolution failure surfaced inline inside the "Go to Folder…" panel.
/// When an error occurs, the panel remains open so the user can edit and retry or cancel.
public enum GoToFolderValidationError: Error, LocalizedError, Sendable, Equatable {
    case emptyInput
    case invalidFileURL(String)
    case pathDoesNotExist(String)
    case accessDenied(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Please enter a folder or archive path."
        case .invalidFileURL(let raw):
            return "Invalid local file URL: “\(raw)”."
        case .pathDoesNotExist(let resolvedPath):
            return "The folder or path “\(resolvedPath)” could not be found. Check the path and try again."
        case .accessDenied(let resolvedPath):
            return "Read permission was not granted for “\(resolvedPath)”."
        case .cancelled:
            return "Navigation cancelled."
        }
    }

    @MainActor
    public var localizedMessage: String {
        switch self {
        case .emptyInput:
            return AppLocalizationState.shared.uiString(
                zh: "请输入文件夹或归档路径。",
                en: "Please enter a folder or archive path."
            )
        case .invalidFileURL(let raw):
            return AppLocalizationState.shared.uiString(
                zh: "无效的本地文件 URL：“\(raw)”。",
                en: "Invalid local file URL: “\(raw)”."
            )
        case .pathDoesNotExist(let resolvedPath):
            return AppLocalizationState.shared.uiString(
                zh: "找不到该文件夹或路径：“\(resolvedPath)”。请检查路径后重试。",
                en: "The folder or path “\(resolvedPath)” could not be found. Check the path and try again."
            )
        case .accessDenied(let resolvedPath):
            return AppLocalizationState.shared.uiString(
                zh: "未授予对路径 “\(resolvedPath)” 的读取权限。",
                en: "Read permission was not granted for “\(resolvedPath)”."
            )
        case .cancelled:
            return AppLocalizationState.shared.uiString(
                zh: "已取消前往文件夹。",
                en: "Navigation cancelled."
            )
        }
    }
}

/// Service handling address parsing, tilde/file-URL normalization, autocompletion,
/// existence validation, and sandbox authorization for the "Go to Folder..." panel.
///
/// Reuses `AcceptedArchiveDirectoryProjection.isLocalArchiveAddress`, `POSIXPathSanitizer`,
/// and `AsyncPathAutocompletionEngine` without touching S1/S2 search engine sources.
@Observable
@MainActor
public final class GoToFolderNavigationService {
    public let autocompletionEngine: AsyncPathAutocompletionEngine
    public var inputText: String = ""
    public var inlineErrorMessage: String?
    public var isResolvingAccess: Bool = false
    public private(set) var activeAttemptGeneration: UInt64 = 0

    /// Optional access verifier override for deterministic unit tests.
    public var accessCheckOverride: ((URL) async -> Bool)?

    private var activeSubmissionTask: Task<Void, Never>?

    public init(autocompletionEngine: AsyncPathAutocompletionEngine = AsyncPathAutocompletionEngine()) {
        self.autocompletionEngine = autocompletionEngine
    }

    public func prepareForPresentation(initialPath: String?, baseDirectory: URL) {
        cancelActiveSubmission()
        let seed = initialPath ?? baseDirectory.standardizedFileURL.path
        inputText = seed
        inlineErrorMessage = nil
        autocompletionEngine.query(rawInput: seed, baseDirectory: baseDirectory)
    }

    public func updateInput(_ newText: String, baseDirectory: URL) {
        inputText = newText
        if inlineErrorMessage != nil {
            inlineErrorMessage = nil
        }
        autocompletionEngine.query(rawInput: newText, baseDirectory: baseDirectory)
    }

    public func applySuggestion(_ suggestion: AddressBarSuggestionItem, baseDirectory: URL) {
        let completed = suggestion.isDirectory && !suggestion.path.hasSuffix("/")
            ? suggestion.path + "/"
            : suggestion.path
        inputText = completed
        inlineErrorMessage = nil
        autocompletionEngine.query(rawInput: completed, baseDirectory: baseDirectory)
    }

    /// Invalidates any in-flight validation/authorization attempt so its late completion cannot navigate or mutate state.
    public func cancelActiveSubmission() {
        activeAttemptGeneration &+= 1
        activeSubmissionTask?.cancel()
        activeSubmissionTask = nil
        isResolvingAccess = false
    }

    /// Verifies that `url` is a strictly local filesystem URL:
    /// - `file` scheme (`isFileURL == true`)
    /// - Empty authority (`nil` or `""`) or `localhost` (case-insensitive)
    /// - Zero credentials (`user == nil && password == nil`) and zero port (`port == nil`)
    /// - Zero query (`percentEncodedQuery == nil`) and zero fragment (`fragment == nil`)
    /// - Absolute path starting with `"/"`
    public nonisolated static func isLocalFilesystemURL(_ url: URL) -> Bool {
        guard AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedQuery == nil,
              components.fragment == nil,
              components.path.hasPrefix("/") else {
            return false
        }
        return true
    }

    private nonisolated static func stripMatchingOuterQuotes(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Parses and normalizes user input supporting:
    /// - Absolute POSIX paths (`/Users/...`, `/Volumes/...`)
    /// - Tilde paths (`~`, `~/Downloads`, `~/Documents/...`)
    /// - Relative paths resolved against `baseDirectory`
    /// - Strictly local `file://` URLs (`file:///...` or `file://localhost/...` with no credentials, port, query, or fragment)
    public nonisolated static func parseInputToCanonicalURL(
        rawInput: String,
        relativeTo baseDirectory: URL? = nil
    ) -> Result<URL, GoToFolderValidationError> {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        let unquoted = stripMatchingOuterQuotes(trimmed)
        guard !unquoted.isEmpty else {
            return .failure(.emptyInput)
        }

        let lower = unquoted.lowercased()
        if lower.hasPrefix("file:") || unquoted.contains("://") {
            guard lower.hasPrefix("file://"),
                  let parsed = URL(string: unquoted),
                  isLocalFilesystemURL(parsed),
                  !parsed.path.isEmpty else {
                return .failure(.invalidFileURL(trimmed))
            }
            return .success(URL(fileURLWithPath: parsed.path).standardizedFileURL)
        }

        let sanitizedPath = POSIXPathSanitizer.sanitize(rawInput: trimmed, relativeTo: baseDirectory)
        guard !sanitizedPath.isEmpty else {
            return .failure(.emptyInput)
        }
        return .success(URL(fileURLWithPath: sanitizedPath).standardizedFileURL)
    }

    /// Validates existence and resolves whether the target is a directory, archive, or plain file.
    /// Rejects non-local URLs and never materializes dataless cloud files (`DatalessProtection.withMaterializationDisabled`).
    public nonisolated static func validateTargetOnDisk(
        url: URL
    ) -> Result<GoToFolderResolvedTarget, GoToFolderValidationError> {
        guard isLocalFilesystemURL(url) else {
            return .failure(.invalidFileURL(url.absoluteString))
        }
        let canonicalURL = URL(fileURLWithPath: url.path).standardizedFileURL
        let path = canonicalURL.path
        var st = Darwin.stat()
        let statResult = DatalessProtection.withMaterializationDisabled {
            lstat(path, &st)
        }
        if statResult != 0 {
            let code = errno
            if code == EACCES || code == EPERM {
                return .success(.directory(canonicalURL))
            }
            return .failure(.pathDoesNotExist(path))
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return .success(.directory(canonicalURL))
        }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFDIR {
            return .success(.directory(canonicalURL))
        }
        let ext = canonicalURL.pathExtension.lowercased()
        if ArchiveCompressionFormat.from(extensionOrName: ext) != nil
            || ArchiveCompressionFormat.from(extensionOrName: canonicalURL.lastPathComponent) != nil {
            return .success(.archiveFile(canonicalURL))
        }
        return .success(.plainFileReveal(canonicalURL))
    }

    /// Validates `inputText`, requests sandbox authorization via `RootFolderAccessManager.shared` if needed,
    /// and returns the resolved navigation target.
    public func validateAndAuthorize(
        baseDirectory: URL,
        expectedGeneration: UInt64? = nil,
        capturedInputText: String? = nil
    ) async -> Result<GoToFolderResolvedTarget, GoToFolderValidationError> {
        let gen: UInt64
        if let expectedGeneration {
            guard !Task.isCancelled, activeAttemptGeneration == expectedGeneration else {
                return .failure(.cancelled)
            }
            gen = expectedGeneration
        } else {
            activeAttemptGeneration &+= 1
            gen = activeAttemptGeneration
        }
        let rawInput = capturedInputText ?? inputText
        inlineErrorMessage = nil

        switch Self.parseInputToCanonicalURL(rawInput: rawInput, relativeTo: baseDirectory) {
        case .failure(let err):
            inlineErrorMessage = err.localizedMessage
            return .failure(err)

        case .success(let candidateURL):
            switch Self.validateTargetOnDisk(url: candidateURL) {
            case .failure(let err):
                inlineErrorMessage = err.localizedMessage
                return .failure(err)

            case .success(let resolvedTarget):
                return await authorizeAndConfirmTarget(
                    resolvedTarget,
                    candidateURL: candidateURL,
                    attemptGen: gen
                )
            }
        }
    }

    private func authorizeAndConfirmTarget(
        _ resolvedTarget: GoToFolderResolvedTarget,
        candidateURL: URL,
        attemptGen: UInt64
    ) async -> Result<GoToFolderResolvedTarget, GoToFolderValidationError> {
        guard !Task.isCancelled, activeAttemptGeneration == attemptGen else {
            return .failure(.cancelled)
        }
        let authURL: URL = {
            switch resolvedTarget {
            case .directory(let u): return u
            case .archiveFile(let u), .plainFileReveal(let u):
                return u.deletingLastPathComponent().standardizedFileURL
            }
        }()

        isResolvingAccess = true
        let granted: Bool
        if let override = accessCheckOverride {
            granted = await override(authURL)
        } else if FileManager.default.isReadableFile(atPath: authURL.path) {
            _ = RootFolderAccessManager.shared.persistBookmark(for: authURL)
            granted = true
        } else {
            granted = await RootFolderAccessManager.shared.ensureAccess(for: authURL, promptIfMissing: true)
        }

        guard !Task.isCancelled, activeAttemptGeneration == attemptGen else {
            return .failure(.cancelled)
        }
        isResolvingAccess = false

        guard granted else {
            let err = GoToFolderValidationError.accessDenied(candidateURL.path)
            inlineErrorMessage = err.localizedMessage
            return .failure(err)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDir) else {
            let err = GoToFolderValidationError.pathDoesNotExist(candidateURL.path)
            inlineErrorMessage = err.localizedMessage
            return .failure(err)
        }
        if isDir.boolValue {
            return .success(.directory(candidateURL))
        }
        return .success(resolvedTarget)
    }

    /// Runs validation and authorization under a new attempt generation and invokes `commitTarget`
    /// in the same synchronous `@MainActor` boundary upon completion if the attempt is still current.
    @discardableResult
    public func submit(
        baseDirectory: URL,
        commitTarget: (GoToFolderResolvedTarget) -> Void
    ) async -> Result<GoToFolderResolvedTarget, GoToFolderValidationError> {
        activeAttemptGeneration &+= 1
        let attemptGen = activeAttemptGeneration
        let submittedInput = inputText
        activeSubmissionTask?.cancel()
        activeSubmissionTask = nil

        let outcome = await validateAndAuthorize(
            baseDirectory: baseDirectory,
            expectedGeneration: attemptGen,
            capturedInputText: submittedInput
        )
        guard !Task.isCancelled, activeAttemptGeneration == attemptGen else {
            return .failure(.cancelled)
        }
        if case .success(let target) = outcome {
            commitTarget(target)
        }
        return outcome
    }

    /// Launches a tracked submission task owned by this service so `cancelActiveSubmission()`
    /// or sheet dismissal invalidates any in-flight authorization before navigation can occur.
    public func beginSubmit(
        baseDirectory: URL,
        commitTarget: @escaping (GoToFolderResolvedTarget) -> Void
    ) {
        activeAttemptGeneration &+= 1
        let attemptGen = activeAttemptGeneration
        let submittedInput = inputText
        let attemptCommitTarget = commitTarget
        activeSubmissionTask?.cancel()

        activeSubmissionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.activeAttemptGeneration == attemptGen else { return }
            let outcome = await self.validateAndAuthorize(
                baseDirectory: baseDirectory,
                expectedGeneration: attemptGen,
                capturedInputText: submittedInput
            )
            guard !Task.isCancelled, self.activeAttemptGeneration == attemptGen else { return }
            self.activeSubmissionTask = nil
            if case .success(let target) = outcome {
                attemptCommitTarget(target)
            }
        }
    }
}
