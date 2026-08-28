@preconcurrency import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
  case inputUnavailable
  case converterUnavailable
  case conversionFailed

  var errorDescription: String? {
    switch self {
    case .inputUnavailable:
      "No microphone input is available."
    case .converterUnavailable:
      "The microphone audio format could not be converted."
    case .conversionFailed:
      "Microphone audio conversion failed."
    }
  }
}

@MainActor
final class AudioCaptureService {
  typealias SampleHandler = @Sendable (_ samples: [Float], _ level: Float) -> Void

  private let engine = AVAudioEngine()
  private var processor: AudioTapProcessor?

  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )

  var isRunning: Bool {
    engine.isRunning
  }

  func start(
    discardingFirst initialDuration: TimeInterval = 0,
    sampleHandler: @escaping SampleHandler
  ) throws {
    guard !engine.isRunning else {
      return
    }
    guard let targetFormat else {
      throw AudioCaptureError.converterUnavailable
    }

    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw AudioCaptureError.inputUnavailable
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
    self.processor = processor
    processor.installTap(on: input, format: inputFormat)

    engine.prepare()
    try engine.start()
  }

  func stop() {
    guard engine.isRunning else {
      return
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    processor = nil
  }
}

private final class AudioTapProcessor: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let targetFormat: AVAudioFormat
  private let sampleHandler: AudioCaptureService.SampleHandler
  private var samplesToDiscard: Int

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
      return
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
