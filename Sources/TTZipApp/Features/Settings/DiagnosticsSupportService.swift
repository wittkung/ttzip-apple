// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTLogKit
import TTZipCore

/// Shared service backing diagnostics log export and channel update triggers from both menu commands and Settings.
public enum DiagnosticsSupportService {
    @MainActor
    public private(set) static var manualUpdateHandler: (@MainActor () -> Void)?

    @MainActor
    public static func registerManualUpdateHandler(_ handler: (@MainActor () -> Void)?) {
        manualUpdateHandler = handler
    }

    @MainActor
    public static func revealLogsInFinder() {
        TTLogFileWriter.shared.flushSync()
        let logPath = TTLogFileWriter.shared.logFilePath
        let logDir = TTLogFileWriter.shared.logDirectoryPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: logPath) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true, attributes: nil)
            fm.createFile(atPath: logPath, contents: nil, attributes: nil)
        }
        NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: logDir)
    }

    @MainActor
    public static func exportDiagnosticReport() {
        TTLogFileWriter.shared.flushSync()

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent("TTZip-Diagnostics-\(UUID().uuidString)")
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            defer {
                try? fm.removeItem(at: tempDir)
            }

            Self.writeSystemInfoReport(to: tempDir)
            Self.collectLogFiles(into: tempDir, fileManager: fm)
            let targetZipURL = Self.makeDiagnosticZipDestination(fileManager: fm)

            if Self.createDiagnosticArchive(from: tempDir, to: targetZipURL, fileManager: fm),
               fm.fileExists(atPath: targetZipURL.path) {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([targetZipURL])
                }
            }
        }
    }

    nonisolated private static func writeSystemInfoReport(to tempDir: URL) {
        var size: size_t = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var modelBuffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &modelBuffer, &size, nil, 0)
        let hardwareModel = modelBuffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? "Unknown"
        }

        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let memoryGB = String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024))
        let timestamp = Date().formatted(.iso8601)

        let reportContent = """
        TTZip Diagnostic Report
        =======================
        Generated: \(timestamp)
        Hardware Model: \(hardwareModel)
        macOS Version: \(osVersion)
        Active Processors: \(processorCount)
        Physical Memory: \(memoryGB)
        """

        let reportFile = tempDir.appendingPathComponent("system_info.txt")
        try? reportContent.write(to: reportFile, atomically: true, encoding: .utf8)
    }

    nonisolated private static func collectLogFiles(into tempDir: URL, fileManager fm: FileManager) {
        let logDirURL = URL(fileURLWithPath: TTLogFileWriter.shared.logDirectoryPath)
        guard let entries = try? fm.contentsOfDirectory(at: logDirURL, includingPropertiesForKeys: nil) else { return }
        for fileURL in entries {
            let name = fileURL.lastPathComponent
            if name == "ttzip.log" || (name.hasPrefix("ttzip.") && name.hasSuffix(".log")) {
                let dest = tempDir.appendingPathComponent(name)
                try? fm.copyItem(at: fileURL, to: dest)
            }
        }
    }

    nonisolated private static func makeDiagnosticZipDestination(fileManager fm: FileManager) -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let dateStr = dateFormatter.string(from: Date())
        let desktopURL = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        return desktopURL.appendingPathComponent("TTZip-Diagnostics-\(dateStr).zip")
    }

    nonisolated private static func createDiagnosticArchive(
        from tempDir: URL,
        to targetZipURL: URL,
        fileManager fm: FileManager
    ) -> Bool {
        guard let collectedItems = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil),
              !collectedItems.isEmpty else {
            return false
        }
        let writer = ArchiveWriter()
        let inputPaths = collectedItems.map { $0.path }
        do {
            try writer.createArchiveSync(
                outputPath: targetZipURL.path,
                format: .zip,
                inputPaths: inputPaths
            )
            return true
        } catch {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, targetZipURL.path]
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }
}
