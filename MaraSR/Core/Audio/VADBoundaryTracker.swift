import Foundation

struct VADBoundaryTracker: Sendable {
  private(set) var speechStartSample: Int?
  let minimumSpeechSamples: Int

  init(minimumSpeechSamples: Int = 3_072) {
    self.minimumSpeechSamples = minimumSpeechSamples
  }

  mutating func speechStarted(at sample: Int) {
    if speechStartSample == nil {
      speechStartSample = max(0, sample)
    }
  }

  mutating func speechEnded(at sample: Int) -> Range<Int>? {
    guard let start = speechStartSample else {
      return nil
    }
    speechStartSample = nil
    let end = max(start, sample)
    guard end - start >= minimumSpeechSamples else {
      return nil
    }
    return start..<end
  }

  mutating func finish(at sample: Int) -> Range<Int>? {
    guard let start = speechStartSample else {
      return nil
    }
    speechStartSample = nil
    let end = max(start, sample)
    guard end - start >= minimumSpeechSamples else {
      return nil
    }
    return start..<end
  }

  mutating func reset() {
    speechStartSample = nil
  }
}
