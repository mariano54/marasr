@preconcurrency import AVFoundation

@MainActor
final class ListeningCuePlayer {
  private static let sampleRate = 48_000.0
  private static let duration = 0.18

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let buffer: AVAudioPCMBuffer?
  private var stopTask: Task<Void, Never>?

  init() {
    let format = AVAudioFormat(
      standardFormatWithSampleRate: Self.sampleRate,
      channels: 1
    )
    buffer = format.flatMap(Self.makeBuffer)
    engine.attach(player)
    if let format {
      engine.connect(
        player,
        to: engine.mainMixerNode,
        format: format
      )
    }
    engine.prepare()
  }

  func play() {
    guard let buffer else {
      return
    }
    stopTask?.cancel()
    player.stop()
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        return
      }
    }
    player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    player.play()
    stopTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(240))
      guard !Task.isCancelled else {
        return
      }
      self?.player.stop()
      self?.engine.stop()
    }
  }

  private static func makeBuffer(
    format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      ),
      let samples = buffer.floatChannelData?.pointee
    else {
      return nil
    }

    buffer.frameLength = frameCount
    let notes: [(start: Double, frequency: Double, gain: Double)] = [
      (0, 587.33, 0.36),
      (0.028, 739.99, 0.26),
      (0.056, 880, 0.19),
    ]
    for frame in 0..<Int(frameCount) {
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
      samples[frame] = Float(value * 0.045)
    }
    return buffer
  }
}
