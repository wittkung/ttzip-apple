// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import Network
import Observation
import dnssd
import Darwin
import TTZipCore
import TTZipUI

/// Discovered local Wi-Fi candidate model representing mDNS wireless endpoints.
public struct DiscoveredWirelessEndpoint: Identifiable, Sendable, Hashable {
    public let id: String
    public let host: String
    public let port: UInt16
    public let deviceModel: String
    public let serviceType: String
    public let isPaired: Bool
    public let lastSeen: Date
    
    public init(
        id: String = UUID().uuidString,
        host: String,
        port: UInt16,
        deviceModel: String,
        serviceType: String = "_adb-tls-connect._tcp",
        isPaired: Bool = false,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.deviceModel = deviceModel
        self.serviceType = serviceType
        self.isPaired = isPaired
        self.lastSeen = lastSeen
    }
}

/// Darwin dns_sd resolver resolving Bonjour instance name to IP address and port.
@MainActor
final class DarwinDnsSdResolver {
    private var serviceRef: DNSServiceRef?
    private var readSource: (any DispatchSourceRead)?
    
    func resolve(
        name: String,
        type: String,
        domain: String,
        queue: DispatchQueue,
        completion: @escaping @Sendable @MainActor (String?, UInt16) -> Void
    ) {
        var localRef: DNSServiceRef?
        let contextPtr = UnsafeMutablePointer<(@Sendable @MainActor (String?, UInt16) -> Void)>.allocate(capacity: 1)
        contextPtr.initialize(to: completion)
        
        let err = DNSServiceResolve(
            &localRef,
            0,
            0,
            name,
            type,
            domain,
            { (sdRef, flags, ifIndex, errCode, fullname, hosttarget, port, txtLen, txtRecord, context) in
                guard let context else { return }
                let cb = context.assumingMemoryBound(to: (@Sendable @MainActor (String?, UInt16) -> Void).self)
                if errCode == 0, let hosttarget {
                    let hostStr = String(cString: hosttarget)
                    let resolvedPort = UInt16(bigEndian: port)
                    
                    var hints = addrinfo()
                    hints.ai_family = AF_INET
                    hints.ai_socktype = SOCK_STREAM
                    var res: UnsafeMutablePointer<addrinfo>?
                    var ipStr: String? = nil
                    if getaddrinfo(hostStr, nil, &hints, &res) == 0, let res {
                        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(res.pointee.ai_addr, res.pointee.ai_addrlen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            ipStr = hostBuffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
                        }
                        freeaddrinfo(res)
                    }
                    let finalHost = ipStr ?? hostStr
                    let handler = cb.pointee
                    Task { @MainActor in
                        handler(finalHost, resolvedPort)
                    }
                } else {
                    let handler = cb.pointee
                    Task { @MainActor in
                        handler(nil, 0)
                    }
                }
            },
            contextPtr
        )
        
        guard err == 0, let localRef else {
            contextPtr.deinitialize(count: 1)
            contextPtr.deallocate()
            completion(nil, 0)
            return
        }
        
        self.serviceRef = localRef
        let fd = DNSServiceRefSockFD(localRef)
        guard fd >= 0 else {
            DNSServiceRefDeallocate(localRef)
            self.serviceRef = nil
            contextPtr.deinitialize(count: 1)
            contextPtr.deallocate()
            completion(nil, 0)
            return
        }
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            DNSServiceProcessResult(localRef)
            source.cancel()
            contextPtr.deinitialize(count: 1)
            contextPtr.deallocate()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let ref = self.serviceRef {
                    DNSServiceRefDeallocate(ref)
                    self.serviceRef = nil
                }
            }
        }
        
        // Timeout safeguard after 5.0 seconds
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.serviceRef != nil else { return }
                self.cancel()
            }
        }
        
        self.readSource = source
        source.resume()
    }
    
    func cancel() {
        readSource?.cancel()
        readSource = nil
        if let ref = serviceRef {
            DNSServiceRefDeallocate(ref)
            serviceRef = nil
        }
    }
}

/// Swift 6 @MainActor coordinator managing asynchronous Bonjour/mDNS browsing
/// and address resolution for Android wireless debugging services.
@Observable
@MainActor
public final class WirelessMdnsCoordinator {
    /// Active list of discovered wireless endpoints on the local network.
    public private(set) var discoveredEndpoints: [DiscoveredWirelessEndpoint] = []
    
    /// Scanning status indicator.
    public private(set) var isScanning: Bool = false
    
    /// User-facing status or error message.
    public private(set) var statusMessage: String? = nil
    
    // MARK: - Private Network Browsers
    
    private var connectBrowser: NWBrowser?
    private var pairingBrowser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "com.ttzip.mdns.browser", qos: .userInitiated)
    
    /// Active DNS-SD resolvers keyed by unique service identifier.
    private var activeResolvers: [String: DarwinDnsSdResolver] = [:]
    
    public init() {}
    
    // MARK: - Lifecycle Management
    
    /// Initiates Bonjour/mDNS discovery for ADB connect and pairing services.
    public func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil
        
        startConnectBrowser()
        startPairingBrowser()
    }
    
    /// Stops all ongoing background mDNS browsers and resolvers.
    public func stopScanning() {
        connectBrowser?.cancel()
        connectBrowser = nil
        
        pairingBrowser?.cancel()
        pairingBrowser = nil
        
        for (_, resolver) in activeResolvers {
            resolver.cancel()
        }
        activeResolvers.removeAll()
        
        isScanning = false
    }
    
    /// Refreshes discovery by flushing existing endpoints and restarting browsers.
    public func refresh() {
        stopScanning()
        discoveredEndpoints.removeAll()
        startScanning()
    }
    
    // MARK: - NWBrowser Setup
    
    private func startConnectBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_adb-tls-connect._tcp", domain: "local.")
        let parameters = NWParameters()
        let browser = NWBrowser(for: descriptor, using: parameters)
        
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleBrowserResults(results, isPairingService: false)
            }
        }
        
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.statusMessage = "Connect browser error: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        
        browser.start(queue: browserQueue)
        self.connectBrowser = browser
    }
    
    private func startPairingBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_adb-tls-pairing._tcp", domain: "local.")
        let parameters = NWParameters()
        let browser = NWBrowser(for: descriptor, using: parameters)
        
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleBrowserResults(results, isPairingService: true)
            }
        }
        
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.statusMessage = "Pairing browser error: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        
        browser.start(queue: browserQueue)
        self.pairingBrowser = browser
    }
    
    private func handleBrowserResults(_ results: Set<NWBrowser.Result>, isPairingService: Bool) {
        var currentKeys = Set<String>()
        
        for result in results {
            if case let .service(name, type, domain, _) = result.endpoint {
                let serviceKey = "\(name).\(type).\(domain)"
                currentKeys.insert(serviceKey)
                
                var txtDict: [String: String] = [:]
                if case .bonjour(let txt) = result.metadata {
                    txtDict = txt.dictionary
                }
                
                if activeResolvers[serviceKey] == nil {
                    resolveService(name: name, type: type, domain: domain, txtProperties: txtDict, isPairingService: isPairingService)
                }
            }
        }
        
        // Remove endpoints that are no longer broadcasting
        let serviceSuffix = isPairingService ? "_adb-tls-pairing._tcp" : "_adb-tls-connect._tcp"
        discoveredEndpoints.removeAll { endpoint in
            endpoint.serviceType.contains(serviceSuffix) && !currentKeys.contains(where: { $0.contains(endpoint.host) || $0.contains(endpoint.deviceModel) })
        }
    }
    
    // MARK: - DNS-SD Resolution
    
    private func resolveService(name: String, type: String, domain: String, txtProperties: [String: String], isPairingService: Bool) {
        let serviceKey = "\(name).\(type).\(domain)"
        let resolver = DarwinDnsSdResolver()
        activeResolvers[serviceKey] = resolver
        
        let model = extractDeviceModel(name: name, txtProperties: txtProperties)
        
        resolver.resolve(name: name, type: type, domain: domain, queue: browserQueue) { [weak self] resolvedHost, resolvedPort in
            guard let self else { return }
            self.activeResolvers.removeValue(forKey: serviceKey)
            
            guard let resolvedHost, resolvedPort > 0 else { return }
            let endpointId = "\(resolvedHost):\(resolvedPort)"
            
            let endpoint = DiscoveredWirelessEndpoint(
                id: endpointId,
                host: resolvedHost,
                port: resolvedPort,
                deviceModel: model,
                serviceType: type,
                isPaired: !isPairingService,
                lastSeen: Date()
            )
            
            if let index = self.discoveredEndpoints.firstIndex(where: { $0.id == endpointId }) {
                self.discoveredEndpoints[index] = endpoint
            } else {
                self.discoveredEndpoints.append(endpoint)
            }
        }
    }
    
    private func extractDeviceModel(name: String, txtProperties: [String: String]) -> String {
        for key in ["ro.product.model", "model", "name", "md"] {
            if let val = txtProperties[key], !val.isEmpty {
                return val
            }
        }
        
        // Parse friendly name from instance name (e.g. adb-xxxx or device name)
        let cleaned = name.replacingOccurrences(of: ".local.", with: "").replacingOccurrences(of: ".local", with: "")
        return cleaned.isEmpty ? name : cleaned
    }
}

/// Sidebar and popover view presenting local Wi-Fi wireless Android device discovery,
/// saved pairings, direct IP connect, and trigger for 6-digit PIN code pairing.
public struct WirelessDeviceDiscoveryView: View {
    @Bindable public var viewModel: AndroidDeviceViewModel
    @Environment(\.dismiss) private var dismiss
    
    private var l10n = AppLocalizationState.shared
    
    @State private var coordinator = WirelessMdnsCoordinator()
    @State private var showManualConnect: Bool = false
    @State private var manualHost: String = ""
    @State private var manualPort: String = "5555"
    @State private var showPairingSheetInternal: Bool = false
    @State private var selectedEndpointForPairing: DiscoveredWirelessEndpoint? = nil
    
    public init(viewModel: AndroidDeviceViewModel = .shared) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerSection
            
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: 1.5)
            
            // Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Nearby Discovery Section
                    discoveryHeader
                    
                    // Discovered Endpoint List or Empty State
                    if coordinator.discoveredEndpoints.isEmpty {
                        emptyDiscoveryState
                    } else {
                        endpointList
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    // Manual Direct IP Connect Toggle
                    manualConnectSection
                }
                .padding(20)
            }
            
            Divider()
            
            // Footer: Pair New Device Button
            footerSection
        }
        .frame(width: 450, height: 490)
        .background(TTZipTheme.paperWhite)
        .sheet(isPresented: $showPairingSheetInternal) {
            AndroidPairingSheet(
                isPresented: $showPairingSheetInternal,
                viewModel: viewModel,
                initialHost: selectedEndpointForPairing?.host ?? "",
                initialPort: selectedEndpointForPairing?.port
            )
        }
        .task {
            coordinator.startScanning()
        }
        .onDisappear {
            coordinator.stopScanning()
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(TTZipTheme.kintsugiGold.opacity(0.18))
                    .frame(width: 32, height: 32)
                
                Image(systemName: "wifi")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.currentLanguage == .zhHans ? "无线设备发现" : "Wireless Device Discovery")
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(l10n.currentLanguage == .zhHans
                     ? "通过 mDNS 自动发现局域网内的安卓调试设备"
                     : "Auto-discovering Android devices broadcasting mDNS on local Wi-Fi")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }
    
    private var discoveryHeader: some View {
        HStack {
            Text(l10n.currentLanguage == .zhHans ? "附近的局域网设备" : "Nearby Discovered Devices")
                .font(.system(size: 11.5, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            
            Spacer()
            
            if coordinator.isScanning {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("mDNS Scanning...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            
            Button(action: {
                coordinator.refresh()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .frame(width: 20, height: 20)
                    .background(TTZipTheme.kintsugiGold.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(l10n.currentLanguage == .zhHans ? "刷新局域网广播" : "Refresh mDNS broadcast")
        }
    }
    
    private var emptyDiscoveryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.7))
                .padding(.top, 8)
            
            VStack(spacing: 4) {
                Text(l10n.currentLanguage == .zhHans ? "正在监听局域网无线设备..." : "Listening for Wireless ADB Devices...")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text(l10n.currentLanguage == .zhHans
                     ? "请确保手机与 Mac 连接同一 Wi-Fi，并在「开发者选项」中开启「无线调试」"
                     : "Ensure device and Mac share the same Wi-Fi with 'Wireless Debugging' enabled")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
    
    private var endpointList: some View {
        VStack(spacing: 8) {
            ForEach(coordinator.discoveredEndpoints) { endpoint in
                endpointRow(endpoint: endpoint)
            }
        }
    }
    
    private func endpointRow(endpoint: DiscoveredWirelessEndpoint) -> some View {
        HStack(spacing: 10) {
            Image(systemName: endpoint.isPaired ? "iphone.badge.play" : "wifi.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(endpoint.isPaired ? TTZipTheme.bambooGreen : TTZipTheme.kintsugiGold)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(endpoint.deviceModel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text(endpoint.isPaired ? "Ready" : "Pairing")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(endpoint.isPaired ? TTZipTheme.bambooGreen : TTZipTheme.kintsugiGold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background((endpoint.isPaired ? TTZipTheme.bambooGreen : TTZipTheme.kintsugiGold).opacity(0.12))
                        .clipShape(Capsule())
                }
                
                Text("\(endpoint.host):\(endpoint.port)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if endpoint.isPaired {
                Button(action: {
                    connectToEndpoint(endpoint)
                }) {
                    Text(l10n.currentLanguage == .zhHans ? "直接连接" : "Connect")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(TTZipTheme.bambooGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    selectedEndpointForPairing = endpoint
                    showPairingSheetInternal = true
                }) {
                    Text(l10n.currentLanguage == .zhHans ? "配对" : "Pair")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
    
    private var manualConnectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showManualConnect.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: showManualConnect ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    Text(l10n.currentLanguage == .zhHans ? "手动输入 IP 与端口连接 (免 mDNS)" : "Manual Direct IP Connect (Bypass mDNS)")
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if showManualConnect {
                HStack(spacing: 8) {
                    TextField("192.168.1.xxx", text: $manualHost)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                    
                    Text(":")
                        .foregroundStyle(.secondary)
                    
                    TextField("5555", text: $manualPort)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .frame(width: 60)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                    
                    Button(action: {
                        connectManual()
                    }) {
                        Text(l10n.currentLanguage == .zhHans ? "连接" : "Connect")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(manualHost.isEmpty)
                }
            }
        }
    }
    
    private var footerSection: some View {
        HStack {
            Spacer()
            
            Button(action: {
                selectedEndpointForPairing = nil
                showPairingSheetInternal = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text(l10n.currentLanguage == .zhHans ? "配对新设备 (PIN 码)" : "Pair New Device (6-Digit PIN)")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(TTZipTheme.kintsugiGold)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: TTZipTheme.kintsugiGold.opacity(0.3), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(Color.primary.opacity(0.02))
    }
    
    private func connectToEndpoint(_ endpoint: DiscoveredWirelessEndpoint) {
        let device = AndroidDevice(
            deviceId: "wifi:\(endpoint.host):\(endpoint.port)",
            displayName: "\(endpoint.deviceModel) (\(endpoint.host))",
            vendorId: 0,
            productId: 0,
            serialNumber: "WIFI_\(endpoint.host)",
            connectionType: .wirelessAdb,
            status: .connected,
            storagePartitions: [
                AndroidStoragePartition(
                    partitionId: "internal_0",
                    displayName: "Internal Storage",
                    totalBytes: 128_000_000_000,
                    availableBytes: 52_000_000_000,
                    rootPath: "/storage/emulated/0",
                    isRemovable: false
                )
            ]
        )
        Task {
            await AndroidDeviceManager.shared.registerDevice(device)
            await MainActor.run {
                viewModel.selectDevice(device)
                dismiss()
            }
        }
    }
    
    private func connectManual() {
        guard let port = UInt16(manualPort) else { return }
        let endpoint = DiscoveredWirelessEndpoint(
            host: manualHost,
            port: port,
            deviceModel: "Android Device",
            isPaired: true
        )
        connectToEndpoint(endpoint)
    }
}
