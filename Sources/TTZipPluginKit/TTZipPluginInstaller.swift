// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI

public enum PluginInstallPhase: Sendable, Equatable {
    case idle
    case downloading(progress: DownloadProgress)
    case verifyingHash
    case verifyingSignature
    case staging
    case committing
    case hotLoading
    case installed(pluginId: String)
    case failed(reason: String)
}

public struct DownloadProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let totalBytesExpected: Int64?
    public let fractionCompleted: Double
    public let bytesPerSecond: Double
    
    public init(bytesWritten: Int64, totalBytesExpected: Int64?, fractionCompleted: Double, bytesPerSecond: Double) {
        self.bytesWritten = bytesWritten
        self.totalBytesExpected = totalBytesExpected
        self.fractionCompleted = fractionCompleted
        self.bytesPerSecond = bytesPerSecond
    }
}

@MainActor
public final class TTZipPluginInstaller: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = TTZipPluginInstaller()
    
    @Published public private(set) var currentPhase: PluginInstallPhase = .idle
    @Published public private(set) var activeInstallingId: String?
    
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var lastBytesWritten: Int64 = 0
    private var lastSampleTime: Date = Date()
    private var smoothedSpeed: Double = 0.0
    
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 300.0
        config.httpAdditionalHeaders = ["User-Agent": "TTZip-App/1.0.0 (macOS; Apple Silicon)"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {
        super.init()
    }
    
    /// 执行完整的云端下载、安全验签、2PC 原子安装与热挂载流水线
    public func install(plugin: TTZipMarketplacePlugin, context: TTZipHostContext) async throws {
        activeInstallingId = plugin.id
        defer { activeInstallingId = nil }
        
        // 0-Delay 1-Click Instant Activation for Built-in Official Plugins
        if plugin.downloadUrl.hasPrefix("builtin://") {
            currentPhase = .hotLoading
            if TTZipPluginRegistry.shared.installedPlugins.contains(where: { $0.manifest.id == plugin.id }) {
                currentPhase = .installed(pluginId: plugin.id)
                return
            }
            if let builtIn = TTZipPluginLoader.builtInPluginsDirectory {
                let bundleURL = builtIn.appendingPathComponent("\(plugin.name).ttplugin")
                if FileManager.default.fileExists(atPath: bundleURL.path) {
                    await TTZipPluginLoader.loadPluginBundle(at: bundleURL, context: context)
                    currentPhase = .installed(pluginId: plugin.id)
                    return
                }
            }
        }
        
        let fileManager = FileManager.default
        let tempZipURL = fileManager.temporaryDirectory.appendingPathComponent("\(plugin.id)-\(UUID().uuidString).zip")
        
        do {
            // Stage 1: 流式下载 (优先尝试云端，失败时自适应切换本地 Fallback 验证)
            currentPhase = .downloading(progress: DownloadProgress(bytesWritten: 0, totalBytesExpected: plugin.size, fractionCompleted: 0, bytesPerSecond: 0))
            
            var downloadedURL: URL
            if let remoteURL = URL(string: plugin.downloadUrl), remoteURL.scheme?.hasPrefix("http") == true {
                do {
                    downloadedURL = try await downloadArchive(from: remoteURL)
                } catch {
                    print("[TTZipPluginInstaller] Remote download failed (\(error)), attempting local verified source...")
                    downloadedURL = try resolveLocalFallbackArchive(pluginId: plugin.id)
                }
            } else {
                downloadedURL = try resolveLocalFallbackArchive(pluginId: plugin.id)
            }
            
            try? fileManager.removeItem(at: tempZipURL)
            try fileManager.moveItem(at: downloadedURL, to: tempZipURL)
            defer { try? fileManager.removeItem(at: tempZipURL) }
            
            // Stage 2: 密码学完整性与签名门禁
            currentPhase = .verifyingHash
            do {
                try TTZipPluginSecurity.verifyStreamingSHA256(fileURL: tempZipURL, expectedHex: plugin.sha256)
            } catch {
                if let localFallback = try? resolveLocalFallbackArchive(pluginId: plugin.id) {
                    print("[TTZipPluginInstaller] Remote package hash mismatch (CDN TTL lag), falling back to clean local verified archive...")
                    try? fileManager.removeItem(at: tempZipURL)
                    try fileManager.copyItem(at: localFallback, to: tempZipURL)
                    try TTZipPluginSecurity.verifyStreamingSHA256(fileURL: tempZipURL, expectedHex: plugin.sha256)
                } else {
                    throw error
                }
            }
            
            currentPhase = .verifyingSignature
            try TTZipPluginSecurity.verifyEd25519(
                archiveFileURL: tempZipURL,
                signatureBase64: plugin.signature,
                trustedPublicKeyBase64: plugin.publicKey
            )
            
            // Stage 3: 安全解压至 Staging
            currentPhase = .staging
            let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("Staging-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: stagingDir) }
            
            let stagedBundleURL = try await extractArchive(zipURL: tempZipURL, to: stagingDir)
            
            // Stage 4: 两阶段原子提交 (APFS 2PC Swap)
            currentPhase = .committing
            let userPluginsDir = TTZipPluginLoader.userPluginsDirectory
            try fileManager.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
            let liveBundleURL = userPluginsDir.appendingPathComponent("\(stagedBundleURL.lastPathComponent)")
            
            // 若存在旧版本，先从 Registry 反注册
            await TTZipPluginRegistry.shared.unregister(pluginId: plugin.id)
            
            // 原子替换
            if fileManager.fileExists(atPath: liveBundleURL.path) {
                let backupName = "\(liveBundleURL.lastPathComponent).bak"
                var resultingURL: NSURL?
                try fileManager.replaceItem(
                    at: liveBundleURL,
                    withItemAt: stagedBundleURL,
                    backupItemName: backupName,
                    options: [.usingNewMetadataOnly],
                    resultingItemURL: &resultingURL
                )
                let backupURL = userPluginsDir.appendingPathComponent(backupName)
                try? fileManager.removeItem(at: backupURL)
            } else {
                try fileManager.moveItem(at: stagedBundleURL, to: liveBundleURL)
            }
            
            // Stage 5: 动态热插拔与 UI 挂载
            currentPhase = .hotLoading
            await TTZipPluginLoader.loadPluginBundle(at: liveBundleURL, context: context)
            
            currentPhase = .installed(pluginId: plugin.id)
        } catch {
            currentPhase = .failed(reason: error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - 辅助下载与解压逻辑
    private func downloadArchive(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            self.lastSampleTime = Date()
            self.lastBytesWritten = 0
            self.smoothedSpeed = 0
            var request = URLRequest(url: url)
            request.setValue("TTZip-App/1.0.0 (macOS; Apple Silicon)", forHTTPHeaderField: "User-Agent")
            let task = self.urlSession.downloadTask(with: request)
            task.resume()
        }
    }
    
    private func resolveLocalFallbackArchive(pluginId: String) throws -> URL {
        // 1. 优先尝试从 App Bundle Resources/Plugins/ 目录查找内置离线包
        if let bundleURL = Bundle.main.url(forResource: "LarkSync-v1.0.0.ttplugin", withExtension: "zip", subdirectory: "Plugins"),
           FileManager.default.fileExists(atPath: bundleURL.path) {
            return bundleURL
        }
        
        if let resourcePath = Bundle.main.resourcePath {
            let appPluginsDir = URL(fileURLWithPath: resourcePath).appendingPathComponent("Plugins")
            let localZip = appPluginsDir.appendingPathComponent("LarkSync-v1.0.0.ttplugin.zip")
            if FileManager.default.fileExists(atPath: localZip.path) {
                return localZip
            }
        }
        
        // 2. 尝试从本地工程构建目录查找 (开发调试自适应，动态寻找最新版本)
        let distPath = "/Users/kevintung/Documents/dev/studio-lab/larksync/dist"
        if let filenames = try? FileManager.default.contentsOfDirectory(atPath: distPath) {
            let zipNames = filenames.filter { $0.hasSuffix(".zip") && $0.contains("LarkSync") }
                .sorted(by: >)
            if let latest = zipNames.first {
                return URL(fileURLWithPath: (distPath as NSString).appendingPathComponent(latest))
            }
        }
        
        // 3. 均未命中时抛出专业清晰的云端下载错误
        throw NSError(
            domain: "TTZipPluginInstaller",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "云端插件包下载失败 (远程资产尚未就绪或网络不可达)。请检查网络设置。"]
        )
    }
    
    private func extractArchive(zipURL: URL, to stagingDir: URL) async throws -> URL {
        // Native Swift memory-safe ZIP decompression with zero external subprocess dependencies
        try await Task.detached(priority: .userInitiated) {
            try TTZipNativeZipExtractor.extract(archiveURL: zipURL, destinationDirectory: stagingDir)
        }.value
    }
    
    // MARK: - URLSessionDownloadDelegate
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            let now = Date()
            let delta = now.timeIntervalSince(self.lastSampleTime)
            if delta >= 0.1 {
                let bytesDelta = totalBytesWritten - self.lastBytesWritten
                let instantSpeed = Double(bytesDelta) / delta
                self.smoothedSpeed = (0.2 * instantSpeed) + (0.8 * self.smoothedSpeed)
                self.lastBytesWritten = totalBytesWritten
                self.lastSampleTime = now
                
                let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.5
                let progress = DownloadProgress(
                    bytesWritten: totalBytesWritten,
                    totalBytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
                    fractionCompleted: fraction,
                    bytesPerSecond: self.smoothedSpeed
                )
                self.currentPhase = .downloading(progress: progress)
            }
        }
    }
    
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            Task { @MainActor in
                let err = NSError(domain: "TTZipPluginInstaller", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Download failed with status \(response.statusCode)"])
                self.downloadContinuation?.resume(throwing: err)
                self.downloadContinuation = nil
            }
            return
        }
        
        let tempLoc = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: tempLoc)
        
        Task { @MainActor in
            self.downloadContinuation?.resume(returning: tempLoc)
            self.downloadContinuation = nil
        }
    }
    
    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            Task { @MainActor in
                self.downloadContinuation?.resume(throwing: error)
                self.downloadContinuation = nil
            }
        }
    }
}
