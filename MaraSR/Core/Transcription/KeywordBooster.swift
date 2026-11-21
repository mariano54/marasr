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
  private let terms: [CustomVocabularyTerm]
  private let minSimilarityFloor: Float
  private let spotter: CtcKeywordSpotter
  private let emptyVocabulary: CustomVocabularyContext
  private let ctcDirectory: URL
  private let candidateIndex: KeywordCandidateIndex
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
    let sizeConfig = ContextBiasingConstants.rescorerConfig(
      forVocabSize: terms.count
    )
    return KeywordBooster(
      termCount: terms.count,
      terms: terms,
      minSimilarityFloor: max(sizeConfig.minSimilarity, vocabulary.minSimilarity),
      spotter: spotter,
      emptyVocabulary: CustomVocabularyContext(terms: []),
      ctcDirectory: directory,
      candidateIndex: KeywordCandidateIndex(
        terms: terms,
        minTermLength: vocabulary.minTermLength,
        aliases: aliases,
        owners: KeywordPolicy.owners(of: glossary)
      ),
      sizeConfig: sizeConfig,
      aliases: aliases,
      owners: KeywordPolicy.owners(of: glossary)
    )
  }

  /// Every replacement FluidAudio considered, with its evidence.
  ///
  /// Pre-filters the vocabulary against the transcript words before running
  /// CTC inference or FluidAudio's term-centric rescorer. Segments with no
  /// candidate spans skip the CTC pass completely; segments with candidates
  /// run CTC without the unused full-vocab spotter loop and rescore only the
  /// matching terms.
  func evaluate(
    text: String,
    tokenTimings: [TokenTiming],
    samples: [Float]
  ) async throws -> VocabularyRescorer.CandidateEvidenceOutput? {
    guard !tokenTimings.isEmpty, !samples.isEmpty else {
      return nil
    }
    let words = KeywordCandidateIndex.extractWords(from: tokenTimings)
    let activeIndices = candidateIndex.activeTermIndices(
      for: words,
      minSimilarity: minSimilarityFloor
    )
    guard !activeIndices.isEmpty else {
      return nil
    }
    let filteredTerms = activeIndices.map { terms[$0] }
    // The spotter-rescue pass is off, so we only need CTC log-probs (pass an
    // empty vocabulary to skip the unused full-vocabulary DP scan). Build the
    // small filtered rescorer concurrently with CTC inference.
    async let spottedTask = spotter.spotKeywordsWithLogProbs(
      audioSamples: samples,
      customVocabulary: emptyVocabulary,
      minScore: nil
    )
    async let rescorerTask = VocabularyRescorer.create(
      spotter: spotter,
      vocabulary: CustomVocabularyContext(terms: filteredTerms),
      config: VocabularyRescorer.Config(spotterRescueEnabled: false),
      ctcModelDirectory: ctcDirectory
    )
    let (spotted, rescorer) = try await (spottedTask, rescorerTask)
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
      minSimilarity: minSimilarityFloor
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
    "up", "over", "about", "is", "are", "was", "were", "be", "it", "its", "this",
    "that", "these", "those", "i", "you", "we", "they", "he", "she", "my",
    "our", "your", "their", "me", "us", "them", "do", "does", "did", "can",
    "will", "not", "no", "just", "then", "than", "there", "what", "which",
  ]
}

/// Fast pre-filter over the glossary that mirrors FluidAudio's term-centric
/// similarity matching using length bounds, ASCII character bitmasks, and
/// bounded scalar Levenshtein distance.
///
/// FluidAudio's rescorer scans every `(term, alias, word span)` pair with full
/// Levenshtein distance (~1 s on a 29 s segment with ~1,200 forms). Filtering
/// down to only the terms that can match a span in the transcript cuts ordinary
/// segments to < 1 ms and keeps matching segments to a handful of terms.
struct KeywordCandidateIndex: Sendable {
  private struct IndexedForm: Sendable {
    let termIndex: Int
    let normalized: String
    let scalars: [UInt32]
    let mask: UInt64
    let wordCount: Int
    let allows2WordCompound: Bool
    let allows3WordCompound: Bool
    let isCanonical: Bool
  }

  private struct Query: Sendable {
    let span: String
    let normalized: String
    let scalars: [UInt32]
    let mask: UInt64
  }

  private let termCount: Int
  private let termTexts: [String]
  private let termAliases: [[String]]
  private let canonicalNormalized: [String]
  private let owners: [String: Set<String>]
  private let singleWordForms: [IndexedForm]
  private let multiWordForms: [IndexedForm]
  private let exactTermIndicesByNormalized: [String: [Int]]

  init(
    terms: [CustomVocabularyTerm],
    minTermLength: Int,
    aliases: [String: [String]] = [:],
    owners: [String: Set<String>] = [:]
  ) {
    self.termCount = terms.count
    self.owners = owners
    var texts: [String] = []
    texts.reserveCapacity(terms.count)
    var aliasList: [[String]] = []
    aliasList.reserveCapacity(terms.count)
    var canonicals: [String] = []
    canonicals.reserveCapacity(terms.count)
    var singleForms: [IndexedForm] = []
    var multiForms: [IndexedForm] = []
    var exactMap: [String: [Int]] = [:]

    for (index, term) in terms.enumerated() {
      texts.append(term.text)
      aliasList.append(aliases[term.text] ?? term.aliases ?? [])
      let canonical = Self.normalize(term.text)
      canonicals.append(canonical)
      guard term.text.count >= minTermLength else {
        continue
      }

      var seen: Set<String> = []
      let rawForms = [term.text] + (term.aliases ?? [])
      for raw in rawForms {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty, seen.insert(normalized).inserted else {
          continue
        }
        exactMap[normalized, default: []].append(index)
        let scalars = Self.scalars(of: normalized)
        let form = IndexedForm(
          termIndex: index,
          normalized: normalized,
          scalars: scalars,
          mask: Self.asciiMask(of: scalars),
          wordCount: normalized.split(separator: " ").count,
          allows2WordCompound: term.text.count >= 4,
          allows3WordCompound: term.text.count >= 8,
          isCanonical: normalized == canonical
        )
        if form.wordCount > 1 {
          multiForms.append(form)
        } else {
          singleForms.append(form)
        }
      }
    }

    self.termTexts = texts
    self.termAliases = aliasList
    self.canonicalNormalized = canonicals
    self.singleWordForms = singleForms
    self.multiWordForms = multiForms
    self.exactTermIndicesByNormalized = exactMap
  }

  /// Reconstructs the exact word sequence FluidAudio builds from `TokenTiming`.
  static func extractWords(from tokenTimings: [TokenTiming]) -> [String] {
    var words: [String] = []
    var current = ""
    for timing in tokenTimings {
      let token = timing.token
      if token.isEmpty || token == "<blank>" || token == "<pad>" {
        continue
      }
      let startsNewWord = isWordBoundary(token) || current.isEmpty
      if startsNewWord && !current.isEmpty {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          words.append(trimmed)
        }
        current = ""
      }
      if startsNewWord {
        current = stripWordBoundaryPrefix(token)
      } else {
        current += token
      }
    }
    let trimmed = current.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty {
      words.append(trimmed)
    }
    return words
  }

  /// Returns the sorted glossary term indices that have at least one candidate
  /// span in `words` (plus any exact-matched terms so FluidAudio's cross-term
  /// guard remains identical). Returns an empty array when no term can match.
  func activeTermIndices(
    for rawWords: [String],
    minSimilarity: Float
  ) -> [Int] {
    guard termCount > 0, !rawWords.isEmpty else {
      return []
    }
    let normalizedWords = rawWords.map(Self.normalize)
    var matched = [Bool](repeating: false, count: termCount)
    var matchedCount = 0

    func markMatched(_ index: Int) {
      if !matched[index] {
        matched[index] = true
        matchedCount += 1
      }
    }

    // 1. Single-word queries + 2-word and 3-word compounds.
    if !singleWordForms.isEmpty {
      var seenSingle: Set<String> = []
      var seenCompound2: Set<String> = []
      var seenCompound3: Set<String> = []
      var singleQueries: [Query] = []
      var compound2Queries: [Query] = []
      var compound3Queries: [Query] = []

      for i in normalizedWords.indices {
        let w1 = normalizedWords[i]
        guard !w1.isEmpty else { continue }
        if seenSingle.insert(w1).inserted {
          singleQueries.append(Self.makeQuery(span: w1, normalized: w1))
        }
        if i + 1 < normalizedWords.count {
          let w2 = normalizedWords[i + 1]
          if !w2.isEmpty {
            let span2 = "\(w1) \(w2)"
            let c2 = w1 + w2
            if seenCompound2.insert(span2).inserted {
              compound2Queries.append(
                Self.makeQuery(span: span2, normalized: c2)
              )
            }
            if i + 2 < normalizedWords.count {
              let w3 = normalizedWords[i + 2]
              if !w3.isEmpty {
                let span3 = "\(span2) \(w3)"
                let c3 = c2 + w3
                if seenCompound3.insert(span3).inserted {
                  compound3Queries.append(
                    Self.makeQuery(span: span3, normalized: c3)
                  )
                }
              }
            }
          }
        }
      }

      for query in singleQueries {
        for form in singleWordForms {
          if matched[form.termIndex] { continue }
          if query.normalized == canonicalNormalized[form.termIndex] {
            continue
          }
          if let similarity = Self.similarityIfAbove(
            query: query,
            form: form,
            minSimilarity: minSimilarity
          ),
            acceptsCandidate(
              span: query.span,
              termIndex: form.termIndex,
              similarity: similarity
            )
          {
            markMatched(form.termIndex)
          }
        }
      }

      let compoundMinSimilarity = max(minSimilarity, 0.55)
      for query in compound2Queries {
        for form in singleWordForms where form.allows2WordCompound {
          if matched[form.termIndex] { continue }
          if let similarity = Self.similarityIfAbove(
            query: query,
            form: form,
            minSimilarity: compoundMinSimilarity
          ),
            acceptsCandidate(
              span: query.span,
              termIndex: form.termIndex,
              similarity: similarity
            )
          {
            markMatched(form.termIndex)
          }
        }
      }

      for query in compound3Queries {
        for form in singleWordForms where form.allows3WordCompound {
          if matched[form.termIndex] { continue }
          if let similarity = Self.similarityIfAbove(
            query: query,
            form: form,
            minSimilarity: compoundMinSimilarity
          ),
            acceptsCandidate(
              span: query.span,
              termIndex: form.termIndex,
              similarity: similarity
            )
          {
            markMatched(form.termIndex)
          }
        }
      }
    }

    // 2. Multi-word phrase queries (2..4 consecutive words).
    if !multiWordForms.isEmpty, normalizedWords.count >= 2 {
      let multiMinSimilarity = max(minSimilarity, 0.55)
      var seenPhrases: Set<String> = []
      var phraseQueriesBySpan: [[Query]] = [[], [], [], [], []]

      let maxSpan = min(4, normalizedWords.count)
      for spanLength in 2...maxSpan {
        for start in 0...(normalizedWords.count - spanLength) {
          let phrase = normalizedWords[start..<(start + spanLength)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
          guard !phrase.isEmpty, seenPhrases.insert(phrase).inserted else {
            continue
          }
          phraseQueriesBySpan[spanLength].append(
            Self.makeQuery(span: phrase, normalized: phrase)
          )
        }
      }

      for form in multiWordForms {
        if matched[form.termIndex] { continue }
        let minSpan = max(2, form.wordCount)
        let maxFormSpan = min(4, form.wordCount + 1)
        guard minSpan <= maxFormSpan else { continue }
        for spanLength in minSpan...maxFormSpan {
          for query in phraseQueriesBySpan[spanLength] {
            if query.normalized == canonicalNormalized[form.termIndex] {
              continue
            }
            if let similarity = Self.similarityIfAbove(
              query: query,
              form: form,
              minSimilarity: multiMinSimilarity
            ),
              acceptsCandidate(
                span: query.span,
                termIndex: form.termIndex,
                similarity: similarity
              )
            {
              markMatched(form.termIndex)
              break
            }
          }
          if matched[form.termIndex] { break }
        }
      }
    }

    guard matchedCount > 0 else {
      return []
    }

    // Include any term that already appears verbatim in the transcript so
    // FluidAudio's cross-term guard (`vocabularyNormalizedSet`) behaves
    // identically to the unfiltered vocabulary.
    for word in normalizedWords where !word.isEmpty {
      if let indices = exactTermIndicesByNormalized[word] {
        for index in indices {
          matched[index] = true
        }
      }
    }
    if normalizedWords.count >= 2 {
      let maxSpan = min(4, normalizedWords.count)
      for spanLength in 2...maxSpan {
        for start in 0...(normalizedWords.count - spanLength) {
          let phrase = normalizedWords[start..<(start + spanLength)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
          if let indices = exactTermIndicesByNormalized[phrase] {
            for index in indices {
              matched[index] = true
            }
          }
        }
      }
    }

    var result: [Int] = []
    result.reserveCapacity(matchedCount)
    for index in 0..<termCount where matched[index] {
      result.append(index)
    }
    return result
  }

  /// Matches FluidAudio's `VocabularyRescorer.normalizeForSimilarity`.
  static func normalize(_ text: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "'-")
    )
    var result = ""
    result.reserveCapacity(text.utf8.count)
    var lastWasSpace = true

    for scalar in text.lowercased().precomposedStringWithCanonicalMapping
      .unicodeScalars
    {
      if allowed.contains(scalar) {
        result.unicodeScalars.append(scalar)
        lastWasSpace = false
      } else if scalar == " " || scalar == "\t" || scalar == "\n" {
        if !lastWasSpace && !result.isEmpty {
          result.append(" ")
          lastWasSpace = true
        }
      }
    }
    while result.last == " " {
      result.removeLast()
    }
    return result
  }

  private func acceptsCandidate(
    span: String,
    termIndex: Int,
    similarity: Float
  ) -> Bool {
    let term = termTexts[termIndex]
    return KeywordPolicy.accepts(
      span: span,
      term: term,
      aliases: termAliases[termIndex],
      similarity: similarity
    )
      && !KeywordPolicy.overwritesAnotherTerm(
        span: span,
        term: term,
        owners: owners
      )
  }

  private static func makeQuery(span: String, normalized: String) -> Query {
    let scalars = scalars(of: normalized)
    return Query(
      span: span,
      normalized: normalized,
      scalars: scalars,
      mask: asciiMask(of: scalars)
    )
  }

  private static func scalars(of text: String) -> [UInt32] {
    var result: [UInt32] = []
    result.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
      result.append(scalar.value)
    }
    return result
  }

  /// Bitmask of ASCII letters, digits, apostrophe, hyphen, and space.
  /// Because each distinct character present in only one string requires at
  /// least one edit, `max(popcount(a & ~b), popcount(b & ~a))` is a sound
  /// lower bound on Levenshtein distance even for strings containing non-ASCII
  /// characters.
  private static func asciiMask(of scalars: [UInt32]) -> UInt64 {
    var mask: UInt64 = 0
    for value in scalars {
      if value >= 97 && value <= 122 {
        mask |= 1 &<< (value - 97)
      } else if value >= 48 && value <= 57 {
        mask |= 1 &<< (26 + value - 48)
      } else if value == 39 {
        mask |= 1 &<< 36
      } else if value == 45 {
        mask |= 1 &<< 37
      } else if value == 32 {
        mask |= 1 &<< 38
      }
    }
    return mask
  }

  private static func similarityIfAbove(
    query: Query,
    form: IndexedForm,
    minSimilarity: Float
  ) -> Float? {
    let m = query.scalars.count
    let n = form.scalars.count
    let maxLen = max(m, n)
    guard maxLen > 0 else { return 1 }
    let maxDistance = Int(floor((1.0 - minSimilarity) * Float(maxLen) + 1e-5))
    if abs(m - n) > maxDistance {
      return nil
    }
    let onlyInQuery = (query.mask & ~form.mask).nonzeroBitCount
    if onlyInQuery > maxDistance {
      return nil
    }
    let onlyInForm = (form.mask & ~query.mask).nonzeroBitCount
    if onlyInForm > maxDistance {
      return nil
    }
    guard
      let distance = boundedLevenshtein(
        query.scalars,
        form.scalars,
        maxDistance: maxDistance
      )
    else {
      return nil
    }
    let similarity = 1.0 - Float(distance) / Float(maxLen)
    return similarity >= minSimilarity ? similarity : nil
  }

  private static func boundedLevenshtein(
    _ a: [UInt32],
    _ b: [UInt32],
    maxDistance: Int
  ) -> Int? {
    let m = a.count
    let n = b.count
    if abs(m - n) > maxDistance { return nil }
    if m == 0 { return n <= maxDistance ? n : nil }
    if n == 0 { return m <= maxDistance ? m : nil }

    var prev = Array(0...n)
    var curr = [Int](repeating: 0, count: n + 1)

    for i in 1...m {
      curr[0] = i
      var rowMin = i
      let ai = a[i - 1]
      for j in 1...n {
        let cost = ai == b[j - 1] ? 0 : 1
        let value = min(
          prev[j] + 1,
          min(curr[j - 1] + 1, prev[j - 1] + cost)
        )
        curr[j] = value
        if value < rowMin {
          rowMin = value
        }
      }
      if rowMin > maxDistance {
        return nil
      }
      swap(&prev, &curr)
    }
    return prev[n] <= maxDistance ? prev[n] : nil
  }
}
