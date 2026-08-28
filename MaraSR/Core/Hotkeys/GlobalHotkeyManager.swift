import AppKit
@preconcurrency import CoreGraphics
import Foundation

@MainActor
final class GlobalHotkeyManager {
  var onHoldChanged: ((Bool) -> Void)?
  var onPasteLast: (() -> Void)?

  private var holdConfiguration: HotkeyConfiguration = .holdToTalk
  private var pasteConfiguration: HotkeyConfiguration = .pasteLast
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var holdIsDown = false
  private var pasteModifierIsDown = false
  private var pasteRegularIsDown = false
  private var captureHandler: ((HotkeyConfiguration) -> Void)?
  private var capturedModifierKeyCode: UInt16?

  func configure(
    holdToTalk: HotkeyConfiguration,
    pasteLast: HotkeyConfiguration
  ) {
    holdConfiguration = holdToTalk
    pasteConfiguration = pasteLast
  }

  func start() throws {
    guard eventTap == nil else {
      return
    }
    let mask =
      CGEventMask(1 << CGEventType.flagsChanged.rawValue)
      | CGEventMask(1 << CGEventType.keyDown.rawValue)
      | CGEventMask(1 << CGEventType.keyUp.rawValue)

    guard
      let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: Self.eventCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      throw GlobalHotkeyError.eventTapUnavailable
    }

    let source = CFMachPortCreateRunLoopSource(
      kCFAllocatorDefault,
      tap,
      0
    )
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      source,
      .commonModes
    )
    eventTap = tap
    runLoopSource = source
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func stop() {
    if let runLoopSource {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        runLoopSource,
        .commonModes
      )
    }
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
    runLoopSource = nil
    eventTap = nil
    holdIsDown = false
    pasteModifierIsDown = false
    pasteRegularIsDown = false
  }

  func captureNext(
    completion: @escaping (HotkeyConfiguration) -> Void
  ) {
    captureHandler = completion
    capturedModifierKeyCode = nil
  }

  func cancelCapture() {
    captureHandler = nil
    capturedModifierKeyCode = nil
  }

  private static let eventCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else {
      return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<GlobalHotkeyManager>
      .fromOpaque(userInfo)
      .takeUnretainedValue()

    return MainActor.assumeIsolated {
      manager.handle(type: type, event: event)
      return Unmanaged.passUnretained(event)
    }
  }

  private func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if holdIsDown {
        holdIsDown = false
        onHoldChanged?(false)
      }
      pasteModifierIsDown = false
      pasteRegularIsDown = false
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return
    }

    if captureHandler != nil, capture(type: type, event: event) {
      return
    }

    let keyCode = UInt16(
      event.getIntegerValueField(.keyboardEventKeycode)
    )

    if holdConfiguration.modifierOnly,
      type == .flagsChanged,
      keyCode == holdConfiguration.keyCode
    {
      holdIsDown.toggle()
      onHoldChanged?(holdIsDown)
      return
    }

    if !holdConfiguration.modifierOnly,
      keyCode == holdConfiguration.keyCode
    {
      if type == .keyDown,
        event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
        normalizedModifiers(event.flags.rawValue)
          == holdConfiguration.modifierFlags,
        !holdIsDown
      {
        holdIsDown = true
        onHoldChanged?(true)
        return
      }
      if type == .keyUp, holdIsDown {
        holdIsDown = false
        onHoldChanged?(false)
        return
      }
    }

    if pasteConfiguration.modifierOnly,
      type == .flagsChanged,
      keyCode == pasteConfiguration.keyCode
    {
      pasteModifierIsDown.toggle()
      if !pasteModifierIsDown {
        onPasteLast?()
      }
      return
    }

    guard !pasteConfiguration.modifierOnly,
      keyCode == pasteConfiguration.keyCode
    else {
      return
    }
    if type == .keyDown,
      event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
      normalizedModifiers(event.flags.rawValue)
        == pasteConfiguration.modifierFlags
    {
      pasteRegularIsDown = true
      return
    }
    if type == .keyUp, pasteRegularIsDown {
      pasteRegularIsDown = false
      onPasteLast?()
    }
  }

  private func capture(type: CGEventType, event: CGEvent) -> Bool {
    let keyCode = UInt16(
      event.getIntegerValueField(.keyboardEventKeycode)
    )

    if type == .flagsChanged {
      if capturedModifierKeyCode == nil {
        capturedModifierKeyCode = keyCode
        return true
      }
      guard capturedModifierKeyCode == keyCode,
        let configuration = modifierConfiguration(
          keyCode: keyCode
        )
      else {
        return true
      }
      finishCapture(configuration)
      return true
    }

    guard type == .keyDown,
      event.getIntegerValueField(.keyboardEventAutorepeat) == 0
    else {
      return true
    }
    let modifiers = normalizedModifiers(event.flags.rawValue)
    let configuration = HotkeyConfiguration(
      keyCode: keyCode,
      modifierFlags: modifiers,
      modifierOnly: false,
      displayName: displayName(
        keyCode: keyCode,
        modifiers: modifiers
      )
    )
    finishCapture(configuration)
    return true
  }

  private func finishCapture(_ configuration: HotkeyConfiguration) {
    let completion = captureHandler
    captureHandler = nil
    capturedModifierKeyCode = nil
    completion?(configuration)
  }

  private func modifierConfiguration(
    keyCode: UInt16
  ) -> HotkeyConfiguration? {
    let values: [UInt16: (UInt64, String)] = [
      54: (CGEventFlags.maskCommand.rawValue, "Right Command"),
      55: (CGEventFlags.maskCommand.rawValue, "Left Command"),
      58: (CGEventFlags.maskAlternate.rawValue, "Left Option"),
      61: (CGEventFlags.maskAlternate.rawValue, "Right Option"),
      59: (CGEventFlags.maskControl.rawValue, "Left Control"),
      62: (CGEventFlags.maskControl.rawValue, "Right Control"),
      56: (CGEventFlags.maskShift.rawValue, "Left Shift"),
      60: (CGEventFlags.maskShift.rawValue, "Right Shift"),
    ]
    guard let (flags, name) = values[keyCode] else {
      return nil
    }
    return HotkeyConfiguration(
      keyCode: keyCode,
      modifierFlags: flags,
      modifierOnly: true,
      displayName: name
    )
  }

  private func displayName(
    keyCode: UInt16,
    modifiers: UInt64
  ) -> String {
    var parts: [String] = []
    if modifiers & CGEventFlags.maskControl.rawValue != 0 {
      parts.append("Control")
    }
    if modifiers & CGEventFlags.maskAlternate.rawValue != 0 {
      parts.append("Option")
    }
    if modifiers & CGEventFlags.maskShift.rawValue != 0 {
      parts.append("Shift")
    }
    if modifiers & CGEventFlags.maskCommand.rawValue != 0 {
      parts.append("Command")
    }
    parts.append(Self.keyNames[keyCode] ?? "Key \(keyCode)")
    return parts.joined(separator: "–")
  }

  private func normalizedModifiers(_ rawValue: UInt64) -> UInt64 {
    rawValue
      & (CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskShift.rawValue)
  }

  private static let keyNames: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
    7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
    14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
    34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N",
    46: "M", 49: "Space", 51: "Delete", 53: "Escape",
  ]
}

enum GlobalHotkeyError: LocalizedError {
  case eventTapUnavailable

  var errorDescription: String? {
    "MaraSR could not start the global hotkey listener. Grant Accessibility permission, then recheck."
  }
}
