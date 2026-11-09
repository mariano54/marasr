import AudioToolbox
import CoreAudio
import Foundation

/// Small Core Audio lookups for picking the capture device and reading or
/// setting the output volume.
enum AudioDevices {
  static var defaultInput: AudioDeviceID? {
    systemDevice(kAudioHardwarePropertyDefaultInputDevice)
  }

  static var defaultOutput: AudioDeviceID? {
    systemDevice(kAudioHardwarePropertyDefaultOutputDevice)
  }

  /// The Mac's own microphone, if one is present (absent when a laptop
  /// lid is closed).
  static var builtInInput: AudioDeviceID? {
    allDevices.first {
      transportType($0) == kAudioDeviceTransportTypeBuiltIn
        && hasInputStreams($0)
    }
  }

  static func isBluetooth(_ device: AudioDeviceID) -> Bool {
    let transport = transportType(device)
    return transport == kAudioDeviceTransportTypeBluetooth
      || transport == kAudioDeviceTransportTypeBluetoothLE
  }

  static func name(_ device: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
      device, &address, 0, nil, &size, &name
    )
    guard status == noErr, let name else {
      return "device \(device)"
    }
    return name.takeRetainedValue() as String
  }

  static func uid(_ device: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
      device, &address, 0, nil, &size, &uid
    )
    guard status == noErr, let uid else {
      return nil
    }
    return uid.takeRetainedValue() as String
  }

  static func device(uid: String) -> AudioDeviceID? {
    allDevices.first { Self.uid($0) == uid }
  }

  /// The output volume slider value, 0...1, or nil when the device has no
  /// software volume (e.g. some HDMI and USB outputs).
  static func outputVolume(_ device: AudioDeviceID) -> Float? {
    var address = volumeAddress
    guard AudioObjectHasProperty(device, &address) else {
      return nil
    }
    var volume = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(
      device, &address, 0, nil, &size, &volume
    )
    return status == noErr ? volume : nil
  }

  @discardableResult
  static func setOutputVolume(
    _ volume: Float,
    on device: AudioDeviceID
  ) -> Bool {
    var address = volumeAddress
    var settable = DarwinBoolean(false)
    guard
      AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
      settable.boolValue
    else {
      return false
    }
    var value = Float32(min(1, max(0, volume)))
    let status = AudioObjectSetPropertyData(
      device,
      &address,
      0,
      nil,
      UInt32(MemoryLayout<Float32>.size),
      &value
    )
    return status == noErr
  }

  private static let volumeAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
  )

  private static var allDevices: [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(0)
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
      ) == noErr
    else {
      return []
    }
    var devices = [AudioDeviceID](
      repeating: 0,
      count: Int(size) / MemoryLayout<AudioDeviceID>.size
    )
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &devices
      ) == noErr
    else {
      return []
    }
    return devices
  }

  private static func systemDevice(
    _ selector: AudioObjectPropertySelector
  ) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &device
    )
    guard status == noErr, device != kAudioObjectUnknown else {
      return nil
    }
    return device
  }

  private static func transportType(_ device: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transport = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
    return transport
  }

  private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(0)
    let status = AudioObjectGetPropertyDataSize(
      device, &address, 0, nil, &size
    )
    return status == noErr && size > 0
  }
}
