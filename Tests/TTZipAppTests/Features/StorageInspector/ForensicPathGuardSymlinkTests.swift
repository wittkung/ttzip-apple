// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipApp

final class ForensicPathGuardSymlinkTests: XCTestCase {
    func testForensicPathGuardProtectsSymlinkedHomeSubpathTargetingOutsideHome() throws {

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_smart_rec_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let externalTarget = tempRoot.appendingPathComponent("external-aws-store-\(UUID().uuidString)", isDirectory: true)
        let fixtureHomeURL = tempRoot.appendingPathComponent("fixture-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtureHomeURL, withIntermediateDirectories: true)

        let credentialsFile = externalTarget.appendingPathComponent("credentials")
        try Data("aws_secret_access_key = test".utf8).write(to: credentialsFile)

        let awsHomeURL = fixtureHomeURL.appendingPathComponent(".aws", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: awsHomeURL, withDestinationURL: externalTarget)
        let symlinkedCredentials = awsHomeURL.appendingPathComponent("credentials")
        XCTAssertTrue(
            ForensicPathGuard.isProtectedSystemPath(
                symlinkedCredentials.path,
                homeDirectory: fixtureHomeURL.path
            ),
            "Symlinked ~/.aws path resolving outside home directory must remain protected"
        )
    }
}
