import CoreGraphics
import Foundation

struct HotkeyConfiguration: Codable, Equatable, Sendable {
  let keyCode: UInt16
  let modifierFlags: UInt64
  let modifierOnly: Bool
  let displayName: String

  static let holdToTalk = HotkeyConfiguration(
    keyCode: 54,
    modifierFlags: CGEventFlags.maskCommand.rawValue,
    modifierOnly: true,
    displayName: "Right Command"
  )

  static let pasteLast = HotkeyConfiguration(
    keyCode: 9,
    modifierFlags: (CGEventFlags.maskControl.rawValue
      | CGEventFlags.maskAlternate.rawValue),
    modifierOnly: false,
    displayName: "Control–Option–V"
  )
}
