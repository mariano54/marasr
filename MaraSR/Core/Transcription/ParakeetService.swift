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

  // Keyword boosting is optional: without the CTC model folder MaraSR
  // only applies the text glossary.
  private var ctcModels: CtcModels?
  private var glossary: [GlossaryEntry] = []
  private var boostedGlossary: [GlossaryEntry]?
  private var booster: KeywordBooster?

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
        version: .ultra,
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
      await loadKeywordModels()
      state = .ready
      progress(1, "")
    } catch {
      let mapped = Self.map(error)
      state = .failed(message: mapped.localizedDescription)
      throw mapped
    }
  }

  /// Live previews pass `boostKeywords: false`: they rerun every second over
  /// up to 14 s of audio, and the committed segment is boosted anyway.
  func transcribe(
    samples: [Float],
    boostKeywords: Bool = true
  ) async throws -> String {
    guard let manager else {
      throw ParakeetServiceError.modelNotLoaded
    }
    let decoderLayers = await manager.decoderLayerCount
    var decoderState = TdtDecoderState.make(
      decoderLayers: decoderLayers
    )
    let result = try await manager.transcribe(
      samples,
      decoderState: &decoderState
    )
    guard boostKeywords, let booster, let timings = result.tokenTimings else {
      return result.text
    }
    do {
      let corrected = try await booster.correct(
        text: result.text,
        tokenTimings: timings,
        samples: samples
      )
      if corrected.replaced > 0 {
        Log.models.notice(
          "Keyword boosting replaced \(corrected.replaced, privacy: .public) term(s)"
        )
      }
      return corrected.text
    } catch {
      // Boosting must never cost a dictation.
      Log.models.error(
        "Keyword boosting failed: \(String(describing: error), privacy: .public)"
      )
      return result.text
    }
  }

  /// Sets the glossary used for keyword boosting. Cheap to call repeatedly;
  /// the booster is only rebuilt when the glossary changes.
  func setGlossary(_ entries: [GlossaryEntry]) async {
    glossary = entries
    await rebuildBoosting()
  }

  func currentState() -> State {
    state
  }

  /// Terms the booster is listening for; nil when its model is missing.
  func boostedTermCount() -> Int? {
    ctcModels == nil ? nil : booster?.termCount ?? 0
  }

  private func loadKeywordModels() async {
    let directory = CtcModels.defaultCacheDirectory()
    guard CtcModels.modelsExist(at: directory) else {
      Log.models.notice(
        "Keyword boosting off: no \(directory.lastPathComponent, privacy: .public) model folder"
      )
      return
    }
    do {
      ctcModels = try await CtcModels.load(from: directory)
      await rebuildBoosting()
    } catch {
      Log.models.error(
        "Keyword boosting model failed to load: \(String(describing: error), privacy: .public)"
      )
    }
  }

  private func rebuildBoosting() async {
    guard let ctcModels, glossary != boostedGlossary else {
      return
    }
    let entries = glossary
    boostedGlossary = entries
    do {
      let built = try await KeywordBooster.make(
        glossary: entries,
        models: ctcModels
      )
      // A newer glossary may have arrived while this one was building.
      guard entries == boostedGlossary else {
        return
      }
      booster = built
      Log.models.notice(
        "Keyword boosting ready: \(built?.termCount ?? 0, privacy: .public) terms"
      )
    } catch {
      booster = nil
      Log.models.error(
        "Keyword boosting failed to build: \(String(describing: error), privacy: .public)"
      )
    }
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
