// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CryptoKit

public enum TTZipPluginSecurity {
    public enum SecurityError: LocalizedError, Sendable {
        case fileNotFound(URL)
        case hashMismatch(expected: String, actual: String)
        case invalidSignature
        case invalidPublicKey
        case zipSlipDetected(path: String)
        case corruptArchive(String)
        case unsupportedCompressionMethod(UInt16)
        case decompressionFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "未找到目标文件: \(url.path)"
            case .hashMismatch(let expected, let actual):
                return "SHA-256 完整性哈希校验不匹配 (期望: \(expected.prefix(8))..., 实际: \(actual.prefix(8))...)"
            case .invalidSignature:
                return "Ed25519 官方数字签名验证失败，插件包可能已被篡改或非官方发布！"
            case .invalidPublicKey:
                return "无效的 Ed25519 发布者公钥"
            case .zipSlipDetected(let path):
                return "检测到 Zip Slip 路径穿越攻击，非法目标路径: \(path)"
            case .corruptArchive(let reason):
                return "ZIP 归档格式损坏或结构异常: \(reason)"
            case .unsupportedCompressionMethod(let method):
                return "不支持的 ZIP 压缩算法代码: \(method)"
            case .decompressionFailed(let details):
                return "ZIP 内存解压失败: \(details)"
            }
        }
    }
    
    /// 1. O(1) 内存分块流式 SHA-256 计算与校验
    public static func verifyStreamingSHA256(fileURL: URL, expectedHex: String, bufferSize: Int = 64 * 1024) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SecurityError.fileNotFound(fileURL)
        }
        
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        
        let actualHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if actualHex.lowercased() != expectedHex.lowercased() {
            throw SecurityError.hashMismatch(expected: expectedHex, actual: actualHex)
        }
    }
    
    /// 2. 基于 Apple CryptoKit 的 Ed25519 数字签名验证
    public static func verifyEd25519(
        archiveFileURL: URL,
        signatureBase64: String,
        trustedPublicKeyBase64: String
    ) throws {
        guard let keyData = Data(base64Encoded: trustedPublicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw SecurityError.invalidPublicKey
        }
        guard let signatureData = Data(base64Encoded: signatureBase64) else {
            throw SecurityError.invalidSignature
        }
        
        let fileData = try Data(contentsOf: archiveFileURL)
        guard publicKey.isValidSignature(signatureData, for: fileData) else {
            throw SecurityError.invalidSignature
        }
    }
    
    /// 3. Zip Slip 路径规范化安全检测
    public static func validateSafeDestination(entryRelativePath: String, stagingRoot: URL) throws -> URL {
        let targetURL = stagingRoot.appendingPathComponent(entryRelativePath).standardizedFileURL
        let canonicalStaging = stagingRoot.standardizedFileURL
        
        guard targetURL.path.hasPrefix(canonicalStaging.path) else {
            throw SecurityError.zipSlipDetected(path: entryRelativePath)
        }
        return targetURL
    }
}
