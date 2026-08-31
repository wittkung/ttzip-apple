// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CryptoKit

/// Cryptographic integrity, Ed25519 signature verification, and path traversal security gate for plugins.
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
                return "Target file not found: \(url.path)"
            case .hashMismatch(let expected, let actual):
                return "SHA-256 integrity hash mismatch (expected: \(expected.prefix(8))..., actual: \(actual.prefix(8))...)"
            case .invalidSignature:
                return "Ed25519 signature verification failed. The plugin archive may have been modified or is from an untrusted source."
            case .invalidPublicKey:
                return "Invalid Ed25519 publisher public key."
            case .zipSlipDetected(let path):
                return "Zip Slip path traversal attack detected for illegal target path: \(path)"
            case .corruptArchive(let reason):
                return "ZIP archive is corrupted or structurally invalid: \(reason)"
            case .unsupportedCompressionMethod(let method):
                return "Unsupported ZIP compression method code: \(method)"
            case .decompressionFailed(let details):
                return "ZIP in-memory decompression failed: \(details)"
            }
        }
    }
    
    /// Computes streaming SHA-256 digest in O(1) resident memory using 64KB micro-buffers.
    public static func computeStreamingSHA256(fileURL: URL, bufferSize: Int = 64 * 1024) throws -> SHA256Digest {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SecurityError.fileNotFound(fileURL)
        }
        
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        while let chunk = try fileHandle.read(upToCount: bufferSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
    
    /// 1. O(1) resident memory chunked streaming SHA-256 calculation and verification.
    public static func verifyStreamingSHA256(fileURL: URL, expectedHex: String, bufferSize: Int = 64 * 1024) throws {
        let digest = try computeStreamingSHA256(fileURL: fileURL, bufferSize: bufferSize)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        if actualHex.lowercased() != expectedHex.lowercased() {
            throw SecurityError.hashMismatch(expected: expectedHex, actual: actualHex)
        }
    }
    
    /// 2. Apple CryptoKit Ed25519 digital signature verification using memory mapping / streaming digest to avoid full resident RAM allocation.
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
        guard FileManager.default.fileExists(atPath: archiveFileURL.path) else {
            throw SecurityError.fileNotFound(archiveFileURL)
        }
        
        // Zero-copy memory mapped buffer to prevent heap memory exhaustion on large archives
        let mappedData = try Data(contentsOf: archiveFileURL, options: .alwaysMapped)
        if publicKey.isValidSignature(signatureData, for: mappedData) {
            return
        }
        
        // Fallback check against streaming SHA-256 digest
        let digest = try computeStreamingSHA256(fileURL: archiveFileURL)
        let digestData = Data(digest)
        if publicKey.isValidSignature(signatureData, for: digestData) {
            return
        }
        
        throw SecurityError.invalidSignature
    }
    
    /// Direct in-memory Ed25519 signature verification compatibility helper.
    public static func verifyEd25519Signature(
        data: Data,
        signatureData: Data,
        publicKeyBase64: String
    ) throws {
        guard let rawKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKeyData) else {
            throw SecurityError.invalidPublicKey
        }
        guard publicKey.isValidSignature(signatureData, for: data) else {
            throw SecurityError.invalidSignature
        }
    }
    
    /// 3. Zip Slip path canonicalization security check.
    public static func validateSafeDestination(entryRelativePath: String, stagingRoot: URL) throws -> URL {
        let targetURL = stagingRoot.appendingPathComponent(entryRelativePath).standardizedFileURL
        let canonicalStaging = stagingRoot.standardizedFileURL
        
        guard targetURL.path.hasPrefix(canonicalStaging.path) else {
            throw SecurityError.zipSlipDetected(path: entryRelativePath)
        }
        return targetURL
    }
}
