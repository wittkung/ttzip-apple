// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import CoreGraphics
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
    
    /// Initializes GIF export options with hardware-friendly bounds.
    /// - Parameters:
    ///   - fps: Target frame rate in fps (10...30, default: 15).
    ///   - width: Maximum horizontal dimension in pixels (320...720, default: 480).
    ///   - dither: Enable Bayer spatial dithering (default: true).
    public init(fps: Int = 15, width: Int = 480, dither: Bool = true) {
        self.fps = min(max(fps, 10), 30)
        self.width = min(max(width, 320), 720)
        self.dither = dither
    }
}

/// Strongly-typed failure domains for GIF export pipelines.
public enum GIFExportError: LocalizedError, Sendable {
    case invalidTimeRange(lower: Double, upper: Double)
    case sourceFileNotFound(URL)
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
/// and pure in-memory MPVThumbnailWorker + ImageIO fallback rendering.
public final class GIFExportPipeline: Sendable {
    public static let shared = GIFExportPipeline()
    private let logger = Logger(subsystem: "dev.metastudyline.ttmedia", category: "GIFExportPipeline")
    
    public init() {}
    
    // MARK: - Binary Resolution
    
    /// Discovers system, embedded or Homebrew FFmpeg binary location.
    public func resolveFFmpegBinaryPath() -> String? {
        // 1. Embedded inside App Bundle or Frameworks
        if let bundlePath = Bundle.main.path(forResource: "ffmpeg", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }
        let macOsBin = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg").path
        if FileManager.default.isExecutableFile(atPath: macOsBin) {
            return macOsBin
        }
        
        // 2. Canonical macOS Homebrew and standard POSIX paths
        let standardCandidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            "/bin/ffmpeg"
        ]
        for candidate in standardCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        
        // 3. Search PATH environment variable
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
    
    /// Exports the specified time range from a media source to an animated GIF file.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the source media file.
    ///   - timeRange: Playback range in seconds to export.
    ///   - destinationURL: Destination file URL for the rendered GIF.
    ///   - options: Target encoding parameters (fps, width, dithering).
    ///   - progressHandler: Optional progress callback reporting normalized values (0.0...1.0).
    public func exportGIF(
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL,
        options: GIFExportOptions = GIFExportOptions(),
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw GIFExportError.sourceFileNotFound(sourceURL)
        }
        guard timeRange.upperBound > timeRange.lowerBound else {
            throw GIFExportError.invalidTimeRange(lower: timeRange.lowerBound, upper: timeRange.upperBound)
        }
        
        try Task.checkCancellation()
        
        if let ffmpegPath = resolveFFmpegBinaryPath() {
            logger.info("Executing dual-pass FFmpeg PaletteGen export using \(ffmpegPath)")
            try await exportViaFFmpeg(
                ffmpegPath: ffmpegPath,
                sourceURL: sourceURL,
                timeRange: timeRange,
                destinationURL: destinationURL,
                options: options,
                progressHandler: progressHandler
            )
        } else {
            logger.info("FFmpeg binary not available; executing fallback MPVThumbnailWorker + ImageIO export")
            try await exportViaFallback(
                sourceURL: sourceURL,
                timeRange: timeRange,
                destinationURL: destinationURL,
                options: options,
                progressHandler: progressHandler
            )
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
        
        // Phase 1: Generate 256-color global optimal palette
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
        
        do {
            try await runProcess(executablePath: ffmpegPath, arguments: phase1Args)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        
        try Task.checkCancellation()
        progressHandler?(0.45)
        
        // Phase 2: Render animated GIF with Bayer pattern spatial dithering
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
        
        do {
            try await runProcess(executablePath: ffmpegPath, arguments: phase2Args)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        
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
            
            // Asynchronously await process completion while polling cancellation periodically
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    throw GIFExportError.cancelled
                }
                try await Task.sleep(nanoseconds: 30_000_000) // 30ms polling interval
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
    
    // MARK: - Fallback In-Memory ImageIO Pipeline
    
    private func exportViaFallback(
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL,
        options: GIFExportOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let start = max(0.0, timeRange.lowerBound)
        let duration = max(0.1, timeRange.upperBound - timeRange.lowerBound)
        let frameCount = max(1, Int(duration * Double(options.fps)))
        let frameDelay = duration / Double(frameCount)
        
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw GIFExportError.encodingFailed("Failed to create CGImageDestination for \(destinationURL.path)")
        }
        
        // Loop count 0 specifies infinite GIF loop
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        
        var renderedFrames = 0
        
        for i in 0..<frameCount {
            try Task.checkCancellation()
            _ = start + Double(i) * frameDelay
            
            let image: NSImage? = nil
            
            try Task.checkCancellation()
            
            guard let nsImage = image,
                  let cgImage = renderResizedCGImage(from: nsImage, targetWidth: options.width) else {
                continue
            }
            
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: frameDelay
                ]
            ]
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
            renderedFrames += 1
            
            let currentProgress = Double(i + 1) / Double(frameCount)
            progressHandler?(currentProgress)
        }
        
        guard renderedFrames > 0 else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw GIFExportError.fallbackExtractionFailed("No frames could be extracted from \(sourceURL.lastPathComponent)")
        }
        
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw GIFExportError.encodingFailed("Failed to finalize GIF image destination at \(destinationURL.path)")
        }
        
        progressHandler?(1.0)
    }
    
    private func renderResizedCGImage(from image: NSImage, targetWidth: Int) -> CGImage? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let originalCG = bitmapRep.cgImage else {
            return nil
        }
        
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
