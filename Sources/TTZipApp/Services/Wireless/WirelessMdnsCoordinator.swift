// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Network
import Observation
import Darwin
import dnssd
import TTZipCore

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
    
    /// Converts this discovered wireless endpoint into an AndroidDevice domain model.
    public func asAndroidDevice() -> AndroidDevice {
        AndroidDevice(
            deviceId: "wifi:\(host):\(port)",
            displayName: "\(deviceModel) (\(host))",
            vendorId: 0,
            productId: 0,
            serialNumber: "WIFI_\(host)",
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
    }
}

/// Darwin dns_sd resolver resolving Bonjour instance name to IP address and port.
@MainActor
final class DarwinDnsSdResolver {
    private var serviceRef: DNSServiceRef?
    private var readSource: (any DispatchSourceRead)?
    private var contextPtr: UnsafeMutableRawPointer?
    
    final class ResolveContext {
        let completion: @Sendable @MainActor (String?, UInt16) -> Void
        init(completion: @escaping @Sendable @MainActor (String?, UInt16) -> Void) {
            self.completion = completion
        }
    }
    
    func resolve(
        name: String,
        type: String,
        domain: String,
        queue: DispatchQueue,
        completion: @escaping @Sendable @MainActor (String?, UInt16) -> Void
    ) {
        self.cancel() // Ensure strict cleanup of prior state
        
        var localRef: DNSServiceRef?
        let contextObj = ResolveContext(completion: completion)
        let contextPtr = Unmanaged.passRetained(contextObj).toOpaque()
        self.contextPtr = contextPtr
        
        let err = DNSServiceResolve(
            &localRef,
            0,
            0,
            name,
            type,
            domain,
            { (sdRef, flags, ifIndex, errCode, fullname, hosttarget, port, txtLen, txtRecord, context) in
                guard let context else { return }
                // Use takeUnretainedValue to avoid double-free inside callback.
                // The explicit memory ownership is bounded to DarwinDnsSdResolver lifecycle.
                let ctx = Unmanaged<ResolveContext>.fromOpaque(context).takeUnretainedValue()
                let handler = ctx.completion
                
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
                    Task { @MainActor in
                        handler(finalHost, resolvedPort)
                    }
                } else {
                    Task { @MainActor in
                        handler(nil, 0)
                    }
                }
            },
            contextPtr
        )
        
        guard err == 0, let localRef else {
            self.cancel()
            completion(nil, 0)
            return
        }
        
        self.serviceRef = localRef
        let fd = DNSServiceRefSockFD(localRef)
        guard fd >= 0 else {
            self.cancel()
            completion(nil, 0)
            return
        }
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            DNSServiceProcessResult(localRef)
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
        
        // Timeout safeguard after 5.0 seconds
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.serviceRef != nil else { return }
                completion(nil, 0)
                self.cancel()
            }
        }
        
        self.readSource = source
        source.resume()
    }
    
    func cancel() {
        if let source = readSource {
            source.cancel()
            readSource = nil
        }
        if let ref = serviceRef {
            DNSServiceRefDeallocate(ref)
            serviceRef = nil
        }
        if let ptr = contextPtr {
            Unmanaged<ResolveContext>.fromOpaque(ptr).release()
            contextPtr = nil
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
