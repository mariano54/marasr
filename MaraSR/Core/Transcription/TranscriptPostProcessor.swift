import Foundation

struct TranscriptPostProcessor: Sendable {
  func process(
    _ text: String,
    glossary: [GlossaryEntry],
    recentTranscripts: [String]
  ) -> String {
    var result = normalizeWhitespace(text)

    for entry in glossary where !entry.canonical.isEmpty {
      let terms = Set(entry.aliases + [entry.canonical])
      for term in terms where !term.isEmpty {
        result = replacingWholeTerm(
          term,
          with: entry.canonical,
          in: result
        )
      }
    }

    let rememberedCasing = casingMemory(from: recentTranscripts)
    for (lowercased, canonical) in rememberedCasing {
      result = replacingWholeTerm(
        lowercased,
        with: canonical,
        in: result
      )
    }

    return normalizeWhitespace(result)
  }

  private func replacingWholeTerm(
    _ term: String,
    with replacement: String,
    in text: String
  ) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: term)
    let pattern = "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
      )
    else {
      return text
    }
    let range = NSRange(text.startIndex..., in: text)
    return expression.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
    )
  }

  private func casingMemory(from transcripts: [String]) -> [String: String] {
    var memory: [String: String] = [:]
    for transcript in transcripts.suffix(5).reversed() {
      let words = transcript.split { !$0.isLetter && !$0.isNumber }
      for wordSlice in words {
        let word = String(wordSlice)
        guard word.count >= 3, hasDistinctiveCasing(word) else {
          continue
        }
        memory[word.lowercased()] = memory[word.lowercased()] ?? word
      }
    }
    return memory
  }

  private func hasDistinctiveCasing(_ word: String) -> Bool {
    let letters = word.filter(\.isLetter)
    guard !letters.isEmpty else {
      return false
    }
    return letters.allSatisfy(\.isUppercase)
      || zip(letters, letters.dropFirst()).contains {
        $0.isLowercase && $1.isUppercase
      }
  }

  private func normalizeWhitespace(_ text: String) -> String {
    text
      .replacingOccurrences(
        of: "\\s+",
        with: " ",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: "\\s+([,.;:!?])",
        with: "$1",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
