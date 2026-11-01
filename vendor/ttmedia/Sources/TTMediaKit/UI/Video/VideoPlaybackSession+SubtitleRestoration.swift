// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

struct PendingSubtitleSelection: Equatable, Sendable {
    let id: String
    let generation: UUID
}

extension VideoPlaybackSession {
    func isPrimarySubtitleSelectionPending(_ id: String) -> Bool {
        pendingPrimarySubtitleSelection == PendingSubtitleSelection(id: id, generation: subtitleLoadGeneration)
    }

    func isSecondarySubtitleSelectionPending(_ id: String) -> Bool {
        pendingSecondarySubtitleSelection == PendingSubtitleSelection(id: id, generation: secondarySubtitleLoadGeneration)
    }

    func finishPrimarySubtitleSelection(id: String, generation: UUID) {
        guard subtitleLoadGeneration == generation,
              pendingPrimarySubtitleSelection == PendingSubtitleSelection(id: id, generation: generation) else { return }
        pendingPrimarySubtitleSelection = nil
        subtitleLoadTask = nil
    }

    func finishSecondarySubtitleSelection(id: String, generation: UUID) {
        guard secondarySubtitleLoadGeneration == generation,
              pendingSecondarySubtitleSelection == PendingSubtitleSelection(id: id, generation: generation) else { return }
        pendingSecondarySubtitleSelection = nil
        secondarySubtitleLoadTask = nil
    }

    func mergePreservedExternalSubtitlesIfNeeded() {
        guard !isMergingPreservedSubtitles else { return }
        isMergingPreservedSubtitles = true
        defer { isMergingPreservedSubtitles = false }
        for fileURL in companionSubtitles where !preservedExternalSubtitles.contains(fileURL) {
            preservedExternalSubtitles.append(fileURL)
        }
        for fileURL in preservedExternalSubtitles where !companionSubtitles.contains(fileURL) && !directorySubtitles.contains(fileURL) {
            companionSubtitles.append(fileURL)
        }
    }

    func registerPreservedExternalURL(from subtitleID: String?) {
        guard let subtitleID, subtitleID != "off",
              let fileURL = URL(string: subtitleID), fileURL.isFileURL else { return }
        if !preservedExternalSubtitles.contains(fileURL) {
            preservedExternalSubtitles.append(fileURL)
        }
    }

    func restoreSelectedSubtitlesAfterDiscoveryIfNeeded() {
        validateRestoredSubtitleAvailability()
        mergePreservedExternalSubtitlesIfNeeded()
        if let primaryID = selectedSubtitleID, primaryID != "off",
           subtitleTrack == nil, bitmapSubtitleTrack == nil,
           !isPrimarySubtitleSelectionPending(primaryID) {
            if let cached = subtitleCache[primaryID] {
                subtitleTrack = cached
            } else if let cached = bitmapSubtitleCache[primaryID] {
                bitmapSubtitleTrack = cached
            } else if let fileURL = URL(string: primaryID), fileURL.isFileURL {
                loadExternalSubtitle(fileURL, showFeedback: false)
            } else {
                selectSubtitle(primaryID, showFeedback: false)
            }
        }
        if selectedSecondarySubtitleID != "off", secondarySubtitleTrack == nil,
           !isSecondarySubtitleSelectionPending(selectedSecondarySubtitleID) {
            if let cached = subtitleCache[selectedSecondarySubtitleID] {
                secondarySubtitleTrack = cached
            } else if let fileURL = URL(string: selectedSecondarySubtitleID), fileURL.isFileURL {
                if !companionSubtitles.contains(fileURL) && !directorySubtitles.contains(fileURL) {
                    companionSubtitles.append(fileURL)
                }
                selectSecondarySubtitle(selectedSecondarySubtitleID)
            } else {
                selectSecondarySubtitle(selectedSecondarySubtitleID)
            }
        }
        refreshActiveSubtitleTexts()
    }
}
