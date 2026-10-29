@preconcurrency import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
  case inputUnavailable
  case converterUnavailable
  case conversionFailed
  case formatMismatch(hardware: Double, tap: Double)

  var errorDescription: String? {
    switch self {
    case .inputUnavailable:
      "No microphone input is available."
    case .converterUnavailable:
      "The microphone audio format could not be converted."
    case .conversionFailed:
      "Microphone audio conversion failed."
    case .formatMismatch:
      "The microphone is switching devices. Try again."
    }
  }
}

@MainActor
final class AudioCaptureService {
  typealias SampleHandler = @Sendable (_ samples: [Float], _ level: Float) -> Void

  /// Called when capture stopped mid-recording and could not be restarted
  /// after Core Audio reconfigured the engine.
  var onCaptureInterrupted: ((Error) -> Void)?

  private var engine = AVAudioEngine()
  private var configurationObserver: NSObjectProtocol?
  private var engineIsStale = false
  private var tapInstalled = false
  private var processor: AudioTapProcessor?
  private var activeSampleHandler: SampleHandler?

  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )

  init() {
    observeConfigurationChanges()
  }

  var isRunning: Bool {
    engine.isRunning
  }

  func start(
    discardingFirst initialDuration: TimeInterval = 0,
    sampleHandler: @escaping SampleHandler
  ) throws {
    guard !engine.isRunning else {
      Log.audio.notice("Microphone start ignored: engine already running")
      return
    }
    if engineIsStale {
      rebuildEngine(reason: "configuration changed since last use")
    }
    try startWithRetry(
      discardingFirst: initialDuration,
      sampleHandler: sampleHandler
    )
    activeSampleHandler = sampleHandler
  }

  private func startWithRetry(
    discardingFirst initialDuration: TimeInterval,
    sampleHandler: @escaping SampleHandler
  ) throws {
    do {
      try startEngine(
        discardingFirst: initialDuration,
        sampleHandler: sampleHandler
      )
    } catch {
      // A device or sample-rate switch leaves the engine with a stale
      // format. A fresh engine reads the current hardware format.
      Log.audio.error(
        "Microphone start failed, retrying on a fresh engine: \(String(describing: error), privacy: .public)"
      )
      rebuildEngine(reason: "start failed")
      do {
        try startEngine(
          discardingFirst: initialDuration,
          sampleHandler: sampleHandler
        )
      } catch {
        Log.audio.error(
          "Microphone start failed twice: \(String(describing: error), privacy: .public)"
        )
        stopEngine()
        engineIsStale = true
        throw error
      }
    }
  }

  func stop() {
    activeSampleHandler = nil
    stopEngine()
  }

  private func stopEngine() {
    // The engine stops itself on a configuration change, so the tap can
    // outlive `isRunning`. A leftover tap makes the next install throw.
    if tapInstalled {
      let input = engine.inputNode
      try? ObjCException.catching("removeTap", log: Log.audio) {
        input.removeTap(onBus: 0)
      }
      tapInstalled = false
    }
    if engine.isRunning {
      engine.stop()
    }
    processor = nil
  }

  private func startEngine(
    discardingFirst initialDuration: TimeInterval,
    sampleHandler: @escaping SampleHandler
  ) throws {
    guard let targetFormat else {
      throw AudioCaptureError.converterUnavailable
    }

    let input = engine.inputNode
    let hardwareFormat = input.inputFormat(forBus: 0)
    let inputFormat = input.outputFormat(forBus: 0)
    Log.audio.notice(
      "Starting microphone: hardware \(Self.describe(hardwareFormat), privacy: .public), tap \(Self.describe(inputFormat), privacy: .public)"
    )
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw AudioCaptureError.inputUnavailable
    }
    guard hardwareFormat.sampleRate == inputFormat.sampleRate else {
      throw AudioCaptureError.formatMismatch(
        hardware: hardwareFormat.sampleRate,
        tap: inputFormat.sampleRate
      )
    }
    guard
      let converter = AVAudioConverter(
        from: inputFormat,
        to: targetFormat
      )
    else {
      throw AudioCaptureError.converterUnavailable
    }

    let processor = AudioTapProcessor(
      converter: converter,
      targetFormat: targetFormat,
      samplesToDiscard: Int(
        targetFormat.sampleRate * initialDuration
      ),
      sampleHandler: sampleHandler
    )
    do {
      try ObjCException.catching("installTap", log: Log.audio) {
        processor.installTap(on: input, format: inputFormat)
      }
      tapInstalled = true
      self.processor = processor

      let engine = engine
      engine.prepare()
      try ObjCException.catching("engine.start", log: Log.audio) {
        try engine.start()
      }
    } catch {
      stopEngine()
      throw error
    }
  }

  private func rebuildEngine(reason: String) {
    Log.audio.notice(
      "Rebuilding audio engine: \(reason, privacy: .public)"
    )
    stopEngine()
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    engine = AVAudioEngine()
    engineIsStale = false
    observeConfigurationChanges()
  }

  private func observeConfigurationChanges() {
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.handleConfigurationChange()
      }
    }
  }

  private func handleConfigurationChange() {
    Log.audio.notice(
      "Audio configuration changed (engine running: \(self.engine.isRunning, privacy: .public), tap installed: \(self.tapInstalled, privacy: .public)); engine will be rebuilt"
    )
    engineIsStale = true

    // Core Audio stops the engine on a reconfiguration. Mid-recording,
    // restart on a fresh engine so the dictation keeps going.
    guard let sampleHandler = activeSampleHandler, !engine.isRunning else {
      return
    }
    rebuildEngine(reason: "restarting capture mid-recording")
    do {
      try startWithRetry(discardingFirst: 0, sampleHandler: sampleHandler)
      Log.audio.notice("Microphone capture resumed after configuration change")
    } catch {
      activeSampleHandler = nil
      Log.audio.error(
        "Microphone capture could not resume: \(String(describing: error), privacy: .public)"
      )
      onCaptureInterrupted?(error)
    }
  }

  private static func describe(_ format: AVAudioFormat) -> String {
    "\(Int(format.sampleRate)) Hz \(format.channelCount) ch"
  }
}

private final class AudioTapProcessor: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let targetFormat: AVAudioFormat
  private let sampleHandler: AudioCaptureService.SampleHandler
  private var samplesToDiscard: Int
  private var loggedConversionFailure = false

  init(
    converter: AVAudioConverter,
    targetFormat: AVAudioFormat,
    samplesToDiscard: Int,
    sampleHandler: @escaping AudioCaptureService.SampleHandler
  ) {
    self.converter = converter
    self.targetFormat = targetFormat
    self.samplesToDiscard = samplesToDiscard
    self.sampleHandler = sampleHandler
  }

  func installTap(
    on input: AVAudioInputNode,
    format: AVAudioFormat
  ) {
    input.installTap(
      onBus: 0,
      bufferSize: 1_024,
      format: format
    ) { [self] buffer, _ in
      process(buffer)
    }
  }

  func process(_ buffer: AVAudioPCMBuffer) {
    do {
      var samples = try convert(buffer)
      if samplesToDiscard > 0 {
        let discardedCount = min(samplesToDiscard, samples.count)
        samples.removeFirst(discardedCount)
        samplesToDiscard -= discardedCount
      }
      guard !samples.isEmpty else {
        return
      }
      sampleHandler(samples, normalizedLevel(samples))
    } catch {
      // The tap runs every ~20 ms; log the first failure only.
      guard !loggedConversionFailure else {
        return
      }
      loggedConversionFailure = true
      Log.audio.error(
        "Microphone buffer conversion failed (\(Int(buffer.format.sampleRate)) Hz \(buffer.format.channelCount) ch): \(String(describing: error), privacy: .public)"
      )
    }
  }

  private func convert(
    _ input: AVAudioPCMBuffer
  ) throws -> [Float] {
    let ratio = targetFormat.sampleRate / input.format.sampleRate
    let capacity =
      AVAudioFrameCount(
        ceil(Double(input.frameLength) * ratio)
      ) + 1
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: capacity
      )
    else {
      throw AudioCaptureError.conversionFailed
    }

    let inputState = ConverterInputState()
    var conversionError: NSError?
    let status = converter.convert(
      to: output,
      error: &conversionError
    ) { _, inputStatus in
      if inputState.supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      inputState.supplied = true
      inputStatus.pointee = .haveData
      return input
    }

    guard status != .error, conversionError == nil,
      let channel = output.floatChannelData?.pointee
    else {
      throw conversionError ?? AudioCaptureError.conversionFailed
    }
    return Array(
      UnsafeBufferPointer(
        start: channel,
        count: Int(output.frameLength)
      )
    )
  }

  private func normalizedLevel(
    _ samples: [Float]
  ) -> Float {
    let meanSquare =
      samples.reduce(Float.zero) {
        $0 + ($1 * $1)
      } / Float(samples.count)
    let decibels = 20 * log10(max(sqrt(meanSquare), 0.000_001))
    return min(1, max(0, (decibels + 60) / 60))
  }
}

private final class ConverterInputState: @unchecked Sendable {
  var supplied = false
}
