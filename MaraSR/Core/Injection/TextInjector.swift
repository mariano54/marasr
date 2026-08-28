import AppKit
import CoreGraphics
import Foundation

struct InjectionTarget: Equatable, Sendable {
  let processIdentifier: pid_t
  let applicationName: String
}

@MainActor
final class TextInjector {
  func currentTarget() -> InjectionTarget? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      return nil
    }
    return InjectionTarget(
      processIdentifier: application.processIdentifier,
      applicationName: application.localizedName ?? "Unknown app"
    )
  }

  func inject(
    _ text: String,
    into target: InjectionTarget?
  ) async throws {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else {
      throw TextInjectionError.emptyText
    }

    if let target,
      let application = NSRunningApplication(
        processIdentifier: target.processIdentifier
      )
    {
      application.activate(options: [])
      try await Task.sleep(for: .milliseconds(80))
    }

    let pasteboard = NSPasteboard.general
    let snapshot = snapshot(pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(cleaned, forType: .string) else {
      throw TextInjectionError.pasteboardUnavailable
    }
    let injectedChangeCount = pasteboard.changeCount

    guard let source = CGEventSource(stateID: .hidSystemState),
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: 9,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: 9,
        keyDown: false
      )
    else {
      restore(snapshot, to: pasteboard)
      throw TextInjectionError.eventCreationFailed
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)

    try await Task.sleep(for: .milliseconds(250))
    if pasteboard.changeCount == injectedChangeCount {
      restore(snapshot, to: pasteboard)
    }
  }

  private func snapshot(
    _ pasteboard: NSPasteboard
  ) -> [[NSPasteboard.PasteboardType: Data]] {
    (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(
        uniqueKeysWithValues: item.types.compactMap { type in
          item.data(forType: type).map { (type, $0) }
        }
      )
    }
  }

  private func restore(
    _ snapshot: [[NSPasteboard.PasteboardType: Data]],
    to pasteboard: NSPasteboard
  ) {
    pasteboard.clearContents()
    let items = snapshot.map { values in
      let item = NSPasteboardItem()
      for (type, data) in values {
        item.setData(data, forType: type)
      }
      return item
    }
    if !items.isEmpty {
      pasteboard.writeObjects(items)
    }
  }
}

enum TextInjectionError: LocalizedError {
  case emptyText
  case pasteboardUnavailable
  case eventCreationFailed

  var errorDescription: String? {
    switch self {
    case .emptyText:
      "There is no transcription to paste."
    case .pasteboardUnavailable:
      "The system clipboard is unavailable."
    case .eventCreationFailed:
      "MaraSR could not create a paste event."
    }
  }
}
