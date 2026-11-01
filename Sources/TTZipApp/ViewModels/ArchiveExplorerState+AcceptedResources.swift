// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
#if canImport(TTZipAppServices)
import TTZipAppServices
#endif

struct AcceptedArchiveResource {
    let projection: AcceptedArchiveDirectoryProjection
    let evidence: ArchivePasswordEvidenceState
}

extension ArchiveExplorerState {
    internal func installAcceptedArchiveProjection(
        _ projection: AcceptedArchiveDirectoryProjection,
        evidence: ArchivePasswordEvidenceState,
        for sessionID: UUID
    ) {
        acceptedArchiveResources[sessionID, default: [:]][projection.archivePath] =
            AcceptedArchiveResource(projection: projection, evidence: evidence)
    }

    public func acceptedArchiveProjection(
        for sessionID: UUID, archivePath: String
    ) -> AcceptedArchiveDirectoryProjection? {
        let key = URL(fileURLWithPath: archivePath).standardizedFileURL.path
        return acceptedArchiveResources[sessionID]?[key]?.projection
    }

    internal func acceptedArchiveEvidence(
        for sessionID: UUID, archivePath: String
    ) -> ArchivePasswordEvidenceState? {
        let key = URL(fileURLWithPath: archivePath).standardizedFileURL.path
        return acceptedArchiveResources[sessionID]?[key]?.evidence
    }

    /// Updates only this accepted resource's evidence, retaining its existing projection.
    internal func updateAcceptedArchiveEvidence(
        _ evidence: ArchivePasswordEvidenceState, for sessionID: UUID, archivePath: String
    ) {
        let key = URL(fileURLWithPath: archivePath).standardizedFileURL.path
        guard let resource = acceptedArchiveResources[sessionID]?[key] else { return }
        acceptedArchiveResources[sessionID]?[key] = AcceptedArchiveResource(
            projection: resource.projection, evidence: evidence
        )
    }

    internal func discardAcceptedArchiveProjections(for sessionID: UUID) {
        acceptedArchiveResources.removeValue(forKey: sessionID)
    }

    internal func retainAcceptedArchiveProjections(for liveSessionIDs: Set<UUID>) {
        acceptedArchiveResources = acceptedArchiveResources.filter { liveSessionIDs.contains($0.key) }
    }

    internal func invalidateAcceptedArchiveProjections(archivePath: String) {
        let key = URL(fileURLWithPath: archivePath).standardizedFileURL.path
        for sessionID in Array(acceptedArchiveResources.keys) {
            acceptedArchiveResources[sessionID]?.removeValue(forKey: key)
            if acceptedArchiveResources[sessionID]?.isEmpty == true {
                acceptedArchiveResources.removeValue(forKey: sessionID)
            }
        }
    }

    internal func invalidateAcceptedArchiveProjections(logicalKey: String) {
        for sessionID in Array(acceptedArchiveResources.keys) {
            acceptedArchiveResources[sessionID] = acceptedArchiveResources[sessionID]?.filter {
                ArchiveCredentialIdentity.logicalKey(for: $0.key) != logicalKey
            }
            if acceptedArchiveResources[sessionID]?.isEmpty == true {
                acceptedArchiveResources.removeValue(forKey: sessionID)
            }
        }
    }

    /// Root supplies paths reachable from each existing session history; no second history is stored.
    internal func pruneAcceptedArchiveProjections(reachablePaths: [UUID: Set<String>]) {
        for sessionID in Array(acceptedArchiveResources.keys) {
            guard let paths = reachablePaths[sessionID] else {
                acceptedArchiveResources.removeValue(forKey: sessionID)
                continue
            }
            acceptedArchiveResources[sessionID] = acceptedArchiveResources[sessionID]?.filter {
                paths.contains($0.key)
            }
            if acceptedArchiveResources[sessionID]?.isEmpty == true {
                acceptedArchiveResources.removeValue(forKey: sessionID)
            }
        }
    }

    internal func discardAllAcceptedArchiveProjections() {
        acceptedArchiveResources.removeAll()
    }

}
