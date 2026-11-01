// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Step-by-step interactive guidance modal illustrating how to unlock high-speed USB debugging
/// and penetrate Android 11+ Scoped Storage restrictions.
public struct AdbEnableGuideSheet: View {
    @Binding public var isPresented: Bool
    
    private var l10n = AppLocalizationState.shared
    @State private var isChecking: Bool = false
    @State private var checkSuccess: Bool = false
    @State private var checkFailed: Bool = false
    @State private var checkFailureDetail: String? = nil
    
    public init(isPresented: Binding<Bool> = .constant(true)) {
        self._isPresented = isPresented
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerSection
            
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: 1.5)
            
            // Scrollable Guide Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // Benefit comparison matrix
                    performanceComparisonBanner
                    
                    // 4-Step Illustrated Walkthrough
                    stepsSection
                }
                .padding(24)
            }
            
            Divider()
            
            // Footer with verification button
            footerSection
        }
        .frame(width: 540, height: 600)
        .ttOverlayGlassPlate(cornerRadius: 18)
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(TTZipTheme.bambooGreen.opacity(0.15))
                    .frame(width: 36, height: 36)
                
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                L10nText(L10n.Device.switchAdbMode)
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                L10nText(L10n.Device.switchAdbModeDesc)
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
    
    private var performanceComparisonBanner: some View {
        HStack(spacing: 12) {
            // MTP standard
            VStack(alignment: .leading, spacing: 4) {
                L10nText(L10n.AndroidInterconnect.guideStandardMtpTitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                
                L10nText(L10n.AndroidInterconnect.guideStandardMtpSpeed)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                L10nText(L10n.AndroidInterconnect.guideStandardMtpDesc)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            // ADB high-speed
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    L10nText(L10n.AndroidInterconnect.guideHighSpeedAdbTitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
                
                L10nText(L10n.AndroidInterconnect.guideHighSpeedAdbSpeed)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                
                L10nText(L10n.AndroidInterconnect.guideHighSpeedAdbDesc)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TTZipTheme.bambooGreen.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(TTZipTheme.bambooGreen.opacity(0.25), lineWidth: 0.5)
            )
        }
    }
    
    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            L10nText(L10n.Device.guideTitle)
                .font(.system(size: 12.5, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            
            stepRow(
                stepNumber: 1,
                icon: "gearshape.fill",
                title: l10n.t(L10n.Device.guideStep1Title),
                description: l10n.t(L10n.Device.guideStep1Desc)
            )
            
            stepRow(
                stepNumber: 2,
                icon: "hand.tap.fill",
                title: l10n.t(L10n.Device.guideStep2Title),
                description: l10n.t(L10n.Device.guideStep2Desc)
            )
            
            stepRow(
                stepNumber: 3,
                icon: "wrench.and.screwdriver.fill",
                title: l10n.t(L10n.Device.guideStep3Title),
                description: l10n.t(L10n.Device.guideStep3Desc)
            )
            
            stepRow(
                stepNumber: 4,
                icon: "lock.open.display",
                title: l10n.t(L10n.Device.guideStep4Title),
                description: l10n.t(L10n.Device.guideStep4Desc)
            )
        }
    }
    
    private func stepRow(stepNumber: Int, icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Badge
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 26, height: 26)
                
                Text("\(stepNumber)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                
                Text(description)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
    }
    
    private var footerSection: some View {
        HStack(spacing: 12) {
            if checkSuccess {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    L10nText(L10n.Device.adbActive)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
            } else if checkFailed {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                    if let detail = checkFailureDetail {
                        Text(detail)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.red)
                            .lineLimit(2)
                    } else {
                        L10nText(L10n.Device.adbNotFound)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.red)
                    }
                }
            }
            
            Spacer()
            
            Button(action: {
                verifyConnection()
            }) {
                HStack(spacing: 6) {
                    if isChecking {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    L10nText(L10n.Device.recheck)
                }
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isChecking)
            
            Button(action: {
                isPresented = false
            }) {
                L10nText(L10n.Common.done)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(TTZipTheme.bambooGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Color.primary.opacity(0.02))
    }
    
    private func probeAdbPort(host: String = "127.0.0.1", port: UInt16 = 5037, timeoutMs: Int32 = 500) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, String(port), &hints, &res) == 0, let addrList = res else {
                    continuation.resume(returning: false)
                    return
                }
                defer { freeaddrinfo(addrList) }
                
                let sock = socket(addrList.pointee.ai_family, addrList.pointee.ai_socktype, addrList.pointee.ai_protocol)
                guard sock >= 0 else {
                    continuation.resume(returning: false)
                    return
                }
                defer { close(sock) }
                
                let flags = fcntl(sock, F_GETFL, 0)
                _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
                
                let ret = connect(sock, addrList.pointee.ai_addr, addrList.pointee.ai_addrlen)
                if ret == 0 {
                    continuation.resume(returning: true)
                    return
                }
                
                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                    let pollRes = poll(&pfd, 1, timeoutMs)
                    if pollRes > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                        var err: Int32 = 0
                        var errLen = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0 && err == 0 {
                            continuation.resume(returning: true)
                            return
                        }
                    }
                }
                continuation.resume(returning: false)
            }
        }
    }
    
    private func verifyConnection() {
        isChecking = true
        checkFailed = false
        checkFailureDetail = nil
        Task {
            let daemonPort = AndroidDeviceViewModel.shared.adbDaemonPort
            let isPortOpen = await probeAdbPort(port: daemonPort)
            let probeResult = await Task.detached(priority: .userInitiated) {
                AdbSmartSocketClient.probeAuthorizedDevices(daemonPort: daemonPort)
            }.value
            await AndroidDeviceViewModel.shared.refreshHardwareDevices()
            
            await MainActor.run {
                isChecking = false
                let connectedAdbDevice = AndroidDeviceViewModel.shared.connectedDevices.first {
                    $0.isConnected && ($0.connectionType == .usbAdb || $0.connectionType == .wirelessAdb)
                }
                if let adbDevice = connectedAdbDevice {
                    checkSuccess = true
                    checkFailed = false
                    checkFailureDetail = nil
                    AndroidDeviceViewModel.shared.selectDevice(adbDevice)
                } else if let firstRecord = probeResult.authorizedDevices.first {
                    checkSuccess = true
                    checkFailed = false
                    checkFailureDetail = nil
                    let firstSerial = firstRecord.serial
                    let displayName = firstRecord.model?.replacingOccurrences(of: "_", with: " ") ?? firstSerial
                    let fallbackDevice = AndroidDevice(
                        deviceId: "adb:\(firstSerial)",
                        displayName: displayName,
                        vendorId: 0x18D1,
                        productId: 0x4EE7,
                        serialNumber: firstSerial,
                        connectionType: firstSerial.contains(":") ? .wirelessAdb : .usbAdb,
                        status: .connected,
                        storagePartitions: AdbSmartSocketClient.defaultPartitions(
                            for: firstSerial.contains(":") ? .wirelessAdb : .usbAdb
                        )
                    )
                    AndroidDeviceViewModel.shared.registerDevice(fallbackDevice)
                    AndroidDeviceViewModel.shared.selectDevice(fallbackDevice)
                } else {
                    checkSuccess = false
                    checkFailed = true
                    if isPortOpen || probeResult.daemonReachable {
                        checkFailureDetail = l10n.t(L10n.AndroidInterconnect.guideProbeDaemonOnlyNoDevice)
                    } else {
                        checkFailureDetail = nil
                    }
                }
            }
        }
    }
}
