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
      "issen improves transcription without changing dissension",
      glossary: [.issen],
      recentTranscripts: []
    )

    XCTAssertEqual(
      result,
      "ISSEN improves transcription without changing dissension"
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
}
