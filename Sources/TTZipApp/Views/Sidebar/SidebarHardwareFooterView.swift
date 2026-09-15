// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipBenchmarkKit
import TTZipCore
import TTZipUI

/// Bottom footer displaying Apple Silicon hardware acceleration status in the sidebar.
public struct SidebarHardwareFooterView: View {
    public var isIconRail: Bool = false
    private var l10n = AppLocalizationState.shared

    public init(isIconRail: Bool = false) {
        self.isIconRail = isIconRail
    }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.8)

            Group {
                if isIconRail {
                    HStack {
                        Spacer(minLength: 0)
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TTZipTheme.bambooGreen.opacity(0.85))

                            Circle()
                                .fill(TTZipTheme.bambooGreen)
                                .frame(width: 4, height: 4)
                                .offset(x: 2, y: -2)
                        }
                        .help("\(hardwareChipSummary) · \(l10n.currentLanguage == .zhHans ? "加速就绪" : "Engine Online")")
                        Spacer(minLength: 0)
                    }
                    .frame(height: 32)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.75))

                        Text(hardwareChipSummary)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)

                        HStack(spacing: 3.5) {
                            Circle()
                                .fill(TTZipTheme.bambooGreen)
                                .frame(width: 4.5, height: 4.5)
                            Text(l10n.currentLanguage == .zhHans ? "加速就绪" : "Online")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                        .help(l10n.currentLanguage == .zhHans ? "Apple Silicon 硬件加速引擎就绪" : "Apple Silicon Hardware Engine Online")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                }
            }
            .frame(height: 32)
            .background(Color.primary.opacity(0.015))
        }
    }

    private var hardwareChipSummary: String {
        let raw = AppleSiliconTuner.shared.topology.chipName
        if raw.hasPrefix("Apple ") {
            return String(raw.dropFirst(6))
        }
        return raw
    }
}
