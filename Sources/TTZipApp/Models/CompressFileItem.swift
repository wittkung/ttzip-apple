// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

/// Lightweight file or directory item descriptor for compression setup.
/// Avoids blocking @MainActor during initialization by keeping disk inspections shallow.
public struct CompressFileItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public var size: Int64
    public var isCalculating: Bool
    public var component: (any ArchiveComponentProtocol)?
    
    /// Initializes a lightweight CompressFileItem without synchronous recursive directory tree scans.
    public init(path: String, component: (any ArchiveComponentProtocol)? = nil) {
        self.id = UUID()
        self.path = path
        self.name = (path as NSString).lastPathComponent
        
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDir)
        self.isDirectory = exists && isDir.boolValue
        
        if let component = component {
            self.component = component
            self.size = component.sizeBytes
            self.isCalculating = false
        } else if self.isDirectory {
            // Directory aggregate size is calculated in the background
            self.component = nil
            self.size = 0
            self.isCalculating = true
        } else {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            self.component = nil
            self.size = fileSize
            self.isCalculating = false
        }
    }
    
    public init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        isDirectory: Bool,
        size: Int64 = 0,
        isCalculating: Bool = false,
        component: (any ArchiveComponentProtocol)? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.size = size
        self.isCalculating = isCalculating
        self.component = component
    }
    
    // MARK: - Equatable & Hashable
    
    public static func == (lhs: CompressFileItem, rhs: CompressFileItem) -> Bool {
        lhs.id == rhs.id && lhs.path == rhs.path
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(path)
    }
}
