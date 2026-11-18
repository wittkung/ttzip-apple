// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public enum ArchiveSourceAddress {
    /// A local archive address may carry a virtual subpath, but never remote authority.
    public static func isLocalArchiveAddress(_ url: URL) -> Bool {
        guard url.isFileURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil else {
            return false
        }
        return components.host == nil || components.host == ""
            || components.host?.lowercased() == "localhost"
    }

    /// Parses the existing virtual directory identity without guessing from an extension.
    public static func archiveSubpath(in url: URL) -> String? {
        guard isLocalArchiveAddress(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "subpath", let value = items[0].value else { return nil }
        if value.isEmpty { return "" }
        let normalized = value.hasSuffix("/") ? String(value.dropLast()) : value
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return normalized
    }
}
