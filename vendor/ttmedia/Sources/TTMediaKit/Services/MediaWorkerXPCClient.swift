// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Foundation
#if canImport(TTMediaDemux)
import TTMediaDemux
#endif

// MARK: - Error Hierarchy

/// Typed errors produced during media worker IPC and lifecycle management.
public enum MediaWorkerError: Error, LocalizedError, Sendable, Equatable {
    case connectionInvalidated
    case connectionInterrupted
    case workerCrashed(code: Int32, reason: String)
    case serviceUnavailable(String)
    case openFailed(String)
    case readPacketFailed(String)
    case seekFailed(String)
    case closeFailed(String)
    case invalidResponse(String)
    case processLaunchFailed(String)
    case channelError(String)
    case timedOut
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .connectionInvalidated:
            return "Media worker XPC connection was invalidated"
        case .connectionInterrupted:
            return "Media worker XPC connection was interrupted"
        case let .workerCrashed(c, r):
            return "Media worker crashed (code: \(c), reason: \(r))"
        case let .serviceUnavailable(m):
            return "Media worker service unavailable: \(m)"
        case let .openFailed(m):
            return "Failed to open media: \(m)"
        case let .readPacketFailed(m):
            return "Failed to read packet: \(m)"
        case let .seekFailed(m):
            return "Failed to seek: \(m)"
        case let .closeFailed(m):
            return "Failed to close media: \(m)"
        case let .invalidResponse(m):
            return "Invalid worker response: \(m)"
        case let .processLaunchFailed(m):
            return "Failed to launch worker process: \(m)"
        case let .channelError(m):
            return "Worker channel error: \(m)"
        case .timedOut:
            return "Media worker request timed out"
        case let .sessionNotFound(s):
            return "Session not found: \(s)"
        }
    }
}

// MARK: - Lifecycle States

/// Dynamic lifecycle states of the media worker supervisor.
public enum TTMediaWorkerLifecycleState: String, Sendable, Codable, Equatable {
    case idle = "idle"
    case activePlayback = "active_playback"
    case warmStandby = "warm_standby"
    case coldHibernation = "cold_hibernation"
    case crashed = "crashed"
}

// MARK: - Transport Abstraction

/// Bidirectional message transport interface decoupling communication implementation from client logic.
public protocol MediaWorkerTransport: Sendable {
    func openMedia(path: String, targetTracks: [Int]?) async throws -> (sessionId: String, metadata: [String: Any])
    func readNextPacket(sessionId: String) async throws -> Data?
    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double
    func closeMedia(sessionId: String) async throws
    func setSleepState(state: Int) async throws
    func invalidate()
    func reconnect() async throws
    func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?)
    var isConnected: Bool { get }
}

// MARK: - XPC Transport Implementation

/// NSXPCConnection-backed transport implementation.
public final class MediaWorkerXPCTransport: MediaWorkerTransport, MediaSubtitleTransport, @unchecked Sendable {
    private static let maxCancelledClientRequests = 512

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let serviceName: String?
    private let machServiceName: String?
    private let endpoint: NSXPCListenerEndpoint?
    private let useFileHandleCapability: Bool
    private var isInvalidatedState: Bool = false
    private var crashHandler: (@Sendable (MediaWorkerError) -> Void)?
    private var cancelledClientRequests: Set<UInt64> = []
    private var cancelledClientRequestOrder: [UInt64] = []
    private var sessionClientRequests: [String: Set<UInt64>] = [:]

    public init(serviceName: String = "com.metastudyline.ttzip.media-worker") {
        self.serviceName = serviceName
        self.machServiceName = nil
        self.endpoint = nil
        self.useFileHandleCapability = true
    }

    public init(machServiceName: String) {
        self.machServiceName = machServiceName
        self.serviceName = nil
        self.endpoint = nil
        self.useFileHandleCapability = false
    }

    public init(endpoint: NSXPCListenerEndpoint, useFileHandleCapability: Bool = false) {
        self.machServiceName = nil
        self.serviceName = nil
        self.endpoint = endpoint
        self.useFileHandleCapability = useFileHandleCapability
    }

    public var isConnected: Bool {
        lock.withLock { connection != nil && !isInvalidatedState }
    }

    public func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {
        lock.withLock { self.crashHandler = handler }
    }

    private func makeRawConnection() throws -> NSXPCConnection {
        if let ep = endpoint {
            return NSXPCConnection(listenerEndpoint: ep)
        }
        if let svc = serviceName {
            return NSXPCConnection(serviceName: svc)
        }
        if let service = machServiceName {
            return NSXPCConnection(machServiceName: service, options: [])
        }
        throw MediaWorkerError.serviceUnavailable("No valid XPC endpoint, bundle service, or Mach service")
    }

    private func handleConnectionEvent(_ conn: NSXPCConnection?, invalidate: Bool, error: MediaWorkerError) {
        lock.lock()
        guard connection === conn else {
            lock.unlock()
            return
        }
        if invalidate {
            isInvalidatedState = true
            connection = nil
        }
        let handler = crashHandler
        lock.unlock()
        handler?(error)
    }

    private func obtainConnection() throws -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if isInvalidatedState {
            throw MediaWorkerError.connectionInvalidated
        }
        if let existing = connection {
            return existing
        }

        let conn = try makeRawConnection()
        conn.remoteObjectInterface = NSXPCInterface.makeMediaWorkerInterface()
        conn.invalidationHandler = { [weak self, weak conn] in
            self?.handleConnectionEvent(conn, invalidate: true, error: .connectionInvalidated)
        }
        conn.interruptionHandler = { [weak self, weak conn] in
            self?.handleConnectionEvent(conn, invalidate: false, error: .connectionInterrupted)
        }
        conn.resume()
        self.connection = conn
        return conn
    }

    private func executeWithProxy<T: Sendable>(
        _ block: @escaping (TTMediaWorkerProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let conn = try obtainConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = conn.remoteObjectProxyWithErrorHandler { err in
                continuation.resume(throwing: MediaWorkerError.serviceUnavailable(err.localizedDescription))
            } as? TTMediaWorkerProtocol
            guard let proxy else {
                continuation.resume(throwing: MediaWorkerError.serviceUnavailable("Proxy unavailable"))
                return
            }
            block(proxy) { res in
                continuation.resume(with: res)
            }
        }
    }

    private struct MediaOpenBox: @unchecked Sendable {
        let sessionId: String
        let metadata: [String: Any]
    }

    public func openMedia(
        path: String,
        targetTracks: [Int]?
    ) async throws -> (sessionId: String, metadata: [String: Any]) {
        let numbers = targetTracks?.map { NSNumber(value: $0) }
        let box: MediaOpenBox = try await executeWithProxy { proxy, reply in
            let resultHandler: @Sendable (Bool, String?, [String: Any]?) -> Void = { success, idOrError, dict in
                if success {
                    let resolvedId = idOrError ?? UUID().uuidString
                    reply(.success(MediaOpenBox(sessionId: resolvedId, metadata: dict ?? [:])))
                } else {
                    reply(.failure(MediaWorkerError.openFailed(idOrError ?? "Open failed")))
                }
            }
            if self.useFileHandleCapability {
                guard let openFile = proxy.openFileMedia else {
                    reply(.failure(MediaWorkerError.openFailed("Bundled service does not support read-only file handles")))
                    return
                }
                do {
                    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    openFile(file, numbers) { success, identifier, metadata in
                        defer { try? file.close() }
                        resultHandler(success, identifier, metadata)
                    }
                } catch {
                    reply(.failure(MediaWorkerError.openFailed(error.localizedDescription)))
                }
            } else {
                proxy.openMedia(at: path, targetTracks: numbers, reply: resultHandler)
            }
        }
        return (box.sessionId, box.metadata)
    }

    public func readNextPacket(sessionId: String) async throws -> Data? {
        try await executeWithProxy { proxy, reply in
            proxy.readNextPacket(forSession: sessionId) { data, error in
                if let error {
                    reply(.failure(MediaWorkerError.readPacketFailed(error)))
                } else {
                    reply(.success(data))
                }
            }
        }
    }

    public func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        try await executeWithProxy { proxy, reply in
            proxy.seek(to: timestamp, sessionId: sessionId, accurate: accurate) { success, landed, error in
                if success {
                    reply(.success(landed))
                } else {
                    reply(.failure(MediaWorkerError.seekFailed(error ?? "Seek failed")))
                }
            }
        }
    }

    public func subtitleData(sessionId: String, track: Int64) async throws -> Data {
        let requestID = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sessionId)
        return try await subtitleData(sessionId: sessionId, track: track, requestID: requestID)
    }

    public func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data {
        let preCancelled = lock.withLock { () -> Bool in
            if requestID != 0 {
                sessionClientRequests[sessionId, default: []].insert(requestID)
                if cancelledClientRequests.contains(requestID) {
                    return true
                }
            }
            return false
        }
        defer {
            reclaimClientRequest(sessionId: sessionId, requestID: requestID)
        }
        if preCancelled {
            await cancelSubtitleRequest(sessionId: sessionId, requestID: requestID)
            throw CancellationError()
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await executeWithProxy { proxy, completion in
                let replyHandler: @Sendable (Data?, String?) -> Void = { data, error in
                    if let data {
                        completion(.success(data))
                    } else {
                        completion(.failure(MediaWorkerError.readPacketFailed(error ?? "Subtitle request failed")))
                    }
                }
                if requestID != 0, let requestWithID = proxy.subtitles(forSession:track:requestID:reply:) {
                    requestWithID(sessionId, track, requestID, replyHandler)
                } else if let request = proxy.subtitles(forSession:track:reply:) {
                    request(sessionId, track, replyHandler)
                } else {
                    completion(.failure(MediaWorkerError.serviceUnavailable("Subtitle service unavailable")))
                }
            }
        } onCancel: { [weak self] in
            guard let self, requestID != 0 else { return }
            self.markClientRequestCancelled(sessionId: sessionId, requestID: requestID)
            Task {
                await self.cancelSubtitleRequest(sessionId: sessionId, requestID: requestID)
            }
        }
    }

    internal func markClientRequestCancelled(sessionId: String, requestID: UInt64) {
        guard requestID != 0 else { return }
        lock.withLock {
            insertCancelledClientRequestLocked(requestID)
            sessionClientRequests[sessionId, default: []].insert(requestID)
        }
    }

    private func insertCancelledClientRequestLocked(_ requestID: UInt64) {
        if cancelledClientRequests.insert(requestID).inserted {
            cancelledClientRequestOrder.append(requestID)
            while cancelledClientRequestOrder.count > Self.maxCancelledClientRequests {
                let evicted = cancelledClientRequestOrder.removeFirst()
                cancelledClientRequests.remove(evicted)
            }
        }
    }

    private func reclaimClientRequest(sessionId: String, requestID: UInt64) {
        guard requestID != 0 else { return }
        lock.withLock {
            if cancelledClientRequests.remove(requestID) != nil {
                cancelledClientRequestOrder.removeAll { $0 == requestID }
            }
            if var set = sessionClientRequests[sessionId] {
                set.remove(requestID)
                if set.isEmpty {
                    sessionClientRequests.removeValue(forKey: sessionId)
                } else {
                    sessionClientRequests[sessionId] = set
                }
            }
        }
    }

    public func cancelSubtitleRequest(sessionId: String, requestID: UInt64) async {
        guard requestID != 0 else { return }
        markClientRequestCancelled(sessionId: sessionId, requestID: requestID)
        _ = try? await executeWithProxy { proxy, completion in
            guard let cancel = proxy.cancelSubtitle(forSession:requestID:reply:) else {
                completion(.success(()))
                return
            }
            cancel(sessionId, requestID) { _ in
                completion(.success(()))
            }
        }
    }

    public func configureSubtitleRequestDelay(requestID: UInt64, delayMs: UInt32) async throws -> Bool {
        try await executeWithProxy { proxy, completion in
            guard let configure = proxy.configureSubtitleRequestDelay(forRequestID:delayMs:reply:) else {
                completion(.failure(MediaWorkerError.serviceUnavailable("Subtitle request delay config unavailable")))
                return
            }
            configure(requestID, delayMs) { ok in
                completion(.success(ok))
            }
        }
    }

    public func subtitleRequestStatus(
        sessionId: String,
        requestID: UInt64
    ) async throws -> (workerPid: Int32, clustersScanned: UInt64, isCancelled: Bool) {
        try await executeWithProxy { proxy, completion in
            guard let query = proxy.subtitleRequestStatus(forSession:requestID:reply:) else {
                completion(.failure(MediaWorkerError.serviceUnavailable("Subtitle request status unavailable")))
                return
            }
            query(sessionId, requestID) { pid, clusters, cancelled in
                completion(.success((pid, clusters, cancelled)))
            }
        }
    }

    public func cancelAllSubtitleRequests(sessionId: String) async {
        let requestIDs = lock.withLock { () -> Set<UInt64> in
            let ids = sessionClientRequests.removeValue(forKey: sessionId) ?? []
            for id in ids where id != 0 {
                insertCancelledClientRequestLocked(id)
            }
            return ids
        }
        for requestID in requestIDs where requestID != 0 {
            await cancelSubtitleRequest(sessionId: sessionId, requestID: requestID)
        }
    }

    public func closeMedia(sessionId: String) async throws {
        await cancelAllSubtitleRequests(sessionId: sessionId)
        lock.withLock {
            _ = sessionClientRequests.removeValue(forKey: sessionId)
        }
        try await executeWithProxy { proxy, reply in
            proxy.closeMedia(forSession: sessionId) { success, error in
                if success {
                    reply(.success(()))
                } else {
                    reply(.failure(MediaWorkerError.closeFailed(error ?? "Close failed")))
                }
            }
        }
    }

    public func setSleepState(state: Int) async throws {
        try await executeWithProxy { proxy, reply in
            proxy.setSleepState(state: state) { _ in
                reply(.success(()))
            }
        }
    }

    private func detachConnection(invalidateState: Bool) -> NSXPCConnection? {
        lock.lock()
        defer { lock.unlock() }
        isInvalidatedState = invalidateState
        let conn = connection
        connection = nil
        conn?.invalidationHandler = nil
        conn?.interruptionHandler = nil
        return conn
    }

    public func invalidate() {
        detachConnection(invalidateState: true)?.invalidate()
    }

    public func reconnect() async throws {
        detachConnection(invalidateState: false)?.invalidate()
        _ = try obtainConnection()
    }
}

// MARK: - Host XPC Client

/// Primary client coordinator communicating with `ttmedia-worker` across XPC or framed pipes.
public final class MediaWorkerXPCClient: @unchecked Sendable {
    private let stateLock = NSLock()
    private let transport: any MediaWorkerTransport
    private var internalCrashCount: Int = 0
    private var internalLastKnownTimestamp: Double = 0.0
    private var internalLifecycleState: TTMediaWorkerLifecycleState = .idle
    private var internalSleepState: TTMediaSleepState = .activePlayback
    private var internalActiveSessionId: String? = nil
    private var internalCurrentURL: URL? = nil
    private var internalOpenGeneration: UInt64 = 0

    public var onCrash: (@Sendable (MediaWorkerError) -> Void)?
    public var onInvalidation: (@Sendable () -> Void)?

    public init(transport: any MediaWorkerTransport) {
        self.transport = transport
        bindCrashHandler()
    }

    public static func makeDefault() -> MediaWorkerXPCClient {
        if Bundle.main.bundleURL.pathExtension == "app" {
            let serviceName = (Bundle.main.bundleIdentifier ?? "com.metastudyline.ttzip") + ".media-worker"
            return MediaWorkerXPCClient(transport: MediaWorkerXPCTransport(serviceName: serviceName))
        }
        // CLI/test hosts have no containing application service bundle.
        return MediaWorkerXPCClient(transport: MediaWorkerDirectTransport())
    }

    public convenience init(machServiceName: String = "com.metastudyline.ttmedia-worker") {
        self.init(transport: MediaWorkerXPCTransport(machServiceName: machServiceName))
    }

    public convenience init(endpoint: NSXPCListenerEndpoint) {
        self.init(transport: MediaWorkerXPCTransport(endpoint: endpoint))
    }

    public convenience init(
        executableURL: URL,
        arguments: [String] = [],
        requestTimeoutSeconds: TimeInterval = 5.0
    ) {
        self.init(
            transport: MediaWorkerProcessTransport(
                executableURL: executableURL,
                arguments: arguments,
                requestTimeoutSeconds: requestTimeoutSeconds
            )
        )
    }

    private func bindCrashHandler() {
        transport.setCrashHandler { [weak self] error in
            self?.recordCrash(error: error)
        }
    }

    // MARK: - Synchronous State Accessors

    public var crashCount: Int { stateLock.withLock { internalCrashCount } }
    public var lastKnownTimestamp: Double { stateLock.withLock { internalLastKnownTimestamp } }
    public var lifecycleState: TTMediaWorkerLifecycleState { stateLock.withLock { internalLifecycleState } }
    public var currentSleepState: TTMediaSleepState { stateLock.withLock { internalSleepState } }
    public var activeSessionId: String? { stateLock.withLock { internalActiveSessionId } }
    public var currentURL: URL? { stateLock.withLock { internalCurrentURL } }

    private func beginOpenGeneration() throws -> UInt64 {
        try stateLock.withLock {
            if internalLifecycleState == .crashed {
                throw MediaWorkerError.connectionInvalidated
            }
            internalOpenGeneration &+= 1
            return internalOpenGeneration
        }
    }

    private func commitActiveSessionIfCurrent(
        sessionId: String,
        url: URL,
        generation: UInt64
    ) -> Bool {
        stateLock.withLock {
            guard internalLifecycleState != .crashed,
                  internalOpenGeneration == generation else {
                return false
            }
            self.internalActiveSessionId = sessionId
            self.internalCurrentURL = url
            self.internalLastKnownTimestamp = 0.0
            self.internalLifecycleState = .activePlayback
            return true
        }
    }

    private func verifyActiveSession(_ sessionId: String) throws {
        try stateLock.withLock {
            if internalLifecycleState == .crashed {
                throw MediaWorkerError.connectionInvalidated
            }
            guard let active = internalActiveSessionId, active == sessionId else {
                throw MediaWorkerError.sessionNotFound(sessionId)
            }
        }
    }

    private func recordTimestampIfActive(seconds: Double, sessionId: String) throws {
        try stateLock.withLock {
            if internalLifecycleState == .crashed {
                throw MediaWorkerError.connectionInvalidated
            }
            guard internalActiveSessionId == sessionId else {
                throw MediaWorkerError.sessionNotFound(sessionId)
            }
            self.internalLastKnownTimestamp = seconds
        }
    }

    private func clearSessionOnClose(sessionId: String) {
        stateLock.withLock {
            guard self.internalActiveSessionId == sessionId else { return }
            self.internalActiveSessionId = nil
            if self.internalLifecycleState != .crashed {
                self.internalLifecycleState = .warmStandby
            }
        }
    }

    private func applySleepState(_ state: TTMediaSleepState) {
        stateLock.withLock {
            self.internalSleepState = state
            if state == .coldHibernation {
                self.internalLifecycleState = .coldHibernation
            } else if state == .warmStandby {
                self.internalLifecycleState = .warmStandby
            }
        }
    }

    private func resetLifecycleOnReconnect() {
        stateLock.withLock {
            self.internalLifecycleState = .idle
        }
    }

    private func retrieveResumeParameters() -> (url: URL?, timestamp: Double) {
        stateLock.withLock {
            (self.internalCurrentURL, self.internalLastKnownTimestamp)
        }
    }

    private func verifyOperational() throws {
        try stateLock.withLock {
            if internalLifecycleState == .crashed {
                throw MediaWorkerError.connectionInvalidated
            }
        }
    }

    // MARK: - Core Client Operations

    public func open(url: URL, targetTracks: [Int]? = nil) async throws -> StreamMetadata {
        let generation = try beginOpenGeneration()
        let result = try await transport.openMedia(path: url.path, targetTracks: targetTracks)
        guard commitActiveSessionIfCurrent(
            sessionId: result.sessionId,
            url: url,
            generation: generation
        ) else {
            try? await transport.closeMedia(sessionId: result.sessionId)
            throw MediaWorkerError.sessionNotFound(result.sessionId)
        }
        return StreamMetadata(sessionId: result.sessionId, dictionary: result.metadata)
    }

    public func readNextPacket(sessionId: String) async throws -> MediaPacketDTO? {
        try verifyActiveSession(sessionId)
        guard let data = try await transport.readNextPacket(sessionId: sessionId) else {
            try verifyActiveSession(sessionId)
            return nil
        }
        let packet = try parsePacket(from: data)
        if let pkt = packet, pkt.ptsTimescale > 0 {
            try recordTimestampIfActive(
                seconds: Double(pkt.ptsValue) / Double(pkt.ptsTimescale),
                sessionId: sessionId
            )
        } else {
            try verifyActiveSession(sessionId)
        }
        return packet
    }

    private func parsePacket(from data: Data) throws -> MediaPacketDTO? {
        if data.isEmpty {
            return nil
        }
        if let direct = try? JSONDecoder().decode(MediaPacketDTO.self, from: data) {
            return direct
        }
        if let contract = try? JSONDecoder().decode(TTMediaWorkerContract.self, from: data),
           let resp = contract.packetResponse {
            return try MediaPacketDTO(packetResponse: resp, payloadData: Data())
        }
        if let plist = try? PropertyListDecoder().decode(MediaPacketDTO.self, from: data) {
            return plist
        }
        throw MediaWorkerError.invalidResponse("Could not decode MediaPacketDTO")
    }

    public func seek(to seconds: Double, sessionId: String, accurate: Bool = true) async throws -> Double {
        try verifyActiveSession(sessionId)
        let landed = try await transport.seek(to: seconds, sessionId: sessionId, accurate: accurate)
        try recordTimestampIfActive(seconds: landed, sessionId: sessionId)
        return landed
    }

    public func subtitleData(track: Int64) async throws -> Data {
        guard let transport = transport as? any MediaSubtitleTransport,
              let session = stateLock.withLock({ internalActiveSessionId }) else {
            throw MediaWorkerError.serviceUnavailable("Embedded subtitles unavailable")
        }
        return try await transport.subtitleData(sessionId: session, track: track)
    }

    public func subtitleData(track: Int64, requestID: UInt64) async throws -> Data {
        guard let transport = transport as? any MediaSubtitleTransport,
              let session = stateLock.withLock({ internalActiveSessionId }) else {
            throw MediaWorkerError.serviceUnavailable("Embedded subtitles unavailable")
        }
        return try await transport.subtitleData(sessionId: session, track: track, requestID: requestID)
    }

    public func cancelSubtitleRequest(_ requestID: UInt64) {
        guard requestID != 0,
              let session = stateLock.withLock({ internalActiveSessionId }) else { return }
        if let xpcTransport = transport as? MediaWorkerXPCTransport {
            xpcTransport.markClientRequestCancelled(sessionId: session, requestID: requestID)
            Task {
                await xpcTransport.cancelSubtitleRequest(sessionId: session, requestID: requestID)
            }
        } else if let subtitleTransport = transport as? any MediaSubtitleTransport {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: session, requestID: requestID)
            Task {
                await subtitleTransport.cancelSubtitleRequest(sessionId: session, requestID: requestID)
            }
        } else {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: session, requestID: requestID)
        }
    }

    public func configureSubtitleRequestDelay(requestID: UInt64, delayMs: UInt32) async throws -> Bool {
        if let xpcTransport = transport as? MediaWorkerXPCTransport {
            return try await xpcTransport.configureSubtitleRequestDelay(requestID: requestID, delayMs: delayMs)
        }
        ttmedia_subtitles_set_request_cluster_delay_ms(requestID, delayMs)
        return true
    }

    public func subtitleRequestStatus(
        requestID: UInt64
    ) async throws -> (workerPid: Int32, clustersScanned: UInt64, isCancelled: Bool) {
        guard let session = stateLock.withLock({ internalActiveSessionId }) else {
            throw MediaWorkerError.serviceUnavailable("No active session")
        }
        if let xpcTransport = transport as? MediaWorkerXPCTransport {
            return try await xpcTransport.subtitleRequestStatus(sessionId: session, requestID: requestID)
        }
        let clusters = requestID != 0 ? ttmedia_subtitles_last_scanned_clusters(requestID) : 0
        let cancelled = SubtitleSessionRequestRegistry.shared.isCancelled(sessionId: session, requestID: requestID)
        return (getpid(), clusters, cancelled)
    }

    internal func cancelAllSubtitleRequestsForActiveSession() {
        guard let session = stateLock.withLock({ internalActiveSessionId }) else { return }
        if let xpcTransport = transport as? MediaWorkerXPCTransport {
            Task {
                await xpcTransport.cancelAllSubtitleRequests(sessionId: session)
            }
        } else if let subtitleTransport = transport as? any MediaSubtitleTransport {
            SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: session)
            Task {
                await subtitleTransport.cancelAllSubtitleRequests(sessionId: session)
            }
        } else {
            SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: session)
        }
    }

    public func close(sessionId: String) async throws {
        try verifyOperational()
        let isCurrentSession = stateLock.withLock { self.internalActiveSessionId == sessionId }
        guard isCurrentSession else { return }
        try await transport.closeMedia(sessionId: sessionId)
        clearSessionOnClose(sessionId: sessionId)
    }

    public func setSleepState(_ state: TTMediaSleepState) {
        applySleepState(state)
        Task { [weak self] in
            try? await self?.transport.setSleepState(state: state.rawValue)
        }
    }

    @discardableResult
    public func setSleepStateAsync(_ state: TTMediaSleepState) async throws -> Bool {
        applySleepState(state)
        try await transport.setSleepState(state: state.rawValue)
        return true
    }

    // MARK: - Resilience & Recovery

    public func recordCrash(error: MediaWorkerError) {
        stateLock.withLock {
            self.internalCrashCount += 1
            self.internalLifecycleState = .crashed
        }
        onCrash?(error)
        if error == .connectionInvalidated {
            onInvalidation?()
        }
    }

    public func simulateInvalidation() {
        recordCrash(error: .connectionInvalidated)
        transport.invalidate()
    }

    public func reconnect() async throws {
        resetLifecycleOnReconnect()
        try await transport.reconnect()
    }

    public func resume() async throws -> StreamMetadata? {
        let (savedURL, savedTimestamp) = retrieveResumeParameters()
        guard let url = savedURL else { return nil }
        try await reconnect()
        let metadata = try await open(url: url)
        if savedTimestamp > 0 {
            _ = try await seek(to: savedTimestamp, sessionId: metadata.sessionId, accurate: true)
        }
        return metadata
    }
}
