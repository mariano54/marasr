@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

/// Records one microphone through AVCaptureSession. Unlike AVAudioEngine,
/// which creates a private duplex aggregate device (combining default input
/// and default output) that can wedge AVFAudio after display or audio-device
/// wakeups, AVCaptureSession opens only the chosen input device and tears down
/// completely between dictations.
@MainActor
final class CaptureSessionMicrophone {
  var onRuntimeError: ((Error) -> Void)?

  private let sessionQueue = DispatchQueue(
    label: "com.mariano.marasr.capture-session.lifecycle",
    qos: .userInitiated
  )
  private let sampleQueue = DispatchQueue(
    label: "com.mariano.marasr.capture-session.samples",
    qos: .userInitiated
  )
  private let state = OSAllocatedUnfairLock(initialState: SessionState())

  private struct SessionState: Sendable {
    var generation: UInt64 = 0
    var isRunning = false
    var activeSession: ActiveCaptureSession?
  }

  var isRunning: Bool {
    state.withLock { $0.isRunning }
  }

  /// Starts capturing from the device matching `deviceUniqueID` (or the
  /// system default audio capture device when `deviceUniqueID` is nil).
  /// Runs AVCaptureSession setup and `startRunning()` off the main actor so
  /// Core Audio wakeups never stall the UI or global hotkey event tap.
  func start(
    deviceUniqueID: String?,
    sampleRate: Double,
    discardingFirst initialDuration: TimeInterval,
    sampleHandler: @escaping AudioCaptureService.SampleHandler
  ) async throws {
    let generation = state.withLock { state -> UInt64 in
      state.generation &+= 1
      return state.generation
    }

    let receiver = CaptureSampleReceiver(
      samplesToDiscard: Int(sampleRate * initialDuration),
      sampleHandler: sampleHandler
    )
    let onInterrupted: @Sendable (UInt64, Error) -> Void = {
      [weak self] errorGeneration, error in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        let isCurrent = self.state.withLock {
          $0.generation == errorGeneration
        }
        guard isCurrent else {
          return
        }
        self.stop()
        self.onRuntimeError?(error)
      }
    }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async { [state, sampleQueue] in
        Self.teardownActiveSession(in: state)

        guard state.withLock({ $0.generation == generation }) else {
          receiver.invalidate()
          continuation.resume(returning: ())
          return
        }

        do {
          let device: AVCaptureDevice? =
            if let deviceUniqueID {
              AVCaptureDevice(uniqueID: deviceUniqueID)
            } else {
              AVCaptureDevice.default(for: .audio)
            }
          guard let device else {
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
          output.setSampleBufferDelegate(receiver, queue: sampleQueue)

          let deviceName = device.localizedName
          let runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
          ) { notification in
            let error =
              notification.userInfo?[AVCaptureSessionErrorKey] as? Error
              ?? AudioCaptureError.inputUnavailable
            Log.audio.error(
              "Capture session failed: \(String(describing: error), privacy: .public)"
            )
            onInterrupted(generation, error)
          }

          let disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
          ) { _ in
            Log.audio.error(
              "Capture device disconnected: \(deviceName, privacy: .public)"
            )
            onInterrupted(generation, AudioCaptureError.inputUnavailable)
          }

          let active = ActiveCaptureSession(
            session: session,
            receiver: receiver,
            observers: [runtimeObserver, disconnectObserver]
          )

          let startedAt = ContinuousClock.now
          session.startRunning()

          let stillCurrent = state.withLock { $0.generation == generation }
          guard stillCurrent else {
            active.stop()
            continuation.resume(returning: ())
            return
          }

          guard session.isRunning else {
            active.stop()
            throw AudioCaptureError.inputUnavailable
          }

          state.withLock {
            $0.isRunning = true
            $0.activeSession = active
          }

          Log.audio.notice(
            "Capture session running on \(deviceName, privacy: .public) after \(String(describing: ContinuousClock.now - startedAt), privacy: .public)"
          )
          continuation.resume(returning: ())
        } catch {
          receiver.invalidate()
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func stop() {
    state.withLock {
      $0.generation &+= 1
      $0.isRunning = false
      $0.activeSession?.invalidateReceiver()
    }
    sessionQueue.async { [state] in
      Self.teardownActiveSession(in: state)
    }
  }

  private nonisolated static func teardownActiveSession(
    in state: OSAllocatedUnfairLock<SessionState>
  ) {
    let active = state.withLock { state -> ActiveCaptureSession? in
      let current = state.activeSession
      state.activeSession = nil
      state.isRunning = false
      return current
    }
    active?.stop()
  }
}

private final class ActiveCaptureSession: @unchecked Sendable {
  private let session: AVCaptureSession
  private let receiver: CaptureSampleReceiver
  private let observers: [NSObjectProtocol]

  init(
    session: AVCaptureSession,
    receiver: CaptureSampleReceiver,
    observers: [NSObjectProtocol]
  ) {
    self.session = session
    self.receiver = receiver
    self.observers = observers
  }

  func invalidateReceiver() {
    receiver.invalidate()
  }

  func stop() {
    receiver.invalidate()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    if session.isRunning {
      session.stopRunning()
    }
  }
}

private final class CaptureSampleReceiver: NSObject,
  AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
  private let sampleHandler: AudioCaptureService.SampleHandler
  private let invalidated = OSAllocatedUnfairLock(initialState: false)
  private var samplesToDiscard: Int

  init(
    samplesToDiscard: Int,
    sampleHandler: @escaping AudioCaptureService.SampleHandler
  ) {
    self.samplesToDiscard = samplesToDiscard
    self.sampleHandler = sampleHandler
  }

  func invalidate() {
    invalidated.withLock { $0 = true }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !invalidated.withLock({ $0 }) else {
      return
    }
    var samples = Self.samples(in: sampleBuffer)
    if samplesToDiscard > 0 {
      let discardedCount = min(samplesToDiscard, samples.count)
      samples.removeFirst(discardedCount)
      samplesToDiscard -= discardedCount
    }
    guard !samples.isEmpty, !invalidated.withLock({ $0 }) else {
      return
    }
    sampleHandler(samples, AudioCaptureService.normalizedLevel(samples))
  }

  /// Extracts mono Float32 PCM samples from `sampleBuffer`, keeping the
  /// backing `CMBlockBuffer` retained for the duration of the copy.
  private static func samples(in sampleBuffer: CMSampleBuffer) -> [Float] {
    var bufferList = AudioBufferList()
    var blockBuffer: CMBlockBuffer?
    var requiredSize = 0
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &requiredSize,
      bufferListOut: &bufferList,
      bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &blockBuffer
    )
    if status == noErr {
      return withExtendedLifetime(blockBuffer) {
        guard bufferList.mNumberBuffers >= 1,
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

    guard status == kCMSampleBufferError_ArrayTooSmall, requiredSize > 0 else {
      return []
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: requiredSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let retryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: listPointer,
      bufferListSize: requiredSize,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &blockBuffer
    )
    guard retryStatus == noErr else {
      return []
    }
    return withExtendedLifetime(blockBuffer) {
      let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
      guard let first = buffers.first,
        let data = first.mData?.assumingMemoryBound(to: Float.self)
      else {
        return []
      }
      return Array(
        UnsafeBufferPointer(
          start: data,
          count: Int(first.mDataByteSize) / MemoryLayout<Float>.size
        )
      )
    }
  }
}
