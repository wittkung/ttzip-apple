// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipPreviewKit
#if canImport(TTZipAppServices)
import TTZipAppServices
#endif

extension AppViewState {
    public typealias VirtualEntryExtractor = @Sendable (
        _ archivePath: String,
        _ entryPath: String,
        _ destinationDir: String,
        _ password: String?
    ) async throws -> Void

    public struct VirtualPreviewResolution: Sendable {
        public let url: URL?
        public let lease: PreviewCacheLease?
        package let failure: ArchiveEntryPreviewFailure?

        public var pinnedKey: String? {
            lease?.key
        }

        public init(url: URL?, lease: PreviewCacheLease?) {
            self.url = url
            self.lease = lease
            self.failure = nil
        }

        package init(failure: ArchiveEntryPreviewFailure) {
            self.url = nil
            self.lease = nil
            self.failure = failure
        }
    }

    /// Resolves, quota-reserves, extracts, validates, and acquires a per-consumer `PreviewCacheLease` in `PreviewLRUCacheManager`.
    package static func resolveAndPinVirtualPreviewURL(
        archivePath: String,
        subpath: String,
        estimatedBytes: Int64 = 0,
        consumerID: UUID = UUID(),
        previousLease: PreviewCacheLease? = nil,
        previousPinnedKey: String? = nil,
        cacheManager: PreviewLRUCacheManager = .shared,
        passwordRequiredWithoutCache: Bool = false,
        customExtractor: VirtualEntryExtractor? = nil
    ) async -> VirtualPreviewResolution {
        await releasePreviousPreviewPin(previousLease, previousPinnedKey, cacheManager)

        let filename = (subpath as NSString).lastPathComponent
        let hash = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archivePath, subpath: subpath)

        for _ in 0..<2 {
            guard !Task.isCancelled else {
                return VirtualPreviewResolution(failure: .cancelled)
            }

            if let cachedHit = await cacheManager.acquireCachedURL(
                forKey: hash,
                expectedFilename: filename,
                consumerID: consumerID
            ) {
                return VirtualPreviewResolution(url: cachedHit.url, lease: cachedHit.lease)
            }

            if let verifiedExisting = try? await cacheManager.resolveAndRegisterExtractedPreview(
                forKey: hash,
                filename: filename,
                subpath: subpath,
                pinActive: true,
                consumerID: consumerID
            ) {
                let lease = await cacheManager.acquireLease(forKey: hash, consumerID: consumerID)
                if Task.isCancelled {
                    await cacheManager.releaseLease(lease)
                    return VirtualPreviewResolution(failure: .cancelled)
                }
                return VirtualPreviewResolution(url: verifiedExisting, lease: lease)
            }

            let reservation: PreviewStagingReservation
            do {
                reservation = try await cacheManager.acquireStagingReservation(
                    forKey: hash,
                    filename: filename,
                    estimatedBytes: max(0, estimatedBytes),
                    consumerID: consumerID,
                    pinActive: true
                )
            } catch EphemeralPreviewCacheError.concurrentStagingInProgress {
                await cacheManager.waitForInFlightStaging(forKey: hash)
                continue
            } catch {
                return VirtualPreviewResolution(failure: .captured(error))
            }

            if let passwordFailure = await passwordFailureIfNeeded(
                archivePath: archivePath, reservation: reservation,
                passwordRequiredWithoutCache: passwordRequiredWithoutCache, cacheManager: cacheManager
            ) {
                return passwordFailure
            }

            return await extractAndCommitReservation(
                reservation,
                archivePath: archivePath,
                subpath: subpath,
                filename: filename,
                consumerID: consumerID,
                cacheManager: cacheManager,
                customExtractor: customExtractor
            )
        }

        return VirtualPreviewResolution(failure: .archive(.invalidState, attemptedPassword: nil))
    }

    private static func releasePreviousPreviewPin(
        _ previousLease: PreviewCacheLease?,
        _ previousPinnedKey: String?,
        _ cacheManager: PreviewLRUCacheManager
    ) async {
        if let previousLease { await cacheManager.releaseLease(previousLease) }
        if let previousPinnedKey { await cacheManager.unpin(key: previousPinnedKey) }
    }

    private static func passwordFailureIfNeeded(
        archivePath: String,
        reservation: PreviewStagingReservation,
        passwordRequiredWithoutCache: Bool,
        cacheManager: PreviewLRUCacheManager
    ) async -> VirtualPreviewResolution? {
        guard passwordRequiredWithoutCache,
              ArchivePasswordStore.shared.getPassword(for: archivePath)?.isEmpty != false else { return nil }
        await cacheManager.cancelStagingReservation(reservation)
        return VirtualPreviewResolution(failure: .archive(.passwordRequired, attemptedPassword: nil))
    }

    private static func extractAndCommitReservation(
        _ reservation: PreviewStagingReservation,
        archivePath: String,
        subpath: String,
        filename: String,
        consumerID: UUID,
        cacheManager: PreviewLRUCacheManager,
        customExtractor: VirtualEntryExtractor?
    ) async -> VirtualPreviewResolution {
        let hash = reservation.key
        let lease = await cacheManager.acquireLease(forKey: hash, consumerID: consumerID)
        let tempDir = reservation.targetURL.deletingLastPathComponent().path
        let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)

        do {
            if let customExtractor {
                try await customExtractor(archivePath, subpath, tempDir, pwd)
            } else {
                let outcome = try await TTZipEngineFacade.shared.extractSingleEntry(
                    archivePath: archivePath,
                    entryPath: subpath,
                    destinationDir: tempDir,
                    password: pwd,
                    handling: .policy(.replace)
                )
                if outcome.status == .stopped { throw ArchiveError.extractionStopped }
                if outcome.status != .completed || !outcome.failed.isEmpty {
                    throw ArchiveError.partialExtractionFailure(outcome: outcome)
                }
            }
        } catch {
            await cacheManager.cancelStagingReservation(reservation)
            await cacheManager.releaseLease(lease)
            return VirtualPreviewResolution(failure: .captured(error, attemptedPassword: pwd))
        }

        guard !Task.isCancelled else {
            await cacheManager.cancelStagingReservation(reservation)
            await cacheManager.releaseLease(lease)
            return VirtualPreviewResolution(failure: .cancelled)
        }

        if let verified = try? await cacheManager.resolveAndRegisterExtractedPreview(
            forKey: hash,
            filename: filename,
            subpath: subpath,
            pinActive: true,
            consumerID: consumerID,
            reservationID: reservation.id
        ) {
            if Task.isCancelled {
                await cacheManager.releaseLease(lease)
                return VirtualPreviewResolution(failure: .cancelled)
            }
            return VirtualPreviewResolution(url: verified, lease: lease)
        }

        await cacheManager.cancelStagingReservation(reservation)
        await cacheManager.releaseLease(lease)
        return VirtualPreviewResolution(failure: .archive(.fileNotFound, attemptedPassword: nil))
    }

    /// Unlocks only the captured selected entry from its already accepted catalog.
    internal func verifyAndResumeAcceptedEntryPreview(
        context: ArchivePasswordOperationContext,
        request: ArchiveEntryPreviewRequest,
        candidate: String
    ) async throws {
        guard isPasswordOperationStillCurrent(operationID: context.operationID, epoch: context.captureEpoch),
              isArchiveEntryPreviewRequestCurrent(request),
              context.tabID == request.sessionID,
              context.archivePath == request.archivePath,
              let projection = explorerState.acceptedArchiveProjection(
                for: request.sessionID, archivePath: context.archivePath
              ) else { throw CancellationError() }
        guard let selectedEntry = projection.entries.first(where: {
            ArchivePasswordProbePolicy.normalizeEntryPath($0.path)
                == ArchivePasswordProbePolicy.normalizeEntryPath(request.entryPath)
        }) else { throw ArchiveError.fileNotFound }
        let outcome = await verifyPlaintextCatalogPassword(
            archivePath: context.archivePath, entries: [selectedEntry], password: candidate
        )
        guard isPasswordOperationStillCurrent(operationID: context.operationID, epoch: context.captureEpoch),
              isArchiveEntryPreviewRequestCurrent(request) else { throw CancellationError() }

        switch outcome {
        case .verified(let scope):
            let evidence = ArchivePasswordEvidenceState.verified(scope)
            ArchivePasswordStore.shared.setPassword(candidate, for: context.archivePath)
            explorerState.activePassword = candidate
            passwordEvidenceState = evidence
            explorerState.updateAcceptedArchiveEvidence(
                evidence, for: request.sessionID, archivePath: context.archivePath
            )
            taskState.statusMessage = ArchivePasswordLocaleKey.passwordVerifiedStatus.localized()
            AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: context.archivePath,
                userInfo: ["windowID": windowID, "previewEntryPath": request.entryPath]
            )
        case .noAvailableEvidence:
            let message = ArchivePasswordLocaleKey.verificationFailedGeneric.localized()
            throw ArchivePasswordProbeFailure(category: .other(message), message: message)
        case .wrongPassword:
            throw ArchiveError.wrongPassword(archivePath: context.archivePath)
        case .otherFailure(let category, let message):
            throw ArchivePasswordProbeFailure(category: category, message: message)
        }
    }
}
