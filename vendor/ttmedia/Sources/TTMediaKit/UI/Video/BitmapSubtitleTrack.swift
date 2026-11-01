// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

internal struct BitmapSubtitleTrack: Sendable {
    struct Composition: Decodable, Sendable {
        let x: UInt16
        let y: UInt16
        let width: UInt16
        let height: UInt16
        let pngBase64: Data
    }

    struct Cue: Decodable, Sendable {
        let start: Double
        let end: Double
        let canvasWidth: UInt16
        let canvasHeight: UInt16
        let compositions: [Composition]
    }

    let cues: [Cue]

    init(cues: [Cue]) throws {
        guard cues.count <= 50_000 else { throw CocoaError(.fileReadCorruptFile) }
        var encodedBytes = 0
        for cue in cues {
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start,
                  cue.canvasWidth > 0, cue.canvasHeight > 0,
                  cue.canvasWidth <= 8_192, cue.canvasHeight <= 8_192,
                  cue.compositions.count <= 64 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for image in cue.compositions {
                guard image.width > 0, image.height > 0,
                      Int(image.x) + Int(image.width) <= Int(cue.canvasWidth),
                      Int(image.y) + Int(image.height) <= Int(cue.canvasHeight),
                      image.pngBase64.count <= 16 * 1024 * 1024 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                encodedBytes += image.pngBase64.count
                guard encodedBytes <= 16 * 1024 * 1024 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        self.cues = cues.sorted { $0.start < $1.start }
    }

    func activeCue(at seconds: Double) -> (index: Int, cue: Cue)? {
        guard seconds.isFinite else { return nil }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].start <= seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        let index = lower - 1
        let cue = cues[index]
        return seconds < cue.end ? (index, cue) : nil
    }
}
