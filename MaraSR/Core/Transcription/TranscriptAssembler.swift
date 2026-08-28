import Foundation

actor TranscriptAssembler {
  private var segments: [Int: String] = [:]

  func append(sequence: Int, text: String) -> String {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.isEmpty {
      segments[sequence] = cleaned
    }
    return Self.merge(segments.keys.sorted().compactMap { segments[$0] })
  }

  func text() -> String {
    Self.merge(segments.keys.sorted().compactMap { segments[$0] })
  }

  func reset() {
    segments.removeAll(keepingCapacity: true)
  }

  static func merge(_ segments: [String]) -> String {
    guard var result = segments.first else {
      return ""
    }

    for segment in segments.dropFirst() {
      result = merge(result, with: segment)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func merge(_ prefix: String, with suffix: String) -> String {
    let prefixWords = prefix.split(separator: " ").map(String.init)
    let suffixWords = suffix.split(separator: " ").map(String.init)
    let maxOverlap = min(8, prefixWords.count, suffixWords.count)

    var overlap = 0
    if maxOverlap > 0 {
      for count in stride(from: maxOverlap, through: 1, by: -1) {
        let left = prefixWords.suffix(count).map(normalizedWord)
        let right = suffixWords.prefix(count).map(normalizedWord)
        if left == right {
          overlap = count
          break
        }
      }
    }

    let remainder = suffixWords.dropFirst(overlap).joined(separator: " ")
    guard !remainder.isEmpty else {
      return prefix
    }
    return prefix + " " + remainder
  }

  private static func normalizedWord(_ word: String) -> String {
    word
      .trimmingCharacters(in: .punctuationCharacters)
      .lowercased()
  }
}
