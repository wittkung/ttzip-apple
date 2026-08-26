// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipCore
@testable import TTZipApp

@MainActor
final class MultiSessionIsolationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipMultiSession_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    func testMultipleArchiveSessionContextsRemainIsolated() async throws {
        let sessionA = ArchiveSessionContext()
        let sessionB = ArchiveSessionContext()
        
        XCTAssertNotEqual(sessionA.id, sessionB.id)
        XCTAssertNotEqual(sessionA.vfsCacheSessionId, sessionB.vfsCacheSessionId)
        
        sessionA.searchQuery = "secret_report.pdf"
        sessionB.searchQuery = "design_spec.sketch"
        
        XCTAssertEqual(sessionA.searchQuery, "secret_report.pdf")
        XCTAssertEqual(sessionB.searchQuery, "design_spec.sketch")
        
        sessionA.currentArchivePath = "/path/to/archiveA.zip"
        sessionB.currentArchivePath = "/path/to/archiveB.7z"
        
        XCTAssertEqual(sessionA.currentArchivePath, "/path/to/archiveA.zip")
        XCTAssertEqual(sessionB.currentArchivePath, "/path/to/archiveB.7z")
        
        sessionA.closeArchive()
        XCTAssertNil(sessionA.currentArchivePath)
        XCTAssertEqual(sessionB.currentArchivePath, "/path/to/archiveB.7z")
    }

    func testDispatcherSessionRegistryManagement() async throws {
        let dispatcher = AppIntentDispatcher.shared
        let session1 = ArchiveSessionContext()
        let session2 = ArchiveSessionContext()
        
        session1.currentArchivePath = "/Volumes/Data/Project1.zip"
        session2.currentArchivePath = "/Volumes/Data/Project2.tar.gz"
        
        dispatcher.registerSession(session1)
        dispatcher.registerSession(session2)
        
        XCTAssertEqual(dispatcher.allSessions.count, 2)
        XCTAssertEqual(dispatcher.activeSession(for: "/Volumes/Data/Project1.zip")?.id, session1.id)
        XCTAssertEqual(dispatcher.activeSession(for: "/Volumes/Data/Project2.tar.gz")?.id, session2.id)
        
        dispatcher.unregisterSession(id: session1.id)
        XCTAssertEqual(dispatcher.allSessions.count, 1)
        XCTAssertNil(dispatcher.activeSession(for: "/Volumes/Data/Project1.zip"))
        
        dispatcher.unregisterSession(id: session2.id)
        XCTAssertEqual(dispatcher.allSessions.count, 0)
    }
}
