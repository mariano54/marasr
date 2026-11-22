import AVFoundation
@preconcurrency import FluidAudio
import SwiftData
import SwiftUI
import XCTest

@testable import MaraSR

final class TranscriptProcessingTests: XCTestCase {
  func testAssemblerKeepsSequenceOrderAndRemovesOverlap() async {
    let assembler = TranscriptAssembler()

    _ = await assembler.append(
      sequence: 1,
      text: "brown fox jumps"
    )
    _ = await assembler.append(
      sequence: 0,
      text: "The quick brown fox"
    )

    let result = await assembler.text()
    XCTAssertEqual(result, "The quick brown fox jumps")
  }

  func testGlossaryReplacementUsesWordBoundaries() {
    let processor = TranscriptPostProcessor()
    let result = processor.process(
      "acme improves transcription without changing academic",
      glossary: [.acme],
      recentTranscripts: []
    )

    XCTAssertEqual(
      result,
      "ACME improves transcription without changing academic"
    )
  }

  func testGlossaryPrefersTheLongestSpelling() {
    let processor = TranscriptPostProcessor()
    let result = processor.process(
      "open smart turn dot py and check smart turn",
      glossary: [
        GlossaryEntry(canonical: "SmartTurn", aliases: ["smart turn"]),
        GlossaryEntry(
          canonical: "smart_turn.py",
          aliases: ["smart turn dot py"]
        ),
      ],
      recentTranscripts: []
    )

    XCTAssertEqual(result, "open smart_turn.py and check SmartTurn")
  }

  func testKeywordPolicyAcceptsMishearingsAndSplitTerms() {
    XCTAssertTrue(accepts("Gladier", "Gladia", similarity: 0.71))
    XCTAssertTrue(accepts("hammer spoon", "Hammerspoon", similarity: 0.6))
    XCTAssertTrue(
      KeywordPolicy.accepts(
        span: "Eason",
        term: "ISSEN",
        aliases: ["Eason"],
        similarity: 1
      )
    )
  }

  func testKeywordPolicyNeedsCloserMatchesForCommonWords() {
    XCTAssertFalse(accepts("German", "Gemma", similarity: 0.67))
    XCTAssertFalse(accepts("prod", "PRD", similarity: 0.75))
    XCTAssertTrue(accepts("Karabina", "Karabiner", similarity: 0.78))
  }

  func testKeywordPolicyKeepsOrdinaryWordsInsideLongerTerms() {
    XCTAssertFalse(accepts("router", "OpenRouter", similarity: 0.9))
    XCTAssertFalse(accepts("Code", "Xcode", similarity: 0.9))
    XCTAssertFalse(accepts("Xcode project", "Xcode", similarity: 0.9))
  }

  func testKeywordPolicyKeepsWordsNextToTheMatch() {
    XCTAssertFalse(accepts("the router", "OpenRouter", similarity: 0.9))
    XCTAssertFalse(accepts("and turn", "SmartTurn", similarity: 0.9))
    XCTAssertFalse(accepts("Deepgram on", "Deepgram", similarity: 0.9))
  }

  func testKeywordPolicyKeepsOtherGlossaryTerms() {
    let owners = KeywordPolicy.owners(of: [
      GlossaryEntry(canonical: "VAD", aliases: ["V A D"]),
      GlossaryEntry(canonical: "OpenAI", aliases: ["Open AI"]),
      GlossaryEntry(canonical: "Soniox", aliases: ["Sonyox"]),
    ])

    XCTAssertTrue(
      KeywordPolicy.overwritesAnotherTerm(
        span: "Open VAD",
        term: "OpenAI",
        owners: owners
      )
    )
    XCTAssertFalse(
      KeywordPolicy.overwritesAnotherTerm(
        span: "Sonyox",
        term: "Soniox",
        owners: owners
      )
    )
  }

  func testKeywordRangeFallbackSkipsEdgePunctuation() {
    let text = "Do we still have credits on Core Weave?"
    let range = KeywordPolicy.uniqueRange(of: "Core Weave?", in: text)
    XCTAssertEqual(
      range.map { KeywordPolicy.apply([($0, "CoreWeave")], to: text) },
      "Do we still have credits on CoreWeave?"
    )
    XCTAssertNil(
      KeywordPolicy.uniqueRange(of: "data dog", in: "data dog or data dog")
    )
  }

  func testOnlySpeakableTermsAreBoosted() {
    XCTAssertTrue(KeywordPolicy.isSpeakable("Claude Code"))
    XCTAssertTrue(KeywordPolicy.isSpeakable("barge-in"))
    XCTAssertFalse(KeywordPolicy.isSpeakable("deploy.sh"))
    XCTAssertFalse(KeywordPolicy.isSpeakable("web_server.py"))
    XCTAssertFalse(KeywordPolicy.isSpeakable(" "))
  }

  func testKeywordReplacementsUseUTF8Ranges() {
    let text = "Café: compare Sonyox and Deat Graham."
    let bytes = Array(text.utf8)
    func range(of word: String) -> Range<Int> {
      let needle = Array(word.utf8)
      let start = (0...(bytes.count - needle.count)).first {
        Array(bytes[$0..<($0 + needle.count)]) == needle
      }!
      return start..<(start + needle.count)
    }

    let result = KeywordPolicy.apply(
      [
        (range(of: "Sonyox"), "Soniox"),
        (range(of: "Deat Graham"), "Deepgram"),
      ],
      to: text
    )

    XCTAssertEqual(result, "Café: compare Soniox and Deepgram.")
  }

  func testCandidateIndexSkipsOrdinarySpeechAndExactCanonicalMatches() {
    let glossary = [
      GlossaryEntry(canonical: "Soniox", aliases: ["Sonyox"]),
      GlossaryEntry(canonical: "Karabiner", aliases: ["Karabina"]),
      GlossaryEntry(canonical: "Hammerspoon", aliases: ["hammer spoon"]),
      GlossaryEntry(canonical: "OpenRouter", aliases: []),
      GlossaryEntry(canonical: "Gemma", aliases: []),
      GlossaryEntry(canonical: "PRD", aliases: []),
    ]
    let index = makeCandidateIndex(for: glossary)

    XCTAssertEqual(
      index.activeTermIndices(
        for: ["This", "is", "ordinary", "German", "router", "prod", "speech"],
        minSimilarity: 0.6
      ),
      []
    )
    XCTAssertEqual(
      index.activeTermIndices(
        for: ["Compare", "Soniox", "and", "Hammerspoon"],
        minSimilarity: 0.6
      ),
      []
    )
  }

  func testCandidateIndexFindsMisheardSingleAndCompoundTerms() {
    let glossary = [
      GlossaryEntry(canonical: "Soniox", aliases: []),
      GlossaryEntry(canonical: "Hammerspoon", aliases: []),
      GlossaryEntry(canonical: "Karabiner", aliases: []),
      GlossaryEntry(canonical: "VAD", aliases: []),
    ]
    let index = makeCandidateIndex(for: glossary)

    XCTAssertEqual(
      index.activeTermIndices(
        for: ["Compare", "Sonyox", "in", "hammer", "spoon", "with", "VAD"],
        minSimilarity: 0.6
      ),
      [0, 1, 3]
    )
  }

  func testCandidateIndexExtractWordsMatchesSentencePieceBoundaries() {
    let timings = [
      TokenTiming(token: "▁Com", tokenId: 1, startTime: 0, endTime: 0.1, confidence: 1),
      TokenTiming(token: "pare", tokenId: 2, startTime: 0.1, endTime: 0.2, confidence: 1),
      TokenTiming(token: "<blank>", tokenId: 0, startTime: 0.2, endTime: 0.2, confidence: 1),
      TokenTiming(token: "▁Sony", tokenId: 3, startTime: 0.2, endTime: 0.3, confidence: 1),
      TokenTiming(token: "ox", tokenId: 4, startTime: 0.3, endTime: 0.4, confidence: 1),
    ]

    XCTAssertEqual(
      KeywordCandidateIndex.extractWords(from: timings),
      ["Compare", "Sonyox"]
    )
  }

  private func makeCandidateIndex(
    for glossary: [GlossaryEntry]
  ) -> KeywordCandidateIndex {
    var aliases: [String: [String]] = [:]
    let terms = glossary.map { entry -> CustomVocabularyTerm in
      aliases[entry.canonical, default: []] += entry.aliases
      return CustomVocabularyTerm(
        text: entry.canonical,
        aliases: entry.aliases.isEmpty ? nil : entry.aliases
      )
    }
    return KeywordCandidateIndex(
      terms: terms,
      minTermLength: 3,
      aliases: aliases,
      owners: KeywordPolicy.owners(of: glossary)
    )
  }

  private func accepts(
    _ span: String,
    _ term: String,
    similarity: Float
  ) -> Bool {
    KeywordPolicy.accepts(
      span: span,
      term: term,
      aliases: [],
      similarity: similarity
    )
  }

  func testRecentDistinctiveCasingIsRemembered() {
    let processor = TranscriptPostProcessor()
    let result = processor.process(
      "open marasr",
      glossary: [],
      recentTranscripts: ["MaraSR is ready"]
    )

    XCTAssertEqual(result, "open MaraSR")
  }

  func testVADBoundaryRejectsShortNoiseAndKeepsSpeech() {
    var tracker = VADBoundaryTracker(minimumSpeechSamples: 3_072)
    tracker.speechStarted(at: 100)
    XCTAssertNil(tracker.speechEnded(at: 2_000))

    tracker.speechStarted(at: 3_000)
    XCTAssertEqual(
      tracker.speechEnded(at: 7_000),
      3_000..<7_000
    )
  }

  func testVADBoundarySplitsLongSpeechOnBriefDipAndHardCap() {
    var tracker = VADBoundaryTracker(
      minimumSpeechSamples: 3_072,
      softMaxSpeechSamples: 10_000,
      hardMaxSpeechSamples: 15_000,
      softSplitProbabilityThreshold: 0.25,
      softSplitSilenceChunks: 2
    )
    tracker.speechStarted(at: 0)

    // Before softMaxSpeechSamples, brief dips do not split.
    XCTAssertNil(tracker.advance(to: 5_000, speechProbability: 0.1))
    XCTAssertNil(tracker.advance(to: 5_512, speechProbability: 0.1))
    XCTAssertNil(tracker.advance(to: 9_000, speechProbability: 0.9))

    // Once past softMaxSpeechSamples, 2 consecutive low-prob chunks split.
    XCTAssertNil(tracker.advance(to: 10_500, speechProbability: 0.1))
    XCTAssertEqual(
      tracker.advance(to: 11_012, speechProbability: 0.1),
      0..<11_012
    )
    XCTAssertEqual(tracker.speechStartSample, 11_012)

    // With continuous high probability, hardMaxSpeechSamples splits at the
    // lowest-probability dip inside the window.
    XCTAssertNil(tracker.advance(to: 21_500, speechProbability: 0.8))
    XCTAssertNil(tracker.advance(to: 23_000, speechProbability: 0.4))
    XCTAssertNil(tracker.advance(to: 25_000, speechProbability: 0.9))
    XCTAssertEqual(
      tracker.advance(to: 26_100, speechProbability: 0.9),
      11_012..<23_000
    )
    XCTAssertEqual(tracker.speechStartSample, 23_000)

    // Finishing at or before the last emitted split emits nothing duplicate.
    XCTAssertNil(tracker.finish(at: 23_000))
  }

  @MainActor
  func testHistoryPersistsInMemory() throws {
    let configuration = ModelConfiguration(
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(
      for: TranscriptionRecord.self,
      configurations: configuration
    )
    let context = container.mainContext
    context.insert(
      TranscriptionRecord(
        text: "A private transcript",
        duration: 1.2,
        destinationApplication: "Notes"
      )
    )
    try context.save()

    let records = try context.fetch(
      FetchDescriptor<TranscriptionRecord>()
    )
    XCTAssertEqual(records.map(\.text), ["A private transcript"])
  }

  @MainActor
  func testSettingsRoundTripHotkeysAndGlossary() {
    let suiteName = "MaraSRTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = SettingsStore(defaults: defaults)
    store.pasteLastHotkey = .holdToTalk
    store.glossary = [
      GlossaryEntry(canonical: "MaraSR", aliases: ["mara sr"])
    ]

    let restored = SettingsStore(defaults: defaults)
    XCTAssertEqual(restored.pasteLastHotkey, .holdToTalk)
    XCTAssertEqual(restored.glossary.first?.canonical, "MaraSR")
  }

  @MainActor
  func testOverlayExpandsToShowLongTranscript() {
    let model = OverlayViewModel()
    model.phase = .recording

    let shortView = NSHostingView(
      rootView: RecordingOverlayView(model: model)
    )
    shortView.sizingOptions = [.intrinsicContentSize]
    let shortSize = shortView.fittingSize

    model.transcript = String(
      repeating:
        "MaraSR keeps the complete live transcription visible. ",
      count: 20
    )
    let longView = NSHostingView(
      rootView: RecordingOverlayView(model: model)
    )
    longView.sizingOptions = [.intrinsicContentSize]
    let longSize = longView.fittingSize

    XCTAssertEqual(longSize.width, 640, accuracy: 1)
    XCTAssertGreaterThan(longSize.height, shortSize.height + 40)
  }

  func testPreferredDeviceUIDsBypassesBluetoothWhenBuiltInAvailable() {
    XCTAssertEqual(
      AudioCaptureService.preferredDeviceUIDs(
        defaultInputUID: "AirPods-UID",
        defaultInputIsBluetooth: true,
        builtInInputUID: "BuiltInMicrophoneDevice"
      ),
      ["BuiltInMicrophoneDevice", "AirPods-UID"]
    )
    XCTAssertEqual(
      AudioCaptureService.preferredDeviceUIDs(
        defaultInputUID: "AirPods-UID",
        defaultInputIsBluetooth: true,
        builtInInputUID: nil
      ),
      ["AirPods-UID"]
    )
    XCTAssertEqual(
      AudioCaptureService.preferredDeviceUIDs(
        defaultInputUID: "BuiltInMicrophoneDevice",
        defaultInputIsBluetooth: false,
        builtInInputUID: "BuiltInMicrophoneDevice"
      ),
      ["BuiltInMicrophoneDevice"]
    )
    XCTAssertEqual(
      AudioCaptureService.preferredDeviceUIDs(
        defaultInputUID: nil,
        defaultInputIsBluetooth: false,
        builtInInputUID: nil
      ),
      []
    )
  }

  func testNormalizedLevelHandlesEmptyAndActiveAudio() {
    XCTAssertEqual(AudioCaptureService.normalizedLevel([]), 0)
    XCTAssertEqual(AudioCaptureService.normalizedLevel([0, 0, 0]), 0)
    XCTAssertEqual(AudioCaptureService.normalizedLevel([1, -1, 1, -1]), 1, accuracy: 0.001)
  }

  func testListeningCueProducesValidPlayableWAV() throws {
    let data = ListeningCuePlayer.makeWAVData()
    XCTAssertGreaterThan(data.count, 44)
    XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
    XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")

    let player = try AVAudioPlayer(
      data: data,
      fileTypeHint: AVFileType.wav.rawValue
    )
    XCTAssertEqual(player.duration, 0.18, accuracy: 0.005)
    XCTAssertEqual(player.numberOfChannels, 1)
  }
}
