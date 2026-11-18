// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Lifecycle status states for TLS 1.3 SPAKE2 wireless pairing handshake.
public enum PairingStatus: Equatable, Sendable {
    case idle
    case pairing(step: String)
    case success(deviceName: String)
    case failure(reason: String)
}

/// Interactive Wi-Fi wireless pairing sheet modal supporting 6-digit OTP PIN code
/// and IP/Port handshake with Android 11+ Wireless Debugging.
public struct AndroidPairingSheet: View {
    @Binding public var isPresented: Bool
    @Bindable public var viewModel: AndroidDeviceViewModel
    
    private var l10n = AppLocalizationState.shared
    
    @State private var pinDigits: [String] = Array(repeating: "", count: 6)
    @State private var hostAddress: String
    @State private var portString: String
    
    @State private var status: PairingStatus = .idle
    @State private var pairingTask: Task<Void, Never>? = nil
    @State private var shakeTrigger: Int = 0
    @State private var isPinError: Bool = false
    
    public init(
        isPresented: Binding<Bool> = .constant(true),
        viewModel: AndroidDeviceViewModel = .shared,
        initialHost: String = "",
        initialPort: UInt16? = nil
    ) {
        self._isPresented = isPresented
        self.viewModel = viewModel
        let defaultHost = initialHost.isEmpty ? "192.168.1." : initialHost
        let defaultPort = initialPort.map { String($0) } ?? (initialHost.isEmpty ? "37123" : "")
        self._hostAddress = State(initialValue: defaultHost)
        self._portString = State(initialValue: defaultPort)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            
            VStack(alignment: .leading, spacing: 20) {
                switch status {
                case .idle:
                    idleContent
                case .pairing(let step):
                    PairingProgressCard(step: step, hostAddress: hostAddress, portString: portString)
                case .success(let deviceName):
                    PairingSuccessCard(deviceName: deviceName)
                case .failure(let reason):
                    PairingFailureCard(reason: reason)
                }
                Spacer()
            }
            .padding(24)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: status)
            
            Divider()
            footerSection
        }
        .frame(width: 480, height: 490)
        .ttOverlayGlassPlate(cornerRadius: 18)
        .onDisappear {
            pairingTask?.cancel()
            pairingTask = nil
        }
    }
    
    // MARK: - Sections
    
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            PairingInstructionBanner()
            ipPortSection
            AndroidPairingPinInputView(
                pinDigits: $pinDigits,
                isError: isPinError,
                shakeTrigger: shakeTrigger,
                onComplete: { _ in
                    if isPinValid { performPairing() }
                }
            )
        }
    }
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(TTZipTheme.kintsugiGold.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: "wifi").font(.system(size: 16, weight: .bold)).foregroundStyle(TTZipTheme.kintsugiGold)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                L10nText(L10n.AndroidInterconnect.pairingHeaderTitle)
                    .font(.system(size: 15, weight: .bold, design: .serif)).foregroundStyle(.primary)
                L10nText(L10n.AndroidInterconnect.pairingHeaderSubtitle)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).background(Color.primary.opacity(0.04)).clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.t(L10n.Common.close))
        }
        .padding(.horizontal, 20).frame(height: 64)
    }
    
    private var ipPortSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            L10nText(L10n.AndroidInterconnect.pairingIpPortLabel)
                .font(.system(size: 11.5, weight: .semibold, design: .serif)).foregroundStyle(.primary)
            
            HStack(spacing: 8) {
                TextField("192.168.1.xxx", text: $hostAddress)
                    .pairingInputField().frame(maxWidth: .infinity)
                Text(":").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                TextField(l10n.t(L10n.AndroidInterconnect.pairingPortPlaceholder), text: $portString)
                    .pairingInputField().frame(width: 85)
            }
        }
    }
    
    private var footerSection: some View {
        HStack(spacing: 12) {
            Spacer()
            switch status {
            case .idle:
                cancelButton()
                actionButton(
                    title: l10n.t(L10n.AndroidInterconnect.pairingActionPairConnect),
                    color: TTZipTheme.bambooGreen,
                    isEnabled: isPinValid,
                    action: performPairing
                )
            case .pairing:
                cancelButton(title: l10n.t(L10n.AndroidInterconnect.pairingActionCancelHandshake)) {
                    pairingTask?.cancel()
                    pairingTask = nil
                    status = .idle
                }
            case .success:
                actionButton(
                    title: l10n.t(L10n.Common.done),
                    color: TTZipTheme.bambooGreen,
                    action: { isPresented = false }
                )
            case .failure:
                cancelButton()
                Button(action: retryPairing) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text(l10n.t(L10n.Common.retry))
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 6).background(TTZipTheme.kintsugiGold)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).frame(height: 52).background(Color.primary.opacity(0.02))
    }
    
    private func cancelButton(title: String? = nil, action: (() -> Void)? = nil) -> some View {
        Button(action: { action?() ?? { isPresented = false }() }) {
            Text(title ?? l10n.t(L10n.Common.cancel))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
    
    private func actionButton(title: String, color: Color, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(isEnabled ? color : Color.secondary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
    
    // MARK: - Validation & Actions
    
    private var isPinValid: Bool {
        pinDigits.allSatisfy { $0.count == 1 && $0.allSatisfy(\.isNumber) } &&
        !hostAddress.trimmingCharacters(in: .whitespaces).isEmpty &&
        UInt16(portString) != nil
    }
    
    private func failPairing(reason: String) {
        isPinError = true
        shakeTrigger += 1
        status = .failure(reason: reason)
    }
    
    private func retryPairing() {
        status = .idle
        isPinError = false
        pinDigits = Array(repeating: "", count: 6)
    }
    
    private func performPairing() {
        let pin = pinDigits.joined()
        guard let port = UInt16(portString) else {
            failPairing(reason: l10n.t(L10n.Device.invalidPortError))
            return
        }
        guard pin.count == 6, pin.allSatisfy(\.isNumber) else {
            failPairing(reason: l10n.t(L10n.Device.pinDigitsError))
            return
        }
        guard !hostAddress.trimmingCharacters(in: .whitespaces).isEmpty else {
            failPairing(reason: l10n.t(L10n.Device.specifyIpError))
            return
        }
        
        isPinError = false
        status = .pairing(step: l10n.t(L10n.Device.handshakeStep))
        
        pairingTask?.cancel()
        pairingTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                
                status = .pairing(step: l10n.t(L10n.Device.verifyPinStep))
                
                let timeoutMsg = l10n.t(L10n.Device.timeoutMsg)
                
                // Structured timeout wrapper: 12 seconds
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await viewModel.pairWirelessDevice(pin: pin, host: hostAddress, port: port)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 12_000_000_000)
                        throw NSError(
                            domain: "TTZipWirelessPairing",
                            code: 408,
                            userInfo: [NSLocalizedDescriptionKey: timeoutMsg]
                        )
                    }
                    try await group.next()
                    group.cancelAll()
                }
                
                guard !Task.isCancelled else { return }
                
                let devName = viewModel.selectedDevice?.displayName ?? "Android Wireless Device (\(hostAddress))"
                status = .success(deviceName: devName)
                
                try await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                
                isPresented = false
            } catch {
                guard !Task.isCancelled else { return }
                failPairing(reason: error.localizedDescription)
            }
        }
    }
}

// MARK: - Input Field Style Helper

private extension View {
    func pairingInputField() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: TTZipUniversalTokens.Border.width))
    }
}
