// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Interactive 6-digit OTP PIN code input component with auto-focus advancement,
/// multi-digit paste handling, and customizable error shake animation.
public struct AndroidPairingPinInputView: View {
    @Binding public var pinDigits: [String]
    public var isError: Bool
    public var shakeTrigger: Int
    public var onComplete: ((String) -> Void)?
    
    @FocusState private var focusedField: Int?
    private var l10n = AppLocalizationState.shared
    
    public init(
        pinDigits: Binding<[String]>,
        isError: Bool = false,
        shakeTrigger: Int = 0,
        onComplete: ((String) -> Void)? = nil
    ) {
        self._pinDigits = pinDigits
        self.isError = isError
        self.shakeTrigger = shakeTrigger
        self.onComplete = onComplete
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            L10nText(L10n.Device.pinCodeTitle)
                .font(.system(size: 11.5, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
            
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    pinDigitBox(index: index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .modifier(PinShakeEffect(animatableData: CGFloat(shakeTrigger)))
            .animation(.default, value: shakeTrigger)
        }
        .onAppear {
            if focusedField == nil {
                focusedField = 0
            }
        }
    }
    
    // MARK: - Box Subview
    
    private func pinDigitBox(index: Int) -> some View {
        let isFocused = focusedField == index
        let digitValue = pinDigits.indices.contains(index) ? pinDigits[index] : ""
        
        let strokeColor: Color = {
            if isError {
                return TTZipTheme.cinnabarRed
            } else if isFocused {
                return TTZipTheme.kintsugiGold
            } else {
                return Color.primary.opacity(0.12)
            }
        }()
        
        let strokeWidth: CGFloat = (isFocused || isError) ? 1.0 : TTZipUniversalTokens.Border.width
        
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .frame(width: 46, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: strokeWidth)
                )
            
            TextField("", text: Binding(
                get: { digitValue },
                set: { newValue in
                    handleDigitInput(newValue, at: index)
                }
            ))
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .focused($focusedField, equals: index)
            .frame(width: 44, height: 50)
            .textFieldStyle(.plain)
        }
    }
    
    // MARK: - Input Handling
    
    private func handleDigitInput(_ newValue: String, at index: Int) {
        // Handle multi-character paste (e.g. pasting "123456")
        if newValue.count > 1 {
            let digits = newValue.filter(\.isNumber)
            for (offset, char) in digits.prefix(6).enumerated() {
                if pinDigits.indices.contains(offset) {
                    pinDigits[offset] = String(char)
                }
            }
            focusedField = min(5, digits.count)
            if digits.count >= 6 {
                onComplete?(pinDigits.joined())
            }
            return
        }
        
        let filtered = newValue.filter(\.isNumber)
        if pinDigits.indices.contains(index) {
            pinDigits[index] = filtered
        }
        
        if !filtered.isEmpty {
            if index < 5 {
                focusedField = index + 1
            } else {
                let fullPin = pinDigits.joined()
                if fullPin.count == 6 {
                    onComplete?(fullPin)
                }
            }
        }
    }
}

// MARK: - Error Shake Animation Effect

/// GeometryEffect providing a horizontal damped oscillating shake animation.
public struct PinShakeEffect: GeometryEffect {
    public var amount: CGFloat = 8
    public var shakesPerUnit: Int = 3
    public var animatableData: CGFloat
    
    public init(amount: CGFloat = 8, shakesPerUnit: Int = 3, animatableData: CGFloat) {
        self.amount = amount
        self.shakesPerUnit = shakesPerUnit
        self.animatableData = animatableData
    }
    
    public func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * CGFloat(shakesPerUnit))
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
