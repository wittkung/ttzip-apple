// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Lifecycle health and reachability state for sidebar items.
public enum SidebarItemHealthState: Hashable, Sendable, Codable {
    /// Item is healthy, accessible on an active mounted volume.
    case accessible
    /// Item is in a non-fatal warning or degraded state.
    case warning(message: String)
    /// Item belongs to an unmounted external drive or disconnected network volume.
    case unmountedVolume(volumeName: String?, volumeUUID: String?)
    /// Item's backing volume is currently mounting or connecting.
    case mounting(volumeName: String?)
    /// Item was deleted, moved across volumes, or unresolvable.
    case missing(lastKnownPath: String)
    /// Item is an evicted cloud placeholder (dataless stub).
    case datalessCloud(isDownloading: Bool)

    public var isInteractive: Bool {
        switch self {
        case .accessible, .datalessCloud, .warning:
            return true
        case .unmountedVolume, .missing, .mounting:
            return false
        }
    }

    public var isBroken: Bool {
        switch self {
        case .missing:
            return true
        default:
            return false
        }
    }

    public var isVolumeOffline: Bool {
        switch self {
        case .unmountedVolume:
            return true
        default:
            return false
        }
    }

    public var isMounting: Bool {
        switch self {
        case .mounting:
            return true
        default:
            return false
        }
    }

    public var isWarning: Bool {
        switch self {
        case .warning:
            return true
        default:
            return false
        }
    }

    public var isAccessible: Bool {
        if case .accessible = self {
            return true
        }
        return false
    }

    public var isDegradedOrOffline: Bool {
        switch self {
        case .unmountedVolume, .missing, .mounting:
            return true
        case .accessible, .warning, .datalessCloud:
            return false
        }
    }

    public var statusDescription: String {
        switch self {
        case .accessible:
            return String(localized: "Healthy and accessible")
        case .warning(let message):
            return String(localized: "Warning: \(message)")
        case .unmountedVolume(let volume, _):
            let volName = volume ?? String(localized: "External Volume")
            return String(localized: "Volume offline: \(volName)")
        case .mounting(let volume):
            let volName = volume ?? String(localized: "Volume")
            return String(localized: "Mounting \(volName)...")
        case .missing(let lastKnown):
            return String(localized: "Missing or moved: \(lastKnown)")
        case .datalessCloud(let isDownloading):
            return isDownloading
                ? String(localized: "Downloading from cloud...")
                : String(localized: "Cloud placeholder")
        }
    }
}
