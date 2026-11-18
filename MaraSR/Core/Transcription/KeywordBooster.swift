@preconcurrency import FluidAudio
import Foundation

/// Fixes glossary terms the recognizer misheard ("Sonyox" → "Soniox") by
/// scoring them against the audio with a small CTC model.
///
/// FluidAudio proposes and scores the replacements; `KeywordPolicy` then
/// drops the ones that look like ordinary speech, and only those left are
/// written into the transcript.
struct KeywordBooster: Sendable {
  let termCount: Int
  private let vocabulary: CustomVocabularyContext
  private let spotter: CtcKeywordSpotter
  private let rescorer: VocabularyRescorer
  private let sizeConfig: ContextBiasingConstants.VocabSizeConfig
  private let aliases: [String: [String]]
  private let owners: [String: Set<String>]

  /// Returns nil when no glossary entry is a speakable term.
  static func make(
    glossary: [GlossaryEntry],
    models: CtcModels
  ) async throws -> KeywordBooster? {
    let directory = CtcModels.defaultCacheDirectory(for: models.variant)
    let tokenizer = try await CtcTokenizer.load(from: directory)
    var aliases: [String: [String]] = [:]
    let terms: [CustomVocabularyTerm] = glossary.compactMap { entry in
      let text = entry.canonical.trimmingCharacters(in: .whitespaces)
      guard KeywordPolicy.isSpeakable(text) else {
        return nil
      }
      let tokens = tokenizer.encode(text)
      guard !tokens.isEmpty else {
        return nil
      }
      aliases[text, default: []] += entry.aliases
      return CustomVocabularyTerm(
        text: text,
        aliases: entry.aliases.isEmpty ? nil : entry.aliases,
        ctcTokenIds: tokens
      )
    }
    guard !terms.isEmpty else {
      return nil
    }
    let vocabulary = CustomVocabularyContext(terms: terms)
    let spotter = CtcKeywordSpotter(
      models: models,
      blankId: models.vocabulary.count
    )
    // The spotter-rescue pass swaps in a term on acoustics alone, even when
    // the transcript looks nothing like it. With short terms it turned
    // sentence openings into keywords ("Should I make" → "Soniox").
    let rescorer = try await VocabularyRescorer.create(
      spotter: spotter,
      vocabulary: vocabulary,
      config: VocabularyRescorer.Config(spotterRescueEnabled: false),
      ctcModelDirectory: directory
    )
    return KeywordBooster(
      termCount: terms.count,
      vocabulary: vocabulary,
      spotter: spotter,
      rescorer: rescorer,
      sizeConfig: ContextBiasingConstants.rescorerConfig(
        forVocabSize: terms.count
      ),
      aliases: aliases,
      owners: KeywordPolicy.owners(of: glossary)
    )
  }

  /// Every replacement FluidAudio considered, with its evidence.
  func evaluate(
    text: String,
    tokenTimings: [TokenTiming],
    samples: [Float]
  ) async throws -> VocabularyRescorer.CandidateEvidenceOutput? {
    guard !tokenTimings.isEmpty, !samples.isEmpty else {
      return nil
    }
    let spotted = try await spotter.spotKeywordsWithLogProbs(
      audioSamples: samples,
      customVocabulary: vocabulary,
      minScore: nil
    )
    guard !spotted.logProbs.isEmpty else {
      return nil
    }
    return rescorer.ctcTokenEvaluateCandidates(
      transcript: text,
      tokenTimings: tokenTimings,
      logProbs: spotted.logProbs,
      frameDuration: spotted.frameDuration,
      cbw: sizeConfig.cbw,
      marginSeconds: 0.5,
      minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity)
    )
  }

  /// The replacements FluidAudio applied that also pass `KeywordPolicy`,
  /// as UTF-8 ranges into `output.baseText`.
  func accepted(
    _ output: VocabularyRescorer.CandidateEvidenceOutput
  ) -> [(range: Range<Int>, text: String)] {
    output.candidates.compactMap { candidate in
      guard
        candidate.legacyOutcome == .applied,
        KeywordPolicy.accepts(
          span: candidate.basePhrase,
          term: candidate.canonicalTerm,
          aliases: aliases[candidate.canonicalTerm] ?? [],
          similarity: candidate.similarity
        ),
        !KeywordPolicy.overwritesAnotherTerm(
          span: candidate.basePhrase,
          term: candidate.canonicalTerm,
          owners: owners
        ),
        let range = candidate.baseTextUTF8Range
          ?? KeywordPolicy.uniqueRange(
            of: candidate.basePhrase,
            in: output.baseText
          )
      else {
        return nil
      }
      return (range, candidate.canonicalTerm)
    }
  }

  func correct(
    text: String,
    tokenTimings: [TokenTiming],
    samples: [Float]
  ) async throws -> (text: String, replaced: Int) {
    guard
      let output = try await evaluate(
        text: text,
        tokenTimings: tokenTimings,
        samples: samples
      )
    else {
      return (text, 0)
    }
    let replacements = accepted(output)
    return (
      KeywordPolicy.apply(replacements, to: output.baseText),
      replacements.count
    )
  }
}

enum KeywordPolicy {
  /// Terms someone can say as written. File names and domains
  /// ("deploy.sh", "issen.com") only go through the text glossary: fuzzy
  /// matching would turn "the web server" into "web_server.py".
  static func isSpeakable(_ term: String) -> Bool {
    let trimmed = term.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty
      && trimmed.allSatisfy {
        $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "'"
      }
  }

  /// Whether replacing `span` with `term` looks like fixing a mishearing
  /// rather than rewriting ordinary speech. `similarity` is FluidAudio's
  /// string similarity between the span and the closest spelling.
  static func accepts(
    span: String,
    term: String,
    aliases: [String],
    similarity: Float
  ) -> Bool {
    let spanWords = words(span)
    let spanKey = spanWords.joined()
    guard !spanKey.isEmpty else {
      return false
    }
    let forms = [term] + aliases
    let termKeys = Set(forms.map { words($0).joined() }).subtracting([""])
    // A known alias, or the term split into words ("hammer spoon").
    if termKeys.contains(spanKey) {
      return true
    }
    // With ~100 terms, correctly heard words that merely resemble one
    // ("start" → STT, "German" → Gemma) scored 0.60–0.67, real mishearings
    // mostly above 0.7. Short words collide with acronyms even higher up
    // ("prod" → PRD at 0.75).
    let minimum: Float = spanWords.count == 1 && spanKey.count <= 4 ? 0.8 : 0.7
    guard similarity >= minimum else {
      return false
    }
    // "the router" → "OpenRouter", "in Xcode" → "Xcode": the span swallowed
    // a real word next to the match.
    let termWords = Set(forms.flatMap(words))
    if spanWords.contains(where: {
      functionWords.contains($0) && !termWords.contains($0)
    }) {
      return false
    }
    // "router" in "OpenRouter", "code" in "Xcode": a word that is part of a
    // longer term is almost always just that word.
    return !termKeys.contains {
      $0.contains(spanKey) || spanKey.contains($0)
    }
  }

  /// Single-word glossary spellings and the terms they belong to.
  static func owners(of glossary: [GlossaryEntry]) -> [String: Set<String>] {
    var owners: [String: Set<String>] = [:]
    for entry in glossary {
      let term = entry.canonical.trimmingCharacters(in: .whitespaces)
      for form in [term] + entry.aliases {
        let formWords = words(form)
        if formWords.count == 1 {
          owners[formWords[0], default: []].insert(term)
        }
      }
    }
    return owners
  }

  /// "Open VAD" → "OpenAI": a word that is already another glossary term
  /// was heard right.
  static func overwritesAnotherTerm(
    span: String,
    term: String,
    owners: [String: Set<String>]
  ) -> Bool {
    words(span).contains { word in
      owners[word].map { !$0.subtracting([term]).isEmpty } ?? false
    }
  }

  /// FluidAudio gives no range for some spans ending in "?"; fall back to
  /// the span without edge punctuation when it occurs exactly once.
  static func uniqueRange(of span: String, in text: String) -> Range<Int>? {
    let phrase = span.trimmingCharacters(
      in: .punctuationCharacters.union(.whitespaces)
    )
    guard !phrase.isEmpty else {
      return nil
    }
    let matches = text.ranges(of: phrase).filter { match in
      let before = match.lowerBound > text.startIndex
        ? text[text.index(before: match.lowerBound)] : " "
      let after = match.upperBound < text.endIndex ? text[match.upperBound] : " "
      return !(before.isLetter || before.isNumber || after.isLetter || after.isNumber)
    }
    guard matches.count == 1, let match = matches.first else {
      return nil
    }
    let start = text.utf8.distance(from: text.startIndex, to: match.lowerBound)
    return start..<(start + text[match].utf8.count)
  }

  /// Applies non-overlapping replacements given as UTF-8 byte ranges.
  static func apply(
    _ replacements: [(range: Range<Int>, text: String)],
    to text: String
  ) -> String {
    var bytes = Array(text.utf8)
    for replacement in replacements.sorted(by: {
      $0.range.lowerBound > $1.range.lowerBound
    }) {
      guard
        replacement.range.lowerBound >= 0,
        replacement.range.upperBound <= bytes.count
      else {
        continue
      }
      bytes.replaceSubrange(replacement.range, with: Array(replacement.text.utf8))
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func words(_ text: String) -> [String] {
    text.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  private static let functionWords: Set<String> = [
    "a", "an", "the", "and", "or", "but", "if", "so", "as", "of", "in", "on",
    "at", "to", "for", "from", "by", "with", "into", "onto", "off", "out",
    "up", "over", "about", "is", "are", "was", "be", "it", "its", "this",
    "that", "these", "those", "i", "you", "we", "they", "he", "she", "my",
    "our", "your", "their", "me", "us", "them", "do", "does", "did", "can",
    "will", "not", "no", "just", "then", "than", "there", "what", "which",
  ]
}
