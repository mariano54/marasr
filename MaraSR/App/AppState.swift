import AppKit
import Combine
import Foundation
import SwiftData

enum DictationState: Equatable {
  case idle
  case recording
  case transcribing
}

@MainActor
final class AppState: ObservableObject {
  @Published private(set) var dictationState: DictationState = .idle
  @Published private(set) var modelReady = false
  @Published private(set) var modelProgress = 0.0
  @Published private(set) var modelFile = ""
  @Published private(set) var lastTranscription = ""
  @Published private(set) var tutorialHotkeyDown = false
  @Published var errorMessage: String?

  let settings: SettingsStore
  let permissions: PermissionManager

  private let modelContainer: ModelContainer
  private let modelContext: ModelContext
  private let audioCapture = AudioCaptureService()
  private let listeningCue = ListeningCuePlayer()
  private let vad = SileroVADService()
  private let parakeet = ParakeetService()
  private let assembler = TranscriptAssembler()
  private let postProcessor = TranscriptPostProcessor()
  private let hotkeys = GlobalHotkeyManager()
  private let injector = TextInjector()
  private let overlay = OverlayPanelController()

  private var targetApplication: InjectionTarget?
  private var recordingStartedAt: Date?
  private var sampleChain: Task<Void, Never>?
  private var prepareTask: Task<Void, Never>?
  private var onboardingWindow: OnboardingWindowController?
  private var dashboardWindow: DashboardWindowController?
  private var cancellables: Set<AnyCancellable> = []
  private var launched = false
  private var tutorialMode = false

  init(
    settings: SettingsStore,
    permissions: PermissionManager,
    modelContainer: ModelContainer
  ) {
    self.settings = settings
    self.permissions = permissions
    self.modelContainer = modelContainer
    modelContext = modelContainer.mainContext

    hotkeys.onHoldChanged = { [weak self] isDown in
      guard let self else {
        return
      }
      Task { @MainActor in
        if self.tutorialMode {
          self.tutorialHotkeyDown = isDown
          return
        }
        if isDown {
          await self.beginDictation()
        } else {
          await self.finishDictation()
        }
      }
    }
    hotkeys.onPasteLast = { [weak self] in
      Task { @MainActor in
        await self?.pasteLast()
      }
    }

    settings.$holdToTalkHotkey
      .combineLatest(settings.$pasteLastHotkey)
      .sink { [weak self] hold, paste in
        self?.hotkeys.configure(
          holdToTalk: hold,
          pasteLast: paste
        )
      }
      .store(in: &cancellables)

    permissions.$inputMonitoringGranted
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.refreshHotkeyListener()
      }
      .store(in: &cancellables)
  }

  func launch() {
    guard !launched else {
      return
    }
    launched = true
    permissions.refresh()
    refreshHotkeyListener()

    if settings.onboardingComplete {
      prepareModels()
      showDashboard()
    } else {
      showOnboarding()
    }
  }

  func prepareModels() {
    guard prepareTask == nil, !modelReady else {
      return
    }
    errorMessage = nil
    prepareTask = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        async let vadPreparation: Void = vad.prepare()
        async let asrPreparation: Void = parakeet.prepare {
          [weak self] progress, file in
          Task { @MainActor in
            self?.modelProgress = progress
            self?.modelFile = file
          }
        }
        try await vadPreparation
        try await asrPreparation
        modelReady = true
        modelProgress = 1
      } catch {
        errorMessage = error.localizedDescription
      }
      prepareTask = nil
    }
  }

  func refreshPermissions() {
    permissions.refresh()
    refreshHotkeyListener()
  }

  func finishOnboarding() {
    settings.onboardingComplete = true
    onboardingWindow?.close()
    onboardingWindow = nil
    refreshPermissions()
    prepareModels()
    showDashboard()
  }

  func showPrimaryWindow() {
    if settings.onboardingComplete {
      showDashboard()
    } else {
      showOnboarding()
    }
  }

  func showOnboarding() {
    NSApp.setActivationPolicy(.regular)
    if let onboardingWindow {
      onboardingWindow.show()
      return
    }
    let controller = OnboardingWindowController(appState: self)
    onboardingWindow = controller
    controller.show()
  }

  func showDashboard() {
    NSApp.setActivationPolicy(.regular)
    if let dashboardWindow {
      dashboardWindow.show()
      return
    }
    let controller = DashboardWindowController(
      appState: self,
      modelContainer: modelContainer
    )
    dashboardWindow = controller
    controller.show()
  }

  func beginHotkeyCapture(
    completion: @escaping (HotkeyConfiguration) -> Void
  ) {
    hotkeys.captureNext(completion: completion)
  }

  func cancelHotkeyCapture() {
    hotkeys.cancelCapture()
  }

  func setTutorialMode(_ active: Bool) {
    tutorialMode = active
    if !active {
      tutorialHotkeyDown = false
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try LaunchAtLoginController().setEnabled(enabled)
      settings.launchAtLogin = enabled
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func paste(_ text: String) {
    Task { @MainActor in
      do {
        try await injector.inject(
          text,
          into: injector.currentTarget()
        )
        overlay.showSuccess()
      } catch {
        overlay.showError(error.localizedDescription)
      }
    }
  }

  private func refreshHotkeyListener() {
    hotkeys.configure(
      holdToTalk: settings.holdToTalkHotkey,
      pasteLast: settings.pasteLastHotkey
    )
    guard permissions.inputMonitoringGranted else {
      hotkeys.stop()
      return
    }
    do {
      try hotkeys.start()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func beginDictation() async {
    guard dictationState == .idle else {
      return
    }
    guard permissions.allRequiredGranted else {
      overlay.showError("Permissions required")
      showOnboarding()
      return
    }
    guard modelReady else {
      overlay.showError("Model is still loading")
      prepareModels()
      return
    }

    listeningCue.play()
    do {
      await assembler.reset()
      await vad.startTurn()
      targetApplication = injector.currentTarget()
      recordingStartedAt = .now
      sampleChain = nil
      overlay.showRecording()
      dictationState = .recording

      try audioCapture.start(
        discardingFirst: 0.2
      ) { [weak self] samples, level in
        Task { @MainActor in
          guard let self,
            self.dictationState == .recording
          else {
            return
          }
          self.overlay.model.push(level: level)
          self.enqueue(samples)
        }
      }
    } catch {
      dictationState = .idle
      overlay.showError(error.localizedDescription)
    }
  }

  private func enqueue(_ samples: [Float]) {
    let previous = sampleChain
    sampleChain = Task { [weak self] in
      await previous?.value
      guard let self,
        self.dictationState != .idle
      else {
        return
      }
      do {
        let segments = try await self.vad.append(samples)
        try await self.transcribe(segments)
        if let previewSamples = await self.vad.previewSamplesIfNeeded() {
          try await self.transcribePreview(previewSamples)
        }
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func finishDictation() async {
    guard dictationState == .recording else {
      return
    }
    dictationState = .transcribing
    audioCapture.stop()
    overlay.showTranscribing()

    await sampleChain?.value
    sampleChain = nil

    do {
      let finalSegments = try await vad.finishTurn()
      try await transcribe(finalSegments)
      let rawText = await assembler.text()
      let recent = recentTranscripts()
      let finalText = postProcessor.process(
        rawText,
        glossary: settings.glossary,
        recentTranscripts: recent
      )
      guard !finalText.isEmpty else {
        overlay.hide()
        resetDictation()
        return
      }

      try await injector.inject(
        finalText,
        into: targetApplication
      )
      save(
        finalText,
        duration: Date.now.timeIntervalSince(
          recordingStartedAt ?? .now
        ),
        destination: targetApplication?.applicationName
          ?? "Unknown app"
      )
      lastTranscription = finalText
      overlay.showSuccess()
    } catch {
      errorMessage = error.localizedDescription
      overlay.showError(error.localizedDescription)
    }
    resetDictation()
  }

  private func transcribe(_ segments: [SpeechSegment]) async throws {
    for segment in segments {
      let rawText = try await parakeet.transcribe(
        samples: segment.samples
      )
      let assembled = await assembler.append(
        sequence: segment.sequence,
        text: rawText
      )
      overlay.model.transcript = postProcessor.process(
        assembled,
        glossary: settings.glossary,
        recentTranscripts: recentTranscripts()
      )
    }
  }

  private func transcribePreview(_ samples: [Float]) async throws {
    let preview = try await parakeet.transcribe(samples: samples)
    let committed = await assembler.text()
    let combined = TranscriptAssembler.merge(
      [committed, preview].filter { !$0.isEmpty }
    )
    overlay.model.transcript = postProcessor.process(
      combined,
      glossary: settings.glossary,
      recentTranscripts: recentTranscripts()
    )
  }

  private func pasteLast() async {
    let text =
      lastTranscription.isEmpty
      ? recentTranscripts().first ?? ""
      : lastTranscription
    guard !text.isEmpty else {
      overlay.showError("No transcription yet")
      return
    }
    do {
      try await injector.inject(text, into: injector.currentTarget())
      overlay.showSuccess()
    } catch {
      overlay.showError(error.localizedDescription)
    }
  }

  private func recentTranscripts() -> [String] {
    var descriptor = FetchDescriptor<TranscriptionRecord>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = 5
    return (try? modelContext.fetch(descriptor))?.map(\.text) ?? []
  }

  private func save(
    _ text: String,
    duration: TimeInterval,
    destination: String
  ) {
    modelContext.insert(
      TranscriptionRecord(
        text: text,
        duration: duration,
        destinationApplication: destination
      )
    )
    try? modelContext.save()
  }

  private func resetDictation() {
    dictationState = .idle
    targetApplication = nil
    recordingStartedAt = nil
  }
}
