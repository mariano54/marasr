import CoreML
@preconcurrency import FluidAudio
import Foundation

actor ParakeetService {
  enum State: Equatable, Sendable {
    case notLoaded
    case loading(progress: Double, file: String)
    case ready
    case failed(message: String)
  }

  typealias ProgressHandler = @Sendable (_ progress: Double, _ file: String) -> Void

  private var manager: AsrManager?
  private(set) var state: State = .notLoaded

  func prepare(progress: @escaping ProgressHandler) async throws {
    guard manager == nil else {
      state = .ready
      progress(1, "")
      return
    }

    do {
      let configuration = MLModelConfiguration()
      configuration.computeUnits = .cpuAndNeuralEngine
      let models = try await AsrModels.loadFromCache(
        configuration: configuration,
        version: .v3,
        encoderComputeUnits: .cpuAndNeuralEngine
      ) { update in
        progress(
          update.fractionCompleted,
          Self.description(for: update.phase)
        )
      }
      let loaded = AsrManager(config: .default)
      try await loaded.loadModels(models)
      manager = loaded
      state = .ready
      progress(1, "")
    } catch {
      let mapped = Self.map(error)
      state = .failed(message: mapped.localizedDescription)
      throw mapped
    }
  }

  func transcribe(samples: [Float]) async throws -> String {
    guard let manager else {
      throw ParakeetServiceError.modelNotLoaded
    }
    let decoderLayers = await manager.decoderLayerCount
    var decoderState = TdtDecoderState.make(
      decoderLayers: decoderLayers
    )
    return try await manager.transcribe(
      samples,
      decoderState: &decoderState
    ).text
  }

  func currentState() -> State {
    state
  }

  private nonisolated static func map(_ error: Error) -> Error {
    if let downloadError = error as? DownloadError {
      switch downloadError {
      case .modelMissing, .networkDisabled, .modelNotFound:
        return ParakeetServiceError.modelsMissing
      default:
        break
      }
    }
    return error
  }

  private nonisolated static func description(
    for phase: DownloadPhase
  ) -> String {
    switch phase {
    case .listing:
      "Checking local model files"
    case .downloading:
      "Local models are incomplete"
    case .compiling(let modelName):
      "Optimizing \(modelName)"
    }
  }
}

enum ParakeetServiceError: LocalizedError {
  case modelNotLoaded
  case modelsMissing

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      "The Parakeet model is not ready."
    case .modelsMissing:
      "Speech models were not found on this Mac. MaraSR is offline-only and will not download them."
    }
  }
}
