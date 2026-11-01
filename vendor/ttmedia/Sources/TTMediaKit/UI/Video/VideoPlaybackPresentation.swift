// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreGraphics

public extension Notification.Name {
    static let ttMediaVideoGeometryChanged = Notification.Name("TTMediaVideoGeometryChanged")
}

/// Host-facing geometry is derived from the same state used by the display layer and subtitles.
@MainActor
public enum VideoPlaybackPresentation {
    public static func orientedSize(for url: URL) -> CGSize? {
        guard let session = VideoPlaybackSessions.shared.current,
              session.canonicalURL == url.standardizedFileURL.resolvingSymlinksInPath(),
              let raw = session.rawVideoNaturalSize else { return nil }
        let size = VideoContentGeometry.orientedDisplaySize(
            rawVideoSize: raw,
            pixelAspectRatio: session.videoPixelAspectRatio,
            rotationDegrees: session.effectiveRotationDegrees
        )
        return size.width > 0 && size.height > 0 ? size : nil
    }
}

extension VideoPlaybackSession {
    func publishPresentationGeometry() {
        NotificationCenter.default.post(name: .ttMediaVideoGeometryChanged, object: url)
    }
}
