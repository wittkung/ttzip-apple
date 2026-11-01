// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import TTMediaKit

/// Opt-in verification of the Dolby production chain against **real films**.
///
/// This entry point is deliberately separate from the deterministic gate:
///
/// * It is never part of the default coverage contract — the hermetic corpus in
///   `HermeticDolbyCorpusTests` owns the default Dolby verification.
/// * It is only reachable through an explicit environment variable that points at a
///   specification file. There is **no** personal default path: when the variable is unset
///   the test is skipped and reported as *manual / real-film verification not run*, so it can
///   never be counted together with the default deterministic results.
/// * The specification file names the films and the track facts each film must reproduce, so
///   the same production-chain semantics are checked for real material as for the hermetic
///   corpus.
///
/// The expected environment variable is `TTMEDIA_REAL_DOLBY_CORPUS_SPEC`, pointing at a JSON
/// file of the shape:
///
/// ```json
/// {
///   "samples": [
///     {
///       "id": "REF-V4",
///       "path": "/absolute/path/to/film.mkv",
///       "codec": "ac3",
///       "rawCodecId": "A_AC3",
///       "channels": 6,
///       "sampleRate": 48000,
///       "audioTrackNumber": 3
///     }
///   ]
/// }
/// ```
final class RealFilmDolbyCorpusOptInTests: XCTestCase {

    /// Environment variable that enables the real-film verification.
    static let specificationEnvironmentKey = "TTMEDIA_REAL_DOLBY_CORPUS_SPEC"

    /// One real film and the production facts it must reproduce.
    private struct Spec: Decodable {
        struct Sample: Decodable {
            let id: String
            let path: String
            let codec: String
            let rawCodecId: String
            let channels: Int
            let sampleRate: Double
            let audioTrackNumber: Int
        }

        let samples: [Sample]
    }

    func testOptInRealFilmDolbyCorpus() async throws {
        guard let specificationPath = ProcessInfo.processInfo.environment[Self.specificationEnvironmentKey],
              !specificationPath.isEmpty else {
            throw XCTSkip(
                """
                MANUAL / REAL-FILM DOLBY VERIFICATION NOT RUN. \
                This entry point is opt-in and is not part of the deterministic gate. \
                Set \(Self.specificationEnvironmentKey)=<spec.json> to run it. \
                The default Dolby verification runs hermetically in HermeticDolbyCorpusTests.
                """
            )
        }

        let specificationURL = URL(fileURLWithPath: specificationPath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: specificationURL.path),
            "The opted-in real-film specification must exist at \(specificationURL.path)"
        )
        guard FileManager.default.fileExists(atPath: specificationURL.path) else { return }

        let specification = try JSONDecoder().decode(
            Spec.self,
            from: try Data(contentsOf: specificationURL)
        )
        XCTAssertFalse(specification.samples.isEmpty, "The real-film specification must name at least one film")

        for sample in specification.samples {
            let filmURL = URL(fileURLWithPath: sample.path)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: filmURL.path),
                "\(sample.id): the opted-in film must exist at \(filmURL.path)"
            )
            guard FileManager.default.fileExists(atPath: filmURL.path) else { continue }
            try await verify(sample: sample, filmURL: filmURL)
        }
    }

    /// Verifies one real film against the production-chain semantics.
    @MainActor
    private func verify(sample: Spec.Sample, filmURL: URL) async throws {
        let transport = MediaWorkerDirectTransport()
        let opened = try await transport.openMedia(path: filmURL.path, targetTracks: nil)
        let info = TTMediaStreamInfo(sessionId: opened.sessionId, dictionary: opened.metadata)

        XCTAssertEqual(
            info.metadataCapability, "v1_structured_contract_v1",
            "\(sample.id) must publish the V1 structured contract"
        )
        XCTAssertEqual(
            info.selectedAudioTrackNumber, sample.audioTrackNumber,
            "\(sample.id) selected audio track number"
        )
        let audio = try XCTUnwrap(info.audioTracks.first, "\(sample.id) must publish the selected audio track")
        XCTAssertEqual(audio.trackIndex, sample.audioTrackNumber, "\(sample.id) audio trackIndex")
        XCTAssertEqual(audio.codec?.rawValue, sample.codec, "\(sample.id) canonical codec")
        XCTAssertEqual(audio.rawCodecId, sample.rawCodecId, "\(sample.id) raw CodecID")
        XCTAssertEqual(audio.channels, sample.channels, "\(sample.id) channel count")
        XCTAssertEqual(audio.sampleRate, sample.sampleRate, "\(sample.id) sample rate")

        let firstAudioPacket = try await Self.readFirstAudioPacket(at: filmURL, transport: transport, sessionId: opened.sessionId)
        XCTAssertNotNil(firstAudioPacket, "\(sample.id) the demuxer must deliver a first audio packet")

        try await transport.closeMedia(sessionId: opened.sessionId)

        let controller = AVSampleBufferWorkerPlaybackController(
            url: filmURL,
            client: MediaWorkerXPCClient(transport: MediaWorkerDirectTransport())
        )
        await controller.startPlayback(autoPlay: true)
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNil(controller.fatalError, "\(sample.id) must not suffer a fatal playback error")
        XCTAssertTrue(controller.isPlaying, "\(sample.id) must stay in active playback")
        XCTAssertGreaterThan(controller.enqueuedVideoPacketCount, 0, "\(sample.id) must enqueue video frames")
        XCTAssertGreaterThan(controller.enqueuedAudioPacketCount, 0, "\(sample.id) must enqueue the real audio packets")
        XCTAssertGreaterThan(
            CMTimeGetSeconds(controller.coordinator.synchronizer.currentTime()), 0.0,
            "\(sample.id) the synchronizer clock must advance"
        )
        print(
            "[REAL-FILM-DOLBY] \(sample.id): "
            + "rust_demux=PASS(raw=\(audio.rawCodecId),ch=\(audio.channels),sr=\(Int(audio.sampleRate))) | "
            + "swift_pipeline=PASS(video_pkts=\(controller.enqueuedVideoPacketCount),"
            + "audio_pkts=\(controller.enqueuedAudioPacketCount),"
            + "isolated=\(controller.isAudioIsolated),"
            + "renderer_status=\(controller.audioPipeline.audioRenderer.status.rawValue)) | "
            + "real_device_audible_av_sync=NOT_VERIFIED_BY_THIS_TEST"
        )
        await controller.stop()
    }

    /// Reads the first audio packet the real demuxer produces for a film.
    private static func readFirstAudioPacket(
        at url: URL,
        transport: MediaWorkerDirectTransport,
        sessionId: String
    ) async throws -> MediaPacketDTO? {
        for _ in 0..<64 {
            guard let raw = try await transport.readNextPacket(sessionId: sessionId) else { return nil }
            let packet = try JSONDecoder().decode(MediaPacketDTO.self, from: raw)
            if packet.mediaType == .audio {
                return packet
            }
        }
        return nil
    }
}
