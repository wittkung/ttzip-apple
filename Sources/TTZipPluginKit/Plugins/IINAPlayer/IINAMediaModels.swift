// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import TTZipCore

// MARK: - Mozilla UniFFI Typealiases

public typealias UniFFISubtitleSpan = UniFfiSubtitleSpan
public typealias UniFFISubtitleColor = UniFfiSubtitleColor
public typealias UniFFISubtitleAlignment = UniFfiSubtitleAlignment
public typealias UniFFISubtitlePosition = UniFfiSubtitlePosition
public typealias UniFFISubtitleDialogue = UniFfiSubtitleDialogue
public typealias UniFFISubtitleStyle = UniFfiSubtitleStyle
public typealias UniFFISubtitleScript = UniFfiSubtitleScript
public typealias UniFFISubtitleFormat = UniFfiSubtitleFormat

public typealias UniFFIMediaTrackType = UniFfiMediaTrackType
public typealias UniFFIMediaTrackInfo = UniFfiMediaTrackInfo
public typealias UniFFIMediaChapter = UniFfiMediaChapter
public typealias UniFFIMediaAttachment = UniFfiMediaAttachment
public typealias UniFFIMediaDemuxSummary = UniFfiMediaDemuxSummary

// MARK: - Subtitle Cue Legacy & Presentation Model

public struct IINASubtitleCue: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let styleName: String
    
    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        styleName: String = "Default"
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.styleName = styleName
    }
}

// MARK: - Color & Alignment Conversions

extension UniFFISubtitleColor {
    /// Converts UniFFI color component bytes into SwiftUI Color.
    public var swiftUIColor: Color {
        Color(
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

extension UniFFISubtitleAlignment {
    /// Maps ASS alignment to SwiftUI Alignment.
    public var swiftUIAlignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .middleLeft: return .leading
        case .middleCenter: return .center
        case .middleRight: return .trailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }
    
    /// Maps ASS alignment to SwiftUI TextAlignment.
    public var swiftUITextAlignment: TextAlignment {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft:
            return .leading
        case .topCenter, .middleCenter, .bottomCenter:
            return .center
        case .topRight, .middleRight, .bottomRight:
            return .trailing
        }
    }
}
