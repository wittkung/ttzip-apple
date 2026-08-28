// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Dual-mode compression level selector combining quick preset capsules with custom numeric input & steppers.
public struct CompressionLevelDualModeSelector: View {
    @Binding public var compressionLevel: ArchiveCompressionLevel
    public let format: ArchiveCompressionFormat
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool
    
    public init(
        compressionLevel: Binding<ArchiveCompressionLevel>,
        format: ArchiveCompressionFormat
    ) {
        self._compressionLevel = compressionLevel
        self.format = format
    }
    
    private var isPresetMatched: Bool {
        format.supportedLevels.contains(compressionLevel)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // 1. Quick preset capsules
                HStack(spacing: 6) {
                    ForEach(format.supportedLevels, id: \.rawValue) { presetLevel in
                        quickPresetCapsule(for: presetLevel)
                    }
                }
                
                Spacer(minLength: 4)
                
                // 2. Custom numeric stepper & direct text input
                if format.maxCompressionLevel > 0 {
                    customStepperInputView
                }
            }
            
            // 3. Status hint when using custom unlisted level
            if !isPresetMatched {
                customLevelDetailHint
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            syncInputText()
        }
        .onChange(of: compressionLevel) { _, _ in
            if !isInputFocused {
                syncInputText()
            }
        }
        .onChange(of: format) { _, newFmt in
            clampLevelToFormatRange(newFmt)
        }
    }
    
    // MARK: - Subviews
    
    private func quickPresetCapsule(for level: ArchiveCompressionLevel) -> some View {
        let isSelected = compressionLevel == level
        let ratioPct = Int(round(level.compressionRatioPercent(for: format)))
        let title: String = {
            switch level {
            case .store: return "Store (0)"
            case .level1: return "Fast (1)"
            case .level6: return "Std (6)"
            case .level9: return "Ultra (9)"
            case .level12: return "DAG (12)"
            default: return "L\(level.rawValue)"
            }
        }()
        
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                compressionLevel = level
                inputText = "\(level.rawValue)"
            }
        }) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isSelected ? TTZipTheme.bambooGreen.opacity(0.14) : Color.primary.opacity(0.03))
                .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Compression Level \(level.rawValue) (Est. ~\(ratioPct)% size)")
    }
    
    private var customStepperInputView: some View {
        HStack(spacing: 4) {
            // Decrement button
            Button(action: decrementLevel) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 22)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(compressionLevel.rawValue <= format.minCompressionLevel)
            
            // Editable text field
            TextField("", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: !isPresetMatched ? .bold : .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 26, height: 22)
                .focused($isInputFocused)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(!isPresetMatched ? TTZipTheme.bambooGreen.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
                )
                .onSubmit {
                    commitInputText()
                }
            
            // Increment button
            Button(action: incrementLevel) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 22)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(compressionLevel.rawValue >= format.maxCompressionLevel)
            
            // Range badge
            Text("(\(format.minCompressionLevel)~\(format.maxCompressionLevel))")
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(!isPresetMatched ? TTZipTheme.bambooGreen.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
    
    private var customLevelDetailHint: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(TTZipTheme.bambooGreen)
                .frame(width: 5, height: 5)
            
            Text("Custom Level \(compressionLevel.rawValue): \(compressionLevel.detailDescription)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TTZipTheme.bambooGreen)
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - Logic Helpers
    
    private func syncInputText() {
        inputText = "\(compressionLevel.rawValue)"
    }
    
    private func commitInputText() {
        if let val = Int(inputText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let clamped = max(format.minCompressionLevel, min(format.maxCompressionLevel, val))
            withAnimation(.easeInOut(duration: 0.15)) {
                compressionLevel = ArchiveCompressionLevel(levelInt: clamped)
                inputText = "\(clamped)"
            }
        } else {
            syncInputText()
        }
    }
    
    private func incrementLevel() {
        let nextVal = compressionLevel.rawValue + 1
        if nextVal <= format.maxCompressionLevel {
            withAnimation(.easeInOut(duration: 0.15)) {
                compressionLevel = ArchiveCompressionLevel(levelInt: nextVal)
                inputText = "\(nextVal)"
            }
        }
    }
    
    private func decrementLevel() {
        let prevVal = compressionLevel.rawValue - 1
        if prevVal >= format.minCompressionLevel {
            withAnimation(.easeInOut(duration: 0.15)) {
                compressionLevel = ArchiveCompressionLevel(levelInt: prevVal)
                inputText = "\(prevVal)"
            }
        }
    }
    
    private func clampLevelToFormatRange(_ fmt: ArchiveCompressionFormat) {
        let current = compressionLevel.rawValue
        if current > fmt.maxCompressionLevel || current < fmt.minCompressionLevel {
            let clamped = max(fmt.minCompressionLevel, min(fmt.maxCompressionLevel, current))
            compressionLevel = ArchiveCompressionLevel(levelInt: clamped)
            inputText = "\(clamped)"
        }
    }
}
