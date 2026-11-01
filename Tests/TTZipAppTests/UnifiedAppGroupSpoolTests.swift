// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipCore
import TTZipFinderSync
@testable import TTZipApp

final class UnifiedAppGroupSpoolTests: XCTestCase {
    
    func testCanonicalSpoolJobRoundTripSerialization() throws {
        let originalJobId = UUID()
        let now = Date()
        let job = TTZipSpoolJob(
            jobId: originalJobId,
            createdAt: now,
            action: "compress_quick_zip",
            targetFormat: "zip",
            sourcePaths: ["/tmp/fileA.txt", "/tmp/fileB.txt"],
            sourceBookmarks: [],
            destinationDirectoryBookmark: nil,
            compressionLevel: 6,
            password: "secret_password"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(job)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TTZipSpoolJob.self, from: data)
        
        XCTAssertEqual(decoded.jobId, originalJobId)
        XCTAssertEqual(decoded.action, "compress_quick_zip")
        XCTAssertEqual(decoded.targetFormat, "zip")
        XCTAssertEqual(decoded.sourcePaths, ["/tmp/fileA.txt", "/tmp/fileB.txt"])
        XCTAssertEqual(decoded.compressionLevel, 6)
        XCTAssertEqual(decoded.password, "secret_password")
        XCTAssertTrue(decoded.sourceBookmarks.isEmpty)
        XCTAssertNil(decoded.destinationDirectoryBookmark)
    }
    
    func testSpoolJobDecodingOmittedOptionalArrays() throws {
        // Simulates cross-process payload where sourcePaths or sourceBookmarks were omitted
        let jsonString = """
        {
            "jobId": "A51B761E-BF19-4C41-9449-74F965FE8A15",
            "createdAt": 1726665000,
            "action": "extract_here"
        }
        """
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode(TTZipSpoolJob.self, from: data)
        
        XCTAssertEqual(decoded.jobId.uuidString, "A51B761E-BF19-4C41-9449-74F965FE8A15")
        XCTAssertEqual(decoded.action, "extract_here")
        XCTAssertEqual(decoded.sourcePaths, [])
        XCTAssertEqual(decoded.sourceBookmarks, [])
        XCTAssertNil(decoded.targetFormat)
        XCTAssertNil(decoded.password)
    }
    
    func testSpoolJobTypealiasParity() {
        // Verify TTZipFinderSync's FinderSyncSpoolPayload is binary and source equivalent to TTZipCore.TTZipSpoolJob
        let payload: FinderSyncSpoolPayload = TTZipSpoolJob(
            action: "inspect_archive",
            sourcePaths: ["/Users/test/archive.zip"]
        )
        XCTAssertEqual(payload.action, "inspect_archive")
        XCTAssertEqual(payload.sourcePaths, ["/Users/test/archive.zip"])
    }
    
    func testSpoolManagerWriteAndConsumeLifecycle() throws {
        let testPaths = ["/var/tmp/sample_1.txt", "/var/tmp/sample_2.txt"]
        let jobId = try AppGroupSpooler.shared.spoolJob(
            action: "compress_quick_7z",
            paths: testPaths,
            targetFormat: "7z",
            compressionLevel: 9,
            password: nil
        )
        
        // AppGroupSpoolManager in App target must consume the job written by AppGroupSpooler
        let consumed = try XCTUnwrap(AppGroupSpoolManager.shared.consumeJob(id: jobId))
        XCTAssertEqual(consumed.jobId, jobId)
        XCTAssertEqual(consumed.action, "compress_quick_7z")
        XCTAssertEqual(consumed.sourcePaths, testPaths)
        XCTAssertEqual(consumed.targetFormat, "7z")
        XCTAssertEqual(consumed.compressionLevel, 9)
        
        // Subsequent consumption must return nil (guaranteeing single-use atomic consumption)
        let reConsumed = AppGroupSpoolManager.shared.consumeJob(id: jobId)
        XCTAssertNil(reConsumed, "Job token must be physically purged upon first consumption")
    }
}
