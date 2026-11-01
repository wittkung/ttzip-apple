// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation

/// Posts a Return keystroke (`0x24`) to confirm the active `NSOpenPanel` when running in automated verification mode.
private func scheduleAutoConfirmOpenPanelIfRequested(enabled: Bool) {
    guard enabled else { return }
    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.9) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Presents a real macOS Powerbox `NSOpenPanel` modal dialog and returns the user-selected security-scoped URL.
@MainActor
private func selectViaNSOpenPanel(
    initialDirectory: URL,
    canChooseFiles: Bool,
    canChooseDirectories: Bool,
    message: String,
    prompt: String,
    autoConfirm: Bool
) -> URL? {
    let panel = NSOpenPanel()
    panel.message = message
    panel.prompt = prompt
    panel.canChooseFiles = canChooseFiles
    panel.canChooseDirectories = canChooseDirectories
    panel.allowsMultipleSelection = false
    panel.directoryURL = initialDirectory

    scheduleAutoConfirmOpenPanelIfRequested(enabled: autoConfirm)
    let timeoutWork = DispatchWorkItem {
        panel.cancel(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: timeoutWork)
    let response = panel.runModal()
    timeoutWork.cancel()
    return response == .OK ? panel.url : nil
}

@main
struct SandboxNSOpenPanelHost {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            fputs(
                "Usage: SandboxNSOpenPanelHost <external_archive_path> <authorized_dest_dir> <unauthorized_dest_dir> [--interactive]\n",
                stderr
            )
            exit(2)
        }

        let archiveFileURL = URL(fileURLWithPath: args[1], isDirectory: false)
        let authorizedDestDirURL = URL(fileURLWithPath: args[2], isDirectory: true)
        let unauthorizedDestDirURL = URL(fileURLWithPath: args[3], isDirectory: true)
        let autoConfirm = !args.contains("--interactive")

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        guard let selectedSourceURL = selectViaNSOpenPanel(
            initialDirectory: archiveFileURL.deletingLastPathComponent(),
            canChooseFiles: true,
            canChooseDirectories: true,
            message: "Select external archive or its parent directory for TTZip Powerbox verification",
            prompt: "Open",
            autoConfirm: autoConfirm
        ) else {
            fputs("ERROR: NSOpenPanel source selection cancelled or timed out\n", stderr)
            exit(3)
        }

        let sourceScoped = selectedSourceURL.startAccessingSecurityScopedResource()
        defer {
            if sourceScoped {
                selectedSourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let authorizedArchiveURL: URL
        if selectedSourceURL.hasDirectoryPath {
            authorizedArchiveURL = selectedSourceURL.appendingPathComponent(
                archiveFileURL.lastPathComponent,
                isDirectory: false
            )
        } else {
            authorizedArchiveURL = selectedSourceURL
        }

        guard let selectedDestURL = selectViaNSOpenPanel(
            initialDirectory: authorizedDestDirURL,
            canChooseFiles: false,
            canChooseDirectories: true,
            message: "Select external destination directory for TTZip Powerbox verification",
            prompt: "Extract Here",
            autoConfirm: autoConfirm
        ) else {
            fputs("ERROR: NSOpenPanel destination selection cancelled or timed out\n", stderr)
            exit(4)
        }

        let destScoped = selectedDestURL.startAccessingSecurityScopedResource()
        defer {
            if destScoped {
                selectedDestURL.stopAccessingSecurityScopedResource()
            }
        }

        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var authorizedResult: Result<UInt64, Error>?
        nonisolated(unsafe) var unauthorizedResult: Result<UInt64, Error>?

        Task {
            do {
                let bytes = try await QuarantineWorkerClient.shared.extractQuarantinedArchive(
                    url: authorizedArchiveURL,
                    destinationDirectory: selectedDestURL
                )
                authorizedResult = .success(bytes)
            } catch {
                authorizedResult = .failure(error)
            }

            do {
                let bytes = try await QuarantineWorkerClient.shared.extractQuarantinedArchive(
                    url: authorizedArchiveURL,
                    destinationDirectory: unauthorizedDestDirURL
                )
                unauthorizedResult = .success(bytes)
            } catch {
                unauthorizedResult = .failure(error)
            }
            sem.signal()
        }

        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }

        switch authorizedResult {
        case .success(let totalBytes):
            print("AUTHORIZED_EXTRACT_OK bytes=\(totalBytes) archive=\(authorizedArchiveURL.path) dest=\(selectedDestURL.path)")
        case .failure(let error):
            fputs("AUTHORIZED_EXTRACT_FAILED error=\(error.localizedDescription)\n", stderr)
            exit(5)
        case .none:
            fputs("AUTHORIZED_EXTRACT_FAILED missing result\n", stderr)
            exit(5)
        }

        switch unauthorizedResult {
        case .failure(let error):
            print("UNAUTHORIZED_DEST_REJECTED_OK error=\(error.localizedDescription)")
            exit(0)
        case .success(let bytes):
            fputs("ERROR: Unauthorized destination unexpectedly succeeded (\(bytes) bytes)\n", stderr)
            exit(6)
        case .none:
            fputs("ERROR: Unauthorized destination missing result\n", stderr)
            exit(6)
        }
    }
}
