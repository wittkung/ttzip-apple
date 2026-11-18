// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import TTZipUI

struct TTZipPDFPasswordUnlockView: View {
    @Binding var passwordInput: String
    let errorMessage: String?
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text(TTZipPDFPreviewLocalization.text(.encryptedTitle))
                .font(.system(size: 14, weight: .bold))

            Text(TTZipPDFPreviewLocalization.text(.encryptedPrompt))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            HStack(spacing: 8) {
                SecureField(TTZipPDFPreviewLocalization.text(.enterPassword), text: $passwordInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(onSubmit)

                Button(action: onSubmit) {
                    Text(TTZipPDFPreviewLocalization.text(.unlock))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(TTZipTheme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
    }
}
