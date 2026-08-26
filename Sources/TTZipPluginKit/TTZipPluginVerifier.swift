// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CryptoKit

/// 插件数字签名与 SHA-256 完整性校验器 (Ed25519 & Safe Hash)
public enum TTZipPluginVerifier {
    public enum VerificationError: Error, Sendable {
        case fileNotFound
        case invalidHash(expected: String, actual: String)
        case invalidSignature
        case invalidPublicKeyData
    }
    
    /// 校验文件 SHA-256 摘要
    public static func verifySHA256(fileURL: URL, expectedHex: String) throws {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw VerificationError.fileNotFound
        }
        let digest = SHA256.hash(data: data)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        if actualHex.lowercased() != expectedHex.lowercased() {
            throw VerificationError.invalidHash(expected: expectedHex, actual: actualHex)
        }
    }
    
    /// 校验 Ed25519 数字签名
    public static func verifyEd25519Signature(
        data: Data,
        signatureData: Data,
        publicKeyBase64: String
    ) throws {
        guard let rawKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKeyData) else {
            throw VerificationError.invalidPublicKeyData
        }
        
        guard publicKey.isValidSignature(signatureData, for: data) else {
            throw VerificationError.invalidSignature
        }
    }
}
