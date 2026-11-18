// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Model representing a recently accessed archive file record.
public struct RecentArchiveRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let extensionName: String
    public let date: Date
    public var bookmarkData: Data?

    public init(path: String, date: Date = Date(), bookmarkData: Data? = nil) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.extensionName = (path as NSString).pathExtension.uppercased()
        self.date = date
        self.bookmarkData = bookmarkData
    }
}
