// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipUI
import TTZipBenchmarkKit

public final class MockFileURLHarness {
    public let sandboxDir: URL
    
    public init() throws {
        let resolvedTmp = (FileManager.default.temporaryDirectory.path as NSString).resolvingSymlinksInPath
        sandboxDir = URL(fileURLWithPath: resolvedTmp, isDirectory: true)
            .appendingPathComponent("MockSandbox_\(UUID().uuidString)", isDirectory: true)
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
    
    private var isCleaned: Bool = false

    public func cleanup() throws {
        guard !isCleaned else { return }
        isCleaned = true
        try FileManager.default.removeItem(at: sandboxDir)
    }

    deinit {
        try? cleanup()
    }
}
