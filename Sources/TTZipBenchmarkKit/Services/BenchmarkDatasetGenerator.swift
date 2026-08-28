// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import QuartzCore
import TTZipCore
import TTZipUI

/// Errors produced during synthetic benchmark dataset creation and system ditto execution.
public enum BenchmarkDatasetError: LocalizedError, Sendable {
    case dittoExecutableNotFound
    case dittoExecutionFailed(exitCode: Int32, message: String)
    case sampleFileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .dittoExecutableNotFound:
            return "System ditto executable not found at /usr/bin/ditto."
        case .dittoExecutionFailed(let code, let msg):
            return "System ditto process failed with exit code \(code): \(msg)"
        case .sampleFileNotFound(let path):
            return "Benchmark sample file not found at path: \(path)"
        }
    }
}

/// Synthetic benchmark dataset generator and competitor toolchain performance measurement harness.
public final class BenchmarkDatasetGenerator: @unchecked Sendable {
    public static let shared = BenchmarkDatasetGenerator()

    private init() {}

    public func calculateTotalSize(at path: String) -> Int64 {
        let component = ArchiveComponentTreeBuilder.buildTree(fromDiskPath: path)
        return component.sizeBytes
    }

    /// Generates synthetic dataset files on disk for deterministic benchmarking.
    public func generateSyntheticDataset(at path: String, targetBytes: Int64, profile: BenchmarkDatasetProfile) throws {
        try TTZipCore.generateSyntheticBenchmarkDataset(
            targetPath: path,
            targetBytes: UInt64(targetBytes),
            profileName: profile.rawValue
        )
    }

    /// Measures system ditto baseline throughput in MB/s with high-resolution monotonic timing.
    public func measureNativeSystemZipThroughput(samplePath: String, targetMB: Double) throws -> Double {
        let fm = FileManager.default
        guard fm.fileExists(atPath: samplePath) else {
            throw BenchmarkDatasetError.sampleFileNotFound(samplePath)
        }
        guard fm.isExecutableFile(atPath: "/usr/bin/ditto") else {
            throw BenchmarkDatasetError.dittoExecutableNotFound
        }

        let tempZip = samplePath + ".native_ditto_bench.zip"
        defer { try? fm.removeItem(atPath: tempZip) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", samplePath, tempZip]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        let start = CACurrentMediaTime()
        do {
            try process.run()
            process.waitUntilExit()
            let elapsed = max(0.0001, CACurrentMediaTime() - start)

            if process.terminationStatus == 0 {
                return targetMB / elapsed
            } else {
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown ditto failure"
                throw BenchmarkDatasetError.dittoExecutionFailed(exitCode: process.terminationStatus, message: errMsg)
            }
        } catch let err as BenchmarkDatasetError {
            throw err
        } catch {
            throw BenchmarkDatasetError.dittoExecutionFailed(exitCode: process.terminationStatus, message: error.localizedDescription)
        }
    }

    /// Measures actual installed competitor toolchains against target payload.
    public func measureRealCompetitorScores(samplePath: String, targetMB: Double, nativeSpeedMBs: Double) -> [CompetitorRealScore] {
        var scores: [CompetitorRealScore] = []
        let installedTools = CompetitorDetector.detectOnlyInstalledCompetitors()
        let fm = FileManager.default

        for tool in installedTools {
            guard tool.toolId != "native_ditto" else { continue }
            guard let cli = tool.cliExecutablePath, fm.isExecutableFile(atPath: cli) else { continue }

            let tempOutput = samplePath + "._bench_\(tool.toolId).zip"
            defer { try? fm.removeItem(atPath: tempOutput) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            if tool.toolId == "7zip_cli" || tool.toolId == "keka" {
                process.arguments = ["a", "-tzip", "-mx5", tempOutput, samplePath]
            } else if tool.toolId == "bandizip" {
                process.arguments = ["c", tempOutput, samplePath]
            } else if tool.toolId == "winzip" {
                process.arguments = ["-a", tempOutput, samplePath]
            } else {
                continue
            }

            let start = CACurrentMediaTime()
            do {
                try process.run()
                process.waitUntilExit()
                let elapsed = max(0.001, CACurrentMediaTime() - start)
                if process.terminationStatus == 0 {
                    let speed = targetMB / elapsed
                    let speedup = speed / max(1.0, nativeSpeedMBs)
                    scores.append(CompetitorRealScore(
                        tool: tool,
                        measuredElapsedSeconds: elapsed,
                        measuredThroughputMBs: speed,
                        relativeSpeedupVsNative: speedup
                    ))
                }
            } catch {
                // Ignore tool failure when probing optional competitor
            }
        }

        return scores
    }
}
