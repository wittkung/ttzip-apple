// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation

// MARK: - Framing Channel for Process Pipes

/// Framed binary transport conforming to `WorkerChannel` 4-byte big-endian framing.
public final class WorkerPipeChannel: @unchecked Sendable {
    private let readHandle: FileHandle
    private let writeHandle: FileHandle
    private let readFD: Int32
    private let writeFD: Int32
    private let stateLock = NSLock()
    private let exchangeLock = NSLock()
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private var ioTimeoutStorage: TimeInterval
    private var isClosedState: Bool = false
    private var handlesClosed: Bool = false
    private var activeExchanges: Int = 0
    private var waitingExchanges: Int = 0
    private var isInReadPhaseState: Bool = false
    private var currentReadDeadlineOverrideNs: UInt64?
    private var onEnteredReadPhaseHandler: (@Sendable () -> Void)?
    private var onWaiterQueuedHandler: (@Sendable () -> Void)?

    public init(
        readHandle: FileHandle,
        writeHandle: FileHandle,
        ioTimeoutSeconds: TimeInterval = 5.0
    ) {
        self.readHandle = readHandle
        self.writeHandle = writeHandle
        self.readFD = readHandle.fileDescriptor
        self.writeFD = writeHandle.fileDescriptor
        self.ioTimeoutStorage = ioTimeoutSeconds
        Self.configureNonBlockingPipeDescriptor(self.readFD)
        Self.configureNonBlockingPipeDescriptor(self.writeFD)
    }

    public var ioTimeoutSeconds: TimeInterval {
        stateLock.withLock { ioTimeoutStorage }
    }

    public func updateIOTimeoutSeconds(_ seconds: TimeInterval) {
        stateLock.withLock {
            ioTimeoutStorage = seconds
            if isInReadPhaseState {
                let timeoutNs = UInt64(max(0.05, seconds) * 1_000_000_000)
                currentReadDeadlineOverrideNs = DispatchTime.now().uptimeNanoseconds + timeoutNs
            }
        }
    }

    internal var waitingExchangeCount: Int {
        stateLock.withLock { waitingExchanges }
    }

    internal var isExchangeInReadPhase: Bool {
        stateLock.withLock { isInReadPhaseState }
    }

    internal func setExchangeSynchronizationHooks(
        onEnteredReadPhase: (@Sendable () -> Void)? = nil,
        onWaiterQueued: (@Sendable () -> Void)? = nil
    ) {
        stateLock.withLock {
            self.onEnteredReadPhaseHandler = onEnteredReadPhase
            self.onWaiterQueuedHandler = onWaiterQueued
        }
    }

    private static func configureNonBlockingPipeDescriptor(_ fd: Int32) {
        guard fd >= 0 else { return }
        let flags = Darwin.fcntl(fd, F_GETFL)
        if flags >= 0, (flags & O_NONBLOCK) == 0 {
            _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var noSigPipe: Int32 = 1
        _ = Darwin.fcntl(fd, F_SETNOSIGPIPE, &noSigPipe)
    }

    public var isClosed: Bool {
        stateLock.withLock { isClosedState }
    }

    public func markClosed() {
        stateLock.withLock {
            isClosedState = true
        }
    }

    public func closeHandles() {
        let shouldClose = stateLock.withLock { () -> Bool in
            isClosedState = true
            guard !handlesClosed else { return false }
            handlesClosed = true
            return true
        }
        guard shouldClose else { return }
        try? readHandle.close()
        try? writeHandle.close()
    }

    private func makeDeadline() -> UInt64 {
        let timeoutNs = UInt64(max(0.05, ioTimeoutSeconds) * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds + timeoutNs
    }

    private func makeQueueDeadline() -> UInt64 {
        let timeoutSeconds = max(2.0, ioTimeoutSeconds * 6.0)
        let timeoutNs = UInt64(timeoutSeconds * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds + timeoutNs
    }

    private func acquireLockWithDeadline(_ targetLock: NSLock, deadline: UInt64) throws {
        while true {
            if stateLock.withLock({ isClosedState }) || Task.isCancelled {
                throw MediaWorkerError.connectionInvalidated
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                throw MediaWorkerError.timedOut
            }
            let sliceSeconds = min(0.01, Double(deadline - now) / 1_000_000_000.0)
            if targetLock.lock(before: Date(timeIntervalSinceNow: max(0.001, sliceSeconds))) {
                if stateLock.withLock({ isClosedState }) || Task.isCancelled {
                    targetLock.unlock()
                    throw MediaWorkerError.connectionInvalidated
                }
                return
            }
        }
    }

    private func acquireExchangeLock(deadline: UInt64) throws {
        if exchangeLock.try() {
            let invalid = stateLock.withLock { () -> Bool in
                if isClosedState || Task.isCancelled { return true }
                activeExchanges += 1
                return false
            }
            if invalid {
                exchangeLock.unlock()
                throw MediaWorkerError.connectionInvalidated
            }
            return
        }
        let queuedHook = stateLock.withLock { () -> (@Sendable () -> Void)? in
            waitingExchanges += 1
            return onWaiterQueuedHandler
        }
        queuedHook?()
        defer {
            stateLock.withLock {
                waitingExchanges = max(0, waitingExchanges - 1)
            }
        }
        try acquireLockWithDeadline(exchangeLock, deadline: deadline)
        stateLock.withLock {
            activeExchanges += 1
        }
    }

    /// Atomically serializes a complete request write + response read exchange so concurrent callers
    /// can never interleave frames or read another request's response.
    /// Marks the channel closed inside `exchangeLock` before unlocking on any failure so queued callers
    /// cannot enter a partially read/written or timed-out channel.
    public func exchangeFrame(_ data: Data) throws -> Data {
        try acquireExchangeLock(deadline: makeQueueDeadline())
        defer {
            stateLock.withLock {
                isInReadPhaseState = false
                currentReadDeadlineOverrideNs = nil
                activeExchanges = max(0, activeExchanges - 1)
            }
            exchangeLock.unlock()
        }

        do {
            let writeDeadline = makeDeadline()
            try writeFrameInternal(data, deadline: writeDeadline)
            let readPhaseHook = stateLock.withLock { () -> (@Sendable () -> Void)? in
                isInReadPhaseState = true
                currentReadDeadlineOverrideNs = nil
                return onEnteredReadPhaseHandler
            }
            readPhaseHook?()
            let readDeadline = makeDeadline()
            return try readFrameInternal(deadline: readDeadline)
        } catch {
            markClosed()
            throw error
        }
    }

    public func writeFrame(_ data: Data) throws {
        try writeFrameInternal(data, deadline: makeDeadline())
    }

    private func writeFrameInternal(_ data: Data, deadline: UInt64) throws {
        guard data.count <= MediaPacketDTO.maxPayloadSizeBytes else {
            throw MediaWorkerError.channelError("Payload exceeds maximum size limit")
        }
        try acquireLockWithDeadline(writeLock, deadline: deadline)
        defer { writeLock.unlock() }

        do {
            var lengthBE = UInt32(data.count).bigEndian
            var framed = Data(capacity: 4 + data.count)
            framed.append(Data(bytes: &lengthBE, count: 4))
            framed.append(data)
            try writeExact(framed, deadline: deadline)
        } catch {
            markClosed()
            throw error
        }
    }

    public func readFrame() throws -> Data {
        try readFrameInternal(deadline: makeDeadline())
    }

    private func readFrameInternal(deadline: UInt64) throws -> Data {
        try acquireLockWithDeadline(readLock, deadline: deadline)
        defer { readLock.unlock() }

        do {
            let header = try readExact(4, deadline: deadline)
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0 else { return Data() }
            guard length <= MediaPacketDTO.maxPayloadSizeBytes else {
                throw MediaWorkerError.channelError("Frame length \(length) exceeds bounds")
            }
            return try readExact(Int(length), deadline: deadline)
        } catch {
            markClosed()
            throw error
        }
    }

    private func writeExact(_ data: Data, deadline: UInt64) throws {
        var written = 0
        while written < data.count {
            if stateLock.withLock({ isClosedState }) || Task.isCancelled {
                throw MediaWorkerError.connectionInvalidated
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                throw MediaWorkerError.timedOut
            }
            let remainingMs = Int32(min(50, max(1, (deadline - now) / 1_000_000)))
            try pollAndWriteChunk(data: data, offset: &written, timeoutMs: remainingMs)
        }
    }

    private func pollAndWriteChunk(
        data: Data,
        offset: inout Int,
        timeoutMs: Int32
    ) throws {
        guard !stateLock.withLock({ isClosedState }), writeFD >= 0 else {
            throw MediaWorkerError.connectionInvalidated
        }
        var pfd = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
        let pollRes = Darwin.poll(&pfd, 1, timeoutMs)
        if pollRes < 0 {
            if Self.isRetryableErrno(errno) { return }
            throw MediaWorkerError.connectionInvalidated
        }
        if (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
            throw MediaWorkerError.connectionInvalidated
        }
        guard pollRes > 0, (pfd.revents & Int16(POLLOUT)) != 0 else { return }

        let remaining = data.count - offset
        let currentOffset = offset
        let bytesWritten = data.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return -1 }
            return Darwin.write(writeFD, base.advanced(by: currentOffset), remaining)
        }
        if bytesWritten > 0 {
            offset += bytesWritten
        } else if bytesWritten < 0 && Self.isRetryableErrno(errno) {
            return
        } else {
            throw MediaWorkerError.connectionInvalidated
        }
    }

    private func readExact(_ count: Int, deadline: UInt64) throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(count)

        while accumulated.count < count {
            let (closed, overrideDeadline) = stateLock.withLock {
                (isClosedState, currentReadDeadlineOverrideNs)
            }
            if closed || Task.isCancelled {
                throw MediaWorkerError.connectionInvalidated
            }
            let effectiveDeadline = overrideDeadline ?? deadline
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= effectiveDeadline {
                throw MediaWorkerError.timedOut
            }
            let remainingMs = Int32(min(50, max(1, (effectiveDeadline - now) / 1_000_000)))
            try pollAndReadChunk(
                remaining: count - accumulated.count,
                timeoutMs: remainingMs,
                into: &accumulated
            )
        }
        return accumulated
    }

    private static func isRetryableErrno(_ code: Int32) -> Bool {
        code == EINTR || code == EAGAIN
    }

    private func pollAndReadChunk(
        remaining: Int,
        timeoutMs: Int32,
        into accumulated: inout Data
    ) throws {
        guard !stateLock.withLock({ isClosedState }), readFD >= 0 else {
            throw MediaWorkerError.connectionInvalidated
        }
        var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
        let pollRes = Darwin.poll(&pfd, 1, timeoutMs)
        if pollRes < 0 {
            if Self.isRetryableErrno(errno) { return }
            throw MediaWorkerError.connectionInvalidated
        }
        guard pollRes > 0 else { return }
        if (pfd.revents & Int16(POLLNVAL | POLLERR)) != 0 && (pfd.revents & Int16(POLLIN)) == 0 {
            throw MediaWorkerError.connectionInvalidated
        }

        var chunk = Data(count: min(remaining, 65536))
        let bytesRead = chunk.withUnsafeMutableBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return -1 }
            return Darwin.read(readFD, base, rawBuf.count)
        }
        if bytesRead > 0 {
            accumulated.append(chunk.prefix(bytesRead))
        } else if bytesRead == 0 || !Self.isRetryableErrno(errno) {
            throw MediaWorkerError.connectionInvalidated
        }
    }
}

// MARK: - Process Transport Implementation

/// Child-process-backed transport communicating via framed stdin/stdout pipes.
public final class MediaWorkerProcessTransport: MediaWorkerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var channel: WorkerPipeChannel?
    private let executableURL: URL?
    private let arguments: [String]
    private var requestTimeoutStorage: TimeInterval
    private var isInvalidatedState: Bool = false
    private var hasOpenSession: Bool = false
    private var activeSessionId: String? = nil
    private var crashHandler: (@Sendable (MediaWorkerError) -> Void)?
    private var onEnteredReadPhaseHandler: (@Sendable () -> Void)?
    private var onWaiterQueuedHandler: (@Sendable () -> Void)?

    public init(
        executableURL: URL? = nil,
        arguments: [String] = [],
        requestTimeoutSeconds: TimeInterval = 5.0
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.requestTimeoutStorage = requestTimeoutSeconds
    }

    public init(channel: WorkerPipeChannel, requestTimeoutSeconds: TimeInterval = 5.0) {
        self.channel = channel
        self.executableURL = nil
        self.arguments = []
        self.requestTimeoutStorage = requestTimeoutSeconds
    }

    public var requestTimeoutSeconds: TimeInterval {
        lock.withLock { requestTimeoutStorage }
    }

    public func updateRequestTimeoutSeconds(_ seconds: TimeInterval) {
        let activeChannel = lock.withLock { () -> WorkerPipeChannel? in
            requestTimeoutStorage = seconds
            return channel
        }
        activeChannel?.updateIOTimeoutSeconds(seconds)
    }

    internal var waitingExchangeCount: Int {
        lock.withLock { channel }?.waitingExchangeCount ?? 0
    }

    internal var isExchangeInReadPhase: Bool {
        lock.withLock { channel }?.isExchangeInReadPhase ?? false
    }

    internal func setExchangeSynchronizationHooks(
        onEnteredReadPhase: (@Sendable () -> Void)? = nil,
        onWaiterQueued: (@Sendable () -> Void)? = nil
    ) {
        let activeChannel = lock.withLock { () -> WorkerPipeChannel? in
            self.onEnteredReadPhaseHandler = onEnteredReadPhase
            self.onWaiterQueuedHandler = onWaiterQueued
            return channel
        }
        activeChannel?.setExchangeSynchronizationHooks(
            onEnteredReadPhase: onEnteredReadPhase,
            onWaiterQueued: onWaiterQueued
        )
    }

    public var isConnected: Bool {
        lock.withLock { !isInvalidatedState && channel?.isClosed == false }
    }

    internal var runningProcessIdentifier: pid_t? {
        lock.withLock {
            guard let proc = process, proc.isRunning else { return nil }
            let pid = proc.processIdentifier
            guard pid > 0, Darwin.kill(pid, 0) == 0 else { return nil }
            return pid
        }
    }

    public func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {
        lock.withLock { self.crashHandler = handler }
    }

    private static func isProcessReapedOrGone(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        var status: Int32 = 0
        let waitRes = Darwin.waitpid(pid, &status, WNOHANG)
        if waitRes == pid {
            return true
        }
        if Darwin.kill(pid, 0) != 0 && errno == ESRCH {
            return true
        }
        return false
    }

    private static func terminateAndReapProcess(_ proc: Process?) {
        guard let proc else { return }
        let pid = proc.processIdentifier
        guard pid > 0 else { return }
        if !isProcessReapedOrGone(pid) {
            _ = Darwin.kill(pid, SIGTERM)
        }
        var waitedMs = 0
        while !isProcessReapedOrGone(pid) && waitedMs < 50 {
            usleep(5_000)
            waitedMs += 5
        }
        if !isProcessReapedOrGone(pid) {
            _ = Darwin.kill(pid, SIGKILL)
            var killWaitedMs = 0
            while !isProcessReapedOrGone(pid) && killWaitedMs < 200 {
                usleep(5_000)
                killWaitedMs += 5
            }
        }
    }

    private func handleProcessTermination(_ proc: Process?, terminated: Process) {
        lock.lock()
        guard process === proc else {
            lock.unlock()
            return
        }
        let ch = channel
        let isNormalIdleExit = terminated.terminationReason == .exit
            && terminated.terminationStatus == 0
            && !hasOpenSession
        channel = nil
        process = nil
        activeSessionId = nil
        ch?.markClosed()

        if isNormalIdleExit {
            isInvalidatedState = false
            lock.unlock()
            ch?.closeHandles()
            return
        }

        hasOpenSession = false
        isInvalidatedState = true
        let handler = crashHandler
        lock.unlock()
        ch?.closeHandles()
        handler?(MediaWorkerError.workerCrashed(code: terminated.terminationStatus, reason: "Terminated"))
    }

    private func ensureChannel() throws -> WorkerPipeChannel {
        lock.lock()
        defer { lock.unlock() }
        if isInvalidatedState {
            throw MediaWorkerError.connectionInvalidated
        }
        if let active = channel {
            if active.isClosed {
                throw MediaWorkerError.connectionInvalidated
            }
            return active
        }
        guard let exe = executableURL else {
            throw MediaWorkerError.processLaunchFailed("No executable URL provided")
        }

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = arguments
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.terminationHandler = { [weak self, weak proc] terminated in
            self?.handleProcessTermination(proc, terminated: terminated)
        }
        do {
            try proc.run()
        } catch {
            try? inPipe.fileHandleForReading.close()
            try? inPipe.fileHandleForWriting.close()
            try? outPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            throw MediaWorkerError.processLaunchFailed(error.localizedDescription)
        }

        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        let ch = WorkerPipeChannel(
            readHandle: outPipe.fileHandleForReading,
            writeHandle: inPipe.fileHandleForWriting,
            ioTimeoutSeconds: requestTimeoutStorage
        )
        ch.setExchangeSynchronizationHooks(
            onEnteredReadPhase: onEnteredReadPhaseHandler,
            onWaiterQueued: onWaiterQueuedHandler
        )
        self.process = proc
        self.channel = ch
        return ch
    }

    private func handleChannelFailure(_ error: Error, failedChannel: WorkerPipeChannel) {
        lock.lock()
        guard channel === failedChannel else {
            lock.unlock()
            return
        }
        isInvalidatedState = true
        hasOpenSession = false
        activeSessionId = nil
        let proc = process
        let ch = channel
        process = nil
        channel = nil
        proc?.terminationHandler = nil
        ch?.markClosed()
        let handler = crashHandler
        lock.unlock()

        Self.terminateAndReapProcess(proc)
        ch?.closeHandles()
        handler?((error as? MediaWorkerError) ?? .connectionInvalidated)
    }

    private func performIPCExchange(_ contract: TTMediaWorkerContract) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let ch = try ensureChannel()
            let payload = try JSONEncoder().encode(contract)
            do {
                return try ch.exchangeFrame(payload)
            } catch {
                handleChannelFailure(error, failedChannel: ch)
                throw error
            }
        } onCancel: {
            self.invalidate()
        }
    }

    private func verifyActiveSessionIfTracked(_ sessionId: String) throws {
        try lock.withLock {
            if isInvalidatedState {
                throw MediaWorkerError.connectionInvalidated
            }
            if let current = activeSessionId, current != sessionId {
                throw MediaWorkerError.sessionNotFound(sessionId)
            }
        }
    }

    private static let streamEnvelopeIndicatorKeys: Set<String> = [
        "format", "container_format", "formatName",
        "duration", "durationSeconds", "duration_seconds", "duration_nanos", "durationNanos",
        "videoTracks", "audioTracks", "subtitleTracks",
        "catalogVideoTracks", "catalogAudioTracks", "catalogSubtitleTracks",
        "tracks", "tracks_catalog", "selected_tracks",
        "containerMetadata", "schema_version", "schemaVersion", "metadataSchemaVersion"
    ]

    private static func extractStreamMetadataDictionary(from json: [String: Any]) -> [String: Any] {
        guard let nested = json["metadata"] as? [String: Any] else {
            return json
        }
        let topHasStreamFields = !streamEnvelopeIndicatorKeys.isDisjoint(with: json.keys)
        let nestedHasStreamFields = !streamEnvelopeIndicatorKeys.isDisjoint(with: nested.keys)
        if nestedHasStreamFields && !topHasStreamFields {
            return nested
        }
        if topHasStreamFields && !nestedHasStreamFields {
            return json
        }
        return nestedHasStreamFields ? nested : json
    }

    public func openMedia(
        path: String,
        targetTracks: [Int]?
    ) async throws -> (sessionId: String, metadata: [String: Any]) {
        let sid = UUID().uuidString
        let contract = TTMediaWorkerContract.open(sessionId: sid, filePath: path, targetTracks: targetTracks)
        let response = try await performIPCExchange(contract)
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw MediaWorkerError.invalidResponse("Invalid JSON from worker process")
        }
        if let err = json["error"] as? String {
            throw MediaWorkerError.openFailed(err)
        }
        let resolvedSid = (json["sessionId"] as? String) ?? sid
        let rawMeta = Self.extractStreamMetadataDictionary(from: json)
        let meta = MediaWorkerDirectTransport.normalizeTransportMetadataDictionary(rawMeta)
        lock.withLock {
            self.hasOpenSession = true
            self.activeSessionId = resolvedSid
        }
        return (resolvedSid, meta)
    }

    public func readNextPacket(sessionId: String) async throws -> Data? {
        try verifyActiveSessionIfTracked(sessionId)
        let response = try await performIPCExchange(.readPacket(sessionId: sessionId))
        try verifyActiveSessionIfTracked(sessionId)
        if response.isEmpty {
            return nil
        }
        if let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let err = json["error"] as? String {
            throw MediaWorkerError.readPacketFailed(err)
        }
        return response
    }

    public func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        try verifyActiveSessionIfTracked(sessionId)
        let contract = TTMediaWorkerContract.seek(
            sessionId: sessionId,
            targetTimestamp: timestamp,
            accurate: accurate
        )
        let response = try await performIPCExchange(contract)
        try verifyActiveSessionIfTracked(sessionId)
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            return timestamp
        }
        if let err = json["error"] as? String {
            throw MediaWorkerError.seekFailed(err)
        }
        return (json["targetTimestamp"] as? Double) ?? timestamp
    }

    public func closeMedia(sessionId: String) async throws {
        let shouldClose = lock.withLock { () -> Bool in
            if let current = self.activeSessionId, current != sessionId {
                return false
            }
            self.hasOpenSession = false
            self.activeSessionId = nil
            return true
        }
        guard shouldClose else { return }
        _ = try await performIPCExchange(.close(sessionId: sessionId))
    }

    public func setSleepState(state: Int) async throws {
        let contract = TTMediaWorkerContract(command: .sleepState, sessionId: UUID().uuidString)
        _ = try await performIPCExchange(contract)
    }

    private func detachAndTeardown(invalidateState: Bool) {
        lock.lock()
        isInvalidatedState = invalidateState
        hasOpenSession = false
        activeSessionId = nil
        let proc = process
        let ch = channel
        process = nil
        channel = nil
        proc?.terminationHandler = nil
        ch?.markClosed()
        lock.unlock()

        Self.terminateAndReapProcess(proc)
        ch?.closeHandles()
    }

    public func invalidate() {
        detachAndTeardown(invalidateState: true)
    }

    private func resetInternalProcess() {
        detachAndTeardown(invalidateState: false)
    }

    public func reconnect() async throws {
        resetInternalProcess()
        _ = try ensureChannel()
    }
}
