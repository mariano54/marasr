import Foundation

struct TranscriptPostProcessor: Sendable {
  private let matchers = GlossaryMatcherCache()

  func process(
    _ text: String,
    glossary: [GlossaryEntry],
    recentTranscripts: [String]
  ) -> String {
    var result = normalizeWhitespace(text)

    if let matcher = matchers.matcher(for: glossary) {
      result = matcher.apply(to: result)
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

/// Every glossary spelling in one case-insensitive pass. Longer forms are
/// tried first, so "smart turn dot py" becomes the file name before
/// "smart turn" alone can match.
struct GlossaryMatcher: @unchecked Sendable {
  // NSRegularExpression is immutable and safe to match from any thread.
  private let expression: NSRegularExpression
  private let canonicalByForm: [String: String]

  init?(glossary: [GlossaryEntry]) {
    var canonicalByForm: [String: String] = [:]
    for entry in glossary where !entry.canonical.isEmpty {
      for form in [entry.canonical] + entry.aliases where !form.isEmpty {
        let key = form.lowercased()
        if canonicalByForm[key] == nil {
          canonicalByForm[key] = entry.canonical
        }
      }
    }
    let alternatives = canonicalByForm.keys
      .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
      .map(NSRegularExpression.escapedPattern(for:))
    guard
      !alternatives.isEmpty,
      let expression = try? NSRegularExpression(
        pattern:
          "(?<![\\p{L}\\p{N}_])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}_])",
        options: [.caseInsensitive]
      )
    else {
      return nil
    }
    self.expression = expression
    self.canonicalByForm = canonicalByForm
  }

  func apply(to text: String) -> String {
    let source = text as NSString
    var result = ""
    var position = 0
    for match in expression.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    ) {
      result += source.substring(
        with: NSRange(
          location: position,
          length: match.range.location - position
        )
      )
      let found = source.substring(with: match.range)
      result += canonicalByForm[found.lowercased()] ?? found
      position = match.range.location + match.range.length
    }
    return result + source.substring(from: position)
  }
}

/// Keeps the compiled matcher until the glossary changes; rebuilding the
/// patterns for a few hundred aliases on every transcript took ~0.4 s.
private final class GlossaryMatcherCache: @unchecked Sendable {
  private let lock = NSLock()
  private var glossary: [GlossaryEntry]?
  private var matcher: GlossaryMatcher?

  func matcher(for glossary: [GlossaryEntry]) -> GlossaryMatcher? {
    lock.withLock {
      if glossary != self.glossary {
        self.glossary = glossary
        matcher = GlossaryMatcher(glossary: glossary)
      }
      return matcher
    }
  }
}
