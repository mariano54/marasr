@preconcurrency import AVFoundation

@MainActor
final class ListeningCuePlayer {
  private static let sampleRate = 48_000.0
  private static let duration = 0.18

  private var engine = AVAudioEngine()
  private var player = AVAudioPlayerNode()
  private let format = AVAudioFormat(
    standardFormatWithSampleRate: sampleRate,
    channels: 1
  )
  private let buffer: AVAudioPCMBuffer?
  private var stopTask: Task<Void, Never>?
  private var configurationObserver: NSObjectProtocol?
  private var engineIsStale = false

  init() {
    buffer = format.flatMap(Self.makeBuffer)
    configureEngine()
  }

  func play() {
    guard let buffer else {
      return
    }
    stopTask?.cancel()
    if engineIsStale {
      rebuildEngine(reason: "configuration changed since last use")
    }
    do {
      try schedule(buffer)
    } catch {
      rebuildEngine(reason: "cue playback failed")
      do {
        try schedule(buffer)
      } catch {
        // The cue is cosmetic; dictation goes ahead without it.
        Log.audio.error(
          "Listening cue skipped: \(String(describing: error), privacy: .public)"
        )
        engineIsStale = true
        return
      }
    }
    stopTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(240))
      guard !Task.isCancelled else {
        return
      }
      self?.player.stop()
      self?.engine.stop()
    }
  }

  private func schedule(_ buffer: AVAudioPCMBuffer) throws {
    let engine = engine
    let player = player
    try ObjCException.catching("listening cue", log: Log.audio) {
      player.stop()
      if !engine.isRunning {
        try engine.start()
      }
      player.scheduleBuffer(buffer, at: nil, options: .interrupts)
      player.play()
    }
  }

  private func configureEngine() {
    let engine = engine
    let player = player
    let format = format
    do {
      try ObjCException.catching("listening cue setup", log: Log.audio) {
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
    } catch {
      engineIsStale = true
    }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        Log.audio.notice("Output configuration changed; cue engine will be rebuilt")
        self?.engineIsStale = true
      }
    }
  }

  private func rebuildEngine(reason: String) {
    Log.audio.notice(
      "Rebuilding cue engine: \(reason, privacy: .public)"
    )
    stopTask?.cancel()
    player.stop()
    engine.stop()
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    engine = AVAudioEngine()
    player = AVAudioPlayerNode()
    engineIsStale = false
    configureEngine()
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
