// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest

/// Harness for reproducing and validating macOS App Sandbox container topology and symlink resolution.
///
/// Under real macOS App Sandbox execution:
/// - NSHomeDirectory() returns `~/Library/Containers/<bundle-id>/Data`
/// - System folders like `Downloads`, `Documents`, and `Desktop` in the container are symbolic links
///   pointing back to `~/Downloads`, `~/Documents`, and `~/Desktop`.
/// This harness creates an isolated mock filesystem structure matching this topology to guarantee
/// path normalization and security-scoped bookmark contracts in headless test runners.
public final class MockSandboxHarness {
    public let baseDirectory: URL
    public let containerDataURL: URL
    public let physicalHomeURL: URL
    public let physicalDownloadsURL: URL
    public let physicalDocumentsURL: URL
    public let physicalDesktopURL: URL
    
    public let sandboxDownloadsURL: URL
    public let sandboxDocumentsURL: URL
    public let sandboxDesktopURL: URL
    
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let uniqueId = UUID().uuidString
        self.baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MockSandbox_\(uniqueId)", isDirectory: true)
        
        self.physicalHomeURL = baseDirectory.appendingPathComponent("Users/MockUser", isDirectory: true)
        self.physicalDownloadsURL = physicalHomeURL.appendingPathComponent("Downloads", isDirectory: true)
        self.physicalDocumentsURL = physicalHomeURL.appendingPathComponent("Documents", isDirectory: true)
        self.physicalDesktopURL = physicalHomeURL.appendingPathComponent("Desktop", isDirectory: true)
        
        self.containerDataURL = baseDirectory
            .appendingPathComponent("Library/Containers/com.metastudyline.ttzip/Data", isDirectory: true)
        
        self.sandboxDownloadsURL = containerDataURL.appendingPathComponent("Downloads")
        self.sandboxDocumentsURL = containerDataURL.appendingPathComponent("Documents")
        self.sandboxDesktopURL = containerDataURL.appendingPathComponent("Desktop")
        
        try setupTopology()
    }
    
    private func setupTopology() throws {
        try fileManager.createDirectory(at: physicalDownloadsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: physicalDocumentsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: physicalDesktopURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: containerDataURL, withIntermediateDirectories: true)
        
        // Create symbolic links matching macOS App Sandbox container architecture
        try fileManager.createSymbolicLink(at: sandboxDownloadsURL, withDestinationURL: physicalDownloadsURL)
        try fileManager.createSymbolicLink(at: sandboxDocumentsURL, withDestinationURL: physicalDocumentsURL)
        try fileManager.createSymbolicLink(at: sandboxDesktopURL, withDestinationURL: physicalDesktopURL)
    }
    
    /// Creates a mock test file within the physical downloads folder and returns both its
    /// sandboxed symlink URL and canonical resolved physical URL.
    public func createDownloadFile(named name: String, contents: Data) throws -> (sandboxedURL: URL, canonicalURL: URL) {
        let physicalFile = physicalDownloadsURL.appendingPathComponent(name)
        try contents.write(to: physicalFile)
        
        let sandboxedFile = sandboxDownloadsURL.appendingPathComponent(name)
        let canonicalFile = sandboxedFile.resolvingSymlinksInPath()
        return (sandboxedFile, canonicalFile)
    }
    
    /// Verifies if a given sandboxed path resolves to the expected canonical physical target.
    public func resolve(_ url: URL) -> URL {
        return url.resolvingSymlinksInPath()
    }
    
    /// Tears down the mock sandbox filesystem hierarchy.
    public func teardown() {
        try? fileManager.removeItem(at: baseDirectory)
    }
    
    deinit {
        teardown()
    }
}
