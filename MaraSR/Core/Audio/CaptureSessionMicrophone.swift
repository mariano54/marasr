@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Records one microphone through AVCaptureSession. Unlike AVAudioEngine,
/// which opens the default input as soon as its input node exists, this
/// touches only the chosen device and never the output side, so headphones
/// playing music stay in their high-quality profile.
@MainActor
final class CaptureSessionMicrophone {
  var onRuntimeError: ((Error) -> Void)?

  private var session: AVCaptureSession?
  private var receiver: CaptureSampleReceiver?
  private var errorObserver: NSObjectProtocol?
  private let queue = DispatchQueue(
    label: "com.mariano.marasr.capture-session",
    qos: .userInitiated
  )

  var isRunning: Bool {
    session?.isRunning ?? false
  }

  func start(
    device deviceID: AudioDeviceID,
    sampleRate: Double,
    discardingFirst initialDuration: TimeInterval,
    sampleHandler: @escaping AudioCaptureService.SampleHandler
  ) throws {
    guard let uid = AudioDevices.uid(deviceID),
      let device = AVCaptureDevice(uniqueID: uid)
    else {
      throw AudioCaptureError.inputUnavailable
    }
    let session = AVCaptureSession()
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureAudioDataOutput()
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsNonInterleaved: true,
    ]
    guard session.canAddInput(input), session.canAddOutput(output) else {
      throw AudioCaptureError.inputUnavailable
    }
    session.addInput(input)
    session.addOutput(output)

    let receiver = CaptureSampleReceiver(
      samplesToDiscard: Int(sampleRate * initialDuration),
      sampleHandler: sampleHandler
    )
    output.setSampleBufferDelegate(receiver, queue: queue)

    errorObserver = NotificationCenter.default.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification,
      object: session,
      queue: .main
    ) { [weak self] notification in
      let error =
        notification.userInfo?[AVCaptureSessionErrorKey] as? Error
        ?? AudioCaptureError.inputUnavailable
      Task { @MainActor in
        Log.audio.error(
          "Capture session failed: \(String(describing: error), privacy: .public)"
        )
        self?.stop()
        self?.onRuntimeError?(error)
      }
    }

    let startedAt = ContinuousClock.now
    session.startRunning()
    guard session.isRunning else {
      stop()
      throw AudioCaptureError.inputUnavailable
    }
    Log.audio.notice(
      "Capture session running on \(device.localizedName, privacy: .public) after \(String(describing: ContinuousClock.now - startedAt), privacy: .public)"
    )
    self.session = session
    self.receiver = receiver
  }

  func stop() {
    if let errorObserver {
      NotificationCenter.default.removeObserver(errorObserver)
      self.errorObserver = nil
    }
    session?.stopRunning()
    session = nil
    receiver = nil
  }
}

private final class CaptureSampleReceiver: NSObject,
  AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
  private let sampleHandler: AudioCaptureService.SampleHandler
  private var samplesToDiscard: Int

  init(
    samplesToDiscard: Int,
    sampleHandler: @escaping AudioCaptureService.SampleHandler
  ) {
    self.samplesToDiscard = samplesToDiscard
    self.sampleHandler = sampleHandler
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    var samples = Self.samples(in: sampleBuffer)
    if samplesToDiscard > 0 {
      let discardedCount = min(samplesToDiscard, samples.count)
      samples.removeFirst(discardedCount)
      samplesToDiscard -= discardedCount
    }
    guard !samples.isEmpty else {
      return
    }
    sampleHandler(samples, AudioCaptureService.normalizedLevel(samples))
  }

  /// The output is configured as mono float32, so the list holds one buffer.
  private static func samples(in sampleBuffer: CMSampleBuffer) -> [Float] {
    var bufferList = AudioBufferList()
    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: &bufferList,
      bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr,
      let data = bufferList.mBuffers.mData?.assumingMemoryBound(
        to: Float.self
      )
    else {
      return []
    }
    return Array(
      UnsafeBufferPointer(
        start: data,
        count: Int(bufferList.mBuffers.mDataByteSize)
          / MemoryLayout<Float>.size
      )
    )
  }
}
