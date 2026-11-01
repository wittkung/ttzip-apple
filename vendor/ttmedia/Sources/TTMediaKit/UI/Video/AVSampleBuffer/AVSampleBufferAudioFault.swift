// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreMedia

/// Classification of isolatable audio faults that must not halt video playback.
public enum AVSampleBufferAudioFaultKind: String, Sendable, Equatable {
    case unsupportedAudioTrack
    case audioInitializationFailed
}

/// The pipeline stage at which an isolatable audio fault was detected.
///
/// The stage is reported instead of a single generic "initialization failed" message because
/// the stages fail for different reasons and need different remedies: a track that CoreAudio
/// cannot decode at all, a format description the system rejects, a sample buffer the
/// renderer refuses, and a pipeline that stalls while media is already queued.
public enum AVSampleBufferAudioFaultStage: String, Sendable, Equatable, CaseIterable {
    /// The audio track could not be selected or is not decodable by the system decoder.
    case trackSelection
    /// The CoreMedia audio format description could not be created.
    case formatDescription
    /// The sample buffer could not be created or handed to the renderer.
    case sampleBufferEnqueue
    /// The renderer itself reported a failure after the media was accepted.
    case rendererFailure
    /// The pipeline stalled: media was queued but the master clock never advanced.
    case pipelineStall
}

/// Structured descriptor for an isolatable audio fault.
public struct AVSampleBufferAudioFault: Error, LocalizedError, Sendable, Equatable {
    public let kind: AVSampleBufferAudioFaultKind
    /// The pipeline stage that detected the fault.
    public let stage: AVSampleBufferAudioFaultStage
    public let codecName: String?
    public let statusCode: Int32?
    public let diagnosticDetail: String
    /// The sample rate the system decoder was configured with, in Hz.
    public let sampleRateHz: Double?
    /// The channel count the system decoder was configured with.
    public let channelCount: Int?

    public init(
        kind: AVSampleBufferAudioFaultKind,
        stage: AVSampleBufferAudioFaultStage = .trackSelection,
        codecName: String? = nil,
        statusCode: Int32? = nil,
        diagnosticDetail: String,
        sampleRateHz: Double? = nil,
        channelCount: Int? = nil
    ) {
        self.kind = kind
        self.stage = stage
        self.codecName = codecName
        self.statusCode = statusCode
        self.diagnosticDetail = diagnosticDetail
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
    }

    public var errorDescription: String? {
        diagnosticDetail
    }
}

/// Errors occurring during audio pipeline processing.
public enum AVSampleBufferAudioPipelineError: LocalizedError, Sendable, Equatable {
    case unsupportedCodec(String)
    case missingCodecConfiguration(String)
    case invalidCodecConfiguration(String)
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case formatDescriptionFailed(OSStatus)
    case rendererFailed(OSStatus, String)
    case emptyPayload

    public var errorDescription: String? {
        switch self {
        case .unsupportedCodec(let codec):
            return "Unsupported audio codec: \(codec)"
        case .missingCodecConfiguration(let detail):
            return "Missing audio codec configuration: \(detail)"
        case .invalidCodecConfiguration(let detail):
            return "Invalid audio codec configuration: \(detail)"
        case .blockBufferFailed(let status):
            return "Block buffer creation failed with OSStatus: \(status)"
        case .sampleBufferFailed(let status):
            return "Sample buffer creation failed with OSStatus: \(status)"
        case .formatDescriptionFailed(let status):
            return "Audio format description creation failed with OSStatus: \(status)"
        case .rendererFailed(let status, let detail):
            return "Audio renderer failed (OSStatus \(status)): \(detail)"
        case .emptyPayload:
            return "Audio packet payload is empty"
        }
    }
}

extension AudioCodec {
    /// Whether the system CoreAudio decoder can decode this format.
    ///
    /// `AVSampleBufferAudioRenderer` decodes through CoreAudio, so only the formats macOS
    /// ships a decoder for can ever produce sound. Vorbis is not among them. DTS and TrueHD
    /// are not representable in this enumeration at all, so they never reach the decoder and
    /// are rejected earlier as an unsupported track.
    public var isDecodableBySystemAudioDecoder: Bool {
        switch self {
        case .aac, .alac, .flac, .opus, .ac3, .eac3, .pcm:
            return true
        case .vorbis:
            return false
        }
    }
}

extension AVSampleBufferAudioPipeline {
    /// The fault semantics of one audio pipeline error.
    ///
    /// The semantics are the part that belongs to the error itself: which kind of fault it
    /// is, at which stage it happened, the raw `OSStatus` when the platform reported one, and
    /// the first cause. The shared context (codec, sample rate, channel count) is assembled
    /// once by the caller, not repeated per error.
    private struct AVSampleBufferAudioFaultSemantics {
        let kind: AVSampleBufferAudioFaultKind
        let stage: AVSampleBufferAudioFaultStage
        /// The codec the error itself names, when it names one.
        let codecName: String?
        let statusCode: Int32?
        let diagnosticDetail: String
    }

    /// Maps an audio pipeline error onto its fault semantics.
    ///
    /// Each pipeline error carries the stage it happened in, so the reported fault names the
    /// actual failure point instead of collapsing every failure into one message.
    private static func faultSemantics(
        for pipelineError: AVSampleBufferAudioPipelineError
    ) -> AVSampleBufferAudioFaultSemantics {
        switch pipelineError {
        case .unsupportedCodec(let codec):
            return AVSampleBufferAudioFaultSemantics(
                kind: .unsupportedAudioTrack,
                stage: .trackSelection,
                codecName: codec,
                statusCode: nil,
                diagnosticDetail: pipelineError.localizedDescription
            )
        case .missingCodecConfiguration(let detail):
            return AVSampleBufferAudioFaultSemantics(
                kind: .audioInitializationFailed,
                stage: .formatDescription,
                codecName: nil,
                statusCode: nil,
                diagnosticDetail: detail
            )
        case .invalidCodecConfiguration(let detail):
            return AVSampleBufferAudioFaultSemantics(
                kind: .audioInitializationFailed,
                stage: .formatDescription,
                codecName: nil,
                statusCode: -50,
                diagnosticDetail: detail
            )
        case .formatDescriptionFailed(let status):
            return AVSampleBufferAudioFaultSemantics(
                kind: .audioInitializationFailed,
                stage: .formatDescription,
                codecName: nil,
                statusCode: status,
                diagnosticDetail: pipelineError.localizedDescription
            )
        case .blockBufferFailed(let status), .sampleBufferFailed(let status):
            return AVSampleBufferAudioFaultSemantics(
                kind: .audioInitializationFailed,
                stage: .sampleBufferEnqueue,
                codecName: nil,
                statusCode: status,
                diagnosticDetail: pipelineError.localizedDescription
            )
        case .rendererFailed(let status, let detail):
            return AVSampleBufferAudioFaultSemantics(
                kind: .audioInitializationFailed,
                stage: .rendererFailure,
                codecName: nil,
                statusCode: status,
                diagnosticDetail: detail
            )
        case .emptyPayload:
            return AVSampleBufferAudioFaultSemantics(
                kind: .audioInitializationFailed,
                stage: .sampleBufferEnqueue,
                codecName: nil,
                statusCode: nil,
                diagnosticDetail: pipelineError.localizedDescription
            )
        }
    }

    /// Maps an audio pipeline error into a structured `AVSampleBufferAudioFault`.
    ///
    /// The shared context is assembled exactly once, so every error reports the same codec,
    /// sample rate and channel count, and the error's own semantics stay authoritative for
    /// the kind, the stage, the `OSStatus` and the first cause.
    public static func classifyFault(
        from error: Error,
        codecName: String? = nil,
        sampleRateHz: Double? = nil,
        channelCount: Int? = nil
    ) -> AVSampleBufferAudioFault {
        if let fault = error as? AVSampleBufferAudioFault {
            return fault
        }
        let semantics = (error as? AVSampleBufferAudioPipelineError).map(faultSemantics(for:))
            ?? AVSampleBufferAudioFaultSemantics(
                kind: .audioInitializationFailed,
                stage: .sampleBufferEnqueue,
                codecName: nil,
                statusCode: nil,
                diagnosticDetail: error.localizedDescription
            )
        return AVSampleBufferAudioFault(
            kind: semantics.kind,
            stage: semantics.stage,
            codecName: semantics.codecName ?? codecName,
            statusCode: semantics.statusCode,
            diagnosticDetail: semantics.diagnosticDetail,
            sampleRateHz: sampleRateHz,
            channelCount: channelCount
        )
    }
}
