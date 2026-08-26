// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

public final class MockFileURLHarness {
    public let sandboxDir: URL
    
    public init() throws {
        sandboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockSandbox_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
    }
    
    public func createFile(named name: String, content: String = "Test file content") -> URL {
        let url = sandboxDir.appendingPathComponent(name)
        try? content.data(using: .utf8)?.write(to: url)
        return url
    }
    
    public func createDirectory(named name: String) -> URL {
        let url = sandboxDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    public func cleanup() throws {
        try FileManager.default.removeItem(at: sandboxDir)
    }
}
