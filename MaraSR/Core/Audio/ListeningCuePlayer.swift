@preconcurrency import AVFoundation
import Foundation

/// Plays the short listening chime without keeping an idle AVAudioEngine alive
/// across display or output-device changes, and off the main actor so waking
/// an external display output never stalls hotkeys or UI.
@MainActor
final class ListeningCuePlayer {
  private nonisolated static let sampleRate = 48_000.0
  private nonisolated static let duration = 0.18

  private let runner: CuePlaybackRunner

  init() {
    runner = CuePlaybackRunner(wavData: Self.makeWAVData())
  }

  func play() {
    runner.play()
  }

  nonisolated static func makeWAVData() -> Data {
    let frameCount = Int(sampleRate * duration)
    let byteCount = frameCount * MemoryLayout<Float32>.size
    var data = Data(capacity: 44 + byteCount)

    func appendLE<T: FixedWidthInteger>(_ value: T) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    data.append(contentsOf: "RIFF".utf8)
    appendLE(UInt32(36 + byteCount))
    data.append(contentsOf: "WAVE".utf8)

    data.append(contentsOf: "fmt ".utf8)
    appendLE(UInt32(16))
    appendLE(UInt16(3))  // IEEE 32-bit float PCM
    appendLE(UInt16(1))  // mono
    appendLE(UInt32(sampleRate))
    appendLE(UInt32(sampleRate) * 4)
    appendLE(UInt16(4))
    appendLE(UInt16(32))

    data.append(contentsOf: "data".utf8)
    appendLE(UInt32(byteCount))

    let notes: [(start: Double, frequency: Double, gain: Double)] = [
      (0, 587.33, 0.36),
      (0.028, 739.99, 0.26),
      (0.056, 880, 0.19),
    ]
    for frame in 0..<frameCount {
      let time = Double(frame) / sampleRate
      let releaseStart = duration - 0.045
      let releaseProgress = max(
        0,
        (time - releaseStart) / (duration - releaseStart)
      )
      let release =
        0.5
        * (1 + cos(Double.pi * min(1, releaseProgress)))
      var value = 0.0
      for note in notes where time >= note.start {
        let noteTime = time - note.start
        let attackProgress = min(1, noteTime / 0.014)
        let attack = sin(attackProgress * Double.pi / 2)
        let envelope =
          attack * attack * exp(-noteTime * 13) * release
        let fundamental = sin(
          2 * Double.pi * note.frequency * noteTime
        )
        let harmonic = sin(
          2 * Double.pi * note.frequency * 2 * noteTime
        )
        value +=
          note.gain * envelope
          * (fundamental + 0.07 * harmonic)
      }
      var sample = Float32(value * 0.045).bitPattern.littleEndian
      withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
  }
}

private final class CuePlaybackRunner: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.mariano.marasr.listening-cue",
    qos: .userInitiated
  )
  private let wavData: Data
  private var activePlayer: AVAudioPlayer?
  private var releaseWorkItem: DispatchWorkItem?

  init(wavData: Data) {
    self.wavData = wavData
  }

  func play() {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      self.releaseWorkItem?.cancel()
      self.releaseWorkItem = nil
      self.activePlayer?.stop()
      self.activePlayer = nil

      do {
        let player = try AVAudioPlayer(
          data: self.wavData,
          fileTypeHint: AVFileType.wav.rawValue
        )
        guard player.play() else {
          Log.audio.error("Listening cue skipped: AVAudioPlayer.play() returned false")
          return
        }
        self.activePlayer = player
        let release = DispatchWorkItem { [weak self] in
          self?.activePlayer?.stop()
          self?.activePlayer = nil
          self?.releaseWorkItem = nil
        }
        self.releaseWorkItem = release
        self.queue.asyncAfter(deadline: .now() + .milliseconds(350), execute: release)
      } catch {
        // The cue is cosmetic; dictation goes ahead without it.
        Log.audio.error(
          "Listening cue skipped: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }
}
