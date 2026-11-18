// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import os.log

/// Configuration options governing high-quality animated GIF synthesis.
public struct GIFExportOptions: Sendable, Equatable {
    /// Target frame rate in frames per second (clamped between 10 and 30).
    public let fps: Int
    /// Target width in pixels (clamped between 320 and 720, aspect ratio preserved).
    public let width: Int
    /// Whether to enable ordered Bayer pattern dithering for optimal color gradation.
    public let dither: Bool
    /// Forces native AVAssetImageGenerator + ImageIO extraction instead of external FFmpeg.
    public var preferNativeImageIO: Bool

    /// Initializes GIF export options with hardware-friendly bounds.
    /// - Parameters:
    ///   - fps: Target frame rate in fps (10...30, default: 15).
    ///   - width: Maximum horizontal dimension in pixels (320...720, default: 480).
    ///   - dither: Enable Bayer spatial dithering (default: true).
    ///   - preferNativeImageIO: Force native AVFoundation + ImageIO pipeline (default: false).
    public init(fps: Int = 15, width: Int = 480, dither: Bool = true, preferNativeImageIO: Bool = false) {
        self.fps = min(max(fps, 10), 30)
        self.width = min(max(width, 320), 720)
        self.dither = dither
        self.preferNativeImageIO = preferNativeImageIO
    }
}

/// Strongly-typed failure domains for GIF export pipelines.
public enum GIFExportError: LocalizedError, Sendable {
    case invalidTimeRange(lower: Double, upper: Double)
    case sourceFileNotFound(URL)
    case unsupportedSource(URL, reason: String)
    case ffmpegNotFound
    case processExecutionFailed(exitCode: Int32, standardError: String)
    case cancelled
    case fallbackExtractionFailed(String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeRange(let lower, let upper):
            return "Invalid time range for GIF export: [\(lower), \(upper)]. Upper bound must exceed lower bound."
        case .sourceFileNotFound(let url):
            return "Source media file does not exist at path: \(url.path)"
        case .unsupportedSource(let url, let reason):
            let name = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
            return "Unsupported source for GIF export (\(name)): \(reason)"
        case .ffmpegNotFound:
            return "FFmpeg binary could not be located in application bundle or system PATH."
        case .processExecutionFailed(let code, let err):
            return "FFmpeg process failed with exit code \(code): \(err)"
        case .cancelled:
            return "GIF export operation was cancelled."
        case .fallbackExtractionFailed(let reason):
            return "Fallback frame extraction failed: \(reason)"
        case .encodingFailed(let reason):
            return "ImageIO GIF destination encoding failed: \(reason)"
        }
    }
}

/// High-quality animated GIF export engine with dual-pass PaletteGen optimization
/// and native AVAssetImageGenerator + ImageIO fallback rendering.
public final class GIFExportPipeline: Sendable {
    public static let shared = GIFExportPipeline()
    private let logger = Logger(subsystem: "dev.metastudyline.ttmedia", category: "GIFExportPipeline")

    public init() {}

    // MARK: - Source Compatibility Validation

    /// Validates whether a candidate source URL can be exported as an animated GIF.
    public func validateSourceCompatibility(_ sourceURL: URL) -> Result<Void, GIFExportError> {
        guard sourceURL.isFileURL else {
            return .failure(.unsupportedSource(sourceURL, reason: "Only local video file URLs can be exported as GIF."))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            return .failure(.sourceFileNotFound(sourceURL))
        }
        guard !isDirectory.boolValue else {
            return .failure(.unsupportedSource(sourceURL, reason: "Source path points to a directory rather than a video file."))
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            return .failure(.unsupportedSource(sourceURL, reason: "Source video file is empty (0 bytes)."))
        }
        return .success(())
    }

    // MARK: - Binary Resolution

    /// Discovers system, embedded or Homebrew FFmpeg binary location.
    public func resolveFFmpegBinaryPath() -> String? {
        if let bundlePath = Bundle.main.path(forResource: "ffmpeg", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }
        let macOsBin = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg").path
        if FileManager.default.isExecutableFile(atPath: macOsBin) {
            return macOsBin
        }

        let standardCandidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            "/bin/ffmpeg"
        ]
        for candidate in standardCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.components(separatedBy: ":") {
                let candidate = (dir as NSString).appendingPathComponent("ffmpeg")
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Public Export API

    /// Constructs a temporary staging file URL in the same directory as `destinationURL`
    /// so existing destination files are never removed before a replacement GIF finishes encoding.
    public func makeStagingURL(for destinationURL: URL, token: String = UUID().uuidString) -> URL {
        let baseName = destinationURL.lastPathComponent.isEmpty ? "export" : destinationURL.lastPathComponent
        return destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(baseName).ttmedia-gif-staging-\(token).gif")
    }

    /// Exports the specified time range from a media source to an animated GIF file.
    public func exportGIF(
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL,
        options: GIFExportOptions = GIFExportOptions(),
        stagingURL: URL? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try validateExportRequest(sourceURL: sourceURL, timeRange: timeRange, destinationURL: destinationURL)
        let activeStagingURL = stagingURL ?? makeStagingURL(for: destinationURL)
        try? FileManager.default.removeItem(at: activeStagingURL)
        defer {
            try? FileManager.default.removeItem(at: activeStagingURL)
        }

        try Task.checkCancellation()
        if !options.preferNativeImageIO, let ffmpegPath = resolveFFmpegBinaryPath() {
            logger.info("Executing dual-pass FFmpeg PaletteGen export using \(ffmpegPath)")
            try await exportViaFFmpeg(
                ffmpegPath: ffmpegPath,
                sourceURL: sourceURL,
                timeRange: timeRange,
                destinationURL: activeStagingURL,
                options: options,
                progressHandler: progressHandler
            )
        } else {
            logger.info("Executing native AVAssetImageGenerator + ImageIO GIF export")
            try await exportViaFallback(
                sourceURL: sourceURL,
                timeRange: timeRange,
                destinationURL: activeStagingURL,
                options: options,
                progressHandler: progressHandler
            )
        }
        try Task.checkCancellation()
        try commitStagedOutput(from: activeStagingURL, to: destinationURL)
    }

    private func commitStagedOutput(from stagingURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fm.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            throw GIFExportError.encodingFailed(
                "Failed to commit GIF output to \(destinationURL.path): \(error.localizedDescription)"
            )
        }
    }

    private func validateExportRequest(
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL
    ) throws {
        if case .failure(let compatibilityError) = validateSourceCompatibility(sourceURL) {
            throw compatibilityError
        }
        guard timeRange.upperBound > timeRange.lowerBound else {
            throw GIFExportError.invalidTimeRange(lower: timeRange.lowerBound, upper: timeRange.upperBound)
        }
        let parentDir = destinationURL.deletingLastPathComponent()
        var isParentDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDir.path, isDirectory: &isParentDir),
              isParentDir.boolValue,
              FileManager.default.isWritableFile(atPath: parentDir.path) else {
            throw GIFExportError.encodingFailed("Destination directory does not exist or is not writable: \(parentDir.path)")
        }
    }

    // MARK: - FFmpeg Dual-Pass Pipeline

    private func exportViaFFmpeg(
        ffmpegPath: String,
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL,
        options: GIFExportOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let start = max(0.0, timeRange.lowerBound)
        let duration = max(0.1, timeRange.upperBound - timeRange.lowerBound)
        let startStr = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), start)
        let durationStr = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), duration)

        let tempPaletteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia_palette_\(UUID().uuidString).png")

        defer {
            try? FileManager.default.removeItem(at: tempPaletteURL)
        }

        progressHandler?(0.05)
        let paletteFilter = "fps=\(options.fps),scale=\(options.width):-1:flags=lanczos,palettegen=stats_mode=diff"
        let phase1Args = [
            "-v", "error",
            "-ss", startStr,
            "-t", durationStr,
            "-i", sourceURL.path,
            "-vf", paletteFilter,
            "-update", "1",
            "-y",
            tempPaletteURL.path
        ]

        try await runProcess(executablePath: ffmpegPath, arguments: phase1Args)
        try Task.checkCancellation()
        progressHandler?(0.45)

        let ditherClause = options.dither ? "bayer:bayer_scale=5" : "none"
        let renderLavfi = "fps=\(options.fps),scale=\(options.width):-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=\(ditherClause):diff_mode=rectangle"
        let phase2Args = [
            "-v", "error",
            "-ss", startStr,
            "-t", durationStr,
            "-i", sourceURL.path,
            "-i", tempPaletteURL.path,
            "-lavfi", renderLavfi,
            "-y",
            destinationURL.path
        ]

        try await runProcess(executablePath: ffmpegPath, arguments: phase2Args)
        try Task.checkCancellation()
        progressHandler?(1.0)
    }

    // MARK: - Process Execution with Cancellation

    private func runProcess(executablePath: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try await withTaskCancellationHandler {
            try process.run()

            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    throw GIFExportError.cancelled
                }
                try await Task.sleep(nanoseconds: 30_000_000)
            }

            let status = process.terminationStatus
            if status != 0 {
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw GIFExportError.processExecutionFailed(exitCode: status, standardError: errString)
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    // MARK: - Fallback Native AVAssetImageGenerator + ImageIO Pipeline

    private func exportViaFallback(
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL,
        options: GIFExportOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let start = max(0.0, timeRange.lowerBound)
        let duration = max(0.1, timeRange.upperBound - timeRange.lowerBound)
        let frameCount = max(1, Int((duration * Double(options.fps)).rounded()))
        let frameDelay = duration / Double(frameCount)

        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let encodedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedData as CFMutableData,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw GIFExportError.encodingFailed("Failed to create in-memory CGImageDestination")
        }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        var renderedFrames = 0
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ]
        ]

        for i in 0..<frameCount {
            try Task.checkCancellation()
            let sampleSeconds = start + Double(i) * frameDelay
            let requestedTime = CMTime(seconds: sampleSeconds, preferredTimescale: 600)
            let extractedCG = try? generator.copyCGImage(at: requestedTime, actualTime: nil)
            try Task.checkCancellation()

            if let rawCG = extractedCG,
               let resizedCG = renderResizedCGImage(from: rawCG, targetWidth: options.width) {
                CGImageDestinationAddImage(destination, resizedCG, frameProperties as CFDictionary)
                renderedFrames += 1
            }

            progressHandler?(Double(i + 1) / Double(frameCount))
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        guard renderedFrames > 0 else {
            throw GIFExportError.fallbackExtractionFailed("No frames could be extracted from \(sourceURL.lastPathComponent)")
        }
        guard CGImageDestinationFinalize(destination) else {
            throw GIFExportError.encodingFailed("Failed to finalize GIF image destination at \(destinationURL.path)")
        }

        try Task.checkCancellation()
        do {
            try (encodedData as Data).write(to: destinationURL, options: .atomic)
        } catch {
            throw GIFExportError.encodingFailed("Failed to write GIF data to \(destinationURL.path): \(error.localizedDescription)")
        }
        progressHandler?(1.0)
    }

    private func renderResizedCGImage(from originalCG: CGImage, targetWidth: Int) -> CGImage? {
        let origWidth = Double(originalCG.width)
        let origHeight = Double(originalCG.height)
        guard origWidth > 0, origHeight > 0 else { return nil }

        let scale = Double(targetWidth) / origWidth
        let targetHeight = max(1, Int(round(origHeight * scale)))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return originalCG
        }

        context.interpolationQuality = .high
        context.draw(originalCG, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }
}
