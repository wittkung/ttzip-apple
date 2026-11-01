// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import IOKit.ps
import TTZipCore

/// Progress and phase tracking for background VFS vector ingestion.
public struct VfsIngestProgress: Sendable, Equatable {
    public let indexedNodes: UInt32
    public let totalNodes: UInt32
    public let currentPhase: VfsIngestPhase

    public var fractionCompleted: Double {
        guard totalNodes > 0 else { return 0.0 }
        return Double(indexedNodes) / Double(totalNodes)
    }

    public init(indexedNodes: UInt32, totalNodes: UInt32, currentPhase: VfsIngestPhase) {
        self.indexedNodes = indexedNodes
        self.totalNodes = totalNodes
        self.currentPhase = currentPhase
    }
}

public enum VfsIngestPhase: Sendable, Equatable {
    case scanningCache
    case tier1PathOnly
    case tier2TextContent
}

public enum VfsIngestPauseReason: Sendable, Equatable {
    case thermalPressure(state: ProcessInfo.ThermalState)
    case lowPowerModeEnabled
    case onBatteryDisabled
    case userManual
}

public enum VfsIngestState: Sendable, Equatable {
    case idle
    case indexing(progress: VfsIngestProgress)
    case paused(reason: VfsIngestPauseReason)
    case ready(totalIndexed: UInt32, vectorCachePath: String)
    case failed(error: String)
}

/// Hardware power and thermal throttle monitor ensuring ingestion does not drain battery or overheat.
public final class IngestPowerThrottle: @unchecked Sendable {
    public var indexOnBattery: Bool
    private let onStateChange: @Sendable (VfsIngestPauseReason?) -> Void
    private var observers: [NSObjectProtocol] = []

    public init(
        indexOnBattery: Bool = false,
        onStateChange: @escaping @Sendable (VfsIngestPauseReason?) -> Void
    ) {
        self.indexOnBattery = indexOnBattery
        self.onStateChange = onStateChange
        setupMonitors()
    }

    public func currentBlocker() -> VfsIngestPauseReason? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled {
            return .lowPowerModeEnabled
        }
        switch info.thermalState {
        case .serious, .critical:
            return .thermalPressure(state: info.thermalState)
        default:
            break
        }
        if !indexOnBattery && !isOnACPower() {
            return .onBatteryDisabled
        }
        return nil
    }

    private func setupMonitors() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reevaluate() })

        observers.append(center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reevaluate() })
    }

    private func reevaluate() {
        let blocker = currentBlocker()
        onStateChange(blocker)
    }

    private func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }
        return type == kIOPMACPowerKey
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Actor orchestrating background vector indexing and sidecar cache persistence.
public actor VfsEmbeddingIngestService {
    private var currentState: VfsIngestState = .idle
    private var throttle: IngestPowerThrottle?
    private var activeTask: Task<Void, Never>?
    private let encoder: SemanticQueryEncoding

    public init(encoder: SemanticQueryEncoding = CoreMLSemanticQueryEncoder()) {
        self.encoder = encoder
    }

    public var state: VfsIngestState {
        currentState
    }

    /// Attaches an existing .ttvec cache or initiates background ingestion.
    public func startIngestion(
        for session: VfsSession,
        archivePath: String,
        totalNodes: UInt32,
        entryPaths: [UInt32: String] = [:]
    ) async {
        guard totalNodes > 1 else { return }

        // 1. Check local sidecar cache
        let cachePath = sidecarPath(for: archivePath)
        if (try? session.attachVectorSidecar(sidecarPath: cachePath)) == true {
            currentState = .ready(totalIndexed: totalNodes, vectorCachePath: cachePath)
            return
        }

        // 2. Set up power throttling
        throttle = IngestPowerThrottle(indexOnBattery: false) { [weak self] blocker in
            guard let self = self else { return }
            Task {
                await self.handlePowerBlockerChange(blocker)
            }
        }

        if let blocker = throttle?.currentBlocker() {
            currentState = .paused(reason: blocker)
            return
        }

        // 3. Launch background indexing worker
        activeTask?.cancel()
        activeTask = Task.detached(priority: .utility) { [weak self, encoder] in
            await self?.runTier1Indexing(
                session: session,
                cachePath: cachePath,
                totalNodes: totalNodes,
                entryPaths: entryPaths,
                encoder: encoder
            )
        }
    }

    public func pauseIngestion(reason: VfsIngestPauseReason = .userManual) {
        activeTask?.cancel()
        activeTask = nil
        currentState = .paused(reason: reason)
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        currentState = .idle
    }

    private func handlePowerBlockerChange(_ blocker: VfsIngestPauseReason?) {
        if let blocker = blocker {
            pauseIngestion(reason: blocker)
        }
    }

    private func runTier1Indexing(
        session: VfsSession,
        cachePath: String,
        totalNodes: UInt32,
        entryPaths: [UInt32: String],
        encoder: SemanticQueryEncoding
    ) async {
        let batchSize: UInt32 = 64
        var currentIndex: UInt32 = 1
        var allIngestedVectors: [Int8] = []
        allIngestedVectors.reserveCapacity(Int(totalNodes) * 128)

        while currentIndex < totalNodes {
            if Task.isCancelled { return }

            let count = min(batchSize, totalNodes - currentIndex)
            var batchVectors: [Int8] = []
            batchVectors.reserveCapacity(Int(count) * 128)

            for i in 0..<count {
                let nodeId = currentIndex + i
                guard let realPath = entryPaths[nodeId],
                      !realPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    updateState(.failed(error: "Missing real entry path for node \(nodeId); refusing placeholder ingestion"))
                    return
                }
                let pathPrompt = SemanticPromptFormatter.formatDocumentPrompt(relativePath: nil, text: realPath)
                do {
                    let vec = try await encoder.encode(query: pathPrompt)
                    guard vec.count == 128, vec.contains(where: { $0 != 0 }) else {
                        updateState(.failed(error: "Rejected zero or invalid 128-D vector for \(realPath)"))
                        return
                    }
                    batchVectors.append(contentsOf: vec)
                } catch {
                    updateState(.failed(error: "Semantic encoding unavailable (\(error.localizedDescription)); lexical search remains active"))
                    return
                }
            }

            let batch = VfsVectorIngestBatch(
                startNodeId: currentIndex,
                flattenedVectors: batchVectors,
                count: count
            )

            _ = try? session.ingestVectorBatch(batch: batch)
            allIngestedVectors.append(contentsOf: batchVectors)
            currentIndex += count

            let progress = VfsIngestProgress(
                indexedNodes: currentIndex,
                totalNodes: totalNodes,
                currentPhase: .tier1PathOnly
            )
            updateState(.indexing(progress: progress))

            // Cooperative yield between batches to keep CPU cool
            await Task.yield()
        }

        // Persist validated .ttvec v2 sidecar cache file
        if persistSidecarV2(vectors: allIngestedVectors, to: cachePath, totalNodes: totalNodes - 1) {
            updateState(.ready(totalIndexed: totalNodes - 1, vectorCachePath: cachePath))
        } else {
            updateState(.failed(error: "Failed to persist validated .ttvec v2 sidecar"))
        }
    }

    private func updateState(_ newState: VfsIngestState) {
        currentState = newState
    }

    private func sidecarPath(for archivePath: String) -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("com.metastudyline.ttzip/vectors")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = String(archivePath.hashValue)
        return dir.appendingPathComponent("\(hash).ttvec").path
    }

    private func persistSidecarV2(vectors: [Int8], to path: String, totalNodes: UInt32) -> Bool {
        guard vectors.count == Int(totalNodes) * 128,
              vectors.contains(where: { $0 != 0 })
        else {
            return false
        }
        var header = Data(count: 96)
        header.replaceSubrange(
            0..<8,
            with: withUnsafeBytes(of: PinnedSemanticModelConstants.ttEmbeddingMagic.littleEndian) { Data($0) }
        )
        header.replaceSubrange(
            8..<12,
            with: withUnsafeBytes(of: PinnedSemanticModelConstants.ttEmbeddingSchemaVersion2.littleEndian) { Data($0) }
        )
        header.replaceSubrange(12..<14, with: withUnsafeBytes(of: UInt16(128).littleEndian) { Data($0) })
        header[14] = 1
        header[15] = 0b0000_0111
        header.replaceSubrange(
            16..<24,
            with: withUnsafeBytes(of: PinnedSemanticModelConstants.modelFingerprint.littleEndian) { Data($0) }
        )
        header.replaceSubrange(56..<60, with: withUnsafeBytes(of: totalNodes.littleEndian) { Data($0) })
        header.replaceSubrange(60..<64, with: withUnsafeBytes(of: totalNodes.littleEndian) { Data($0) })

        var outData = Data(capacity: 96 + vectors.count)
        outData.append(header)
        for b in vectors {
            outData.append(UInt8(bitPattern: b))
        }
        do {
            try outData.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
