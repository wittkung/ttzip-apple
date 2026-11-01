// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
import TTMediaKit

public enum PreviewCorpusSampleError: Error, Equatable {
    case missingPreviewFixturesRoot
    case missingRealVideoCorpusFixture(ext: String)
    case missingRealAudioCorpusFixture(ext: String)
    case unsupportedSyntheticVideoHeader(ext: String)
    case unsupportedSyntheticAudioHeader(ext: String)
}

extension XCTestCase {
    /// Video extensions with real matching `video/clip.<ext>` files in `infra/ttmedia/Tests/Fixtures/preview/video`.
    public static let realVideoCorpusExtensions: Set<String> = [
        "3g2", "3gp", "asf", "avi", "dat", "divx", "f4v", "flv", "m2t", "m2ts",
        "m2v", "m4v", "mkv", "mov", "mp4", "mpe", "mpeg", "mpg", "mpv", "mts",
        "nut", "qt", "rm", "ts", "vob", "webm", "wmv", "y4m"
    ]

    /// Video extensions verified for detector branch routing using minimal container headers (not playability).
    public static let syntheticHeaderVideoExtensions: Set<String> = ["ogv", "mxf", "rmvb", "vro"]

    /// Registered video extensions that currently lack a real native corpus sample in `Tests/Fixtures/preview`.
    public static let missingCorpusVideoExtensions: Set<String> = ["dv"]

    /// Audio extensions with real matching `audio/tone.<ext>` or `audio/notes.<ext>` files in `Tests/Fixtures/preview/audio`.
    public static let realAudioCorpusExtensions: Set<String> = [
        "aac", "ac3", "aif", "aifc", "aiff", "au", "caf", "eac3", "flac",
        "m4a", "m4b", "m4r", "mid", "midi", "mp3", "oga", "ogg", "opus",
        "ra", "snd", "tta", "voc", "wav", "wma", "wv"
    ]

    /// Audio extensions verified for detector branch routing using minimal stream/container headers (not playability).
    public static let syntheticHeaderAudioExtensions: Set<String> = [
        "alac", "ape", "dts", "amr", "mka", "dsd", "dsf", "dff", "mpc", "spx"
    ]

    /// Registered audio extensions that currently lack a real native corpus sample in `Tests/Fixtures/preview`.
    public static let missingCorpusAudioExtensions: Set<String> = ["tak", "gsm"]

    /// Allocates an isolated, strongly-typed temporary directory for the current test execution.
    @discardableResult
    public func makeTemporaryDirectory(prefix: String = "TTZipTest") throws -> URL {
        let uniqueID = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(uniqueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Resolves the shared `infra/ttmedia/Tests/Fixtures/preview` corpus root across Bazel runfiles and local trees.
    public func locatePreviewFixturesRoot() throws -> URL {
        if let testSrcDir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let candidates = [
                URL(fileURLWithPath: testSrcDir).appendingPathComponent("_main/infra/ttmedia/Tests/Fixtures/preview"),
                URL(fileURLWithPath: testSrcDir).appendingPathComponent("infra/ttmedia/Tests/Fixtures/preview")
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = cursor.appendingPathComponent("vendor/ttmedia/Tests/Fixtures/preview")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let monorepoCandidate = cursor.appendingPathComponent("infra/ttmedia/Tests/Fixtures/preview")
            if FileManager.default.fileExists(atPath: monorepoCandidate.path) {
                return monorepoCandidate
            }
            cursor.deleteLastPathComponent()
        }
        throw PreviewCorpusSampleError.missingPreviewFixturesRoot
    }

    /// Loads an exact real video fixture `video/clip.<ext>` from the corpus. Never falls back to another format.
    public func loadRealVideoCorpusFixture(for ext: String, fixturesRoot: URL) throws -> Data {
        let clean = ext.lowercased()
        let directURL = fixturesRoot.appendingPathComponent("video/clip.\(clean)")
        guard FileManager.default.fileExists(atPath: directURL.path) else {
            throw PreviewCorpusSampleError.missingRealVideoCorpusFixture(ext: clean)
        }
        return try Data(contentsOf: directURL)
    }

    /// Loads an exact real audio fixture `audio/tone.<ext>` or `audio/notes.<ext>` from the corpus. Never falls back.
    public func loadRealAudioCorpusFixture(for ext: String, fixturesRoot: URL) throws -> Data {
        let clean = ext.lowercased()
        for prefix in ["tone", "notes"] {
            let candidate = fixturesRoot.appendingPathComponent("audio/\(prefix).\(clean)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }
        throw PreviewCorpusSampleError.missingRealAudioCorpusFixture(ext: clean)
    }

    /// Constructs a minimal recognition header for video formats without a corpus file (routing test only, not playback).
    public func syntheticVideoProbeHeader(for ext: String) throws -> Data {
        switch ext.lowercased() {
        case "ogv":
            var oggTheora = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02])
            oggTheora.append(Data(repeating: 0x00, count: 22))
            oggTheora.append(Data([0x80, 0x74, 0x68, 0x65, 0x6F, 0x72, 0x61]))
            oggTheora.append(Data(repeating: 0x00, count: 32))
            return oggTheora
        case "mxf":
            var mxf = Data([
                0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
                0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x04, 0x00
            ])
            mxf.append(Data(repeating: 0x00, count: 48))
            return mxf
        case "rmvb":
            var rmvb = Data([0x2E, 0x52, 0x4D, 0x46, 0x00, 0x00, 0x00, 0x12])
            rmvb.append(Data("video/x-pn-realvideo".utf8))
            rmvb.append(Data(repeating: 0x00, count: 36))
            return rmvb
        case "vro":
            var vro = Data([0x00, 0x00, 0x01, 0xBA, 0x44, 0x00, 0x04, 0x00, 0x04, 0x01, 0x00, 0x00, 0x03, 0xF8])
            vro.append(Data(repeating: 0x00, count: 50))
            return vro
        default:
            throw PreviewCorpusSampleError.unsupportedSyntheticVideoHeader(ext: ext.lowercased())
        }
    }

    /// Constructs a minimal recognition header for audio formats without a corpus file (routing test only, not playback).
    public func syntheticAudioProbeHeader(for ext: String) throws -> Data {
        switch ext.lowercased() {
        case "alac":
            var alac = Data([0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])
            alac.append(Data([0x00, 0x00, 0x00, 0x00, 0x4D, 0x34, 0x41, 0x20]))
            let hdlr = Data([
                0x00, 0x00, 0x00, 0x20, 0x68, 0x64, 0x6C, 0x72,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x73, 0x6F, 0x75, 0x6E, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
            ])
            var moov = Data([0x00, 0x00, 0x00, 0x28, 0x6D, 0x6F, 0x6F, 0x76])
            moov.append(hdlr)
            alac.append(moov)
            return alac
        case "ape":
            return Data([0x4D, 0x41, 0x43, 0x20, 0x98, 0x0F, 0x00, 0x00]) + Data(repeating: 0x00, count: 56)
        case "dts":
            return Data([0x7F, 0xFE, 0x80, 0x01, 0xFC, 0x3C, 0x00, 0x00]) + Data(repeating: 0x00, count: 56)
        case "amr":
            return Data([0x23, 0x21, 0x41, 0x4D, 0x52, 0x0A, 0x3C, 0x00]) + Data(repeating: 0x00, count: 56)
        case "mka":
            var mka = Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x83, 0x81, 0x02])
            mka.append(Data("A_FLAC".utf8))
            mka.append(Data(repeating: 0x00, count: 48))
            return mka
        case "dsd", "dsf":
            return Data([0x44, 0x53, 0x44, 0x20, 0x1C, 0x00, 0x00, 0x00]) + Data(repeating: 0x00, count: 56)
        case "dff":
            var dff = Data([0x46, 0x52, 0x4D, 0x38, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20])
            dff.append(Data([0x44, 0x53, 0x44, 0x20]))
            dff.append(Data(repeating: 0x00, count: 48))
            return dff
        case "mpc":
            return Data([0x4D, 0x50, 0x43, 0x4B, 0x53, 0x48, 0x0C, 0x00]) + Data(repeating: 0x00, count: 56)
        case "spx":
            var spx = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02])
            spx.append(Data(repeating: 0x00, count: 22))
            spx.append(Data("Speex   ".utf8))
            spx.append(Data(repeating: 0x00, count: 32))
            return spx
        default:
            throw PreviewCorpusSampleError.unsupportedSyntheticAudioHeader(ext: ext.lowercased())
        }
    }

    @MainActor
    public func assertVideoRoutingAcrossAllEntries(url: URL, data: Data, ext: String) async throws {
        if case .video(let u) = MediaPreviewFactory.detectType(url: url) {
            XCTAssertEqual(u, url)
        } else {
            XCTFail("Extension .\(ext) sync failed to detect as .video")
        }
        if case .video(let u) = await MediaPreviewFactory.detectTypeAsync(url: url) {
            XCTAssertEqual(u, url)
        } else {
            XCTFail("Extension .\(ext) async failed to detect as .video")
        }
        let memType = MediaPreviewFactory.detectTypeFromMemory(data: data, suggestedName: "entry.\(ext)")
        defer { memType.releaseEphemeralMediaLease() }
        if case .video(let stagedURL) = memType {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
            XCTAssertEqual(stagedURL.pathExtension.lowercased(), ext)
        } else {
            XCTFail("Extension .\(ext) in-memory fell through to \(memType) instead of .video")
        }
    }

    @MainActor
    public func assertAudioRoutingAcrossAllEntries(url: URL, data: Data, ext: String) async throws {
        if case .audio(let u) = MediaPreviewFactory.detectType(url: url) {
            XCTAssertEqual(u, url)
        } else {
            XCTFail("Extension .\(ext) sync failed to detect as .audio")
        }
        if case .audio(let u) = await MediaPreviewFactory.detectTypeAsync(url: url) {
            XCTAssertEqual(u, url)
        } else {
            XCTFail("Extension .\(ext) async failed to detect as .audio")
        }
        let memType = MediaPreviewFactory.detectTypeFromMemory(data: data, suggestedName: "entry.\(ext)")
        defer { memType.releaseEphemeralMediaLease() }
        if case .audio(let stagedURL) = memType {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
            XCTAssertEqual(stagedURL.pathExtension.lowercased(), ext)
        } else {
            XCTFail("Extension .\(ext) in-memory fell through to \(memType) instead of .audio")
        }
    }

    @MainActor
    public func assertDisguisedTextRoutesToText(text: String, fileName: String, in dir: URL) async throws {
        let url = dir.appendingPathComponent(fileName)
        let data = Data(text.utf8)
        try data.write(to: url)
        if case .text(let s) = MediaPreviewFactory.detectType(url: url) {
            XCTAssertEqual(s, text)
        } else {
            XCTFail("ASCII text in \(fileName) sync must route to .text")
        }
        if case .text(let s) = await MediaPreviewFactory.detectTypeAsync(url: url) {
            XCTAssertEqual(s, text)
        } else {
            XCTFail("ASCII text in \(fileName) async must route to .text")
        }
        if case .text(let s) = MediaPreviewFactory.detectTypeFromMemory(data: data, suggestedName: fileName) {
            XCTAssertEqual(s, text)
        } else {
            XCTFail("ASCII text in \(fileName) in-memory must route to .text")
        }
    }
}
