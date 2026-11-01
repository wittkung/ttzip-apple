// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreML

/// Protocol defining asynchronous query vector encoding contracts.
public protocol SemanticQueryEncoding: Sendable {
    /// Encodes a search query string into a 128-dimensional INT8 embedding vector.
    func encode(query: String) async throws -> [Int8]
}

/// Errors occurring during query vector encoding and CoreML inference.
public enum SemanticQueryEncoderError: Error, Sendable, LocalizedError {
    case modelNotAvailable
    case invalidModelInput(String)
    case invalidModelOutput
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotAvailable:
            return "CoreML EmbeddingGemma model is not available."
        case .invalidModelInput(let details):
            return "Invalid model input: \(details)"
        case .invalidModelOutput:
            return "CoreML model output could not be parsed as embedding vectors."
        case .inferenceFailed(let reason):
            return "Model inference failed: \(reason)"
        }
    }
}

/// CoreML-backed query encoder executing on Apple Neural Engine (ANE)
/// using EmbeddingGemma 2 Matryoshka Representation Learning (MRL) truncation.
public struct CoreMLSemanticQueryEncoder: SemanticQueryEncoding {
    private let runner: CoreMLModelRunner

    public init(
        modelURL: URL? = nil,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) {
        self.runner = CoreMLModelRunner(modelURL: modelURL, computeUnits: computeUnits)
    }

    public func encode(query: String) async throws -> [Int8] {
        let (isCode, cleanQuery) = SemanticPromptFormatter.stripCodeQueryPrefix(query)
        guard !cleanQuery.isEmpty else {
            throw SemanticQueryEncoderError.invalidModelInput("Query string is empty")
        }
        let formattedPrompt = isCode
            ? SemanticPromptFormatter.formatCodeQueryPrompt(cleanQuery)
            : SemanticPromptFormatter.formatQueryPrompt(cleanQuery)
        let rawFloats = try await runner.predict(prompt: formattedPrompt)

        // 1. Require at least 128 finite dimensions (never zero-pad short or invalid outputs)
        guard rawFloats.count >= 128, rawFloats.prefix(128).allSatisfy({ $0.isFinite }) else {
            throw SemanticQueryEncoderError.invalidModelOutput
        }
        let truncated = Array(rawFloats.prefix(128))

        // 2. L2 Normalization
        var sumSquares: Float = 0.0
        for val in truncated {
            sumSquares += val * val
        }
        let norm = sqrt(sumSquares)
        guard norm > 1e-9 else {
            throw SemanticQueryEncoderError.invalidModelOutput
        }
        let invNorm = 1.0 / norm

        // 3. Symmetrical scale to INT8: round(v * 127.0)
        var int8Vector = [Int8](repeating: 0, count: 128)
        var hasNonZero = false
        for i in 0..<128 {
            let normalized = truncated[i] * invNorm
            let scaled = round(normalized * 127.0)
            let clamped = Int8(max(-127.0, min(127.0, scaled)))
            if clamped != 0 { hasNonZero = true }
            int8Vector[i] = clamped
        }
        guard hasNonZero else {
            throw SemanticQueryEncoderError.invalidModelOutput
        }

        return int8Vector
    }
}

/// Actor encapsulating CoreML model lifecycle and thread-safe execution on Apple Neural Engine.
private actor CoreMLModelRunner {
    private var model: MLModel?
    private let modelURL: URL?
    private let computeUnits: MLComputeUnits

    init(modelURL: URL?, computeUnits: MLComputeUnits) {
        self.modelURL = modelURL
        self.computeUnits = computeUnits
    }

    func predict(prompt: String) throws -> [Float] {
        let activeModel = try getOrLoadModel()
        return try runInference(model: activeModel, prompt: prompt)
    }

    private func getOrLoadModel() throws -> MLModel {
        if let existing = model {
            return existing
        }
        let loaded = try loadModel()
        self.model = loaded
        return loaded
    }

    private func loadModel() throws -> MLModel {
        guard let resolvedURL = resolveModelURL() else {
            throw SemanticQueryEncoderError.modelNotAvailable
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        do {
            if resolvedURL.pathExtension == "mlpackage" {
                let compiledURL = try MLModel.compileModel(at: resolvedURL)
                return try MLModel(contentsOf: compiledURL, configuration: configuration)
            } else {
                return try MLModel(contentsOf: resolvedURL, configuration: configuration)
            }
        } catch {
            throw SemanticQueryEncoderError.modelNotAvailable
        }
    }

    private func resolveModelURL() -> URL? {
        if let explicitURL = modelURL, FileManager.default.fileExists(atPath: explicitURL.path) {
            return explicitURL
        }

        let modelNames = [
            "EmbeddingGemma2_128_MRL",
            "EmbeddingGemma2",
            "embeddinggemma2",
            "EmbeddingGemma"
        ]

        let extensions = ["mlmodelc", "mlpackage"]

        // Check main bundle resources
        for name in modelNames {
            for ext in extensions {
                if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                    return url
                }
            }
        }

        // Check user Application Support cache directory
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            for name in modelNames {
                for ext in extensions {
                    let candidate = appSupport.appendingPathComponent("TTZip/Models/\(name).\(ext)")
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }

        return nil
    }

    private func runInference(model: MLModel, prompt: String) throws -> [Float] {
        let provider = try createFeatureProvider(model: model, prompt: prompt)

        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw SemanticQueryEncoderError.inferenceFailed("\(error)")
        }

        guard let outputName = output.featureNames.first,
              let feature = output.featureValue(for: outputName),
              let multiArray = feature.multiArrayValue else {
            throw SemanticQueryEncoderError.invalidModelOutput
        }

        let count = multiArray.count
        guard count > 0 else {
            throw SemanticQueryEncoderError.invalidModelOutput
        }

        var floats = [Float]()
        let targetCount = min(128, count)
        floats.reserveCapacity(targetCount)

        switch multiArray.dataType {
        case .float32:
            let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<targetCount {
                floats.append(ptr[i])
            }
        case .double:
            let ptr = multiArray.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<targetCount {
                floats.append(Float(ptr[i]))
            }
        case .float16:
            #if arch(arm64)
            let ptr = multiArray.dataPointer.bindMemory(to: Float16.self, capacity: count)
            for i in 0..<targetCount {
                floats.append(Float(ptr[i]))
            }
            #else
            for i in 0..<targetCount {
                floats.append(multiArray[i].floatValue)
            }
            #endif
        default:
            for i in 0..<targetCount {
                floats.append(multiArray[i].floatValue)
            }
        }

        return floats
    }

    private func createFeatureProvider(model: MLModel, prompt: String) throws -> MLFeatureProvider {
        let inputDescriptions = model.modelDescription.inputDescriptionsByName

        if inputDescriptions.keys.contains("input_ids") {
            let seqLen: Int
            if let constraint = inputDescriptions["input_ids"]?.multiArrayConstraint {
                seqLen = constraint.shape.last?.intValue ?? 32
            } else {
                seqLen = 32
            }

            let inputIds = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
            let attentionMask = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)

            let tokenIds = tokenizeToTokenIds(prompt: prompt, maxLen: seqLen)

            let inputPtr = inputIds.dataPointer.bindMemory(to: Int32.self, capacity: seqLen)
            let maskPtr = attentionMask.dataPointer.bindMemory(to: Int32.self, capacity: seqLen)

            for i in 0..<seqLen {
                if i < tokenIds.count {
                    inputPtr[i] = tokenIds[i]
                    maskPtr[i] = 1
                } else {
                    inputPtr[i] = 0
                    maskPtr[i] = 0
                }
            }

            var featureDict: [String: MLFeatureValue] = [
                "input_ids": MLFeatureValue(multiArray: inputIds)
            ]
            if inputDescriptions.keys.contains("attention_mask") {
                featureDict["attention_mask"] = MLFeatureValue(multiArray: attentionMask)
            }
            return try MLDictionaryFeatureProvider(dictionary: featureDict)
        } else {
            let inputName: String
            if inputDescriptions.keys.contains("text") {
                inputName = "text"
            } else if inputDescriptions.keys.contains("prompt") {
                inputName = "prompt"
            } else if inputDescriptions.keys.contains("query") {
                inputName = "query"
            } else if let first = inputDescriptions.keys.first {
                inputName = first
            } else {
                throw SemanticQueryEncoderError.invalidModelInput("Model description contains no input features.")
            }
            return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(string: prompt)])
        }
    }

    private func tokenizeToTokenIds(prompt: String, maxLen: Int) -> [Int32] {
        var tokens: [Int32] = [2] // Gemma BOS
        tokens.reserveCapacity(maxLen)

        for byte in prompt.utf8 {
            if tokens.count >= maxLen - 1 {
                break
            }
            // In Gemma SentencePiece, single bytes are offset by 3 (vocab 3..258)
            tokens.append(Int32(3 + Int(byte)))
        }

        if tokens.count < maxLen {
            tokens.append(1) // Gemma EOS
        }

        return tokens
    }
}

/// Deterministic mock query encoder for integration testing without model assets.
public struct MockSemanticQueryEncoder: SemanticQueryEncoding {
    public let stubVector: [Int8]?
    public let shouldThrowModelNotAvailable: Bool

    public init(
        stubVector: [Int8]? = nil,
        shouldThrowModelNotAvailable: Bool = false
    ) {
        self.stubVector = stubVector
        self.shouldThrowModelNotAvailable = shouldThrowModelNotAvailable
    }

    public func encode(query: String) async throws -> [Int8] {
        if shouldThrowModelNotAvailable {
            throw SemanticQueryEncoderError.modelNotAvailable
        }
        if let stub = stubVector {
            return stub
        }

        var vec = [Int8](repeating: 0, count: 128)
        let hash = query.utf8.reduce(into: 0) { $0 = ($0 &* 31) &+ Int($1) }
        for i in 0..<128 {
            let v = sin(Double(hash + i)) * 127.0
            vec[i] = Int8(clamping: Int(round(v)))
        }
        return vec
    }
}


