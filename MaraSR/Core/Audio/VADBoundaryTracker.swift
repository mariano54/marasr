import Foundation

struct VADBoundaryTracker: Sendable {
  private(set) var speechStartSample: Int?
  let minimumSpeechSamples: Int
  let softMaxSpeechSamples: Int
  let hardMaxSpeechSamples: Int
  let softSplitProbabilityThreshold: Float
  let softSplitSilenceChunks: Int

  private var emittedUpToSample = 0
  private var consecutiveLowProbChunks = 0
  private var lowestProbInWindow: Float = .infinity
  private var lowestProbSample: Int?

  init(
    minimumSpeechSamples: Int = 3_072,
    softMaxSpeechSamples: Int = 160_000,
    hardMaxSpeechSamples: Int = 232_000,
    softSplitProbabilityThreshold: Float = 0.25,
    softSplitSilenceChunks: Int = 4
  ) {
    self.minimumSpeechSamples = minimumSpeechSamples
    self.softMaxSpeechSamples = softMaxSpeechSamples
    self.hardMaxSpeechSamples = hardMaxSpeechSamples
    self.softSplitProbabilityThreshold = softSplitProbabilityThreshold
    self.softSplitSilenceChunks = softSplitSilenceChunks
  }

  mutating func speechStarted(at sample: Int) {
    if speechStartSample == nil {
      speechStartSample = max(0, sample)
      resetSplitWindow()
    }
  }

  /// Enforces max segment duration during continuous speech (FluidAudio's
  /// streaming VAD does not split on `maxSpeechDuration`). Once a segment
  /// passes `softMaxSpeechSamples`, it splits at the next brief pause in
  /// Silero speech probability, or at the lowest-probability dip by
  /// `hardMaxSpeechSamples` so segments stay inside Parakeet's single-chunk
  /// window and finish transcribing while the user is still speaking.
  mutating func advance(
    to sample: Int,
    speechProbability: Float
  ) -> Range<Int>? {
    guard let start = speechStartSample else {
      resetSplitWindow()
      return nil
    }
    let elapsed = sample - start
    if speechProbability < softSplitProbabilityThreshold {
      consecutiveLowProbChunks += 1
    } else {
      consecutiveLowProbChunks = 0
    }
    guard elapsed >= softMaxSpeechSamples else {
      return nil
    }
    if speechProbability <= lowestProbInWindow {
      lowestProbInWindow = speechProbability
      lowestProbSample = sample
    }
    if consecutiveLowProbChunks >= softSplitSilenceChunks {
      return split(at: sample)
    }
    if elapsed >= hardMaxSpeechSamples {
      return split(at: lowestProbSample ?? sample)
    }
    return nil
  }

  mutating func speechEnded(at sample: Int) -> Range<Int>? {
    guard let start = speechStartSample else {
      return nil
    }
    speechStartSample = nil
    resetSplitWindow()
    let end = max(start, sample)
    guard end > emittedUpToSample, end - start >= minimumSpeechSamples else {
      return nil
    }
    emittedUpToSample = max(emittedUpToSample, end)
    return start..<end
  }

  mutating func finish(at sample: Int) -> Range<Int>? {
    guard let start = speechStartSample else {
      return nil
    }
    speechStartSample = nil
    resetSplitWindow()
    let end = max(start, sample)
    guard end > emittedUpToSample, end - start >= minimumSpeechSamples else {
      return nil
    }
    emittedUpToSample = max(emittedUpToSample, end)
    return start..<end
  }

  mutating func reset() {
    speechStartSample = nil
    emittedUpToSample = 0
    resetSplitWindow()
  }

  private mutating func split(at splitPoint: Int) -> Range<Int>? {
    guard let start = speechStartSample else {
      return nil
    }
    let end = max(start, splitPoint)
    guard end > emittedUpToSample, end - start >= minimumSpeechSamples else {
      return nil
    }
    emittedUpToSample = max(emittedUpToSample, end)
    speechStartSample = end
    resetSplitWindow()
    return start..<end
  }

  private mutating func resetSplitWindow() {
    consecutiveLowProbChunks = 0
    lowestProbInWindow = .infinity
    lowestProbSample = nil
  }
}
