// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipCore

final class ArchiveWriterRecoveryRecordTests: XCTestCase {
    func testArchiveWriterCreatesZipWithRecoveryRecordAndRejectsInvalidConfigs() async throws {

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_smart_rec_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let line = "The quick brown fox jumps over the lazy dog. TTZip structured compressible text payload.\n"
        let inputURL = tempRoot.appendingPathComponent("writer_rec.txt")
        try Data(String(repeating: line, count: 200).utf8).write(to: inputURL)
        let outZip = tempRoot.appendingPathComponent("writer_rec.zip")
        let adv = ArchiveAdvancedOptions.builder()
            .withRecoveryRecordRedundancyPercent(10)
            .build()
        XCTAssertEqual(adv.recoveryRecordRedundancyPercent, 10)

        let writer = ArchiveWriter()
        let report = try await writer.createArchiveWithOutcome(
            outputPath: outZip.path,
            format: .zip,
            level: .normal,
            inputPaths: [inputURL.path],
            advancedOptions: adv
        )
        let data = try Data(contentsOf: outZip)
        XCTAssertEqual(UInt64(data.count), report.compressedBytes)
        XCTAssertEqual(String(decoding: data.suffix(12).prefix(4), as: UTF8.self), "TTRC")

        let outTarGz = tempRoot.appendingPathComponent("bad_rec.tar.gz")
        var badFmtOptions = ArchiveAdvancedOptions.defaultOptions
        badFmtOptions.recoveryRecordRedundancyPercent = 10
        do {
            _ = try await writer.createArchiveWithOutcome(
                outputPath: outTarGz.path,
                format: .tarGz,
                inputPaths: [inputURL.path],
                advancedOptions: badFmtOptions
            )
            XCTFail("Expected unsupportedOperation for .tar.gz recovery record")
        } catch {}

        var badPctOptions = ArchiveAdvancedOptions.defaultOptions
        badPctOptions.recoveryRecordRedundancyPercent = 75
        do {
            _ = try await writer.createArchiveWithOutcome(
                outputPath: outZip.path,
                format: .zip,
                inputPaths: [inputURL.path],
                advancedOptions: badPctOptions
            )
            XCTFail("Expected invalidArgument for 75% recovery record")
        } catch {}
    }
}
