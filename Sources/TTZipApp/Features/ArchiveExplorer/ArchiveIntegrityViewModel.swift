// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

public enum ArchiveRepairError: Error, LocalizedError, Sendable, Equatable {
    case outputMatchesSource
    case sourceNotFound(path: String)
    case overwriteConfirmationRequired(existingOutputPath: String)
    case overwriteDisallowed(existingOutputPath: String)
    case repairCancelled
    case repairFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .outputMatchesSource:
            return "Repaired archive output path cannot overwrite the damaged source archive."
        case .sourceNotFound(let path):
            return "Damaged archive not found at \(path)."
        case .overwriteConfirmationRequired(let existingOutputPath):
            return "Target file already exists at \(existingOutputPath) and requires overwrite confirmation."
        case .overwriteDisallowed(let existingOutputPath):
            return "Overwriting existing target file at \(existingOutputPath) is disallowed."
        case .repairCancelled:
            return "Archive repair was cancelled."
        case .repairFailed(let reason):
            return reason
        }
    }
}

public enum ArchiveRepairOverwritePolicy: Sendable, Equatable {
    case disallowOverwrite
    case requireConfirmation
    case overwriteConfirmed
}

public enum ArchiveRepairOutcome: Sendable, Equatable {
    case fullSuccess(
        outputPath: String,
        recoveredEntryCount: Int,
        recoveredEntries: [String],
        message: String
    )
    case partialRecovery(
        outputPath: String,
        recoveredEntryCount: Int,
        unrecoveredEntries: [String],
        message: String
    )
    case failed(reason: String)
}

public enum ArchiveRepairPhase: Sendable, Equatable {
    case idle
    case awaitingOverwriteConfirmation(existingOutputPath: String)
    case repairing(targetOutputPath: String)
    case completed(ArchiveRepairOutcome)
    case cancelled
}

@Observable
@MainActor
public final class ArchiveIntegrityViewModel {
    public var isVerifying: Bool = false
    public var progressFraction: Double = 0.0
    public var currentVerifyingEntry: String = ""
    public var report: ArchiveIntegrityReport?
    public var errorMessage: String?

    public var overwritePolicy: ArchiveRepairOverwritePolicy = .requireConfirmation
    public var repairPhase: ArchiveRepairPhase = .idle
    public var repairOutcome: ArchiveRepairOutcome?
    public var customOutputPath: String = ""
    public var repairOutputPath: String {
        get { customOutputPath }
        set {
            customOutputPath = newValue
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            explicitInitialOutputPath = trimmed.isEmpty ? nil : trimmed
        }
    }

    private let engineFacade: TTZipEngineFacading
    private let integrityChecker: ArchiveIntegrityChecker
    private var explicitInitialOutputPath: String?
    private var pendingDamagedPath: String?
    private var pendingOutputPath: String?
    private var activeCancellationBox: RepairCancellationBox?
    private var activeRepairTask: Task<Void, Never>?

    public var isRepairing: Bool {
        if case .repairing = repairPhase {
            return true
        }
        return false
    }

    public var canRepairArchive: Bool {
        guard !isVerifying && !isRepairing else { return false }
        if errorMessage != nil { return true }
        guard let status = report?.overallStatus else { return false }
        return status == .corrupted || status == .unreadable
    }

    public init(
        engineFacade: TTZipEngineFacading = TTZipEngineFacade.shared,
        integrityChecker: ArchiveIntegrityChecker = ArchiveIntegrityChecker(),
        initialOutputPath: String? = nil
    ) {
        self.engineFacade = engineFacade
        self.integrityChecker = integrityChecker
        if let initialOutputPath {
            let trimmed = initialOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.customOutputPath = trimmed
                self.explicitInitialOutputPath = trimmed
            }
        }
    }

    public static func defaultRepairedOutputPath(for damagedPath: String) -> String {
        let nsPath = damagedPath as NSString
        let dir = nsPath.deletingLastPathComponent
        let fileName = nsPath.lastPathComponent
        let lower = fileName.lowercased()
        let compoundSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4"]
        for suffix in compoundSuffixes where lower.hasSuffix(suffix) {
            let stemEnd = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
            let stem = String(fileName[..<stemEnd])
            let rebuilt = "\(stem)_repaired\(suffix)"
            return dir.isEmpty ? rebuilt : (dir as NSString).appendingPathComponent(rebuilt)
        }
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        let rebuilt = ext.isEmpty ? "\(stem)_repaired" : "\(stem)_repaired.\(ext)"
        return dir.isEmpty ? rebuilt : (dir as NSString).appendingPathComponent(rebuilt)
    }

    public static func pathsReferToSameFile(_ lhs: String, _ rhs: String) -> Bool {
        let lhsURL = URL(fileURLWithPath: lhs).standardizedFileURL
        let rhsURL = URL(fileURLWithPath: rhs).standardizedFileURL
        if lhsURL.path == rhsURL.path {
            return true
        }
        return lhsURL.resolvingSymlinksInPath().path == rhsURL.resolvingSymlinksInPath().path
    }

    public func startIntegrityCheck(archivePath: String, password: String? = nil) {
        Task { [weak self] in
            await self?.runIntegrityCheck(archivePath: archivePath, password: password)
        }
    }

    public func runIntegrityCheck(archivePath: String, password: String? = nil) async {
        isVerifying = true
        progressFraction = 0.0
        currentVerifyingEntry = "Initializing..."
        report = nil
        errorMessage = nil
        if customOutputPath.isEmpty {
            customOutputPath = Self.defaultRepairedOutputPath(for: archivePath)
        }

        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0)
        do {
            let result = try await integrityChecker.checkArchiveIntegrity(
                archivePath: archivePath,
                password: password
            ) { [weak self] progress, entry in
                if progress >= 1.0 || throttler.shouldEmit() {
                    Task { @MainActor [weak self] in
                        self?.progressFraction = progress
                        self?.currentVerifyingEntry = entry
                    }
                }
            }
            self.report = result
            self.progressFraction = 1.0
            self.isVerifying = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isVerifying = false
        }
    }

    public func startRepair(
        damagedPath: String,
        outputPath: String? = nil,
        policy: ArchiveRepairOverwritePolicy? = nil
    ) {
        activeRepairTask?.cancel()
        activeRepairTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.repairArchive(
                damagedPath: damagedPath,
                outputPath: outputPath,
                policy: policy
            )
        }
    }

    @discardableResult
    public func repairArchive(
        damagedPath: String,
        outputPath: String? = nil,
        policy: ArchiveRepairOverwritePolicy? = nil
    ) async throws -> ArchiveRepairOutcome {
        let trimmedOut = outputPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitOut = (trimmedOut?.isEmpty == false ? trimmedOut : nil) ?? explicitInitialOutputPath
        let resolvedOutput = explicitOut ?? Self.defaultRepairedOutputPath(for: damagedPath)

        try validateRepairTarget(
            damagedPath: damagedPath,
            targetOutput: resolvedOutput,
            policy: policy ?? overwritePolicy
        )

        return try await executeStagedRepair(
            damagedPath: damagedPath,
            targetOutput: resolvedOutput
        )
    }

    @discardableResult
    public func confirmOverwriteAndRepair() async throws -> ArchiveRepairOutcome {
        guard let damagedPath = pendingDamagedPath,
              let targetOutput = pendingOutputPath else {
            let reason = "No pending overwrite confirmation to confirm."
            let outcome = ArchiveRepairOutcome.failed(reason: reason)
            repairOutcome = outcome
            repairPhase = .completed(outcome)
            throw ArchiveRepairError.repairFailed(reason: reason)
        }
        pendingDamagedPath = nil
        pendingOutputPath = nil
        return try await repairArchive(
            damagedPath: damagedPath,
            outputPath: targetOutput,
            policy: .overwriteConfirmed
        )
    }

    public func cancelRepair() {
        activeCancellationBox?.cancel()
        activeRepairTask?.cancel()
        activeRepairTask = nil
        pendingDamagedPath = nil
        pendingOutputPath = nil
        repairPhase = .cancelled
    }

    private func validateRepairTarget(
        damagedPath: String,
        targetOutput: String,
        policy: ArchiveRepairOverwritePolicy
    ) throws {
        if Self.pathsReferToSameFile(damagedPath, targetOutput) {
            let outcome = ArchiveRepairOutcome.failed(
                reason: ArchiveRepairError.outputMatchesSource.localizedDescription
            )
            repairOutcome = outcome
            repairPhase = .completed(outcome)
            throw ArchiveRepairError.outputMatchesSource
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: damagedPath) else {
            let err = ArchiveRepairError.sourceNotFound(path: damagedPath)
            let outcome = ArchiveRepairOutcome.failed(reason: err.localizedDescription)
            repairOutcome = outcome
            repairPhase = .completed(outcome)
            throw err
        }

        if fm.fileExists(atPath: targetOutput) {
            switch policy {
            case .requireConfirmation:
                pendingDamagedPath = damagedPath
                pendingOutputPath = targetOutput
                repairPhase = .awaitingOverwriteConfirmation(existingOutputPath: targetOutput)
                throw ArchiveRepairError.overwriteConfirmationRequired(existingOutputPath: targetOutput)
            case .disallowOverwrite:
                let err = ArchiveRepairError.overwriteDisallowed(existingOutputPath: targetOutput)
                let outcome = ArchiveRepairOutcome.failed(reason: err.localizedDescription)
                repairOutcome = outcome
                repairPhase = .completed(outcome)
                throw err
            case .overwriteConfirmed:
                break
            }
        }
    }

    private func executeStagedRepair(
        damagedPath: String,
        targetOutput: String
    ) async throws -> ArchiveRepairOutcome {
        let cancelBox = RepairCancellationBox()
        activeCancellationBox = cancelBox
        pendingDamagedPath = nil
        pendingOutputPath = nil
        repairPhase = .repairing(targetOutputPath: targetOutput)

        let baselineEntries = await collectExpectedBaselineEntries(
            for: damagedPath,
            cancelBox: cancelBox
        )
        let stagingPath = Self.makeStagingPath(for: targetOutput)
        defer {
            try? FileManager.default.removeItem(atPath: stagingPath)
        }

        let proxy = StagingRepairEngineProxy(
            base: engineFacade,
            stagingPath: stagingPath,
            cancellationBox: cancelBox,
            integrityChecker: integrityChecker
        )
        let command = RepairCommand(
            damagedPath: damagedPath,
            outputPath: targetOutput,
            engineFacade: proxy
        )

        do {
            _ = try await engineFacade.executeCommand(command)
            if cancelBox.isCancelled || Task.isCancelled {
                repairPhase = .cancelled
                throw ArchiveRepairError.repairCancelled
            }
            let outcome = buildRepairOutcome(
                targetOutput: targetOutput,
                recoveredEntries: proxy.recoveredEntries,
                prunedCorruptEntries: proxy.prunedCorruptEntries,
                baselineEntries: baselineEntries
            )
            repairOutcome = outcome
            repairPhase = .completed(outcome)
            return outcome
        } catch let error as ArchiveRepairError where error == .repairCancelled {
            repairPhase = .cancelled
            throw error
        } catch is CancellationError {
            repairPhase = .cancelled
            throw ArchiveRepairError.repairCancelled
        } catch {
            if cancelBox.isCancelled || Task.isCancelled {
                repairPhase = .cancelled
                throw ArchiveRepairError.repairCancelled
            }
            let outcome = ArchiveRepairOutcome.failed(reason: error.localizedDescription)
            repairOutcome = outcome
            repairPhase = .completed(outcome)
            return outcome
        }
    }

    private func collectExpectedBaselineEntries(
        for damagedPath: String,
        cancelBox: RepairCancellationBox
    ) async -> [String] {
        var collected: [String] = []
        if let inspected = try? await engineFacade.inspectArchive(
            archivePath: damagedPath,
            password: nil,
            autoVaultUnlock: false
        ) {
            for entry in inspected.entries where !entry.isDirectory {
                if !collected.contains(entry.path) {
                    collected.append(entry.path)
                }
            }
        }

        let activeReport: ArchiveIntegrityReport?
        if let existing = report, existing.archivePath == damagedPath {
            activeReport = existing
        } else {
            activeReport = try? await integrityChecker.checkArchiveIntegrity(
                archivePath: damagedPath,
                password: nil,
                progressHandler: nil
            )
        }
        if let activeReport {
            for item in activeReport.corruptedEntries where item.entryPath != damagedPath {
                if !collected.contains(item.entryPath) {
                    collected.append(item.entryPath)
                }
            }
        }

        let hasExistingFileEntries = !collected.isEmpty
        let tarCandidates = await Task.detached(priority: .userInitiated) {
            Self.scanTarHeaderEntryNames(
                atPath: damagedPath,
                hasExistingFileEntries: hasExistingFileEntries,
                isCancelled: { cancelBox.isCancelled || Task.isCancelled }
            )
        }.value
        for tarCandidate in tarCandidates where !collected.contains(tarCandidate) {
            collected.append(tarCandidate)
        }
        return collected
    }

    private func buildRepairOutcome(
        targetOutput: String,
        recoveredEntries: [String],
        prunedCorruptEntries: [String],
        baselineEntries: [String]
    ) -> ArchiveRepairOutcome {
        guard !recoveredEntries.isEmpty else {
            return .failed(reason: "No valid entries could be recovered from the damaged archive.")
        }
        let recoveredSet = Set(recoveredEntries)
        var unrecovered: [String] = []
        for entry in prunedCorruptEntries where !recoveredSet.contains(entry) && !unrecovered.contains(entry) {
            unrecovered.append(entry)
        }
        for entry in baselineEntries where !recoveredSet.contains(entry) && !unrecovered.contains(entry) {
            unrecovered.append(entry)
        }
        if unrecovered.isEmpty {
            return .fullSuccess(
                outputPath: targetOutput,
                recoveredEntryCount: recoveredEntries.count,
                recoveredEntries: recoveredEntries,
                message: "Recovered all \(recoveredEntries.count) entries into \(URL(fileURLWithPath: targetOutput).lastPathComponent)."
            )
        }
        return .partialRecovery(
            outputPath: targetOutput,
            recoveredEntryCount: recoveredEntries.count,
            unrecoveredEntries: unrecovered,
            message: "Recovered \(recoveredEntries.count) entries; \(unrecovered.count) corrupted entries could not be salvaged."
        )
    }

    private static func makeStagingPath(for targetOutput: String) -> String {
        let parentDir = (targetOutput as NSString).deletingLastPathComponent
        let ext = (targetOutput as NSString).pathExtension
        let name = ext.isEmpty
            ? ".ttzip-repair-staging-\(UUID().uuidString)"
            : ".ttzip-repair-staging-\(UUID().uuidString).\(ext)"
        return (parentDir as NSString).appendingPathComponent(name)
    }

    nonisolated private static func scanTarHeaderEntryNames(
        atPath path: String,
        hasExistingFileEntries: Bool = false,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> [String] {
        guard path.lowercased().hasSuffix(".tar"),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return []
        }
        defer { try? handle.close() }

        let ustarMagic = Data("ustar".utf8)
        let chunkByteLimit = 64 * 1024
        var carryBuffer = Data()
        var fileNames: [String] = []
        var directoryNames: [String] = []

        while !isCancelled() {
            guard let chunk = try? handle.read(upToCount: chunkByteLimit), !chunk.isEmpty else {
                break
            }
            carryBuffer.append(chunk)
            var offset = 0
            while offset + 512 <= carryBuffer.count {
                if isCancelled() { return [] }
                let block = carryBuffer.subdata(in: offset..<(offset + 512))
                appendTarBlockHeaderName(
                    from: block,
                    ustarMagic: ustarMagic,
                    fileNames: &fileNames,
                    directoryNames: &directoryNames
                )
                offset += 512
            }
            if offset > 0 {
                carryBuffer.removeSubrange(0..<offset)
            }
        }
        if !fileNames.isEmpty || hasExistingFileEntries {
            return fileNames
        }
        return directoryNames
    }

    nonisolated private static func appendTarBlockHeaderName(
        from block: Data,
        ustarMagic: Data,
        fileNames: inout [String],
        directoryNames: inout [String]
    ) {
        guard block.subdata(in: 257..<262) == ustarMagic else { return }
        let nameSlice = block.subdata(in: 0..<100)
        let rawBytes = nameSlice.prefix { $0 != 0 }
        guard let name = String(bytes: rawBytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return
        }
        let typeflag = block[block.startIndex + 156]
        if typeflag == UInt8(ascii: "x") || typeflag == UInt8(ascii: "g") {
            return
        }
        let isDirectory = (typeflag == UInt8(ascii: "5")) || name.hasSuffix("/")
        if isDirectory {
            if !directoryNames.contains(name) {
                directoryNames.append(name)
            }
        } else if !fileNames.contains(name) {
            fileNames.append(name)
        }
    }
}

private final class RepairCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class StagingRepairEngineProxy: TTZipEngineFacading, @unchecked Sendable {
    private let base: TTZipEngineFacading
    private let stagingPath: String
    private let cancellationBox: RepairCancellationBox
    private let integrityChecker: ArchiveIntegrityChecker
    private let stateLock = NSLock()
    private var storedRecoveredEntries: [String] = []
    private var storedPrunedEntries: [String] = []

    var recoveredEntries: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedRecoveredEntries
    }

    var prunedCorruptEntries: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedPrunedEntries
    }

    init(
        base: TTZipEngineFacading,
        stagingPath: String,
        cancellationBox: RepairCancellationBox,
        integrityChecker: ArchiveIntegrityChecker
    ) {
        self.base = base
        self.stagingPath = stagingPath
        self.cancellationBox = cancellationBox
        self.integrityChecker = integrityChecker
    }

    private func recordEntries(recovered: [String], pruned: [String]) {
        stateLock.lock()
        storedRecoveredEntries = recovered
        storedPrunedEntries = pruned
        stateLock.unlock()
    }

    private func ensureNotCancelled(cleaningStaging staging: Bool) throws {
        if cancellationBox.isCancelled || Task.isCancelled {
            if staging {
                try? FileManager.default.removeItem(atPath: stagingPath)
            }
            throw ArchiveRepairError.repairCancelled
        }
    }

    func repairArchive(damagedPath: String, outputPath: String) async throws -> Int {
        try ensureNotCancelled(cleaningStaging: false)
        let rawCount = try await runBaseRepairIntoStaging(damagedPath: damagedPath)
        try ensureNotCancelled(cleaningStaging: true)
        guard rawCount > 0, FileManager.default.fileExists(atPath: stagingPath) else {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw ArchiveRepairError.repairFailed(reason: "Zero entries could be salvaged from the damaged archive.")
        }

        let pruned = try await pruneCorruptedStagedEntriesIfNeeded()
        let surviving = try await readSurvivingStagedEntries()
        try ensureNotCancelled(cleaningStaging: true)

        try commitStagingFile(to: outputPath)
        recordEntries(recovered: surviving, pruned: pruned)
        return surviving.count
    }

    private func runBaseRepairIntoStaging(damagedPath: String) async throws -> Int {
        do {
            return try await base.repairArchive(damagedPath: damagedPath, outputPath: stagingPath)
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw error
        }
    }

    private func pruneCorruptedStagedEntriesIfNeeded() async throws -> [String] {
        guard let stagedReport = try? await integrityChecker.checkArchiveIntegrity(
            archivePath: stagingPath,
            password: nil,
            progressHandler: nil
        ), !stagedReport.corruptedEntries.isEmpty else {
            return []
        }
        guard stagedReport.verifiedEntriesCount > 0 else {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw ArchiveRepairError.repairFailed(
                reason: "Repaired output failed integrity verification with zero intact entries."
            )
        }
        let corruptPaths = stagedReport.corruptedEntries
            .map(\.entryPath)
            .filter { $0 != stagingPath }
        guard !corruptPaths.isEmpty else { return [] }
        let actions = corruptPaths.map {
            InPlaceMutationAction(isDelete: true, entryPath: $0, sourcePath: nil)
        }
        try? inPlaceMutateArchive(archivePath: stagingPath, actions: actions)
        return corruptPaths
    }

    private func readSurvivingStagedEntries() async throws -> [String] {
        guard let inspected = try? await base.inspectArchive(
            archivePath: stagingPath,
            password: nil,
            autoVaultUnlock: false
        ) else {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw ArchiveRepairError.repairFailed(reason: "No readable entries found in repaired archive.")
        }
        let nonDirEntries = inspected.entries.filter { !$0.isDirectory }.map(\.path)
        let allEntries = nonDirEntries.isEmpty ? inspected.entries.map(\.path) : nonDirEntries
        guard !allEntries.isEmpty else {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw ArchiveRepairError.repairFailed(reason: "No readable entries found in repaired archive.")
        }
        return allEntries
    }

    private func commitStagingFile(to outputPath: String) throws {
        let fm = FileManager.default
        let stagingURL = URL(fileURLWithPath: stagingPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        if fm.fileExists(atPath: outputPath) {
            _ = try fm.replaceItemAt(outputURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: outputURL)
        }
    }

    func quickCompress(
        inputs: [String], outputPath: String, format: ArchiveCompressionFormat,
        level: ArchiveCompressionLevel, password: String?, splitSize: Int64?,
        filterOptions: ArchiveFilterOptions, advancedOptions: ArchiveAdvancedOptions?,
        progress: (@Sendable (ArchiveProgress) -> Void)?, token: CancellationToken?
    ) async throws -> ArchiveOperationResult {
        try await base.quickCompress(
            inputs: inputs, outputPath: outputPath, format: format, level: level,
            password: password, splitSize: splitSize, filterOptions: filterOptions,
            advancedOptions: advancedOptions, progress: progress, token: token
        )
    }

    func quickExtract(
        archivePath: String, destinationDir: String, password: String?,
        autoVaultUnlock: Bool, handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?, token: CancellationToken?
    ) async throws -> ExtractResult {
        try await base.quickExtract(
            archivePath: archivePath, destinationDir: destinationDir, password: password,
            autoVaultUnlock: autoVaultUnlock, handling: handling, progress: progress, token: token
        )
    }

    func extractSingleEntry(
        archivePath: String, entryPath: String, destinationDir: String,
        password: String?, handling: CollisionHandling
    ) async throws -> ExtractionOutcome {
        try await base.extractSingleEntry(
            archivePath: archivePath, entryPath: entryPath, destinationDir: destinationDir,
            password: password, handling: handling
        )
    }

    func inspectArchive(
        archivePath: String, password: String?, autoVaultUnlock: Bool
    ) async throws -> ArchiveInspectionResult {
        try await base.inspectArchive(
            archivePath: archivePath, password: password, autoVaultUnlock: autoVaultUnlock
        )
    }

    func verifyIntegrity(archivePath: String) async throws -> HashVerificationResult {
        try await base.verifyIntegrity(archivePath: archivePath)
    }

    func openVfsSnapshot(archivePath: String, password: String?) async throws -> Any {
        try await base.openVfsSnapshot(archivePath: archivePath, password: password)
    }
}
