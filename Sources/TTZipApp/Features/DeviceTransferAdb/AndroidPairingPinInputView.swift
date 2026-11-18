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
        let outcome = Self.applyDigitInput(newValue, at: index, pinDigits: &pinDigits)
        if let nextFocus = outcome.nextFocus {
            focusedField = nextFocus
        }
        if let completedPin = outcome.completedPin {
            onComplete?(completedPin)
        }
    }
    
    /// Pure state transition for 6-digit PIN boxes supporting single-digit replacement,
    /// multi-digit paste, and backspace focus traversal.
    public static func applyDigitInput(
        _ newValue: String,
        at index: Int,
        pinDigits: inout [String]
    ) -> (nextFocus: Int?, completedPin: String?) {
        let previous = pinDigits.indices.contains(index) ? pinDigits[index] : ""
        let digits = newValue.filter(\.isNumber)
        
        if let replacement = extractSingleReplacement(digits: digits, previous: previous) {
            return applySingleDigit(replacement, at: index, pinDigits: &pinDigits)
        }
        if digits.count > 1 {
            return applyMultiDigitPaste(digits, at: index, pinDigits: &pinDigits)
        }
        return applySingleDigit(digits, at: index, pinDigits: &pinDigits)
    }
    
    private static func extractSingleReplacement(digits: String, previous: String) -> String? {
        guard digits.count == 2, previous.count == 1, let prevChar = previous.first else {
            return nil
        }
        if digits.first == prevChar { return String(digits.last!) }
        if digits.last == prevChar { return String(digits.first!) }
        return nil
    }
    
    private static func applyMultiDigitPaste(
        _ digits: String,
        at index: Int,
        pinDigits: inout [String]
    ) -> (nextFocus: Int?, completedPin: String?) {
        let startIndex = digits.count >= 6 ? 0 : index
        var lastFilled = startIndex
        for (offset, char) in digits.enumerated() {
            let target = startIndex + offset
            guard pinDigits.indices.contains(target) else { break }
            pinDigits[target] = String(char)
            lastFilled = target
        }
        let nextFocus = min(5, lastFilled + 1)
        let fullPin = pinDigits.joined()
        return (nextFocus, fullPin.count == 6 ? fullPin : nil)
    }
    
    private static func applySingleDigit(
        _ digit: String,
        at index: Int,
        pinDigits: inout [String]
    ) -> (nextFocus: Int?, completedPin: String?) {
        if pinDigits.indices.contains(index) {
            pinDigits[index] = digit
        }
        guard !digit.isEmpty else {
            return (max(0, index - 1), nil)
        }
        let nextFocus = min(5, index + 1)
        let fullPin = pinDigits.joined()
        return (nextFocus, fullPin.count == 6 ? fullPin : nil)
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
