// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

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
    @FocusState private var focusedField: Int?
    
    @State private var hostAddress: String
    @State private var portString: String
    
    @State private var status: PairingStatus = .idle
    @State private var pairingTask: Task<Void, Never>? = nil
    
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
            // Header Bar
            headerSection
            
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: 1.5)
            
            // Content
            VStack(alignment: .leading, spacing: 20) {
                switch status {
                case .idle:
                    idleContent
                case .pairing(let step):
                    pairingProgressCard(step: step)
                case .success(let deviceName):
                    pairingSuccessCard(deviceName: deviceName)
                case .failure(let reason):
                    pairingFailureCard(reason: reason)
                }
                
                Spacer()
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.25), value: status)
            
            Divider()
            
            // Footer with Action buttons
            footerSection
        }
        .frame(width: 480, height: 490)
        .background(TTZipTheme.paperWhite)
        .onAppear {
            if initialHostIsComplete {
                focusedField = 0
            } else {
                focusedField = 0
            }
        }
        .onDisappear {
            pairingTask?.cancel()
            pairingTask = nil
        }
    }
    
    private var initialHostIsComplete: Bool {
        !hostAddress.hasSuffix(".")
    }
    
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            instructionBanner
            ipPortSection
            pinCodeSection
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(TTZipTheme.kintsugiGold.opacity(0.18))
                    .frame(width: 36, height: 36)
                
                Image(systemName: "wifi")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.currentLanguage == .zhHans ? "无线 Wi-Fi 设备配对" : "Pair Android Device via Wi-Fi")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(l10n.currentLanguage == .zhHans
                     ? "通过 Android 11+ 原生无线调试免线缆高速浏览与管理"
                     : "Cable-free high-speed management using Android 11+ Wireless Debugging")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }
    
    private var instructionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.currentLanguage == .zhHans ? "手机端操作步骤：" : "Steps on your Android device:")
                .font(.system(size: 11.5, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            
            Text(l10n.currentLanguage == .zhHans
                 ? "1. 确保手机与 Mac 处于同一 Wi-Fi 局域网\n2. 打开「系统设置」->「开发者选项」->「无线调试」\n3. 轻触「使用配对码配对设备」，输入界面显示的 6 位配对码与 IP 端口"
                 : "1. Ensure phone and Mac are connected to the same Wi-Fi network\n2. Open Settings -> Developer Options -> Wireless Debugging\n3. Tap 'Pair device with pairing code' and input the PIN and IP:port shown")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }
    
    private var ipPortSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.currentLanguage == .zhHans ? "设备 IP 与配对端口" : "Device IP & Pairing Port")
                .font(.system(size: 11.5, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
            
            HStack(spacing: 8) {
                TextField("192.168.1.xxx", text: $hostAddress)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
                    )
                    .frame(maxWidth: .infinity)
                
                Text(":")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                
                TextField("Port", text: $portString)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
                    )
                    .frame(width: 85)
            }
        }
    }
    
    private var pinCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.currentLanguage == .zhHans ? "6 位无线配对码 (PIN Code)" : "6-Digit Wireless Pairing Code (PIN)")
                .font(.system(size: 11.5, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
            
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    pinDigitBox(index: index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    
    private func pinDigitBox(index: Int) -> some View {
        let isFocused = focusedField == index
        
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .frame(width: 46, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isFocused ? TTZipTheme.kintsugiGold : Color.primary.opacity(0.12), lineWidth: isFocused ? 1.5 : 0.8)
                )
            
            TextField("", text: Binding(
                get: { pinDigits[index] },
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
    
    private func handleDigitInput(_ newValue: String, at index: Int) {
        // Handle multi-character paste (e.g. pasting "123456")
        if newValue.count > 1 {
            let digits = newValue.filter { $0.isNumber }
            for (offset, char) in digits.prefix(6).enumerated() {
                pinDigits[offset] = String(char)
            }
            focusedField = min(5, digits.count)
            return
        }
        
        let filtered = newValue.filter { $0.isNumber }
        pinDigits[index] = filtered
        
        if !filtered.isEmpty && index < 5 {
            focusedField = index + 1
        }
    }
    
    // MARK: - State Cards
    
    private func pairingProgressCard(step: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.3)
                .padding(.top, 24)
            
            VStack(spacing: 8) {
                Text(l10n.currentLanguage == .zhHans ? "正在进行安全无线配对..." : "Negotiating Secure Pairing...")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(step)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                Text("\(hostAddress):\(portString)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text("TLS 1.3 SPAKE2 Key Exchange")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.03))
            .clipShape(Capsule())
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }
    
    private func pairingSuccessCard(deviceName: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(TTZipTheme.bambooGreen.opacity(0.15))
                    .frame(width: 56, height: 56)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            .padding(.top, 24)
            
            VStack(spacing: 6) {
                Text(l10n.currentLanguage == .zhHans ? "无线配对成功！" : "Pairing Successful!")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(deviceName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                
                Text(l10n.currentLanguage == .zhHans
                     ? "已完成双向密钥协商与设备注册，无线管理通道已就绪。"
                     : "Bi-directional authentication complete. Wireless channel ready.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(TTZipTheme.bambooGreen.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func pairingFailureCard(reason: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(TTZipTheme.cinnabarRed.opacity(0.15))
                    .frame(width: 56, height: 56)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(TTZipTheme.cinnabarRed)
            }
            .padding(.top, 24)
            
            VStack(spacing: 8) {
                Text(l10n.currentLanguage == .zhHans ? "无线配对未完成" : "Pairing Failed")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(reason)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TTZipTheme.cinnabarRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                Text(l10n.currentLanguage == .zhHans
                     ? "请核对手机屏幕上显示的 6 位配对码与端口（非直连端口），并确保手机屏幕保持点亮。"
                     : "Check the 6-digit PIN and pairing port (not connect port) and keep screen awake.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(TTZipTheme.cinnabarRed.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var footerSection: some View {
        HStack(spacing: 12) {
            Spacer()
            
            switch status {
            case .idle:
                Button(action: { isPresented = false }) {
                    Text(l10n.currentLanguage == .zhHans ? "取消" : "Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    performPairing()
                }) {
                    Text(l10n.currentLanguage == .zhHans ? "配对并连接" : "Pair & Connect")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(isPinValid ? TTZipTheme.bambooGreen : Color.secondary.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!isPinValid)
                
            case .pairing:
                Button(action: {
                    pairingTask?.cancel()
                    pairingTask = nil
                    status = .idle
                }) {
                    Text(l10n.currentLanguage == .zhHans ? "取消握手" : "Cancel Handshake")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                
            case .success:
                Button(action: {
                    isPresented = false
                }) {
                    Text(l10n.currentLanguage == .zhHans ? "完成" : "Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .background(TTZipTheme.bambooGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                
            case .failure:
                Button(action: {
                    isPresented = false
                }) {
                    Text(l10n.currentLanguage == .zhHans ? "取消" : "Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    retryPairing()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text(l10n.currentLanguage == .zhHans ? "重新输入并重试" : "Retry")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(TTZipTheme.kintsugiGold)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Color.primary.opacity(0.02))
    }
    
    private var isPinValid: Bool {
        pinDigits.allSatisfy { $0.count == 1 && $0.allSatisfy(\.isNumber) } &&
        !hostAddress.trimmingCharacters(in: .whitespaces).isEmpty &&
        UInt16(portString) != nil
    }
    
    private func retryPairing() {
        status = .idle
        pinDigits = Array(repeating: "", count: 6)
        focusedField = 0
    }
    
    private func performPairing() {
        let pin = pinDigits.joined()
        guard let port = UInt16(portString) else {
            status = .failure(reason: l10n.currentLanguage == .zhHans ? "配对端口无效（必须为 1-65535）" : "Invalid pairing port (1-65535)")
            return
        }
        guard pin.count == 6, pin.allSatisfy(\.isNumber) else {
            status = .failure(reason: l10n.currentLanguage == .zhHans ? "配对码必须为 6 位纯数字" : "PIN must be 6 digits")
            return
        }
        guard !hostAddress.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = .failure(reason: l10n.currentLanguage == .zhHans ? "请输入设备 IP 地址" : "Please specify device IP")
            return
        }
        
        status = .pairing(step: l10n.currentLanguage == .zhHans ? "正在发起 TLS 1.3 SPAKE2 握手..." : "Initiating TLS 1.3 SPAKE2 handshake...")
        
        pairingTask?.cancel()
        pairingTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                
                status = .pairing(step: l10n.currentLanguage == .zhHans ? "正在校验 6 位配对口令..." : "Verifying 6-digit authentication token...")
                
                let timeoutMsg = l10n.currentLanguage == .zhHans
                    ? "配对连接超时。请确保手机与电脑处于同一 Wi-Fi，且手机屏幕保持常亮。"
                    : "Pairing timed out. Ensure device is on the same Wi-Fi and screen is awake."
                
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
                let reason = error.localizedDescription
                status = .failure(reason: reason)
            }
        }
    }
}
