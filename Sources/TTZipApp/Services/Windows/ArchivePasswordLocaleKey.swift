// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
#if canImport(TTI18nCore)
import TTI18nCore
import TTI18nUI
#endif

/// Strongly-typed localization keys for archive password verification, error classification,
/// and original operation resumption (Q1-ISSUE-07).
public enum ArchivePasswordLocaleKey: String, TTZipCore.LocaleKeyProtocol, CaseIterable, Sendable {
    case incorrectPassword = "archive.password.incorrect_password"
    case archiveCorrupted = "archive.password.archive_corrupted"
    case unsupportedFormatOrEncryption = "archive.password.unsupported_format_or_encryption"
    case permissionDenied = "archive.password.permission_denied"
    case fileNotFound = "archive.password.file_not_found"
    case operationCancelled = "archive.password.operation_cancelled"
    case verificationFailedGeneric = "archive.password.verification_failed_generic"
    case directoryBrowsableUnverifiedStatus = "archive.password.directory_browsable_unverified"
    case passwordVerifiedStatus = "archive.password.password_verified_status"
    case credentialsExpiredReenter = "archive.password.credentials_expired_reenter"

    public static let corruptedArchive: Self = .archiveCorrupted
    public static let unsupportedEncryption: Self = .unsupportedFormatOrEncryption
    public static let unsupportedFormat: Self = .unsupportedFormatOrEncryption

    public var rawKey: String { rawValue }

    /// Resolves the localized string for the given `TTZipCore.AppLanguage` (defaults to current language).
    @MainActor
    public func localized(for language: TTZipCore.AppLanguage? = nil) -> String {
        let lang = language ?? TTZipUI.AppLocalizationState.shared.currentLanguage
        return translation(for: lang)
    }

    public func translation(for language: TTZipCore.AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawValue }
        switch language {
        case .zhHans:
            return values.zh
        case .zhHant:
            return values.hant
        default:
            return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .incorrectPassword: (
            "Incorrect password. Please verify and try again.",
            "密码错误，请核对后重试。",
            "密碼錯誤，請核對後重試。"
        ),
        .archiveCorrupted: (
            "Archive header or payload is corrupted and cannot be decrypted.",
            "归档文件头或数据已损坏，无法解密或提取。",
            "歸檔檔案標頭或資料已損毀，無法解密或擷取。"
        ),
        .unsupportedFormatOrEncryption: (
            "Unsupported archive format or encryption algorithm.",
            "不支持的归档格式或加密算法。",
            "不支援的歸檔格式或加密演算法。"
        ),
        .permissionDenied: (
            "Permission denied while accessing archive or destination folder.",
            "访问归档或目标目录权限不足。",
            "存取歸檔或目標目錄權限不足。"
        ),
        .fileNotFound: (
            "Archive file or destination path was not found.",
            "未找到归档文件或目标路径。",
            "找不到歸檔檔案或目標路徑。"
        ),
        .operationCancelled: (
            "Decryption cancelled",
            "已取消解密操作",
            "已取消解密操作"
        ),
        .verificationFailedGeneric: (
            "Unable to complete archive operation.",
            "无法完成归档操作。",
            "無法完成歸檔操作。"
        ),
        .directoryBrowsableUnverifiedStatus: (
            "Directory loaded (encrypted entries require password verification)",
            "已读取目录列表（加密内容待验证密码）",
            "已讀取目錄列表（加密內容待驗證密碼）"
        ),
        .passwordVerifiedStatus: (
            "Password verified",
            "密码已验证",
            "密碼已驗證"
        ),
        .credentialsExpiredReenter: (
            "Saved password is no longer valid for this entry. Please enter the password.",
            "已缓存的密码对该条目无效，请重新输入密码。",
            "已快取的密碼對該項目無效，請重新輸入密碼。"
        )
    ]
}

#if canImport(TTI18nCore)
extension ArchivePasswordLocaleKey: FallbackLocaleKeyProtocol {
    public func fallbackTranslation(for language: TTI18nCore.AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawValue }
        switch language {
        case .zhHans:
            return values.zh
        case .zhHant:
            return values.hant
        default:
            return values.en
        }
    }
}
#endif

/// Scope of cryptographic password verification achieved for an archive.
public enum ArchivePasswordVerificationScope: Sendable, Equatable {
    case headerCatalog
    case selectedEntries(Set<String>)
    case fullArchive

    public static func entries(_ paths: Set<String>) -> Self {
        .selectedEntries(paths)
    }
}

/// Three-tier password evidence state distinguishing unverified catalog listing from cryptographic proof.
public enum ArchivePasswordEvidenceState: Sendable, Equatable {
    case notEncrypted
    case directoryBrowsableUnverified
    case candidate
    case verified(ArchivePasswordVerificationScope)

    public var isCryptographicallyVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// Distinct failure categories surfaced during archive password verification and resumption.
public enum ArchivePasswordFailureCategory: Sendable, Equatable {
    case wrongPassword
    case corruptedArchive
    case unsupportedFormatOrEncryption
    case permissionDenied
    case fileNotFound
    case cancelled
    case other(String)

    public var isPasswordFailure: Bool {
        self == .wrongPassword
    }
}

/// Explicit four-way outcome for encrypted entry payload probing, keeping verification scope
/// strictly separate from `.noAvailableEvidence` (`directoryBrowsableUnverified`), `.wrongPassword`,
/// and `.otherFailure`.
public enum ArchivePasswordProbeOutcome: Sendable, Equatable {
    case verified(ArchivePasswordVerificationScope)
    case noAvailableEvidence
    case wrongPassword(message: String)
    case otherFailure(category: ArchivePasswordFailureCategory, message: String)
}

/// Result returned to `PasswordPromptSheetView` when submitting a candidate password.
public enum ArchivePasswordSubmissionResult: Sendable, Equatable {
    case verifiedAndResumed
    case wrongPassword(message: String)
    case nonPasswordFailure(category: ArchivePasswordFailureCategory, message: String)
    case cancelledOrStale
    case alreadyInFlight

    public var isSuccess: Bool {
        self == .verifiedAndResumed
    }

    public var errorMessage: String? {
        switch self {
        case .verifiedAndResumed, .cancelledOrStale, .alreadyInFlight:
            return nil
        case .wrongPassword(let message), .nonPasswordFailure(_, let message):
            return message
        }
    }
}

/// Concrete typed error representing non-password probe failure.
public struct ArchivePasswordProbeFailure: Error, Sendable, Equatable {
    public let category: ArchivePasswordFailureCategory
    public let message: String

    public init(category: ArchivePasswordFailureCategory, message: String) {
        self.category = category
        self.message = message
    }
}

/// Classifies `ArchiveError` and `NSError` instances so non-password errors are never misreported as wrong passwords.
public enum ArchivePasswordErrorClassifier {
    @MainActor
    private static func localizedText(for key: ArchivePasswordLocaleKey, l10n: TTZipUI.AppLocalizationState) -> String {
        let text = l10n.t(key)
        if text == key.rawKey {
            return key.localized(for: l10n.currentLanguage)
        }
        return text
    }

    @MainActor
    public static func classify(_ error: Error, l10n: TTZipUI.AppLocalizationState = .shared) -> (category: ArchivePasswordFailureCategory, message: String) {
        if let probe = error as? ArchivePasswordProbeFailure {
            return (probe.category, probe.message)
        }
        if error is CancellationError {
            return (.cancelled, localizedText(for: .operationCancelled, l10n: l10n))
        }
        if let archiveError = error as? ArchiveError {
            return classifyArchiveError(archiveError, l10n: l10n)
        }
        if let classified = classifySystemError(error as NSError, l10n: l10n) {
            return classified
        }
        return (.other(error.localizedDescription), error.localizedDescription)
    }

    @MainActor
    private static func classifySystemError(
        _ nsError: NSError, l10n: TTZipUI.AppLocalizationState
    ) -> (category: ArchivePasswordFailureCategory, message: String)? {
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
                return (.permissionDenied, localizedText(for: .permissionDenied, l10n: l10n))
            }
            if nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
                return (.fileNotFound, localizedText(for: .fileNotFound, l10n: l10n))
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                return (.permissionDenied, localizedText(for: .permissionDenied, l10n: l10n))
            }
            if nsError.code == Int(ENOENT) {
                return (.fileNotFound, localizedText(for: .fileNotFound, l10n: l10n))
            }
        }
        return nil
    }

    @MainActor
    private static func classifyArchiveError(
        _ archiveError: ArchiveError,
        l10n: TTZipUI.AppLocalizationState
    ) -> (category: ArchivePasswordFailureCategory, message: String) {
        switch archiveError {
        case .passwordRequired, .passwordRequiredDetailed, .wrongPassword:
            return (.wrongPassword, localizedText(for: .incorrectPassword, l10n: l10n))
        case .corruptHeader, .corruptedData:
            return (.corruptedArchive, localizedText(for: .corruptedArchive, l10n: l10n))
        case .unsupportedEncryptionMethod:
            return (.unsupportedFormatOrEncryption, localizedText(for: .unsupportedEncryption, l10n: l10n))
        case .invalidFormat:
            return (.unsupportedFormatOrEncryption, localizedText(for: .unsupportedFormat, l10n: l10n))
        case .fileNotFound:
            return (.fileNotFound, localizedText(for: .fileNotFound, l10n: l10n))
        case .cancelled, .extractionStopped:
            return (.cancelled, localizedText(for: .operationCancelled, l10n: l10n))
        case .engineFailure(_, let detail):
            return classifyIOErrorDetail(detail, l10n: l10n)
        case .partialExtractionFailure(let outcome):
            return classifyPartialExtractionOutcome(outcome, fallbackDescription: archiveError.localizedDescription, l10n: l10n)
        default:
            return (.other(archiveError.localizedDescription), archiveError.localizedDescription)
        }
    }

    @MainActor
    private static func classifyIOErrorDetail(
        _ detail: String,
        l10n: TTZipUI.AppLocalizationState
    ) -> (category: ArchivePasswordFailureCategory, message: String) {
        let lower = detail.lowercased()
        if lower.contains("permission denied") || lower.contains("operation not permitted") || lower.contains("eacces") {
            return (.permissionDenied, localizedText(for: .permissionDenied, l10n: l10n))
        }
        return (.other(detail), detail)
    }

    @MainActor
    private static func classifyPartialExtractionOutcome(
        _ outcome: ExtractionOutcome,
        fallbackDescription: String,
        l10n: TTZipUI.AppLocalizationState
    ) -> (category: ArchivePasswordFailureCategory, message: String) {
        let reasons = outcome.failed.map(\.reason)
        if reasons.contains(.permissionDenied) {
            return (.permissionDenied, l10n.t(ArchivePasswordLocaleKey.permissionDenied))
        }
        if reasons.contains(.notSupportedByVolume) {
            return (.unsupportedFormatOrEncryption, l10n.t(ArchivePasswordLocaleKey.unsupportedFormat))
        }
        return (.other(fallbackDescription), fallbackDescription)
    }

    public static func errorForProbeFailure(
        category: ArchivePasswordFailureCategory,
        archivePath: String,
        message: String
    ) -> ArchiveError {
        switch category {
        case .wrongPassword:
            return .wrongPassword(archivePath: archivePath)
        case .corruptedArchive:
            return .corruptHeader
        case .unsupportedFormatOrEncryption:
            return .unsupportedEncryptionMethod(archivePath: archivePath, method: message)
        case .fileNotFound:
            return .fileNotFound
        case .cancelled:
            return .cancelled
        case .permissionDenied, .other:
            return .engineFailure(code: -500, message: message)
        }
    }
}

/// Policy governing encrypted entry selection and budget bounds for plaintext-catalog password probing.
public enum ArchivePasswordProbePolicy {
    public static let maxProbeEntryBytes: Int64 = 64 * 1024 * 1024

    public static func normalizeEntryPath(_ path: String) -> String {
        var cleaned = path.replacingOccurrences(of: "\\", with: "/")
        while cleaned.hasPrefix("/") {
            cleaned.removeFirst()
        }
        while cleaned.hasSuffix("/") && cleaned.count > 1 {
            cleaned.removeLast()
        }
        return cleaned
    }

    /// Selects the smallest non-empty encrypted file entry whose uncompressed size does not exceed `maxProbeBytes`.
    public static func selectProbeEntry(
        from entries: [ArchiveEntry],
        maxProbeBytes: Int64 = maxProbeEntryBytes
    ) -> ArchiveEntry? {
        entries
            .filter { !$0.isDirectory && $0.isEncrypted && $0.uncompressedSize > 0 && $0.uncompressedSize <= maxProbeBytes }
            .min { lhs, rhs in
                if lhs.uncompressedSize != rhs.uncompressedSize {
                    return lhs.uncompressedSize < rhs.uncompressedSize
                }
                return normalizeEntryPath(lhs.path) < normalizeEntryPath(rhs.path)
            }
    }
}

extension ArchiveInspectionResult {
    public init(
        archivePath: String,
        format: String = "zip",
        entries: [ArchiveEntry],
        totalUncompressedBytes: Int64 = 0,
        totalCompressedBytes: Int64 = 0,
        unlockedPassword: String? = nil
    ) {
        let tree = ArchiveComponentTreeBuilder.buildTree(from: entries)
        let report = SecurityScanner.shared.scanEntriesForReport(entries)
        self.init(
            archivePath: archivePath,
            entries: entries,
            treeNode: tree,
            securityReport: report,
            unlockedPassword: unlockedPassword
        )
    }
}
