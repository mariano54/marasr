import CoreAudio
import Foundation

/// Turns the output volume down while dictating so music keeps playing
/// quietly instead of competing with the speaker, then puts it back.
@MainActor
final class OutputVolumeDucker {
  /// Ducked volume as a fraction of the user's volume (80% lower).
  static let duckedFraction: Float = 0.2

  private struct Ducking: Codable {
    let deviceUID: String
    let originalVolume: Float
    let duckedVolume: Float
  }

  private static let defaultsKey = "outputVolumeDucking"

  private let defaults: UserDefaults
  private var ducking: Ducking?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // A crash or force quit mid-dictation leaves the volume ducked.
    if let data = defaults.data(forKey: Self.defaultsKey),
      let saved = try? JSONDecoder().decode(Ducking.self, from: data)
    {
      ducking = saved
      Log.audio.notice("Restoring output volume left ducked by the last run")
      restore()
    }
  }

  func duck() {
    guard ducking == nil,
      let device = AudioDevices.defaultOutput,
      let uid = AudioDevices.uid(device),
      let original = AudioDevices.outputVolume(device)
    else {
      return
    }
    let ducked = original * Self.duckedFraction
    guard AudioDevices.setOutputVolume(ducked, on: device) else {
      Log.audio.notice(
        "Output volume not ducked: \(AudioDevices.name(device), privacy: .public) has no settable volume"
      )
      return
    }
    // Read back the value the device settled on, since it may round.
    let applied = AudioDevices.outputVolume(device) ?? ducked
    let ducking = Ducking(
      deviceUID: uid,
      originalVolume: original,
      duckedVolume: applied
    )
    self.ducking = ducking
    if let data = try? JSONEncoder().encode(ducking) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }

  func restore() {
    guard let ducking else {
      return
    }
    self.ducking = nil
    defaults.removeObject(forKey: Self.defaultsKey)
    guard let device = AudioDevices.device(uid: ducking.deviceUID),
      let current = AudioDevices.outputVolume(device)
    else {
      return
    }
    // If the volume was changed by hand while dictating, keep that.
    guard abs(current - ducking.duckedVolume) < 0.02 else {
      Log.audio.notice("Output volume changed while ducked; leaving it")
      return
    }
    AudioDevices.setOutputVolume(ducking.originalVolume, on: device)
  }
}
