import CoreML
@preconcurrency import FluidAudio
import Foundation

struct SpeechSegment: Sendable {
  let sequence: Int
  let samples: [Float]
}

actor SileroVADService {
  private let segmentationConfig = VadSegmentationConfig(
    minSpeechDuration: 0.192,
    minSilenceDuration: 0.384,
    maxSpeechDuration: 14,
    speechPadding: 0.12,
    silenceThresholdForSplit: 0.3,
    negativeThreshold: nil,
    negativeThresholdOffset: 0.15,
    minSilenceAtMaxSpeech: 0.098,
    useMaxPossibleSilenceAtMaxSpeech: true
  )

  private var manager: VadManager?
  private var streamState = VadStreamState.initial()
  private var boundaryTracker = VADBoundaryTracker()
  private var allSamples: [Float] = []
  private var analysisBuffer: [Float] = []
  private var nextSequence = 0
  private var lastPreviewSampleCount = 0

  func prepare() async throws {
    guard manager == nil else {
      return
    }
    do {
      manager = try await VadManager(
        config: VadConfig(
          defaultThreshold: 0.5,
          debugMode: false,
          computeUnits: .cpuOnly
        )
      )
      streamState = .initial()
    } catch {
      if let downloadError = error as? DownloadError {
        switch downloadError {
        case .modelMissing, .networkDisabled, .modelNotFound:
          throw SileroVADError.modelsMissing
        default:
          break
        }
      }
      throw error
    }
  }

  func startTurn() async {
    allSamples.removeAll(keepingCapacity: true)
    analysisBuffer.removeAll(keepingCapacity: true)
    boundaryTracker.reset()
    nextSequence = 0
    lastPreviewSampleCount = 0
    if let manager {
      streamState = await manager.makeStreamState()
    } else {
      streamState = .initial()
    }
  }

  func append(_ samples: [Float]) async throws -> [SpeechSegment] {
    guard !samples.isEmpty else {
      return []
    }
    allSamples.append(contentsOf: samples)
    analysisBuffer.append(contentsOf: samples)

    var segments: [SpeechSegment] = []
    while analysisBuffer.count >= VadManager.chunkSize {
      let chunk = Array(analysisBuffer.prefix(VadManager.chunkSize))
      analysisBuffer.removeFirst(VadManager.chunkSize)
      if let segment = try await process(chunk) {
        segments.append(segment)
      }
    }
    return segments
  }

  func previewSamplesIfNeeded() -> [Float]? {
    guard let start = boundaryTracker.speechStartSample else {
      return nil
    }
    let previewInterval = 16_000
    guard allSamples.count - lastPreviewSampleCount >= previewInterval,
      allSamples.count - start >= boundaryTracker.minimumSpeechSamples
    else {
      return nil
    }
    lastPreviewSampleCount = allSamples.count
    let previewStart = max(start, allSamples.count - 224_000)
    return Array(allSamples[previewStart..<allSamples.count])
  }

  func finishTurn() async throws -> [SpeechSegment] {
    var segments: [SpeechSegment] = []
    if !analysisBuffer.isEmpty {
      let remainder = analysisBuffer
      analysisBuffer.removeAll(keepingCapacity: true)
      if let segment = try await process(remainder) {
        segments.append(segment)
      }
    }

    if let range = boundaryTracker.finish(at: allSamples.count),
      let segment = makeSegment(range: range)
    {
      segments.append(segment)
    } else if segments.isEmpty,
      let range = energyFallbackRange(in: allSamples),
      let segment = makeSegment(range: range)
    {
      segments.append(segment)
    }
    return segments
  }

  private func process(_ chunk: [Float]) async throws -> SpeechSegment? {
    guard let manager else {
      throw SileroVADError.notPrepared
    }
    let result = try await manager.processStreamingChunk(
      chunk,
      state: streamState,
      config: segmentationConfig,
      returnSeconds: false
    )
    streamState = result.state

    guard let event = result.event else {
      return nil
    }
    switch event.kind {
    case .speechStart:
      boundaryTracker.speechStarted(at: event.sampleIndex)
      return nil
    case .speechEnd:
      guard
        let range = boundaryTracker.speechEnded(
          at: event.sampleIndex
        )
      else {
        return nil
      }
      return makeSegment(range: range)
    }
  }

  private func makeSegment(range: Range<Int>) -> SpeechSegment? {
    let lower = min(max(0, range.lowerBound), allSamples.count)
    let upper = min(max(lower, range.upperBound), allSamples.count)
    guard upper > lower else {
      return nil
    }

    let samples = trimSilenceEdges(Array(allSamples[lower..<upper]))
    guard samples.count >= boundaryTracker.minimumSpeechSamples else {
      return nil
    }
    defer { nextSequence += 1 }
    return SpeechSegment(sequence: nextSequence, samples: samples)
  }

  private func trimSilenceEdges(_ samples: [Float]) -> [Float] {
    let frameSize = 320
    let padding = 1_920
    let frameLevels = stride(
      from: 0,
      to: samples.count,
      by: frameSize
    ).map { start -> Float in
      let end = min(start + frameSize, samples.count)
      let frame = samples[start..<end]
      return sqrt(
        frame.reduce(Float.zero) { $0 + ($1 * $1) }
          / Float(frame.count)
      )
    }
    let threshold: Float = 0.004
    guard let first = frameLevels.firstIndex(where: { $0 >= threshold }),
      let last = frameLevels.lastIndex(where: { $0 >= threshold })
    else {
      return []
    }
    let start = max(0, first * frameSize - padding)
    let end = min(samples.count, (last + 1) * frameSize + padding)
    return Array(samples[start..<end])
  }

  private func energyFallbackRange(
    in samples: [Float]
  ) -> Range<Int>? {
    guard samples.count >= boundaryTracker.minimumSpeechSamples else {
      return nil
    }
    let rootMeanSquare = sqrt(
      samples.reduce(Float.zero) { $0 + ($1 * $1) }
        / Float(samples.count)
    )
    guard rootMeanSquare >= 0.004 else {
      return nil
    }
    return 0..<samples.count
  }
}

enum SileroVADError: LocalizedError {
  case notPrepared
  case modelsMissing

  var errorDescription: String? {
    switch self {
    case .notPrepared:
      "Voice activity detection is not ready."
    case .modelsMissing:
      "Speech models were not found on this Mac. MaraSR is offline-only and will not download them."
    }
  }
}
