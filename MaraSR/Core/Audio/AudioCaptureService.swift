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

  /// Called when capture stops mid-recording because the microphone
  /// disconnected or hit a runtime error.
  var onCaptureInterrupted: ((Error) -> Void)?

  static let targetSampleRate: Double = 16_000

  private let sessionMicrophone = CaptureSessionMicrophone()
  private var captureGeneration: UInt64 = 0

  init() {
    sessionMicrophone.onRuntimeError = { [weak self] error in
      self?.onCaptureInterrupted?(error)
    }
  }

  var isRunning: Bool {
    sessionMicrophone.isRunning
  }

  func start(
    discardingFirst initialDuration: TimeInterval = 0,
    sampleHandler: @escaping SampleHandler
  ) async throws {
    guard !isRunning else {
      Log.audio.notice("Microphone start ignored: already running")
      return
    }
    captureGeneration &+= 1
    let generation = captureGeneration

    let defaultInput = AudioDevices.defaultInput
    let defaultInputUID = defaultInput.flatMap(AudioDevices.uid)
    let defaultIsBluetooth = defaultInput.map(AudioDevices.isBluetooth) ?? false
    let builtInUID =
      defaultIsBluetooth
      ? AudioDevices.builtInInput.flatMap(AudioDevices.uid)
      : nil

    let candidateUIDs: [String?] =
      Self.preferredDeviceUIDs(
        defaultInputUID: defaultInputUID,
        defaultInputIsBluetooth: defaultIsBluetooth,
        builtInInputUID: builtInUID
      ).map(Optional.some) + [nil]

    var lastError: Error = AudioCaptureError.inputUnavailable
    for (index, candidateUID) in candidateUIDs.enumerated() {
      guard captureGeneration == generation else {
        return
      }
      do {
        try await sessionMicrophone.start(
          deviceUniqueID: candidateUID,
          sampleRate: Self.targetSampleRate,
          discardingFirst: initialDuration,
          sampleHandler: sampleHandler
        )
        return
      } catch {
        guard captureGeneration == generation else {
          return
        }
        lastError = error
        let label = candidateUID ?? "default audio device"
        if index + 1 < candidateUIDs.count {
          Log.audio.error(
            "Microphone \(label, privacy: .public) failed, trying fallback: \(String(describing: error), privacy: .public)"
          )
        } else {
          Log.audio.error(
            "Microphone start failed on \(label, privacy: .public): \(String(describing: error), privacy: .public)"
          )
        }
      }
    }
    throw lastError
  }

  func stop() {
    captureGeneration &+= 1
    sessionMicrophone.stop()
  }

  /// Opening a Bluetooth headset's microphone switches the headset to its
  /// call profile, which cuts music playing through it. Prefer the Mac's own
  /// microphone first when the default input is Bluetooth and fall back to
  /// the default input if needed.
  nonisolated static func preferredDeviceUIDs(
    defaultInputUID: String?,
    defaultInputIsBluetooth: Bool,
    builtInInputUID: String?
  ) -> [String] {
    var result: [String] = []
    if defaultInputIsBluetooth, let builtInInputUID {
      result.append(builtInInputUID)
    }
    if let defaultInputUID, !result.contains(defaultInputUID) {
      result.append(defaultInputUID)
    }
    return result
  }

  nonisolated static func normalizedLevel(
    _ samples: [Float]
  ) -> Float {
    guard !samples.isEmpty else {
      return 0
    }
    let meanSquare =
      samples.reduce(Float.zero) {
        $0 + ($1 * $1)
      } / Float(samples.count)
    let decibels = 20 * log10(max(sqrt(meanSquare), 0.000_001))
    return min(1, max(0, (decibels + 60) / 60))
  }
}
