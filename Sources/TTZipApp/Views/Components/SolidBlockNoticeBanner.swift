// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: macOS Native Archiving & Compression Application.

import SwiftUI

/// Elegant warning and fallback action banner for large 7z solid archive previews.
public struct SolidBlockNoticeBanner: View {
    public let precedingSizeFormatted: String
    public let onExtractSingle: () -> Void
    public let onExtractAll: () -> Void
    
    public init(
        precedingSizeFormatted: String = "100+ MB",
        onExtractSingle: @escaping () -> Void,
        onExtractAll: @escaping () -> Void
    ) {
        self.precedingSizeFormatted = precedingSizeFormatted
        self.onExtractSingle = onExtractSingle
        self.onExtractAll = onExtractAll
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.orange.gradient)
            
            Text("7z Solid Block Preceding Stream Required")
                .font(.headline)
                .foregroundStyle(.primary)
            
            Text("This file is located deep within a 7z solid block (\(precedingSizeFormatted) preceding data). Instant preview is paused to preserve system responsiveness.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            
            HStack(spacing: 12) {
                Button(action: onExtractSingle) {
                    Label("Decode & Preview", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                
                Button(action: onExtractAll) {
                    Label("Extract Archive", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}
