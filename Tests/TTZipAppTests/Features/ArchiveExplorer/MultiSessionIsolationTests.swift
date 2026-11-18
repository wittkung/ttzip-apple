// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class MultiSessionIsolationTests: XCTestCase {

    func testMultipleArchiveSessionContextsRemainIsolated() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "SessionIsolation")
        let sessionA = ArchiveSessionContext()
        let sessionB = ArchiveSessionContext()
        
        XCTAssertNotEqual(sessionA.id, sessionB.id)
        XCTAssertNotEqual(sessionA.vfsCacheSessionId, sessionB.vfsCacheSessionId)
        
        sessionA.searchQuery = "secret_report.pdf"
        sessionB.searchQuery = "design_spec.sketch"
        
        XCTAssertEqual(sessionA.searchQuery, "secret_report.pdf")
        XCTAssertEqual(sessionB.searchQuery, "design_spec.sketch")
        
        let archivePathA = tempDir.appendingPathComponent("archiveA.zip").path
        let archivePathB = tempDir.appendingPathComponent("archiveB.7z").path
        sessionA.currentArchivePath = archivePathA
        sessionB.currentArchivePath = archivePathB
        
        XCTAssertEqual(sessionA.currentArchivePath, archivePathA)
        XCTAssertEqual(sessionB.currentArchivePath, archivePathB)
        
        sessionA.closeArchive()
        XCTAssertNil(sessionA.currentArchivePath)
        XCTAssertEqual(sessionB.currentArchivePath, archivePathB)
    }

    func testDispatcherSessionRegistryManagement() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "SessionIsolation")
        let dispatcher = AppIntentDispatcher.shared
        let session1 = ArchiveSessionContext()
        let session2 = ArchiveSessionContext()
        
        let path1 = tempDir.appendingPathComponent("Project1.zip").path
        let path2 = tempDir.appendingPathComponent("Project2.tar.gz").path
        session1.currentArchivePath = path1
        session2.currentArchivePath = path2
        
        dispatcher.registerSession(session1)
        dispatcher.registerSession(session2)
        
        XCTAssertEqual(dispatcher.allSessions.count, 2)
        XCTAssertEqual(dispatcher.activeSession(for: path1)?.id, session1.id)
        XCTAssertEqual(dispatcher.activeSession(for: path2)?.id, session2.id)
        
        dispatcher.unregisterSession(id: session1.id)
        XCTAssertEqual(dispatcher.allSessions.count, 1)
        XCTAssertNil(dispatcher.activeSession(for: path1))
        
        dispatcher.unregisterSession(id: session2.id)
        XCTAssertEqual(dispatcher.allSessions.count, 0)
    }
}
