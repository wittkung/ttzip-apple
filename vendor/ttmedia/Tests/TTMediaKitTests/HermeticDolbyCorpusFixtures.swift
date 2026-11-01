// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@testable import TTMediaKit

/// Hermetic Dolby corpus used by the default Swift media gate.
///
/// The corpus replaces the retired personal-film corpus (`REF-V4`/`REF-V5`/`REF-V6`) with
/// three self-contained samples that are synthesised locally by
/// `infra/ttmedia/tools/generate_hermetic_swift_corpus.py` and committed to the repository.
/// Nothing in this file may point at a personal media directory: the default gate has to
/// reproduce on a clean machine that has never seen the original films.
///
/// The two AC-3 samples retain a `default`-flagged but non-playable decoy audio track
/// before the Dolby track; the E-AC-3 sample has no decoy, matching its film. The demuxer must
/// prove that it selects the *Dolby* track instead of the decoy — the exact failure mode the
/// retired corpus was written to catch.
enum HermeticDolbyCorpusFixtures {

    /// One corpus sample together with the production facts it must reproduce.
    struct Sample: Sendable {
        /// Stable identifier used in assertion messages.
        let id: String
        /// Path of the sample relative to `infra/ttmedia/Tests`.
        let relativePath: String
        /// Canonical codec the demuxer must publish for the selected audio track.
        let expectedCodec: AudioCodec
        /// Matroska `CodecID` the demuxer must publish for the selected audio track.
        let expectedRawCodecID: String
        /// Channel count the demuxer must publish, probed from the Dolby bitstream.
        let expectedChannels: Int
        /// Sample rate the demuxer must publish, probed from the Dolby bitstream.
        let expectedSampleRate: Double
        /// Speaker layout the demuxer must publish for the selected audio track.
        let expectedChannelLayout: String
        /// Dolby profile name the demuxer must publish for the selected audio track.
        let expectedAudioProfile: String
        /// Container track number of the selected Dolby audio track.
        let expectedAudioTrackNumber: Int
        /// Container track number of the video track.
        let expectedVideoTrackNumber: Int
        /// Number of audio tracks the demuxer must publish in its catalog.
        let expectedCatalogAudioTrackCount: Int
        /// Container track number of the non-playable decoy audio track, if the sample has one.
        let expectedDecoyTrackNumber: Int?
        /// Matroska `CodecID` of the non-playable decoy audio track, if the sample has one.
        let expectedDecoyRawCodecID: String?
        /// Channel count of the non-playable decoy audio track, if the sample has one.
        let expectedDecoyChannels: Int?
    }

    /// ATSC A/52 sync word (`0x0B77`) shared by AC-3 and E-AC-3 sync frames.
    static let syncWord: [UInt8] = [0x0B, 0x77]

    /// Duration of a single AC-3 / E-AC-3 sync frame at 48 kHz (1536 samples).
    static let expectedFrameDurationSeconds: Double = 0.032

    /// The three corpus samples, in the order the retired personal corpus used.
    static let samples: [Sample] = [
        Sample(
            id: "HERMETIC-AC3-6CH",
            relativePath: "Fixtures/hermetic-swift/hermetic_ac3_6ch.mkv",
            expectedCodec: .ac3,
            expectedRawCodecID: "A_AC3",
            expectedChannels: 6,
            expectedSampleRate: 48_000,
            expectedChannelLayout: "5.1",
            expectedAudioProfile: "Dolby Digital",
            expectedAudioTrackNumber: 3,
            expectedVideoTrackNumber: 1,
            expectedCatalogAudioTrackCount: 2,
            expectedDecoyTrackNumber: 2,
            expectedDecoyRawCodecID: "A_MPEG/L3",
            expectedDecoyChannels: 2
        ),
        Sample(
            id: "HERMETIC-EAC3-6CH",
            relativePath: "Fixtures/hermetic-swift/hermetic_eac3_6ch.mkv",
            expectedCodec: .eac3,
            expectedRawCodecID: "A_EAC3",
            expectedChannels: 6,
            expectedSampleRate: 48_000,
            expectedChannelLayout: "5.1",
            expectedAudioProfile: "Dolby Digital Plus",
            expectedAudioTrackNumber: 2,
            expectedVideoTrackNumber: 1,
            expectedCatalogAudioTrackCount: 1,
            expectedDecoyTrackNumber: nil,
            expectedDecoyRawCodecID: nil,
            expectedDecoyChannels: nil
        ),
        Sample(
            id: "HERMETIC-AC3-5CH",
            relativePath: "Fixtures/hermetic-swift/hermetic_ac3_5ch.mkv",
            expectedCodec: .ac3,
            expectedRawCodecID: "A_AC3",
            expectedChannels: 5,
            expectedSampleRate: 48_000,
            expectedChannelLayout: "5.0",
            expectedAudioProfile: "Dolby Digital",
            expectedAudioTrackNumber: 3,
            expectedVideoTrackNumber: 1,
            expectedCatalogAudioTrackCount: 2,
            expectedDecoyTrackNumber: 2,
            expectedDecoyRawCodecID: "A_MPEG/L3",
            expectedDecoyChannels: 2
        )
    ]

    /// Root directory of `infra/ttmedia/Tests` as seen by the running test binary.
    ///
    /// Bazel exposes the runfiles tree through `TEST_SRCDIR`; a plain `swift test` run
    /// resolves the same directory from the source path of this file. There is deliberately
    /// no machine-specific fallback path.
    static func testsRoot() -> URL {
        if let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let runfiles = URL(fileURLWithPath: srcdir)
                .appendingPathComponent("_main/infra/ttmedia/Tests")
            if FileManager.default.fileExists(atPath: runfiles.path) {
                return runfiles
            }
        }
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = cursor.appendingPathComponent("Tests")
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Fixtures/hermetic-swift").path
            ) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Absolute URL of a corpus sample.
    static func url(for sample: Sample) -> URL {
        testsRoot().appendingPathComponent(sample.relativePath)
    }

    /// Regeneration command quoted in failure messages, so a missing fixture can be restored
    /// without guessing where it came from.
    static let regenerationCommand =
        "python3 infra/ttmedia/tools/generate_hermetic_swift_corpus.py"
}
